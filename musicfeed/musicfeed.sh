#!/bin/bash
# ─────────────────────────────────────────────
# musicfeed V3.5.1
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 加载纯函数库（配置加载、常量、工具函数、yt-dlp 元数据抓取、链接类型检测）
# shellcheck disable=SC1091
source "$SCRIPT_DIR/mf_lib.sh"

echo "=================================================="
echo " 🎵 musicfeed V3.5.1"
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

    while IFS= read -r line; do
        [[ "$line" == "$MF_DEFAULT_ARTIST_DIR" ]] && continue
        local hidden=0
        for h in "${MF_HIDDEN_DIRS[@]}"; do
            [[ "$line" == "$h" ]] && hidden=1 && break
        done
        [ $hidden -eq 1 ] && continue
        folders+=("$line")
    done < <(ls -F "$MF_BASE_DIR" 2>/dev/null | grep '/$' | sed 's/\///')

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

    if [ "$TRACK_COUNT" -gt 100 ]; then
        if is_en; then
            echo "⚠️ Note: Playlist has $TRACK_COUNT tracks. Due to yt-dlp limits, only the first 100 can be fetched."
        else
            echo "⚠️ 提示: 播放列表共 $TRACK_COUNT 首。受 yt-dlp 限制，目前仅能抓取并下载前 100 首。"
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

mv_write_id3() {
    python3 - "$@" << 'PYEOF'
import sys, os, re

def split_artists(artist_str):
    """智能拆分多艺人字符串，返回艺人列表"""
    if not artist_str:
        return ['Unknown Artist']
    
    # 先统一中文逗号为英文逗号 (中文逗号 Unicode: \uff0c)
    artist_str = artist_str.replace('\uff0c', ',')
    
    # 定义分隔符模式（按优先级排序）
    patterns = [
        r'\s+feat\.\s+',
        r'\s+ft\.\s+',
        r'\s+&\s+',
        r'\s*,\s*',  # 逗号 (已统一处理)
        r'\s+with\s+',
        r'\s+vs\.\s+'
    ]
    
    result = [artist_str]
    for pattern in patterns:
        new_result = []
        for item in result:
            parts = re.split(pattern, item, flags=re.IGNORECASE)
            new_result.extend([p.strip() for p in parts if p.strip()])
        result = new_result
    
    # 去重并保持顺序
    seen = set()
    unique = []
    for a in result:
        if a and a not in seen and a.lower() not in seen:
            seen.add(a.lower())
            unique.append(a)
    
    return unique if unique else ['Unknown Artist']

fpath = sys.argv[1]; title = sys.argv[2]; artist = sys.argv[3]
album = sys.argv[4]; album_artist = sys.argv[5]; cover_file = sys.argv[6] if len(sys.argv) > 6 else ""

# 拆分多艺人
artists_list = split_artists(artist)

if fpath.endswith('.m4a'):
    from mutagen.mp4 import MP4, MP4Cover
    audio = MP4(fpath)
    audio['\xa9nam'] = [title]
    audio['\xa9ART'] = artists_list  # 多艺人列表
    if album: audio['\xa9alb'] = [album]
    elif '\xa9alb' in audio: del audio['\xa9alb']
    if album_artist: audio['aART'] = [album_artist]
    elif 'aART' in audio: del audio['aART']
    if cover_file and os.path.exists(cover_file):
        with open(cover_file, 'rb') as img:
            audio['covr'] = [MP4Cover(img.read(), imageformat=MP4Cover.FORMAT_JPEG)]
        print(f'  ✅ +Cover: {os.path.basename(fpath)}')
    else:
        print(f'  ✅ ID3: {os.path.basename(fpath)}')
    audio.save()
else:
    from mutagen.oggopus import OggOpus
    audio = OggOpus(fpath)
    audio['title'] = [title]
    audio['artist'] = artists_list  # 多艺人列表 (Vorbis Comments 原生支持多值)
    if album: audio['album'] = [album]
    elif 'album' in audio: del audio['album']
    if album_artist: audio['ALBUMARTIST'] = [album_artist]  # 大写 ALBUMARTIST
    elif 'ALBUMARTIST' in audio: del audio['ALBUMARTIST']
    if cover_file and os.path.exists(cover_file):
        from mutagen.flac import Picture
        import base64
        with open(cover_file, 'rb') as img:
            pic = Picture(); pic.data = img.read(); pic.type = 3; pic.mime = 'image/jpeg'
            audio['metadata_block_picture'] = [base64.b64encode(pic.write()).decode('ascii')]
        print(f'  ✅ +Cover: {os.path.basename(fpath)}')
    else:
        print(f'  ✅ ID3: {os.path.basename(fpath)}')
    audio.save()
PYEOF
}

