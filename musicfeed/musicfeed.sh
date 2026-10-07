#!/bin/bash
# ─────────────────────────────────────────────
# musicfeed V4.1
# v4.0: 打标签/内嵌封面从 python3+mutagen 迁移到 ffmpeg；
#       json 解析/电台歌名提取从 python3 迁移到 jq + 纯 bash（彻底不再依赖 python3）
# v4.0.8: 并发加固——worker 临时文件 PID 化（temp_$$_mv_*，彻底消除同文件夹多任务
#         互抢 temp/info.json）；每个专辑目录 flock 互斥（根治 yt-dlp 同名 .part
#         互写损坏，MF_FLOCK_TIMEOUT 可调）；交互段每链接重置 SELECTION/SELECTED_COUNT
#         （修复多链接时单曲继承上一链接计数、TOTAL_SELECTED 双重累加）
# v4.1: 选号解析加固——xargs → 参数展开去空白，空结果不再当作"全选"（INVALID:empty）；
#       m_parse_sel 非法/越界片段整体失败 + 数字层重试；目录列举改 find -L -print0
#       （软链接目录可见、防换行名撕裂）；封面配对修复——文件名截断改 yt-dlp 模板层
#       （长"歌手 - 歌名"下 audio 与 info.json 基名失配致封面静默丢失），
#       embed_cover artist 标签优先取 JSON 元数据（原从文件名拆分）
# ─────────────────────────────────────────────

# 中文等多字节字符的 grep/sed 正则匹配、wc -m 字符计数都依赖 UTF-8 locale，
# 系统默认 locale 不确定时（很多精简容器是 C/POSIX），强制指定一个保证可用
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=en_US.UTF-8 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 加载纯函数库（配置加载、常量、工具函数、yt-dlp 元数据抓取、链接类型检测）
# shellcheck disable=SC1091
source "$SCRIPT_DIR/mf_lib.sh"

echo "=================================================="
echo " 🎵 musicfeed V4.1"
echo "=================================================="
say "支持: 专辑 / 播放列表 / YTM电台 / 单曲" "Supports: albums / playlists / YTM radios / singles"
echo "=================================================="

display_paged_list() {
    local -a items=("$@")
    local total=${#items[@]}
    [ "$total" -eq 0 ] && return 0
    local term_lines=$(get_term_lines)
    local page_size=$((term_lines - 6))
    [ "$page_size" -lt 5 ] && page_size=10
    local total_pages=$(( (total - 1) / page_size + 1 ))
    local page=0

    while true; do
        local start=$((page * page_size))
        local end=$((start + page_size))
        [ "$end" -gt "$total" ] && end=$total

        for ((i=start; i<end; i++)); do
            printf "%s\n" "${items[$i]}"
        done

        if [ "$end" -ge "$total" ]; then
            return 0
        fi

        echo ""
        if is_en; then
            echo "━━━━ Page $((page+1))/$total_pages | Enter=next, q=quit ━━━━"
        else
            echo "━━━━ 第 $((page+1))/$total_pages 页 | 回车继续, q退出 ━━━━"
        fi
        read -r -n 1 key < /dev/tty
        echo ""

        if [[ "$key" =~ ^[Qq]$ ]]; then
            return 1
        fi
        page=$((page + 1))
    done
}

select_artist_folder() {
    local prompt_suffix="$1"
    local folders=()
    folders+=("$MF_DEFAULT_ARTIST_DIR")

    # v4.0.x: 用 find -L -print0 取代 ls -F | grep '/$'（后者在 Linux 上漏掉软链接目录，
    # 且被含换行的目录名撕裂）。! -name '.*' 保持与 ls 一致（不列点开头目录）。
    local _entry
    while IFS= read -r -d '' _entry; do
        line="${_entry##*/}"
        [[ "$line" == *$'\n'* ]] && continue   # 含换行的目录名无法安全进入菜单/勾选列表，跳过
        [[ "$line" == "$MF_DEFAULT_ARTIST_DIR" ]] && continue
        local hidden=0
        for h in "${MF_HIDDEN_DIRS[@]}"; do
            [[ "$line" == "$h" ]] && hidden=1 && break
        done
        [ $hidden -eq 1 ] && continue
        folders+=("$line")
    done < <(find -L "$MF_BASE_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 2>/dev/null | sort -z)

    local items=() i
    for i in "${!folders[@]}"; do
        if [ "$i" -eq 0 ]; then
            is_en && items+=("📁 ${folders[$i]} (default)") || items+=("📁 ${folders[$i]} （默认）")
        else
            items+=("📁 ${folders[$i]}")
        fi
    done
    items+=("➕ $(is_en && echo 'Create new folder…' || echo '新建文件夹…')")

    local sel rc
    sel=$(ui_menu "$(is_en && echo "📂 Select artist folder${prompt_suffix}" || echo "📂 请选择歌手文件夹${prompt_suffix}")" "" 1 "${items[@]}")
    rc=$?
    [ $rc -ne 0 ] && return 255

    if [ "$sel" -eq "${#items[@]}" ]; then
        local nn
        nn=$(ui_input "$(is_en && echo 'New folder name' || echo '新文件夹名称')" "")
        [ $? -ne 0 ] && return 255
        [ -n "$nn" ] || nn="$MF_DEFAULT_ARTIST_DIR"
        echo "$nn"
    else
        echo "${folders[$((sel-1))]}"
    fi
}

input_album_artist() {
    local default_name="$1" sel rc o1 o2 o3
    if is_en; then
        o1="Use default: $default_name"
        o2="Skip (don't write album artist)"
        o3="Custom input…"
    else
        o1="使用默认值「$default_name」"
        o2="跳过（不写入专辑艺术家）"
        o3="自定义输入…"
    fi
    sel=$(ui_menu "$(is_en && echo '🎤 Album Artist' || echo '🎤 专辑艺术家')" "" 1 "$o1" "$o2" "$o3")
    rc=$?
    [ $rc -ne 0 ] && return 255
    case "$sel" in
        1) say "✅ 专辑艺术家: $default_name（默认）" "✅ Album artist: $default_name (default)"; echo "$default_name" ;;
        2) say "⏭️ 跳过专辑艺术家" "⏭️ Album artist skipped"; echo "SKIP" ;;
        3)
            local v
            v=$(ui_input "$(is_en && echo 'Album artist' || echo '专辑艺术家')" "$default_name")
            [ $? -ne 0 ] && return 255
            v=$(echo "$v" | sed 's/|/｜/g')
            say "✅ 专辑艺术家: $v（自定义）" "✅ Album artist: $v (custom)"
            echo "$v"
            ;;
    esac
}

input_mv_full() {
    local default_title="$1" default_artist="$2" raw_title="${3:-}" t a al
    local hint=""
    [ -n "$raw_title" ] && hint="🎬 ${raw_title:0:70}"
    t=$(ui_input "$(is_en && echo '🎤 Title' || echo '🎤 歌名')" "$default_title" "$hint")
    [ $? -ne 0 ] && return 255
    a=$(ui_input "$(is_en && echo '👤 Artist' || echo '👤 歌手')" "$default_artist" "$hint")
    [ $? -ne 0 ] && return 255
    al=$(ui_input "$(is_en && echo '💿 Album (Enter = same as title)' || echo '💿 专辑（回车=同歌名）')" "$t" "$hint")
    [ $? -ne 0 ] && return 255
    t=$(echo "$t" | sed 's/|/｜/g; s/=/＝/g')
    a=$(echo "$a" | sed 's/|/｜/g; s/=/＝/g')
    al=$(echo "$al" | sed 's/|/｜/g; s/=/＝/g')
    echo "${t}|${a}|${al}"
}

echo ""
say "请粘贴链接（一行一条），空行或输入 end 开始：" "Paste links, one per line. Submit an empty line or type end to start:"

URLS=()
while true; do
    read -r line
    [[ "$line" == "end" ]] && break
    [[ -z "$line" ]] && break
    URLS+=("$line")
    [ ${#URLS[@]} -ge $MF_MAX_LINKS_PER_RUN ] && { say "⚠️ 已达上限" "⚠️ Link limit reached"; break; }
done

[ ${#URLS[@]} -eq 0 ] && { say "❌ 未检测到链接" "❌ No links detected"; exit 1; }

echo ""
say "🔍 检测链接类型..." "🔍 Detecting link types..."

VALID_URLS=(); URL_TYPES=(); URL_NAMES=()
for url in "${URLS[@]}"; do
    TYPE=$(get_link_type "$url")
    if [ "$TYPE" != "unknown" ]; then
        VALID_URLS+=("$url"); URL_TYPES+=("$TYPE")
        case "$TYPE" in
            album) if is_en; then N="Album"; else N="专辑"; fi;;
            playlist) if is_en; then N="Playlist"; else N="播放列表"; fi;;
            ytm_radio) if is_en; then N="YTM Radio"; else N="YTM电台"; fi;;
            single) if is_en; then N="Single"; else N="单曲"; fi;;
        esac
        URL_NAMES+=("$N")
        echo "✅ $N: $url"
    else
        if is_en; then echo "⚠️ Skipping invalid link: $url"; else echo "⚠️ 跳过无效: $url"; fi
    fi
done