embed_cover() {
    python3 - "$@" << 'PYEOF'
import sys, os, re, base64

def split_artists(artist_str):
    """智能拆分多艺人字符串，返回艺人列表"""
    if not artist_str:
        return ['Unknown Artist']
    artist_str = artist_str.replace('\uff0c', ',')
    patterns = [r'\s+feat\.\s+', r'\s+ft\.\s+', r'\s+&\s+', r'\s*,\s*', r'\s+with\s+', r'\s+vs\.\s+']
    result = [artist_str]
    for pattern in patterns:
        new_result = []
        for item in result:
            parts = re.split(pattern, item, flags=re.IGNORECASE)
            new_result.extend([p.strip() for p in parts if p.strip()])
        result = new_result
    seen = set()
    unique = []
    for a in result:
        if a and a not in seen and a.lower() not in seen:
            seen.add(a.lower())
            unique.append(a)
    return unique if unique else ['Unknown Artist']

fpath = sys.argv[1]; aa = sys.argv[2]; an = sys.argv[3]
hc = sys.argv[4]; em = sys.argv[5]; oa = sys.argv[6]; cf = sys.argv[7] if len(sys.argv) > 7 else ""
# v3.4: 无元数据曲目按 title 首个 " - " 拆分出的强制歌名/歌手（优先级高于文件名提取）
ft = sys.argv[8] if len(sys.argv) > 8 else ''
fa = sys.argv[9] if len(sys.argv) > 9 else ''

# 从文件名提取艺人信息（如果有）
basename = os.path.basename(fpath)
artist_from_file = None
if ' - ' in basename:
    artist_part = basename.split(' - ')[0]
    if artist_part and artist_part != 'NA':
        artists_list = split_artists(artist_part)
    else:
        artists_list = []
else:
    artists_list = []
if fa:
    artists_list = split_artists(fa)

try:
    if fpath.endswith('.m4a'):
        from mutagen.mp4 import MP4, MP4Cover
        audio = MP4(fpath)
        if aa and aa not in ('None','SKIP',''): audio['aART'] = [aa]
        elif 'aART' in audio: del audio['aART']
        # 写入多艺人标签
        if artists_list:
            audio['\xa9ART'] = artists_list
        if ft: audio['\xa9nam'] = [ft]
        if em=='true' and oa and oa!='None' and not oa.startswith('%'): audio['\xa9alb'] = [oa]
        else: audio['\xa9alb'] = [an]
        if em=='true' and 'trkn' in audio: del audio['trkn']
        if hc=='true' and cf and os.path.exists(cf):
            with open(cf,'rb') as img: audio['covr'] = [MP4Cover(img.read(), imageformat=MP4Cover.FORMAT_JPEG)]
            print(f'  ✅ +Cover: {os.path.basename(fpath)}')
        else:
            print(f'  ✅ ID3: {os.path.basename(fpath)}')
        audio.save()
    else:
        from mutagen.oggopus import OggOpus
        from mutagen.flac import Picture
        audio = OggOpus(fpath)
        if aa and aa not in ('None','SKIP',''): audio['ALBUMARTIST'] = [aa]
        elif 'ALBUMARTIST' in audio: del audio['ALBUMARTIST']
        # 写入多艺人标签
        if artists_list:
            audio['artist'] = artists_list
        if ft: audio['title'] = [ft]
        if em=='true' and oa and oa!='None' and not oa.startswith('%'): audio['album'] = [oa]
        else: audio['album'] = [an]
        if em=='true' and 'tracknumber' in audio: del audio['tracknumber']
        if hc=='true' and cf and os.path.exists(cf):
            with open(cf,'rb') as img:
                pic=Picture(); pic.data=img.read(); pic.type=3; pic.mime='image/jpeg'
                audio['metadata_block_picture'] = [base64.b64encode(pic.write()).decode('ascii')]
            print(f'  ✅ +Cover: {os.path.basename(fpath)}')
        else:
            print(f'  ✅ ID3: {os.path.basename(fpath)}')
        audio.save()
except Exception as e:
    print(f'  ❌ Failed: {os.path.basename(fpath)} - {e}')
PYEOF
}