[ ${#VALID_URLS[@]} -eq 0 ] && { say "❌ 没有有效链接" "❌ No valid links"; exit 1; }

echo ""
if is_en; then echo "📊 Valid links: ${#VALID_URLS[@]}"; else echo "📊 有效链接: ${#VALID_URLS[@]} 个"; fi

declare -a ALBUM_CONFIGS
TOTAL_SELECTED=0

for idx in "${!VALID_URLS[@]}"; do
    url="${VALID_URLS[$idx]}"; TYPE="${URL_TYPES[$idx]}"

    echo ""
    echo "=========================================="
    if is_en; then echo "🔍 Fetching info: ${URL_NAMES[$idx]}"; else echo "🔍 获取信息: ${URL_NAMES[$idx]}"; fi
    echo "=========================================="

    IS_SINGLE=false; IS_PLAYLIST=false; IS_ALBUM=false; IS_YTM_RADIO=false
    HAS_METADATA="False"; DISPLAY_NAME=""; TRACK_COUNT=0; DISPLAY_ARTIST=""
    SONG_LIST=""; SONG_LIST_FULL=""
    MV_TITLE=""; MV_ARTIST=""; MV_ALBUM=""; MV_ALBUM_ARTIST=""
    BATCH_ALBUM=""; NORMAL_SELECTION=""; MV_VIDS=""; MV_INFO=""; MV_STRATEGY=""
    # v4.0.8: 每链接重置选曲状态——单曲链接（TRACK_COUNT=1 不进 tracks 步骤）此前
    # 会继承上一链接的残留值：TOTAL_SELECTED 双重累加（可误触 150 上限跳过链接）、
    # 残留 SELECTION 写进配置字段 2，worker 对带元数据单曲拼出 --playlist-items <残留>
    SELECTION=""; SELECTED_COUNT=0

    if [ "$TYPE" == "album" ]; then
        IS_ALBUM=true; HAS_METADATA="True"
        INFO=$(get_album_info "$url")
        DISPLAY_NAME=$(echo "$INFO" | sed -n '1p'); TRACK_COUNT=$(echo "$INFO" | sed -n '2p')
        [[ "$TRACK_COUNT" =~ ^[0-9]+$ ]] || TRACK_COUNT=0
        DISPLAY_ARTIST=$(echo "$INFO" | sed -n '3p'); SONG_LIST=$(echo "$INFO" | tail -n +4)
    elif [ "$TYPE" == "ytm_radio" ]; then
        IS_YTM_RADIO=true
        INFO=$(get_playlist_info "$url")
        DISPLAY_NAME=$(echo "$INFO" | sed -n '1p'); TRACK_COUNT=$(echo "$INFO" | sed -n '2p')
        [[ "$TRACK_COUNT" =~ ^[0-9]+$ ]] || TRACK_COUNT=0
        SONG_LIST_FULL=$(echo "$INFO" | tail -n +3); SONG_LIST=$(echo "$SONG_LIST_FULL" | sed 's/|.*//')
    elif [ "$TYPE" == "playlist" ]; then
        IS_PLAYLIST=true
        INFO=$(get_playlist_info "$url")
        DISPLAY_NAME=$(echo "$INFO" | sed -n '1p'); TRACK_COUNT=$(echo "$INFO" | sed -n '2p')
        [[ "$TRACK_COUNT" =~ ^[0-9]+$ ]] || TRACK_COUNT=0
        SONG_LIST_FULL=$(echo "$INFO" | tail -n +3); SONG_LIST=$(echo "$SONG_LIST_FULL" | sed 's/|.*//')
    else
        IS_SINGLE=true
        SINGLE_INFO=$(get_single_info "$url")
        SINGLE_ALBUM=$(echo "$SINGLE_INFO" | sed -n '1p'); SINGLE_TITLE=$(echo "$SINGLE_INFO" | sed -n '2p')
        SINGLE_ARTIST=$(echo "$SINGLE_INFO" | sed -n '3p'); SINGLE_UPLOADER=$(echo "$SINGLE_INFO" | sed -n '4p')
        HAS_METADATA=$(echo "$SINGLE_INFO" | sed -n '5p')
        DISPLAY_NAME="${SINGLE_ALBUM:-$SINGLE_TITLE}"; DISPLAY_ARTIST="${SINGLE_ARTIST:-$SINGLE_UPLOADER}"
        SONG_LIST="1. $SINGLE_TITLE"; TRACK_COUNT=1
    fi

    [ -z "$DISPLAY_NAME" ] && { say "⚠️ 无法获取信息，跳过" "⚠️ Could not fetch info, skipping"; continue; }

    # v4.0.8: 单曲固定计 1 首——tracks 步骤只对 TRACK_COUNT>1 的链接运行，
    # 不进选曲步骤的链接 SELECTED_COUNT 若不在此补记将恒为 0（统计失真、上限判断漏算）。
    # v4.1: 条件从 IS_SINGLE 放宽到 TRACK_COUNT=1——单曲目专辑/播放列表/电台
    # 同样不进选曲步骤，此前同样少计 1 首（单曲链接的 TRACK_COUNT 恒为 1，行为不变）
    [ "$TRACK_COUNT" -eq 1 ] && SELECTED_COUNT=1

    if [ "$TRACK_COUNT" -gt 100 ]; then
        if is_en; then
            echo "⚠️ Note: Playlist has $TRACK_COUNT tracks. If it cannot be fetched/displayed in full, re-run mf_setup.sh and switch yt-dlp to the NIGHTLY version."
        else
            echo "⚠️ 提示: 播放列表共 $TRACK_COUNT 首。如遇不能完整显示/抓取，重新运行 mf_setup.sh 切换 yt-dlp 到 nightly 版即可。"
        fi
    fi

    SAFE_NAME=$(sanitize_filename "$DISPLAY_NAME")

    echo ""
    if is_en; then echo "📀 Item: $SAFE_NAME"; else echo "📀 项目: $SAFE_NAME"; fi
    [ -n "$DISPLAY_ARTIST" ] && [ "$DISPLAY_ARTIST" != "Unknown Artist" ] && { if is_en; then echo "🎤 Artist: $DISPLAY_ARTIST"; else echo "🎤 歌手: $DISPLAY_ARTIST"; fi; }
    if is_en; then echo "🎵 Tracks: $TRACK_COUNT"; else echo "🎵 曲目数: $TRACK_COUNT"; fi

    [ "$IS_ALBUM" == true ] && { if is_en; then echo "📌 Type: YTM album"; else echo "📌 类型: 正规专辑"; fi; }
    [ "$IS_YTM_RADIO" == true ] && { if is_en; then echo "📌 Type: YTM radio/mix"; else echo "📌 类型: YTM 电台/合集"; fi; }
    [ "$IS_PLAYLIST" == true ] && { if is_en; then echo "📌 Type: YouTube playlist"; else echo "📌 类型: YouTube 播放列表"; fi; }
    [ "$IS_SINGLE" == true ] && {
        if [ "$HAS_METADATA" == "True" ]; then
            if is_en; then echo "🔧 Type: audio single"; else echo "🔧 类型: 纯音频单曲"; fi;
        else
            if is_en; then echo "🎬 Type: MV single"; else echo "🎬 类型: MV 单曲"; fi;
        fi
    }

    # ═══ v3.3 步骤式交互（whiptail/方向键/数字三层 UI，可回退上一步）═══
    ALBUM_ARTIST=""; ENHANCED_MODE=false
    if [ "$IS_ALBUM" != true ]; then
        ENHANCED_MODE=true
        [ "$IS_YTM_RADIO" == true ] && say "📌 YTM 电台：自动使用独立封面模式" "📌 YTM radio: per-track cover mode automatically"
    fi

    step_pl_type() {
        local t1 t2 sel pos
        pos="$((idx+1))/${#VALID_URLS[@]}"
        if is_en; then t1="YouTube video playlist (MV mode)"; t2="YouTube Music user playlist (per-track mode)"
        else t1="YouTube 视频播放列表（MV 模式）"; t2="YouTube Music 用户自建播放列表（独立封面模式）"; fi
        sel=$(ui_menu "$(is_en && echo "🎬 Playlist type [$pos]: $DISPLAY_NAME" || echo "🎬 播放列表类型 [$pos]：《$DISPLAY_NAME》")" "" 1 "$t1" "$t2")
        [ $? -ne 0 ] && return 1
        if [ "$sel" = "2" ]; then
            IS_PLAYLIST=false; IS_YTM_RADIO=true; TYPE="ytm_radio"
            say "📌 已切换为: YTM 电台/合集模式" "📌 Switched to: YTM radio/mix mode"
        else
            say "📌 使用: MV 模式" "📌 Using: MV mode"
        fi
        return 0
    }

    step_path() {
        ARTIST_DIR=$(select_artist_folder " (《$SAFE_NAME》)")
        [ $? -ne 0 ] && return 1
        ARTIST_PATH="$MF_BASE_DIR/$ARTIST_DIR"
        FINAL_PATH="$ARTIST_PATH"
        local create_subfolder default_subfolder SUB rc
        default_subfolder="$SAFE_NAME"
        # v4.1: 单曲/MV 单曲默认不建子文件夹（列表/专辑/电台默认建），对齐 WebUI 策略
        create_subfolder=y
        [ "$IS_SINGLE" == true ] && create_subfolder=n
        ui_confirm "$(is_en && echo "Create subfolder 《$default_subfolder》?" || echo "创建子文件夹《$default_subfolder》？")" "$create_subfolder"
        rc=$?
        [ $rc -eq 255 ] && return 1
        if [ $rc -eq 0 ]; then
            SUB=$(ui_input "$(is_en && echo '📂 Custom subfolder (Enter = default name)' || echo '📂 自定义子文件夹（回车=默认名称）')" "$default_subfolder")
            [ $? -ne 0 ] && return 1
            [ -n "$SUB" ] || SUB="$default_subfolder"
            local SAFE_SUB
            SAFE_SUB=$(sanitize_filename "$SUB")
            [ -n "$SAFE_SUB" ] && FINAL_PATH="$FINAL_PATH/$SAFE_SUB"
        fi
        mkdir -p "$FINAL_PATH"
        say "✅ 路径: $FINAL_PATH" "✅ Path: $FINAL_PATH"
        return 0
    }

    step_album_opts() {
        local AA_RESULT
        AA_RESULT=$(input_album_artist "$ARTIST_DIR")
        [ $? -ne 0 ] && return 1
        [ "$AA_RESULT" != "SKIP" ] && ALBUM_ARTIST="$AA_RESULT"
        local c1 c2 sel
        if is_en; then c1="Unified cover (one album cover)"; c2="Per-track covers (each song its own)"
        else c1="统一封面（整张专辑一张封面）"; c2="独立封面（每首各自封面）"; fi
        sel=$(ui_menu "$(is_en && echo '🖼️ Cover mode' || echo '🖼️ 封面模式')" "" 1 "$c1" "$c2")
        [ $? -ne 0 ] && return 1
        ENHANCED_MODE=false
        [ "$sel" = "2" ] && ENHANCED_MODE=true
        return 0
    }

    step_tracks() {
        local songs_display=() line SEL
        while IFS= read -r line; do songs_display+=("$line"); done <<< "$SONG_LIST"
        if [ "$TRACK_COUNT" -gt 50 ]; then
            say "💡 共 $TRACK_COUNT 首，建议分批下载（如 1-50, 51-100）" "💡 $TRACK_COUNT tracks total. Consider batches (e.g. 1-50, 51-100)."
        fi
        SEL=$(printf '%s\n' "${songs_display[@]}" | ui_checklist "$(is_en && echo "🎵 Select tracks [$((idx+1))/${#VALID_URLS[@]}]: $DISPLAY_NAME" || echo "🎵 选择曲目 〔$((idx+1))/${#VALID_URLS[@]}〕《$DISPLAY_NAME》")" 12)
        [ $? -ne 0 ] && return 1
        if [ "$SEL" = "ALL" ]; then
            SELECTION="ALL"; SELECTED_COUNT=$TRACK_COUNT
        else
            SELECTION="$SEL"; SELECTED_COUNT=$(echo "$SELECTION" | tr ',' '\n' | wc -l)
        fi
        return 0
    }

    step_mv_single() {
        say "⚠️ MV 单曲：YouTube 未提供音乐元数据" "⚠️ MV single: no music metadata from YouTube"
        local SI ST SA
        SI=$(extract_song_info "$SINGLE_TITLE"); ST=$(echo "$SI" | cut -d'|' -f1); SA=$(echo "$SI" | cut -d'|' -f2)
        [ -z "$SA" ] && SA="$ARTIST_DIR"
        local m1 m2 sel
        if is_en; then m1="Enter title / artist / album manually"; m2="Use video defaults (artist = channel name)"
        else m1="手动输入 歌名 / 歌手 / 专辑"; m2="使用视频默认值（歌手=上传频道名）"; fi
        sel=$(ui_menu "$(is_en && echo '🎬 Track info' || echo '🎬 歌曲信息')" "" 1 "$m1" "$m2")
        [ $? -ne 0 ] && return 1
        if [ "$sel" = "1" ]; then
            MV_STRATEGY="1"
            local MV_INPUT
            MV_INPUT=$(input_mv_full "$ST" "$SA" "$SINGLE_TITLE")
            [ $? -ne 0 ] && return 1
            MV_TITLE=$(echo "$MV_INPUT" | cut -d'|' -f1)
            MV_ARTIST=$(echo "$MV_INPUT" | cut -d'|' -f2)
            MV_ALBUM=$(echo "$MV_INPUT" | cut -d'|' -f3)
        else
            MV_STRATEGY="2"
            MV_TITLE="$SINGLE_TITLE"; MV_ARTIST="$SINGLE_UPLOADER"; MV_ALBUM="$SINGLE_TITLE"
        fi
        return 0
    }

    step_pl_mv() {
        [ "$IS_PLAYLIST" != true ] && return 0
        local SEL_ITEMS="" inum L VID HAS
        if [ "$SELECTION" = "ALL" ]; then
            for ((inum=1; inum<=TRACK_COUNT; inum++)); do SEL_ITEMS="${SEL_ITEMS}${SEL_ITEMS:+ }$inum"; done
        else
            SEL_ITEMS=$(echo "$SELECTION" | tr ',' ' ')
        fi
        local NORMAL_LIST="" MV_LIST=""
        for inum in $SEL_ITEMS; do
            L=$(echo "$SONG_LIST_FULL" | sed -n "${inum}p")
            [ -z "$L" ] && continue
            # 固定字段号（同 mf_batch.sh：$(NF-1)/$NF 在 4 字段行格式下取错列）
            VID=$(echo "$L" | awk -F'|' '{print $2}')
            HAS=$(echo "$L" | awk -F'|' '{print $3}')
            if [ "$HAS" != "True" ]; then MV_LIST="$MV_LIST $VID"; else NORMAL_LIST="${NORMAL_LIST}${NORMAL_LIST:+,}$inum"; fi
        done
        NORMAL_SELECTION="$NORMAL_LIST"
        MV_VIDS=$(echo "$MV_LIST" | xargs)
        if [ -z "$MV_VIDS" ]; then MV_STRATEGY="2"; return 0; fi

        local mv_cnt m1 m2 sel
        mv_cnt=$(echo "$MV_VIDS" | wc -w)
        if is_en; then m1="Enter title / artist / album for each"; m2="Use video defaults (artist = channel name)"
        else m1="逐首输入 歌名 / 歌手 / 专辑"; m2="使用视频默认值（歌手=上传频道名）"; fi
        sel=$(ui_menu "$(is_en && echo "🎬 $mv_cnt MV track(s) in playlist" || echo "🎬 检测到 $mv_cnt 首 MV 曲目")" "" 1 "$m1" "$m2")
        [ $? -ne 0 ] && return 1
        if [ "$sel" = "1" ]; then
            MV_STRATEGY="1"
            echo ""
            say "--- 🎬 逐首确认 ---" "--- 🎬 Confirm each MV track ---"
            MV_INFO=""
            local VID2 LINE INUM RAW_TITLE SInfo ST2 SA2 NAME_INPUT TITLE ARTIST ALBUM
            while IFS= read -r VID2; do
                [ -z "$VID2" ] && continue
                LINE=$(echo "$SONG_LIST_FULL" | grep -F -- "|$VID2|")
                [ -z "$LINE" ] && continue
                INUM=$(echo "$LINE" | sed 's/^\([0-9]*\)\. .*/\1/')
                RAW_TITLE=$(echo "$LINE" | sed 's/^[0-9]*\. //; s/|[^|]*|[^|]*$//')
                SInfo=$(extract_song_info "$RAW_TITLE"); ST2=$(echo "$SInfo" | cut -d'|' -f1); SA2=$(echo "$SInfo" | cut -d'|' -f2)
                [ -z "$SA2" ] && SA2="$ARTIST_DIR"
                echo "" >&2
                if is_en; then echo "━━━━ Track ${INUM}: ${RAW_TITLE:0:60}..." >&2
                else echo "━━━━ 第 ${INUM} 首: ${RAW_TITLE:0:60}..." >&2; fi
                NAME_INPUT=$(input_mv_full "$ST2" "$SA2" "$RAW_TITLE")
                [ $? -ne 0 ] && return 1
                TITLE=$(echo "$NAME_INPUT" | cut -d'|' -f1)
                ARTIST=$(echo "$NAME_INPUT" | cut -d'|' -f2)
                ALBUM=$(echo "$NAME_INPUT" | cut -d'|' -f3)
                [ -n "$MV_INFO" ] && MV_INFO="${MV_INFO};"
                MV_INFO="${MV_INFO}${VID2}=${TITLE}=${ARTIST}=${ALBUM}"
            done <<< "$(echo "$MV_VIDS" | tr ' ' '\n' | grep -v '^$')"
        else
            MV_STRATEGY="2"
            NORMAL_SELECTION="$SELECTION"; MV_VIDS=""; MV_INFO=""
        fi
        if [ -n "$NORMAL_SELECTION" ]; then SELECTION="$NORMAL_SELECTION"; else SELECTION=""; fi
        return 0
    }

    # 组装本链接的步骤链（按类型裁剪），状态机驱动，支持回退
    STEPS=(); si=0; r=0   # for 循环顶层非函数内，不能用 local
    [ "$IS_PLAYLIST" == true ] && STEPS+=(pl_type)
    STEPS+=(path)
    [ "$IS_ALBUM" == true ] && STEPS+=(album_opts)
    [ "$TRACK_COUNT" -gt 1 ] && STEPS+=(tracks)
    { [ "$IS_SINGLE" == true ] && [ "$HAS_METADATA" != "True" ]; } && STEPS+=(mv_single)
    STEPS+=(pl_mv)

    si=0
    while :; do
        case "${STEPS[$si]}" in
            pl_type)    step_pl_type; r=$? ;;
            path)       step_path; r=$? ;;
            album_opts) step_album_opts; r=$? ;;
            tracks)     step_tracks; r=$? ;;
            mv_single)  step_mv_single; r=$? ;;
            pl_mv)      step_pl_mv; r=$? ;;
        esac
        if [ $r -eq 0 ]; then
            si=$((si+1))
            [ $si -ge ${#STEPS[@]} ] && break
        else
            if [ $si -gt 0 ]; then
                si=$((si-1))
            else
                ui_confirm "$(is_en && echo 'No previous step here — skip this link?' || echo '已是最早步骤——跳过这个链接？')" n
                [ $? -eq 0 ] && { say "⏭️ 已跳过" "⏭️ Skipped"; continue 2; }
            fi
        fi
    done

    NT=$((TOTAL_SELECTED + SELECTED_COUNT))
    [ "$NT" -gt "$MF_MAX_TRACKS_PER_RUN" ] && { if is_en; then echo "⚠️ Total selection exceeds $MF_MAX_TRACKS_PER_RUN tracks"; else echo "⚠️ 累计超限 $MF_MAX_TRACKS_PER_RUN 首"; fi; continue; }
    TOTAL_SELECTED=$NT

    ALBUM_CONFIGS+=("$(safe_field "$SAFE_NAME")|$SELECTION|$url|$FINAL_PATH|$(safe_field "$ALBUM_ARTIST")|$ENHANCED_MODE|$TYPE|$HAS_METADATA|$(safe_field "$MV_TITLE")|$(safe_field "$MV_ARTIST")|$(safe_field "$MV_ALBUM")|$(safe_field "$MV_ALBUM_ARTIST")|$(safe_field "$BATCH_ALBUM")|||$NORMAL_SELECTION|$MV_VIDS|$(safe_field "$MV_INFO")|$MV_STRATEGY")

    echo ""
done

[ ${#ALBUM_CONFIGS[@]} -eq 0 ] && { say "❌ 没有项目" "❌ No items to download"; exit 1; }

if is_en; then echo "📊 Summary: ${#ALBUM_CONFIGS[@]} item(s), $TOTAL_SELECTED track(s) total"
else echo "📊 统计: ${#ALBUM_CONFIGS[@]} 个项目，累计 $TOTAL_SELECTED 首"; fi

LOG_DIR="${SCRIPT_DIR}/log"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/musicfeed-$(date +%Y%m%d-%H%M%S).log"

WORKER_SH=$(mktemp /tmp/musicfeed_worker_XXXXXX.sh)
chmod +x "$WORKER_SH"

cat > "$WORKER_SH" << 'WORKEREOF'
#!/bin/bash
export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=en_US.UTF-8 2>/dev/null || true
YTDLP="__YTDLP__"
NODE_ARGS="__NODE_ARGS__"
LOG_FILE="__LOG_FILE__"
AUDIO_FORMAT="__AUDIO_FORMAT__"

if [ "$AUDIO_FORMAT" = "m4a" ]; then
    AUDIO_EXT="m4a"
    FORMAT_ARGS=(-f "ba[ext=m4a]/ba" --audio-format m4a --audio-quality 0)
else
    AUDIO_EXT="opus"
    FORMAT_ARGS=(-f ba -x --audio-format opus --audio-quality 0)
fi


cleanup_worker() {
    rm -f /tmp/existing_before_$$* /tmp/cover_$$* /tmp/cover_mv_$$* /tmp/cover_$$_* 2>/dev/null
}
trap cleanup_worker EXIT

log() { echo "$1" >> "$LOG_FILE"; }

file_size() {
    local f="$1"
    if stat -c%s "$f" >/dev/null 2>&1; then stat -c%s "$f"; else stat -f%z "$f"; fi
}

cover_crop_center() {
    local src="$1" dst="$2"
    ffmpeg -i "$src" \
        -vf "crop=min(iw\,ih):min(iw\,ih):(iw-min(iw\,ih))/2:(ih-min(iw\,ih))/2" \
        -q:v 2 -y "$dst" 2>/dev/null
    [ -f "$dst" ] && return 0 || return 1
}

cover_compress() {
    local src="$1" dst="$2"
    ffmpeg -i "$src" -q:v 2 -y "$dst" 2>/dev/null
    [ -f "$dst" ] && return 0 || return 1
}

# ─────────────────────────────────────────────
# v4.0: 打标签引擎从 python3+mutagen 迁移到 ffmpeg
# ─────────────────────────────────────────────
# 智能拆分多艺人字符串（复刻原 python split_artists 逻辑），逐行输出艺人
mf_split_artists() {
    local input="$1"
    if [ -z "$input" ]; then printf '%s\n' "Unknown Artist"; return; fi
    input="${input//，/,}"
    local normalized
    normalized=$(printf '%s' "$input" | sed -E \
        -e 's/[[:space:]]+feat\.[[:space:]]+/\n/gI' \
        -e 's/[[:space:]]+ft\.[[:space:]]+/\n/gI' \
        -e 's/[[:space:]]+&[[:space:]]+/\n/g' \
        -e 's/[[:space:]]*,[[:space:]]*/\n/g' \
        -e 's/[[:space:]]+with[[:space:]]+/\n/gI' \
        -e 's/[[:space:]]+vs\.[[:space:]]+/\n/gI')
    local seen=() out=() line low dup s
    while IFS= read -r line; do
        line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        low=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
        dup=0
        for s in "${seen[@]}"; do [ "$s" = "$low" ] && { dup=1; break; }; done
        [ "$dup" -eq 0 ] && { seen+=("$low"); out+=("$line"); }
    done <<< "$normalized"
    if [ "${#out[@]}" -eq 0 ]; then printf '%s\n' "Unknown Artist"; return; fi
    printf '%s\n' "${out[@]}"
}

# 多艺人 → 单字符串（ffmpeg CLI 无法像 mutagen 那样写多值标签，
# 用 "; " 拼接作为折中方案，是本次迁移与 mutagen 版本行为的主要差异点，需重点验证）
mf_artists_joined() {
    local joined
    joined=$(mf_split_artists "$1" | tr '\n' '\036')
    joined="${joined%$'\036'}"
    joined="${joined//$'\036'/; }"
    printf '%s' "$joined"
}

# 32 位大端整数 → 原始字节（FLAC Picture Block 头部用，纯 bash+printf，无外部依赖）
be32_raw() {
    local n="$1" b1 b2 b3 b4 esc
    b1=$(( (n>>24)&255 )); b2=$(( (n>>16)&255 )); b3=$(( (n>>8)&255 )); b4=$(( n&255 ))
    esc=$(printf '\\%03o\\%03o\\%03o\\%03o' "$b1" "$b2" "$b3" "$b4")
    printf '%b' "$esc"
}

# 手工构造 FLAC Picture Block 并 base64（等价于 mutagen 的 Picture().write()），
# 用途：ogg/opus 容器下 ffmpeg 无法像 mp4 那样用 -map 1:v 直接挂封面视频流
# （实测 "Unsupported codec id in stream 1" mux 失败），但可以把这个 block 当作普通
# metadata_block_picture 文本标签写入——ffmpeg 会在读取时自动识别还原成 attached_pic 视频流，
# 效果与 mutagen 版本完全一致（已用 ffprobe 验证 DISPOSITION:attached_pic=1）
mf_flac_picture_b64() {
    local cover="$1" mime="image/jpeg" w h dims tmp_hdr tmp_blob b64 dlen
    dims=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$cover" 2>/dev/null)
    w="${dims%x*}"; h="${dims#*x}"
    [[ "$w" =~ ^[0-9]+$ ]] || w=0
    [[ "$h" =~ ^[0-9]+$ ]] || h=0
    dlen=$(file_size "$cover")
    tmp_hdr=$(mktemp)
    {
        be32_raw 3                 # picture type 3 = front cover
        be32_raw "${#mime}"
        printf '%s' "$mime"
        be32_raw 0                 # description length = 0
        be32_raw "$w"
        be32_raw "$h"
        be32_raw 24                # color depth
        be32_raw 0                 # colors used (非索引色)
        be32_raw "$dlen"
    } > "$tmp_hdr"
    tmp_blob=$(mktemp)
    cat "$tmp_hdr" "$cover" > "$tmp_blob"
    b64=$(base64 -w0 "$tmp_blob")
    rm -f "$tmp_hdr" "$tmp_blob"
    printf '%s' "$b64"
}

# ffmpeg 打标签核心：$1=文件路径 $2=封面文件("" 表示不嵌封面)，
# 其余参数为 "key=value" 元数据对；value 传空字符串 = 显式清除该字段，
# 未列出的字段一律透传原有值（对应 -map_metadata 0，行为对齐 mutagen 的"只改被赋值字段"）
# ffmetadata 文件格式转义（=、;、#、\ 需要反斜杠转义；换行一律压扁成空格避免格式错乱）
mf_ffmeta_esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/=/\\=/g' -e 's/;/\\;/g' -e 's/#/\\#/g' | tr '\n' ' '
}

# ffmpeg 打标签核心：$1=文件路径 $2=封面文件("" 表示不嵌封面)，
# 其余参数为 "key=value" 元数据对；value 传空字符串 = 显式清除该字段，
# 未列出的字段一律透传原有值。
#
# v4.0.1: 修复真实实况——封面 base64（几百 KB）直接塞进 -metadata CLI 参数会撞到系统
# ARG_MAX 导致 "Argument list too long"（execve E2BIG）。现在改为：先用 ffprobe 读出
# 原文件全部已有标签，与覆盖字段在 bash 关联数组里合并好，一次性写成 ffmpeg 的
# ffmetadata 文件（-f ffmetadata，无参数长度限制），再用 -map_metadata 1 从文件喂入，
# 不再通过命令行参数传任何标签值（包括封面 base64）。
mf_ffmpeg_apply() {
    local fpath="$1" cover="$2"; shift 2
    local ext dir base tmp_out meta_file args has_cover_stream=0 kv k v pic_b64 err_out rc
    ext="${fpath##*.}"
    dir="$(dirname "$fpath")"; base="$(basename "$fpath")"
    tmp_out="${dir}/.mf_tmp_$$_${base}"
    meta_file="$(mktemp)"

    local -A TAGS=()
    while IFS='=' read -r k v; do
        k="$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')"
        [ -n "$k" ] && TAGS["$k"]="$v"
    done < <(ffprobe -v error -show_entries format_tags:stream_tags -of default=noprint_wrappers=1 "$fpath" 2>/dev/null | sed -n 's/^TAG://p')

    if [ -n "$cover" ] && [ -f "$cover" ]; then
        if [ "$ext" = "m4a" ]; then
            has_cover_stream=1
        else
            # opus/ogg：写成 metadata_block_picture 文本标签（走文件，不再走 argv）
            pic_b64=$(mf_flac_picture_b64 "$cover")
            [ -n "$pic_b64" ] && TAGS["metadata_block_picture"]="$pic_b64"
        fi
    fi

    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        k="$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')"
        if [ -z "$v" ]; then
            unset "TAGS[$k]"
        else
            TAGS["$k"]="$v"
        fi
    done

    {
        echo ";FFMETADATA1"
        for k in "${!TAGS[@]}"; do
            printf '%s=%s\n' "$(mf_ffmeta_esc "$k")" "$(mf_ffmeta_esc "${TAGS[$k]}")"
        done
    } > "$meta_file"

    args=(-y -i "$fpath" -i "$meta_file")
    [ "$has_cover_stream" -eq 1 ] && args+=(-i "$cover")
    # -map_metadata:s:a -1 关键：阻止 ffmpeg 在 -map 0:a 时自动把源音轨自身的
    # stream 级标签（ogg/opus 的 vorbis comment 本就挂在音轨上）带过来，
    # 否则会跟我们写的全局标签重复共存，读回来到底显示哪个不可控
    args+=(-map_metadata 1 -map_metadata:s:a -1 -map 0:a)
    if [ "$has_cover_stream" -eq 1 ]; then
        # v4.0.4: 封面源全程是 jpg（i.ytimg.com 原图 / ffmpeg 裁剪压缩产物），之前
        # -c:v mjpeg 会把封面再编码一代（实测 48KB→33KB 有损），与 mutagen 原字节
        # 嵌入的行为不一致。JPEG 魔数（FF D8）命中时改用流复制按原字节嵌入；
        # 非 jpg（防扩展名伪装的 webp/png）兜底仍走重编码保证可读
        local cover_is_jpeg=0
        [ "$(head -c 2 "$cover" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "ffd8" ] && cover_is_jpeg=1
        if [ "$cover_is_jpeg" -eq 1 ]; then
            args+=(-map 2:v -c:v copy -disposition:v attached_pic)
        else
            args+=(-map 2:v -c:v mjpeg -disposition:v attached_pic)
        fi
    fi
    args+=(-c:a copy)
    args+=("$tmp_out")

    err_out=$(ffmpeg "${args[@]}" 2>&1 >/dev/null)
    rc=$?
    rm -f "$meta_file"
    if [ "$rc" -eq 0 ] && [ -s "$tmp_out" ]; then
        mv -f "$tmp_out" "$fpath"
        return 0
    else
        log "  ⚠️ ffmpeg tag write failed for $(basename "$fpath"):"
        log "$err_out"
        rm -f "$tmp_out" 2>/dev/null
        return 1
    fi
}

# mv_write_id3: fpath title artist album album_artist [cover_file]
# 全量覆盖写（对应原 mutagen 版本：title/artist 必写，album/album_artist 为空则清除）
mv_write_id3() {
    local fpath="$1" title="$2" artist="$3" album="$4" album_artist="$5" cover_file="${6:-}"
    local artists_str kv=()
    artists_str=$(mf_artists_joined "$artist")
    kv+=("title=$title" "artist=$artists_str")
    if [ -n "$album" ]; then kv+=("album=$album"); else kv+=("album="); fi
    if [ -n "$album_artist" ]; then kv+=("album_artist=$album_artist"); else kv+=("album_artist="); fi
    if mf_ffmpeg_apply "$fpath" "$cover_file" "${kv[@]}"; then
        if [ -n "$cover_file" ] && [ -f "$cover_file" ]; then
            echo "  ✅ +Cover: $(basename "$fpath")"
        else
            echo "  ✅ ID3: $(basename "$fpath")"
        fi
    else
        echo "  ❌ Failed: $(basename "$fpath")"
    fi
}

# embed_cover: fpath album_artist album has_cover enhanced_mode orig_album [cover_file] [force_title] [force_artist]
# 增量写（只覆盖被赋值的字段，其余沿用 yt-dlp --embed-metadata 已写入的原始标签）
embed_cover() {
    local fpath="$1" aa="$2" an="$3" hc="$4" em="$5" oa="$6" cf="${7:-}" ft="${8:-}" fa="${9:-}"
    local base artist_part artists_str="" final_album kv=() cover_arg=""

    base="$(basename "$fpath")"
    if [[ "$base" == *" - "* ]]; then
        artist_part="${base%% - *}"
        if [ -n "$artist_part" ] && [ "$artist_part" != "NA" ]; then
            artists_str=$(mf_artists_joined "$artist_part")
        fi
    fi
    # v3.4/v4.0: 无元数据曲目按 title 首个 " - " 拆分出的强制歌名/歌手（优先级高于文件名提取）
    [ -n "$fa" ] && artists_str=$(mf_artists_joined "$fa")

    if [ "$em" = "true" ] && [ -n "$oa" ] && [ "$oa" != "None" ] && [[ "$oa" != %* ]]; then
        final_album="$oa"
    else
        final_album="$an"
    fi

    if [ -n "$aa" ] && [ "$aa" != "None" ] && [ "$aa" != "SKIP" ]; then
        kv+=("album_artist=$aa")
    else
        kv+=("album_artist=")
    fi
    [ -n "$artists_str" ] && kv+=("artist=$artists_str")
    [ -n "$ft" ] && kv+=("title=$ft")
    kv+=("album=$final_album")
    [ "$em" = "true" ] && kv+=("track=")

    [ "$hc" = "true" ] && [ -n "$cf" ] && [ -f "$cf" ] && cover_arg="$cf"

    if mf_ffmpeg_apply "$fpath" "$cover_arg" "${kv[@]}"; then
        if [ -n "$cover_arg" ]; then
            echo "  ✅ +Cover: $(basename "$fpath")"
        else
            echo "  ✅ ID3: $(basename "$fpath")"
        fi
    else
        echo "  ❌ Failed: $(basename "$fpath")"
    fi
}

get_cover_url() {
    jq -r '(.thumbnails // []) | sort_by((.width // 0) * (.height // 0)) | last | .url // empty' "$1" 2>/dev/null
}

download_cover() {
    local json_file="$1" out_var="$2"
    local url=""
    url=$(get_cover_url "$json_file")
    if [ -n "$url" ]; then
        if ! command -v curl &>/dev/null; then
            echo "  curl not found, cannot download cover" >&2
            return 1
        fi
        local tmp="/tmp/cover_$$.jpg"
        curl -sL "$url" -o "$tmp" 2>/dev/null
        if [ -f "$tmp" ] && [ "$(file_size "$tmp" 2>/dev/null)" -gt 10240 ]; then
            eval "$out_var=$tmp"
            return 0
        fi
    fi
    return 1
}

declare -A MV_DATA
parse_mv_info() {
    local info="$1"
    if [ -z "$info" ]; then return; fi
    IFS=';' read -ra ENTRIES <<< "$info"
    for entry in "${ENTRIES[@]}"; do
        VID=$(echo "$entry" | cut -d= -f1)
        TITLE=$(echo "$entry" | cut -d= -f2)
        ARTIST=$(echo "$entry" | cut -d= -f3)
        ALBUM=$(echo "$entry" | cut -d= -f4)
        [ -n "$VID" ] && MV_DATA["$VID"]="$TITLE|$ARTIST|$ALBUM"
    done
}

# v4.3: 电台/社区列表无元数据曲目的歌名/歌手提取（与 mf_lib.sh extract_nm_info 同一实现，
# worker 是生成的独立脚本，需内嵌一份）
# 用法: extract_nm_info "原始标题" "uploader"；输出 "歌名|歌手"
# ─────────────────────────────────────────────
# 7.5 电台/社区列表无元数据曲目的歌名/歌手提取（无交互）
# ─────────────────────────────────────────────
# 用法: extract_nm_info "原始标题" "uploader"
# 输出: "歌名|歌手"
# 算法（v4.3，经两个真实电台 118 首验证）:
#   1) 歌名书名号优先：《》→【】→[ ]，取第一个合格括号去壳内容，其后文字全部丢弃
#   2) 括号逐层处理：污染词连符号整删；白名单(feat/ft/国/粵/粤)保留本层符号；
#      其余去壳留内容（外层自然剥除，如《K歌之王(國)》→ K歌之王(國)）
#   3) 无书名号：按 " - " 分段，uploader 与某段互相包含 → 该段为歌手；
#      匹配不上盲猜左段为歌手；纯歌名 → 歌手 fallback uploader
# v4.0: 从 python3 正则迁移到纯 bash + grep -E + sed（不依赖任何脚本语言运行时），
# 已用原始 python 实现跑过 20+ 组覆盖全分支的真实/边界标题逐字节比对验证一致
MF_POLL_RE='歌詞|歌词|動態|动态|MV|Official|官方|Video|Audio|Visualizer|Live|完整版|主題曲|主题曲|片尾曲|片頭曲|片头曲'
MF_KEEP_RE='feat|ft\.|国|國|粤|粵'
MF_BR_RE='（[^（）()]*）|\([^()]*\)|『[^『』]*』|「[^「」]*」|【[^【】]*】|《[^《》]*》|\[[^][]*\]'

mf_poll_match() { grep -qiE "$MF_POLL_RE" <<< "$1"; }
mf_keep_match() { grep -qiE "$MF_KEEP_RE" <<< "$1"; }

# 单层去壳：一次左到右扫描替换全部括号组（等价 python re.sub 一次调用）
mf_br_proc_once() {
    local remaining="$1" result="" match before after inner flat
    while :; do
        match=$(grep -oE "$MF_BR_RE" <<< "$remaining" | head -1)
        [ -z "$match" ] && { result+="$remaining"; break; }
        before="${remaining%%"$match"*}"
        after="${remaining#*"$match"}"
        inner=$(sed -E 's/^.(.*).$/\1/' <<< "$match")
        flat=$(sed -E "s/$MF_BR_RE/ /g" <<< "$inner")
        if mf_poll_match "$flat"; then
            result+="$before"
        elif mf_keep_match "$flat"; then
            result+="$before$match"
        else
            result+="$before$inner"
        fi
        remaining="$after"
    done
    printf '%s' "$result"
}

# 反复迭代到不动点（等价 python while prev != s 外层循环）
mf_br_proc() {
    local prev cur="$1"
    while :; do
        prev="$cur"
        cur=$(mf_br_proc_once "$prev")
        [ "$cur" = "$prev" ] && break
    done
    printf '%s' "$cur"
}

mf_clean() {
    local s
    s=$(sed -E 's/[[:space:]]*-[[:space:]]*$//' <<< "$1")
    s=$(sed -E 's/[[:space:]]{2,}/ /g' <<< "$s")
    s=$(sed -E 's/^[ -]+//; s/[ -]+$//' <<< "$s")
    printf '%s' "$s"
}

mf_esc() { printf '%s' "${1//|/｜}"; }

# 书名号优先匹配：《》→【】→[ ]，返回第一个命中的括号内容 + 之前的文字
mf_bracket_priority_match() {
    local t="$1" pat m inner
    for pat in '《[^《》]*》' '【[^【】]*】' '\[[^][]*\]'; do
        m=$(grep -oE "$pat" <<< "$t" | head -1)
        if [ -n "$m" ]; then
            inner=$(sed -E 's/^.(.*).$/\1/' <<< "$m")
            BR1_INNER="$inner"
            BR1_PREFIX="${t%%"$m"*}"
            return 0
        fi
    done
    return 1
}

extract_nm_info() {
    local title_raw="$1" up_raw="$2"
    local up t song artist prefix flat_song t2 plen
    local -a segs=() segs_raw=() keep=()
    local seg trimmed i joined

    up=$(sed -E 's/[[:space:]]*-[[:space:]]*Topic[[:space:]]*$//' <<< "$up_raw")
    up=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$up")

    t=$(sed 's/–/-/g; s/—/-/g' <<< "$title_raw")

    # 0) 方括号全量扫描（v4.1）：按出现顺序取第一个「内容未污染、且前缀非空 ≤30 字」
    #    的 [ 歌名 ] 组为歌名，前缀为歌手。厂牌官方 MV 的惯例是「歌手 [ 歌名 ] Official MV」，
    #    而片尾署名括号（影集《劇名》插曲之类）前面拖着长前缀，会被 30 字上限自然排除。
    #    只扫 [ ]：圆括号/书名号/【】更多承担署名、feat、纯享标签等角色，仍走原有优先级。
    #    扫描不中（如括号组在标题开头、无歌手前缀）则落入原有书名号优先逻辑。
    local bm inner2 pre2 flat2
    while IFS= read -r bm; do
        [ -z "$bm" ] && continue
        inner2=$(sed -E 's/^.(.*).$/\1/' <<< "$bm")
        song=$(mf_br_proc "$inner2")
        song=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$song")
        flat2=$(sed -E "s/$MF_BR_RE/ /g" <<< "$song")
        if [ -z "$song" ] || mf_poll_match "$flat2"; then continue; fi
        pre2="${t%%"$bm"*}"
        [ -z "$pre2" ] && continue
        pre2=$(sed -E 's/^(\[[^]]*\][[:space:]]*)+//' <<< "$pre2")
        pre2=$(sed -E 's/[[:space:]:：*|｜-]+$//' <<< "$pre2")
        pre2=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$pre2")
        plen=$(printf '%s' "$pre2" | wc -m)
        if [ -n "$pre2" ] && [ "$plen" -le 30 ]; then
            echo "$(mf_esc "$song")|$(mf_esc "$pre2")"
            return 0
        fi
    done < <(grep -oE '\[[^][]*\]' <<< "$t")

    # 1) 书名号优先（内容被污染词清空时视为无书名号，继续走后面分支）
    if mf_bracket_priority_match "$t"; then
        song=$(mf_br_proc "$BR1_INNER")
        song=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$song")
        flat_song=$(sed -E "s/$MF_BR_RE/ /g" <<< "$song")
        if [ -n "$song" ] && ! mf_poll_match "$flat_song"; then
            prefix=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$BR1_PREFIX")
            prefix=$(sed -E 's/^(\[[^]]*\][[:space:]]*)+//' <<< "$prefix")
            prefix=$(sed -E 's/[[:space:]:：*|｜-]+$//' <<< "$prefix")
            prefix=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$prefix")
            plen=$(printf '%s' "$prefix" | wc -m)
            if [ -n "$prefix" ] && [ "$plen" -le 30 ]; then
                artist="$prefix"
            else
                artist="$up"
            fi
            echo "$(mf_esc "$song")|$(mf_esc "$artist")"
            return 0
        fi
    fi

    # 2) 无书名号：括号清洗后按 " - " 分段
    t2=$(mf_br_proc "$t")
    local delim=$'\x01' t2_delim
    t2_delim="${t2// - /$delim}"
    local oldIFS="$IFS"; IFS="$delim"; read -ra segs_raw <<< "$t2_delim"; IFS="$oldIFS"
    for seg in "${segs_raw[@]}"; do
        trimmed=$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$seg")
        [ -n "$trimmed" ] && segs+=("$trimmed")
    done

    if [ "${#segs[@]}" -ge 2 ]; then
        if [ -n "$up" ]; then
            keep=()
            for seg in "${segs[@]}"; do
                if [[ "$up" == *"$seg"* || "$seg" == *"$up"* ]]; then
                    continue
                fi
                keep+=("$seg")
            done
            if [ "${#keep[@]}" -gt 0 ] && [ "${#keep[@]}" -lt "${#segs[@]}" ]; then
                echo "$(mf_esc "$(mf_clean "${keep[0]}")")|$(mf_esc "$up")"
                return 0
            fi
        fi
        joined=""
        for ((i=1; i<${#segs[@]}; i++)); do
            if [ -z "$joined" ]; then joined="${segs[$i]}"; else joined="$joined - ${segs[$i]}"; fi
        done
        echo "$(mf_esc "$(mf_clean "$joined")")|$(mf_esc "${segs[0]}")"
        return 0
    fi

    # 3) 纯歌名
    echo "$(mf_esc "$(mf_clean "$t2")")|$(mf_esc "$up")"
}

log "⚙️ PID: $$ | 🕒 $(date '+%Y-%m-%d %H:%M:%S')"
WORKEREOF

replace_token() {
    local token="$1" value="$2" content
    content="$(cat "$WORKER_SH")"
    content="${content//$token/$value}"
    printf '%s\n' "$content" > "$WORKER_SH"
}

replace_token "__YTDLP__" "$MF_YTDLP"
replace_token "__NODE_ARGS__" "$MF_NODE_ARGS"
replace_token "__LOG_FILE__" "$LOG_FILE"
replace_token "__AUDIO_FORMAT__" "$MF_AUDIO_FORMAT"

echo 'ALBUMS=(' >> "$WORKER_SH"
for config in "${ALBUM_CONFIGS[@]}"; do
    printf ' %q\n' "$config" >> "$WORKER_SH"
done
echo ')' >> "$WORKER_SH"

cat >> "$WORKER_SH" << 'LOOPEOF'
for album_entry in "${ALBUMS[@]}"; do
    ALBUM_NAME=$(echo "$album_entry" | cut -d'|' -f1)
    SELECTION=$(echo "$album_entry" | cut -d'|' -f2)
    url=$(echo "$album_entry" | cut -d'|' -f3)
    FINAL_PATH=$(echo "$album_entry" | cut -d'|' -f4)
    ALBUM_ARTIST=$(echo "$album_entry" | cut -d'|' -f5)
    ENHANCED_MODE=$(echo "$album_entry" | cut -d'|' -f6)
    TYPE=$(echo "$album_entry" | cut -d'|' -f7)

    # 统一封面临时目录清理（循环头，兼容 continue 路径）
    [ -n "$CTD" ] && rm -rf "$CTD" 2>/dev/null
    CTD=""; UNIFIED_COVER=""
    HAS_METADATA=$(echo "$album_entry" | cut -d'|' -f8)
    MV_TITLE=$(echo "$album_entry" | cut -d'|' -f9)
    MV_ARTIST=$(echo "$album_entry" | cut -d'|' -f10)
    MV_ALBUM=$(echo "$album_entry" | cut -d'|' -f11)
    MV_ALBUM_ARTIST=$(echo "$album_entry" | cut -d'|' -f12)
    BATCH_ALBUM=$(echo "$album_entry" | cut -d'|' -f13)
    NORMAL_SELECTION=$(echo "$album_entry" | cut -d'|' -f16)
    MV_VIDS=$(echo "$album_entry" | cut -d'|' -f17)
    MV_INFO=$(echo "$album_entry" | cut -d'|' -f18)
    MV_STRATEGY=$(echo "$album_entry" | cut -d'|' -f19)

    log "========================================"
    log "💿 $ALBUM_NAME | 📂 $FINAL_PATH | 📌 $TYPE"
    log "========================================"
    mkdir -p "$FINAL_PATH"

    # v4.0.8: 文件夹内互斥（flock，util-linux 自带）——多个 worker 实例同时写同一
    # 库目录时在此串行化，根治 yt-dlp 同名 .part 互写损坏与 temp/info.json 互删误读。
    # exec 9>> 重开 fd 会自动释放上一迭代（或 continue 路径）持有的锁；等待超时
    # 用 MF_FLOCK_TIMEOUT 可调（默认 600s），超时后带警告继续（可用性优先）
    if { exec 9>>"$FINAL_PATH/.mf.lock"; } 2>/dev/null; then
        if ! flock -w "${MF_FLOCK_TIMEOUT:-600}" 9 2>/dev/null; then
            log "⚠️ Waited ${MF_FLOCK_TIMEOUT:-600}s for $FINAL_PATH — another task still active, proceeding anyway (write conflicts possible)"
        fi
    else
        log "⚠️ Cannot create $FINAL_PATH/.mf.lock — proceeding without folder lock"
    fi
    # v4.0.8: 一次性清理 v4.0.8 之前命名的 temp_mv_* 残留（含 .part）。旧命名跨实例
    # 互抢，升级后不再产生，且此处已在锁内——对所有旧残留只扫这一次
    if [ -z "${MF_LEGACY_TMP_CLEANED:-}" ]; then
        rm -f "$FINAL_PATH"/temp_mv_* 2>/dev/null
        MF_LEGACY_TMP_CLEANED=1
    fi

    IS_MV_SINGLE=false
    [ "$TYPE" = "single" ] && [ "$HAS_METADATA" != "True" ] && [ -n "$MV_TITLE" ] && IS_MV_SINGLE=true

    ls "$FINAL_PATH"/*.$AUDIO_EXT 2>/dev/null > /tmp/existing_before_$$.txt


    if [ "$ENHANCED_MODE" != "true" ]; then
        log "🖼️ Unified cover..."
        CTD=$(mktemp -d)
        "$YTDLP" $NODE_ARGS --no-warnings --write-thumbnail --skip-download --convert-thumbnails jpg \
            --playlist-items 1 -o "$CTD/%(id)s" "$url" >> "$LOG_FILE" 2>&1
        CS=$(find "$CTD" -name "*.jpg" -type f -exec ls -la {} \; 2>/dev/null | sort -k5 -rn | head -1 | awk '{print $NF}')
        if [ -n "$CS" ]; then
            # v3.3: 封面全程留在临时目录，最终目录不再落 cover.jpg
            if cover_compress "$CS" "$CTD/cover.jpg" 2>/dev/null && [ -f "$CTD/cover.jpg" ]; then
                UNIFIED_COVER="$CTD/cover.jpg"
                log "✅ Unified cover (compressed)"
            else
                UNIFIED_COVER="$CS"
                log "✅ Unified cover (compression failed, keeping original)"
            fi
        else
            log "⚠️ Could not fetch unified cover"
        fi
    fi

    MV_DATA=()
    parse_mv_info "$MV_INFO"

    if [ "$IS_MV_SINGLE" = true ]; then
        log "🚚 MV single (temp)..."
        "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --write-info-json \
            "${FORMAT_ARGS[@]}" \
            -o "temp_$$_mv_%(id)s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1

    elif [ "$MV_STRATEGY" = "2" ]; then
        log "🚚 Default mode batch..."
        "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --yes-playlist \
            --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json \
            "${FORMAT_ARGS[@]}" \
            --playlist-items "$SELECTION" \
            -o "%(artist,uploader).50s - %(title).25s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1

    else
        if [ -n "$NORMAL_SELECTION" ]; then
            log "🚚 Normal track batch..."
            "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --yes-playlist \
                --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json \
                "${FORMAT_ARGS[@]}" \
                --playlist-items "$NORMAL_SELECTION" \
                -o "%(artist,uploader).50s - %(title).25s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1
        fi

        if [ -n "$MV_VIDS" ] && [ "$MV_STRATEGY" = "1" ]; then
            while IFS= read -r VID; do
                [ -z "$VID" ] && continue
                SINGLE_URL="https://www.youtube.com/watch?v=$VID"
                log "🚚 MV track: $VID"
                "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                    --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --write-info-json \
                    "${FORMAT_ARGS[@]}" \
                    -o "temp_$$_mv_%(id)s.%(ext)s" -P "$FINAL_PATH" "$SINGLE_URL" >> "$LOG_FILE" 2>&1
            done <<< "$(echo "$MV_VIDS" | tr ' ' '\n' | grep -v '^$')"
        fi

        if [ -z "$NORMAL_SELECTION" ] && [ -z "$MV_VIDS" ]; then
            log "🚚 Downloading..."
            DOWNLOAD_ARGS=""
            [ "$SELECTION" != "ALL" ] && [ -n "$SELECTION" ] && DOWNLOAD_ARGS="--playlist-items $SELECTION"
            "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --yes-playlist \
                --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json \
                "${FORMAT_ARGS[@]}" $DOWNLOAD_ARGS \
                -o "%(artist,uploader).50s - %(title).25s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1
        fi
    fi

    log "✅ Download complete"

    if [ "$IS_MV_SINGLE" = true ]; then
        log "🏷️ MV single post-processing..."
        for mv_f in "$FINAL_PATH"/temp_$$_mv_*.$AUDIO_EXT; do
            [ -f "$mv_f" ] || continue
            SAFE_ARTIST=$(echo "$MV_ARTIST" | sed 's/[\/:*?"<>|]/-/g')
            SAFE_TITLE=$(echo "$MV_TITLE" | sed 's/[\/:*?"<>|]/-/g')
            NEW_NAME="${SAFE_ARTIST} - ${SAFE_TITLE}.$AUDIO_EXT"
            NEW_PATH="$FINAL_PATH/$NEW_NAME"
            if [ -f "$NEW_PATH" ]; then
                rm -f "$mv_f"
                log "  🔁 Duplicate: exists $NEW_NAME, new copy removed" "info" "dedupe"
                echo "$NEW_PATH" >> /tmp/existing_before_$$.txt
                continue
            fi
            mv "$mv_f" "$NEW_PATH"
            log "  📝 Renamed: $(basename "$mv_f") → $NEW_NAME"
            CF=""; JSON_FILE="${NEW_PATH%.$AUDIO_EXT}.info.json"
            [ ! -f "$JSON_FILE" ] && JSON_FILE=$(find "$FINAL_PATH" -name "temp_$$_mv_*.info.json" 2>/dev/null | head -1)
            if [ -f "$JSON_FILE" ]; then
                if download_cover "$JSON_FILE" CF; then
                    CC="/tmp/cover_$$_compressed.jpg"
                    cover_compress "$CF" "$CC" 2>/dev/null
                    if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "  🖼️ Cover compressed"; fi
                fi
                rm -f "$JSON_FILE"
            fi
            mv_write_id3 "$NEW_PATH" "$MV_TITLE" "$MV_ARTIST" "$MV_ALBUM" "" "$CF"
            [ -n "$CF" ] && rm -f "$CF"
            echo "$NEW_PATH" >> /tmp/existing_before_$$.txt
        done
        rm -f "$FINAL_PATH"/temp_$$_mv_* "$FINAL_PATH"/*.webm 2>/dev/null
        log "🎉 Done: $ALBUM_NAME"
        continue
    fi

    if [ "$MV_STRATEGY" = "2" ]; then
        log "🏷️ Default mode post-processing..."
        for f in "$FINAL_PATH"/*.$AUDIO_EXT; do
            [ -f "$f" ] || continue
            [[ "$(basename "$f")" == temp_* ]] && continue
            # v4.0.3: yt-dlp 自身的 embed-metadata 后处理若失败（比如上游 ffmpeg 出错），
            # 会在目录里留下 "原名.temp.$AUDIO_EXT" 这种半成品文件——命名规律跟我们自己
            # 用的 temp_*/temp_mv_* 前缀不一样，之前没过滤掉，导致被当正常曲目去打标签，
            # 结果是"Invalid data found"这种一头雾水的 ffmpeg 报错。这里先按后缀过滤掉，
            # 再额外用 ffprobe 兜底探测任何形式的损坏文件，遇到就跳过而不是硬上
            [[ "$(basename "$f")" == *".temp.$AUDIO_EXT" ]] && { log "  ⚠️ Skipping yt-dlp leftover temp file: $(basename "$f")"; continue; }
            if grep -qxF "$f" /tmp/existing_before_$$.txt 2>/dev/null; then
                log "  ⏭️ Skipping existing: $(basename "$f")"
                continue
            fi
            if ! ffprobe -v error -i "$f" >/dev/null 2>&1; then
                log "  ⚠️ Skipping invalid/corrupt file: $(basename "$f")"
                continue
            fi
            JSON_FILE="${f%.$AUDIO_EXT}.info.json"
            TITLE=""; SA=""; REAL_ALBUM=""; HS=false; FORCE_TITLE=""; FORCE_ARTIST=""
            if [ -f "$JSON_FILE" ]; then
                TITLE=$(jq -r '.title // ""' "$JSON_FILE" 2>/dev/null)
                SA=$(jq -r '.artist // ""' "$JSON_FILE" 2>/dev/null)
                REAL_ALBUM=$(jq -r '.album // ""' "$JSON_FILE" 2>/dev/null)
                [ -n "$TITLE" ] && [ -n "$SA" ] && HS=true
            fi
            # v4.3: 电台/社区列表无元数据曲目 —— 新提取算法（extract_nm_info，与 postproc_normal 同规则）
            if [ "$TYPE" = "ytm_radio" ] && [ "$HS" != "true" ] && [ -f "$JSON_FILE" ]; then
                NM_UP=$(jq -r '.uploader // ""' "$JSON_FILE" 2>/dev/null)
                NM_INFO=$(extract_nm_info "$TITLE" "$NM_UP")
                FORCE_TITLE=$(printf '%s' "$NM_INFO" | cut -d'|' -f1)
                FORCE_ARTIST=$(printf '%s' "$NM_INFO" | cut -d'|' -f2)
                log "  ✂️ Extract: '$FORCE_ARTIST' / '$FORCE_TITLE'"
            fi
            CF=""
            if [ -f "$JSON_FILE" ]; then
                if download_cover "$JSON_FILE" CF; then
                    if [ "$HS" = "true" ]; then
                        CC="/tmp/cover_$$_cropped.jpg"
                        cover_crop_center "$CF" "$CC" 2>/dev/null
                        if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "  🖼️ Cover cropped (metadata)"; fi
                    else
                        CC="/tmp/cover_$$_compressed.jpg"
                        cover_compress "$CF" "$CC" 2>/dev/null
                        if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "  🖼️ Cover compressed (no metadata)"; fi
                    fi
                fi
                rm -f "$JSON_FILE"
            fi
            [ -n "$REAL_ALBUM" ] && FINAL_ALBUM="$REAL_ALBUM" || FINAL_ALBUM="$TITLE"
            embed_cover "$f" "" "$ALBUM_NAME" "$([ -n "$CF" ] && echo true || echo false)" "true" "$FINAL_ALBUM" "$CF" "$FORCE_TITLE" "${FORCE_ARTIST:-$SA}" >> "$LOG_FILE" 2>&1
            [ -n "$CF" ] && rm -f "$CF"
            # v4.3: 无元数据曲目按提取结果重命名（歌手 - 歌名），与 MV 分支同语义
            if [ "$HS" != "true" ] && [ -n "$FORCE_TITLE" ] && [ -n "$FORCE_ARTIST" ]; then
                SAFE_ARTIST=$(printf '%s' "$FORCE_ARTIST" | sed 's/[\/:*?"<>|]/-/g')
                SAFE_TITLE=$(printf '%s' "$FORCE_TITLE" | sed 's/[\/:*?"<>|]/-/g')
                NEW_NAME="${SAFE_ARTIST} - ${SAFE_TITLE}.$AUDIO_EXT"
                if [ "$(basename "$f")" != "$NEW_NAME" ]; then
                    if [ -e "$FINAL_PATH/$NEW_NAME" ]; then
                        # 目标名已存在 = 同名曲目已在库中：删本次新副本（对齐跳过已有语义），
                        # 否则重命名会破坏 yt-dlp 按文件名判重的幂等性
                        rm -f "$f"
                        f="$FINAL_PATH/$NEW_NAME"
                        log "  🔁 Duplicate: exists $NEW_NAME, new copy removed"
                    else
                        mv "$f" "$FINAL_PATH/$NEW_NAME"
                        f="$FINAL_PATH/$NEW_NAME"
                        log "  📝 Renamed: $NEW_NAME"
                    fi
                fi
            fi
            echo "$f" >> /tmp/existing_before_$$.txt
        done
        rm -f "$FINAL_PATH"/*.info.json "$FINAL_PATH"/*.webm "$FINAL_PATH"/*.temp.$AUDIO_EXT 2>/dev/null
        rm -f /tmp/existing_before_$$.txt
        log "🎉 Done: $ALBUM_NAME"
        continue
    fi

    if [ -n "$MV_VIDS" ] && [ "$MV_STRATEGY" = "1" ]; then
        log "🏷️ MV track post-processing..."
        for mv_f in "$FINAL_PATH"/temp_$$_mv_*.$AUDIO_EXT; do
            [ -f "$mv_f" ] || continue
            JSON_FILE="${mv_f%.$AUDIO_EXT}.info.json"
            VID=""
            [ -f "$JSON_FILE" ] && VID=$(jq -r '.id // ""' "$JSON_FILE" 2>/dev/null)
            if [ -n "$VID" ] && [ -n "${MV_DATA[$VID]}" ]; then
                IFS='|' read -r TITLE ARTIST ALBUM <<< "${MV_DATA[$VID]}"
                # v4.3: 预览误判安全网 —— info.json 有完整 artist+album 的曲目优先走 meta
                #（预览 hasMeta 是启发式，歌手频道上传的音频版本可能漏判为 MV）
                HS_META="false"
                if [ -f "$JSON_FILE" ]; then
                    M_SA=$(jq -r '.artist // ""' "$JSON_FILE" 2>/dev/null)
                    M_AL=$(jq -r '.album // ""' "$JSON_FILE" 2>/dev/null)
                    M_TI=$(jq -r '.title // ""' "$JSON_FILE" 2>/dev/null)
                    M_TR=$(jq -r '.track // ""' "$JSON_FILE" 2>/dev/null)
                    [ -n "$M_SA" ] && [ -n "$M_AL" ] && HS_META="true"
                fi
                if [ "$HS_META" = "true" ]; then
                    TITLE="${M_TR:-$M_TI}"; ARTIST="$M_SA"; ALBUM="$M_AL"
                    log "  📀 Metadata found, overriding MV manual info"
                fi
                SAFE_ARTIST=$(echo "$ARTIST" | sed 's/[\/:*?"<>|]/-/g')
                SAFE_TITLE=$(echo "$TITLE" | sed 's/[\/:*?"<>|]/-/g')
                NEW_NAME="${SAFE_ARTIST} - ${SAFE_TITLE}.$AUDIO_EXT"
                NEW_PATH="$FINAL_PATH/$NEW_NAME"
                if [ -f "$NEW_PATH" ]; then
                    rm -f "$mv_f"
                    log "  🔁 Duplicate: exists $NEW_NAME, new copy removed" "info" "dedupe"
                    echo "$NEW_PATH" >> /tmp/existing_before_$$.txt
                    continue
                fi
                mv "$mv_f" "$NEW_PATH"
                log "  📝 Renamed: $(basename "$mv_f") → $NEW_NAME"
                CF=""
                SA_META=""; HS=false
                if [ -f "$JSON_FILE" ]; then
                    SA_META="$M_SA"
                    [ -n "$TITLE" ] && [ -n "$SA_META" ] && HS=true
                fi
                if [ -f "$JSON_FILE" ]; then
                    if download_cover "$JSON_FILE" CF; then
                        if [ "$HS" = "true" ]; then
                            CC="/tmp/cover_$$_cropped.jpg"
                            cover_crop_center "$CF" "$CC" 2>/dev/null
                            if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "  🖼️ Cover cropped (metadata fallback)"; fi
                        else
                            CC="/tmp/cover_$$_compressed.jpg"
                            cover_compress "$CF" "$CC" 2>/dev/null
                            if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "  🖼️ Cover compressed (no metadata)"; fi
                        fi
                    fi
                fi
                FINAL_ALBUM="${ALBUM:-$TITLE}"
                mv_write_id3 "$NEW_PATH" "$TITLE" "$ARTIST" "$FINAL_ALBUM" "" "$CF"
                [ -n "$CF" ] && rm -f "$CF"
                echo "$NEW_PATH" >> /tmp/existing_before_$$.txt
            fi
            [ -f "$JSON_FILE" ] && rm -f "$JSON_FILE"
        done
    fi

    log "🏷️ Post-processing..."
    for f in "$FINAL_PATH"/*.$AUDIO_EXT; do
        [ -f "$f" ] || continue
        [[ "$(basename "$f")" == temp_* || "$(basename "$f")" == temp_mv_* ]] && continue
        # v4.0.3: 同上——过滤 yt-dlp 自己的 "原名.temp.$AUDIO_EXT" 半成品文件，
        # 并用 ffprobe 兜底探测任何损坏文件，跳过而不是硬打标签导致报错
        [[ "$(basename "$f")" == *".temp.$AUDIO_EXT" ]] && { log "  ⚠️ Skipping yt-dlp leftover temp file: $(basename "$f")"; continue; }
        if grep -qxF "$f" /tmp/existing_before_$$.txt 2>/dev/null; then
            log "  ⏭️ Skipping existing: $(basename "$f")"
            continue
        fi
        if ! ffprobe -v error -i "$f" >/dev/null 2>&1; then
            log "  ⚠️ Skipping invalid/corrupt file: $(basename "$f")"
            continue
        fi
        ORIG_ALBUM=""; CF=""; HC="false"; FORCE_TITLE=""; FORCE_ARTIST=""; SA=""
        if [ "$ENHANCED_MODE" = "true" ]; then
            JSON_FILE="${f%.$AUDIO_EXT}.info.json"
            if [ -f "$JSON_FILE" ]; then
                ORIG_ALBUM=$(jq -r '.album // ""' "$JSON_FILE" 2>/dev/null)
                SA=$(jq -r '.artist // ""' "$JSON_FILE" 2>/dev/null)
                HS=false
                [ -n "$ORIG_ALBUM" ] && [ -n "$SA" ] && HS=true
                log "  📀 Metadata: $HS"
                # v4.3: 电台/社区列表无元数据曲目 —— 新提取算法（extract_nm_info）
                if [ "$TYPE" = "ytm_radio" ] && [ "$HS" != true ]; then
                    TITLE_RAW=$(jq -r '.title // ""' "$JSON_FILE" 2>/dev/null)
                    NM_UP=$(jq -r '.uploader // ""' "$JSON_FILE" 2>/dev/null)
                    NM_INFO=$(extract_nm_info "$TITLE_RAW" "$NM_UP")
                    FORCE_TITLE=$(printf '%s' "$NM_INFO" | cut -d'|' -f1)
                    FORCE_ARTIST=$(printf '%s' "$NM_INFO" | cut -d'|' -f2)
                    log "  ✂️ Extract: '$FORCE_ARTIST' / '$FORCE_TITLE'"
                fi
                if download_cover "$JSON_FILE" CF; then
                    if [ "$HS" = "true" ]; then
                        CC="/tmp/cover_$$_cropped.jpg"
                        if cover_crop_center "$CF" "$CC"; then
                            rm -f "$CF"; CF="$CC"; HC="true"
                            log "  🖼️ Cover cropped (1:1)"
                        else
                            log "  ⚠️ Crop failed, using original"
                            HC="true"
                        fi
                    else
                        CC="/tmp/cover_$$_compressed.jpg"
                        if cover_compress "$CF" "$CC"; then
                            rm -f "$CF"; CF="$CC"; HC="true"
                            log "  🖼️ Cover compressed"
                        else
                            HC="true"
                        fi
                    fi
                fi
                rm -f "$JSON_FILE"
            fi
        else
            ORIG_ALBUM="$ALBUM_NAME"
            if [ -n "$UNIFIED_COVER" ] && [ -f "$UNIFIED_COVER" ] && [ "$(file_size "$UNIFIED_COVER" 2>/dev/null)" -gt 10240 ]; then
                CF="$UNIFIED_COVER"
                HC="true"
                log "  🖼️ Using unified cover"
            fi
        fi
        embed_cover "$f" "$ALBUM_ARTIST" "$ALBUM_NAME" "$HC" "$ENHANCED_MODE" "$ORIG_ALBUM" "$CF" "$FORCE_TITLE" "${FORCE_ARTIST:-$SA}" >> "$LOG_FILE" 2>&1
        [ -n "$CF" ] && [ "$CF" != "$UNIFIED_COVER" ] && rm -f "$CF"
        # v4.3: 无元数据曲目按提取结果重命名（歌手 - 歌名），与 MV 分支同语义
        if [ "$HS" != "true" ] && [ -n "$FORCE_TITLE" ] && [ -n "$FORCE_ARTIST" ]; then
            SAFE_ARTIST=$(printf '%s' "$FORCE_ARTIST" | sed 's/[\/:*?"<>|]/-/g')
            SAFE_TITLE=$(printf '%s' "$FORCE_TITLE" | sed 's/[\/:*?"<>|]/-/g')
            NEW_NAME="${SAFE_ARTIST} - ${SAFE_TITLE}.$AUDIO_EXT"
            if [ "$(basename "$f")" != "$NEW_NAME" ]; then
                if [ -e "$FINAL_PATH/$NEW_NAME" ]; then
                    # 目标名已存在 = 同名曲目已在库中：删本次新副本（对齐跳过已有语义），
                    # 否则重命名会破坏 yt-dlp 按文件名判重的幂等性
                    rm -f "$f"
                    f="$FINAL_PATH/$NEW_NAME"
                    log "  🔁 Duplicate: exists $NEW_NAME, new copy removed"
                else
                    mv "$f" "$FINAL_PATH/$NEW_NAME"
                    f="$FINAL_PATH/$NEW_NAME"
                    log "  📝 Renamed: $NEW_NAME"
                fi
            fi
        fi
    done
    rm -f "$FINAL_PATH"/*.info.json "$FINAL_PATH"/*.webm "$FINAL_PATH"/*.temp.$AUDIO_EXT 2>/dev/null
    rm -f /tmp/existing_before_$$.txt
    log "🎉 Done: $ALBUM_NAME"
done

# 最后一轮的封面临时目录清理
[ -n "$CTD" ] && rm -rf "$CTD" 2>/dev/null

# v4.0.8: 释放最后一个专辑持有的文件夹锁
flock -u 9 2>/dev/null

rm -f "$0"
exit 0
LOOPEOF

nohup bash "$WORKER_SH" >> "$LOG_FILE" 2>&1 &
WORKER_PID=$!

echo ""
if is_en; then
    echo "📝 Log: tail -n +1 -f \"$LOG_FILE\""
    echo "🚀 Running in the background..."
else
    echo "📝 日志: tail -n +1 -f \"$LOG_FILE\""
    echo "🚀 切入后台..."
fi
echo "✅ PID: $WORKER_PID"