get_cover_url() {
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
thumbs = sorted(d.get('thumbnails',[]), key=lambda x: x.get('width',0)*x.get('height',0), reverse=True)
if thumbs: print(thumbs[0]['url'])
" "$1" 2>/dev/null
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
extract_nm_info() {
    python3 - "$1" "$2" << 'NM_PYEOF'
import re, sys

POLL = re.compile(r'歌詞|歌词|動態|动态|MV|Official|官方|Video|Audio|Visualizer|Live|完整版|主題曲|主题曲|片尾曲|片頭曲|片头曲', re.I)
KEEP = re.compile(r'feat|ft\.|国|國|粤|粵', re.I)
BR = re.compile(r'（([^（）()]*)）|\(([^()]*)\)|『([^『』]*)』|「([^「」]*)」|【([^【】]*)】|《([^《》]*)》|\[([^\[\]]*)\]')

def inner_of(m):
    return next(g for g in m.groups() if g is not None)

def br_proc(s):
    prev = None
    while prev != s:
        prev = s
        def repl(m):
            inner = inner_of(m)
            flat = BR.sub(' ', inner)
            if POLL.search(flat):
                return ''
            if KEEP.search(flat):
                return m.group(0)
            return inner
        s = BR.sub(repl, s)
    return s

def clean(s):
    s = re.sub(r'\s*-\s*$', '', s)
    s = re.sub(r'\s{2,}', ' ', s)
    return s.strip(' -').strip()

def esc(s):
    return (s or '').replace('|', '｜')

title = sys.argv[1] or ''
up = re.sub(r'\s*-\s*Topic\s*$', '', sys.argv[2] or '').strip()
t = title.replace('–', '-').replace('—', '-')

m = re.search(r'《([^《》]*)》', t) or re.search(r'【([^【】]*)】', t) or re.search(r'\[([^\[\]]*)\]', t)
if m:
    song = br_proc(m.group(1)).strip()
    if song and not POLL.search(BR.sub(' ', song)):
        prefix = re.sub(r'^(\[[^\]]*\]\s*)+', '', t[:m.start()].strip())
        prefix = re.sub(r'[\s\-:：*|｜]+$', '', prefix).strip()
        artist = prefix if prefix and len(prefix) <= 30 else up
        print(f"{esc(song)}|{esc(artist)}")
        sys.exit(0)

t2 = br_proc(t)
segs = [s.strip() for s in t2.split(' - ') if s.strip()]
if len(segs) >= 2:
    if up:
        keep = [s for s in segs if not (s in up or up in s)]
        if keep and len(keep) < len(segs):
            print(f"{esc(clean(keep[0]))}|{esc(up)}")
            sys.exit(0)
    print(f"{esc(clean(' - '.join(segs[1:])))}|{esc(segs[0])}")
    sys.exit(0)

print(f"{esc(clean(t2))}|{esc(up)}")
NM_PYEOF
}

log "⚙️ PID: $$ | 🕒 $(date '+%Y-%m-%d %H:%M:%S')"
WORKEREOF

replace_token() {
    python3 - "$WORKER_SH" "$1" "$2" << 'PYEOF'
import sys
path, token, value = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, 'r', encoding='utf-8') as f:
    data = f.read()
data = data.replace(token, value)
with open(path, 'w', encoding='utf-8') as f:
    f.write(data)
PYEOF
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
            -o "temp_mv_%(id)s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1

    elif [ "$MV_STRATEGY" = "2" ]; then
        log "🚚 Default mode batch..."
        "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --yes-playlist \
            --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json \
            "${FORMAT_ARGS[@]}" \
            --playlist-items "$SELECTION" \
            -o "%(artist,uploader)s - %(title)s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1

    else
        if [ -n "$NORMAL_SELECTION" ]; then
            log "🚚 Normal track batch..."
            "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --yes-playlist \
                --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json \
                "${FORMAT_ARGS[@]}" \
                --playlist-items "$NORMAL_SELECTION" \
                -o "%(artist,uploader)s - %(title)s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1
        fi

        if [ -n "$MV_VIDS" ] && [ "$MV_STRATEGY" = "1" ]; then
            while IFS= read -r VID; do
                [ -z "$VID" ] && continue
                SINGLE_URL="https://www.youtube.com/watch?v=$VID"
                log "🚚 MV track: $VID"
                "$YTDLP" $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                    --embed-metadata --no-embed-thumbnail --windows-filenames --trim-filenames 78 --write-info-json \
                    "${FORMAT_ARGS[@]}" \
                    -o "temp_mv_%(id)s.%(ext)s" -P "$FINAL_PATH" "$SINGLE_URL" >> "$LOG_FILE" 2>&1
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
                -o "%(artist,uploader)s - %(title)s.%(ext)s" -P "$FINAL_PATH" "$url" >> "$LOG_FILE" 2>&1
        fi
    fi

    log "✅ Download complete"

    if [ "$IS_MV_SINGLE" = true ]; then
        log "🏷️ MV single post-processing..."
        for mv_f in "$FINAL_PATH"/temp_mv_*.$AUDIO_EXT; do
            [ -f "$mv_f" ] || continue
            SAFE_ARTIST=$(echo "$MV_ARTIST" | sed 's/[\/:*?"<>|]/-/g')
            SAFE_TITLE=$(echo "$MV_TITLE" | sed 's/[\/:*?"<>|]/-/g')
            NEW_NAME="${SAFE_ARTIST} - ${SAFE_TITLE}.$AUDIO_EXT"
            NEW_PATH="$FINAL_PATH/$NEW_NAME"
            [ -f "$NEW_PATH" ] && NEW_PATH="$FINAL_PATH/${SAFE_ARTIST} - ${SAFE_TITLE}_$(date +%s).$AUDIO_EXT"
            mv "$mv_f" "$NEW_PATH"
            log "  📝 Renamed: $(basename "$mv_f") → $NEW_NAME"
            CF=""; JSON_FILE="${NEW_PATH%.$AUDIO_EXT}.info.json"
            [ ! -f "$JSON_FILE" ] && JSON_FILE=$(find "$FINAL_PATH" -name "temp_mv_*.info.json" 2>/dev/null | head -1)
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
        rm -f "$FINAL_PATH"/temp_mv_* "$FINAL_PATH"/*.webm 2>/dev/null
        log "🎉 Done: $ALBUM_NAME"
        continue
    fi

    if [ "$MV_STRATEGY" = "2" ]; then
        log "🏷️ Default mode post-processing..."
        for f in "$FINAL_PATH"/*.$AUDIO_EXT; do
            [ -f "$f" ] || continue
            [[ "$(basename "$f")" == temp_* ]] && continue
            if grep -qxF "$f" /tmp/existing_before_$$.txt 2>/dev/null; then
                log "  ⏭️ Skipping existing: $(basename "$f")"
                continue
            fi
            JSON_FILE="${f%.$AUDIO_EXT}.info.json"
            TITLE=""; SA=""; REAL_ALBUM=""; HS=false; FORCE_TITLE=""; FORCE_ARTIST=""
            if [ -f "$JSON_FILE" ]; then
                TITLE=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('title',''))" "$JSON_FILE" 2>/dev/null)
                SA=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('artist',''))" "$JSON_FILE" 2>/dev/null)
                REAL_ALBUM=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('album',''))" "$JSON_FILE" 2>/dev/null)
                [ -n "$TITLE" ] && [ -n "$SA" ] && HS=true
            fi
            # v4.3: 电台/社区列表无元数据曲目 —— 新提取算法（extract_nm_info，与 postproc_normal 同规则）
            if [ "$TYPE" = "ytm_radio" ] && [ "$HS" != "true" ] && [ -f "$JSON_FILE" ]; then
                NM_UP=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('uploader',''))" "$JSON_FILE" 2>/dev/null)
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
            embed_cover "$f" "" "$ALBUM_NAME" "$([ -n "$CF" ] && echo true || echo false)" "true" "$FINAL_ALBUM" "$CF" "$FORCE_TITLE" "$FORCE_ARTIST" >> "$LOG_FILE" 2>&1
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
        rm -f "$FINAL_PATH"/*.info.json "$FINAL_PATH"/*.webm "$FINAL_PATH"/*.temp.* 2>/dev/null
        rm -f /tmp/existing_before_$$.txt
        log "🎉 Done: $ALBUM_NAME"
        continue
    fi

    if [ -n "$MV_VIDS" ] && [ "$MV_STRATEGY" = "1" ]; then
        log "🏷️ MV track post-processing..."
        for mv_f in "$FINAL_PATH"/temp_mv_*.$AUDIO_EXT; do
            [ -f "$mv_f" ] || continue
            JSON_FILE="${mv_f%.$AUDIO_EXT}.info.json"
            VID=""
            [ -f "$JSON_FILE" ] && VID=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('id',''))" "$JSON_FILE" 2>/dev/null)
            if [ -n "$VID" ] && [ -n "${MV_DATA[$VID]}" ]; then
                IFS='|' read -r TITLE ARTIST ALBUM <<< "${MV_DATA[$VID]}"
                # v4.3: 预览误判安全网 —— info.json 有完整 artist+album 的曲目优先走 meta
                #（预览 hasMeta 是启发式，歌手频道上传的音频版本可能漏判为 MV）
                HS_META="false"
                if [ -f "$JSON_FILE" ]; then
                    M_SA=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('artist',''))" "$JSON_FILE" 2>/dev/null)
                    M_AL=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('album',''))" "$JSON_FILE" 2>/dev/null)
                    M_TI=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('title',''))" "$JSON_FILE" 2>/dev/null)
                    M_TR=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('track',''))" "$JSON_FILE" 2>/dev/null)
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
                [ -f "$NEW_PATH" ] && NEW_PATH="$FINAL_PATH/${SAFE_ARTIST} - ${SAFE_TITLE}_$(date +%s).$AUDIO_EXT"
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
        if grep -qxF "$f" /tmp/existing_before_$$.txt 2>/dev/null; then
            log "  ⏭️ Skipping existing: $(basename "$f")"
            continue
        fi
        ORIG_ALBUM=""; CF=""; HC="false"; FORCE_TITLE=""; FORCE_ARTIST=""
        if [ "$ENHANCED_MODE" = "true" ]; then
            JSON_FILE="${f%.$AUDIO_EXT}.info.json"
            if [ -f "$JSON_FILE" ]; then
                ORIG_ALBUM=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('album',''))" "$JSON_FILE" 2>/dev/null)
                SA=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('artist',''))" "$JSON_FILE" 2>/dev/null)
                HS=false
                [ -n "$ORIG_ALBUM" ] && [ -n "$SA" ] && HS=true
                log "  📀 Metadata: $HS"
                # v4.3: 电台/社区列表无元数据曲目 —— 新提取算法（extract_nm_info）
                if [ "$TYPE" = "ytm_radio" ] && [ "$HS" != true ]; then
                    TITLE_RAW=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('title',''))" "$JSON_FILE" 2>/dev/null)
                    NM_UP=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('uploader',''))" "$JSON_FILE" 2>/dev/null)
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
        embed_cover "$f" "$ALBUM_ARTIST" "$ALBUM_NAME" "$HC" "$ENHANCED_MODE" "$ORIG_ALBUM" "$CF" "$FORCE_TITLE" "$FORCE_ARTIST" >> "$LOG_FILE" 2>&1
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
    rm -f "$FINAL_PATH"/*.info.json "$FINAL_PATH"/*.webm "$FINAL_PATH"/*.temp.* 2>/dev/null
    rm -f /tmp/existing_before_$$.txt
    log "🎉 Done: $ALBUM_NAME"
done

# 最后一轮的封面临时目录清理
[ -n "$CTD" ] && rm -rf "$CTD" 2>/dev/null

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
