#!/bin/bash
# mf_batch.sh - musicfeed 非交互式入口
# 供 Web UI 后端调用
#
# 子命令:
#   preview   — 预览链接元数据（不下载），输出 JSON
#   download  — 启动下载任务（前台运行），输出 JSON 进度行
#
# 退出码:
#   0  成功
#   1  一般错误（参数错误 / 配置缺失）
#   2  链接类型未知
#   3  元数据抓取失败
#  10+ worker 子进程退出码透传

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/mf_lib.sh"

# ─────────────────────────────────────────────
# 工具：安全 JSON 输出
# ─────────────────────────────────────────────
emit_json_error() {
    # usage: emit_json_error "error message"
    jq -cn --arg error "$1" '{ok: false, error: $error}'
}
# ── preview JSON 组装（jq 版，替代原 python 解析；字段结构与 WebUI 约定一致）──
preview_json_album() {
    # $1 = get_album_info 输出：行1 专辑名 / 行2 数量 / 行3 歌手 / 行4+ "N. 曲名"
    local info="$1" album count artist line idx title tracks="" sep=""
    album=$(printf '%s\n' "$info" | sed -n '1p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    count=$(printf '%s\n' "$info" | sed -n '2p'); [[ "$count" =~ ^[0-9]+$ ]] || count=0
    artist=$(printf '%s\n' "$info" | sed -n '3p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        if [[ "$line" == *". "* ]]; then
            idx="${line%%. *}"; title="${line#*. }"
            [[ "$idx" =~ ^[0-9]+$ ]] || continue
        else
            idx=0; title="$line"
        fi
        tracks="$tracks$sep$(jq -cn --argjson idx "$idx" --arg title "$title" '{idx:$idx,title:$title,vid:"",hasMeta:true}')"
        sep=","
    done < <(printf '%s\n' "$info" | tail -n +4)
    jq -cn --arg album "$album" --argjson count "$count" --arg artist "$artist" \
        --argjson tracks "[$tracks]" \
        '{ok:true, type:"album", albumName:$album, artist:$artist, trackCount:$count, tracks:$tracks, hasMetadata:true}'
}

preview_json_playlist() {
    # $1 = get_playlist_info 输出：行1 名称 / 行2 数量 / 行3+ "N. 曲名|vid|hasMeta|uploader"
    # $2 = type（playlist | ytm_radio）
    local info="$1" type="$2" playlist count line idx rest title vid has_meta uploader
    local tracks="" sep="" any_meta=false display_artist="" rest2 tj
    playlist=$(printf '%s\n' "$info" | sed -n '1p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    count=$(printf '%s\n' "$info" | sed -n '2p'); [[ "$count" =~ ^[0-9]+$ ]] || count=0
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        if [[ "$line" == *". "* ]]; then
            idx="${line%%. *}"; rest="${line#*. }"
            [[ "$idx" =~ ^[0-9]+$ ]] || continue
        else
            idx=0; rest="$line"
        fi
        title="${rest%%|*}"
        rest2="${rest#*|}"
        if [[ "$rest2" == *"|"* ]]; then vid="${rest2%%|*}"; rest2="${rest2#*|}"; else vid="$rest2"; rest2=""; fi
        if [[ "$rest2" == *"|"* ]]; then has_meta="${rest2%%|*}"; uploader="${rest2#*|}"; else has_meta="$rest2"; uploader=""; fi
        [ "$has_meta" = "True" ] && any_meta=true
        uploader=$(printf '%s' "$uploader" | sed -E 's/ - Topic$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -z "$display_artist" ] && [ -n "$uploader" ]; then display_artist="$uploader"; fi
        tj=$(jq -cn --argjson idx "$idx" --arg title "$title" --arg vid "$vid" \
            --argjson hm "$([ "$has_meta" = "True" ] && echo true || echo false)" --arg uploader "$uploader" \
            '{idx:$idx,title:$title,vid:$vid,hasMeta:$hm,uploader:$uploader}')
        tracks="$tracks$sep$tj"; sep=","
    done < <(printf '%s\n' "$info" | tail -n +3)
    jq -cn --arg type "$type" --arg album "$playlist" --arg artist "$display_artist" \
        --argjson count "$count" --argjson hm "$any_meta" --argjson tracks "[$tracks]" \
        '{ok:true, type:$type, albumName:$album, artist:$artist, trackCount:$count, tracks:$tracks, hasMetadata:$hm}'
}

preview_json_single() {
    # $1 = get_single_info 输出：行1 专辑 / 行2 歌名 / 行3 歌手 / 行4 上传者 / 行5 hasMeta
    local info="$1" album title artist uploader has_meta=false display_name display_artist
    album=$(printf '%s\n' "$info" | sed -n '1p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    title=$(printf '%s\n' "$info" | sed -n '2p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'); [ -z "$title" ] && title="Unknown"
    artist=$(printf '%s\n' "$info" | sed -n '3p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    uploader=$(printf '%s\n' "$info" | sed -n '4p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ "$(printf '%s\n' "$info" | sed -n '5p')" = "True" ] && has_meta=true
    display_name="$album"; [ -z "$display_name" ] && display_name="$title"
    display_artist="$artist"; [ -z "$display_artist" ] && display_artist="$uploader"
    jq -cn --arg dn "$display_name" --arg da "$display_artist" --arg title "$title" --argjson hm "$has_meta" \
        '{ok:true, type:"single", albumName:$dn, artist:$da, trackCount:1, tracks:[{idx:1,title:$title,vid:"",hasMeta:$hm}], hasMetadata:$hm}'
}
# ── done 文件写入（WebUI 轮询任务结束状态用）──
write_done_file() {
    local file="$1" ec="$2" err="${3:-}" ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ' | sed -E 's/(\.[0-9]{6})[0-9]+$/\1/')
    if [ -n "$err" ]; then
        jq -n --argjson ec "$ec" --arg ts "$ts" --arg err "$err" \
            '{exitCode:$ec, finishedAt:$ts, error:$err}' > "$file"
    else
        jq -n --argjson ec "$ec" --arg ts "$ts" \
            '{exitCode:$ec, finishedAt:$ts}' > "$file"
    fi
}

# ─────────────────────────────────────────────
# 子命令 A: preview
# ─────────────────────────────────────────────
preview_cmd() {
    local url="" lang="${MF_LANG:-en}"
    while [ $# -gt 0 ]; do
        case "$1" in
            --url) url="$2"; shift 2;;
            --lang) lang="$2"; shift 2;;
            --help|-h)
                cat <<EOF
mf_batch.sh preview --url URL [--lang zh|en]
  输出 JSON 元数据，不下载。
EOF
                exit 0;;
            *) emit_json_error "preview: unknown argument: $1"; exit 1;;
        esac
    done

    [ -z "$url" ] && { emit_json_error "preview: --url is required"; exit 1; }

    # 局部 override MF_LANG
    MF_LANG="$lang"

    local type
    type=$(get_link_type "$url")
    [ "$type" = "unknown" ] && { emit_json_error "preview: unknown link type for $url"; exit 2; }

    case "$type" in
        album)
            local info
            info=$(get_album_info "$url")
            if [ -z "$info" ]; then
                emit_json_error "preview: failed to fetch album metadata (yt-dlp returned empty)"
                exit 3
            fi
            preview_json_album "$info"
            ;;
        playlist|ytm_radio)
            local info
            info=$(get_playlist_info "$url")
            if [ -z "$info" ]; then
                emit_json_error "preview: failed to fetch playlist metadata (yt-dlp returned empty)"
                exit 3
            fi
            preview_json_playlist "$info" "$type"
            ;;
        single)
            local info
            info=$(get_single_info "$url")
            if [ -z "$info" ]; then
                emit_json_error "preview: failed to fetch single metadata (yt-dlp returned empty)"
                exit 3
            fi
            preview_json_single "$info"
            ;;
        *)
            emit_json_error "preview: unsupported type $type"
            exit 2
            ;;
    esac
}

# ─────────────────────────────────────────────
# 子命令 B: download
# ─────────────────────────────────────────────
download_cmd() {
    local url="" artist_dir="" cover_mode="unified" album_artist_arg="" tracks="all"
    local format="" playlist_mode="mv" mv_strategy="default" lang="${MF_LANG:-en}"
    local job_id="" json_output=0 mv_meta="" subfolder=""
    local mv_title="" mv_artist="" mv_album=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --url) url="$2"; shift 2;;
            --artist-dir) artist_dir="$2"; shift 2;;
            --subfolder) subfolder="$2"; shift 2;;
            --cover-mode) cover_mode="$2"; shift 2;;
            --album-artist) album_artist_arg="$2"; shift 2;;
            --tracks) tracks="$2"; shift 2;;
            --format) format="$2"; shift 2;;
            --playlist-mode) playlist_mode="$2"; shift 2;;
            --mv-strategy) mv_strategy="$2"; shift 2;;
            --lang) lang="$2"; shift 2;;
            --job-id) job_id="$2"; shift 2;;
            --mv-meta) mv_meta="$2"; shift 2;;
            --mv-title) mv_title="$2"; shift 2;;
            --mv-artist) mv_artist="$2"; shift 2;;
            --mv-album) mv_album="$2"; shift 2;;
            --json-output) json_output=1; shift;;
            --help|-h)
                cat <<EOF
mf_batch.sh download [options]
  --url URL              必填，下载源链接
  --artist-dir NAME      必填，歌手文件夹名
  --subfolder NAME       可选，自定义子文件夹名（覆盖专辑层 → 歌手/NAME）；"none" = 直接下载到 歌手/
  --cover-mode M         unified (默认) | per-track
  --album-artist NAME    Album Artist；"skip" 表示不写入；未传则=artist-dir
  --tracks SPEC          all (默认) | "1,3,5-7"
  --format F             opus (默认) | m4a
  --playlist-mode M       mv (默认) | ytm；仅对 PL/LM 链接生效
  --mv-strategy S        default (默认) | manual
  --lang L               zh (默认) | en
  --job-id ID            任务 ID（用于日志文件名）；缺省自动生成
  --mv-meta STR          可选，"VID=T=A=AL;..."；manual 模式下使用
  --mv-title T           可选，单曲 MV 手动元数据：歌名（设定即视为 manual 模式）
  --mv-artist A          可选，单曲 MV 手动元数据：歌手
  --mv-album AL          可选，单曲 MV 手动元数据：专辑（缺省 = 歌名）
  --json-output          启用 JSON 行日志输出
EOF
                exit 0;;
            *) echo "download: unknown argument: $1" >&2; exit 1;;
        esac
    done

    # 参数校验
    [ -z "$url" ] && { echo "download: --url is required" >&2; exit 1; }
    [ -z "$artist_dir" ] && { echo "download: --artist-dir is required" >&2; exit 1; }
    case "$cover_mode" in unified|per-track) ;; *) echo "download: --cover-mode must be unified|per-track" >&2; exit 1;; esac
    case "$playlist_mode" in mv|ytm) ;; *) echo "download: --playlist-mode must be mv|ytm" >&2; exit 1;; esac
    case "$mv_strategy" in default|manual) ;; *) echo "download: --mv-strategy must be default|manual" >&2; exit 1;; esac
    case "$lang" in zh|en) ;; *) echo "download: --lang must be zh|en" >&2; exit 1;; esac
    if [ -n "$format" ]; then
        case "$format" in opus|m4a) ;; *) echo "download: --format must be opus|m4a" >&2; exit 1;; esac
        MF_AUDIO_FORMAT="$format"
    fi
    MF_LANG="$lang"

    [ -z "$job_id" ] && job_id="job-$(date +%s)-$$"

    # 简单 job_id 安全性检查（防止路径穿越）
    if [[ ! "$job_id" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "download: --job-id must match [A-Za-z0-9_.-]+" >&2; exit 1
    fi

    # artist_dir 路径穿越防护
    if [[ "$artist_dir" == ..* ]] || [[ "$artist_dir" == */..* ]] || [[ "$artist_dir" == /* ]]; then
        echo "download: --artist-dir must be a relative path without .." >&2; exit 1
    fi
    # subfolder 同样防护（v3.3）
    if [[ "$subfolder" == ..* ]] || [[ "$subfolder" == */..* ]] || [[ "$subfolder" == /* ]]; then
        echo "download: --subfolder must be a relative path without .." >&2; exit 1
    fi
    # v4.1: "none" = 完全不建专辑层子文件夹，音频直接落 歌手/（对齐 musicfeed.sh 交互里的「不创建子文件夹」）
    local NO_ALBUM_FOLDER=0
    if [ "$subfolder" = "none" ]; then subfolder=""; NO_ALBUM_FOLDER=1; fi

    # 日志目录 & 文件
    local LOG_DIR="$SCRIPT_DIR/log"
    mkdir -p "$LOG_DIR"
    local LOG_FILE="$LOG_DIR/mf-${job_id}.log"
    local DONE_FILE="$LOG_DIR/mf-${job_id}.done"
    # v4.1: 不截断（同一次队列运行共用一个日期时间命名的 log 文件，追加写入）
    touch "$LOG_FILE"

    # 链接类型检测
    local type
    type=$(get_link_type "$url")
    [ "$type" = "unknown" ] && {
        echo "download: unknown link type for $url" >&2
        write_done_file "$DONE_FILE" 2 "unknown link type"
        exit 2
    }

    # single 语义只取当前视频：剥离 &list= 参数，否则 watch?v=X&list=RD… 的
    # Mix/Radio 形态会让 yt-dlp 把整个播放列表逐条下载成 temp 文件
    if [ "$type" = "single" ] && [[ "$url" == *"&list="* ]]; then
        url="${url%%&list=*}"
        echo "download: single link — stripped playlist parameter" >&2
    fi

    # playlist 类型 → 根据 --playlist-mode 决定
    if [ "$type" = "playlist" ] && [ "$playlist_mode" = "ytm" ]; then
        type="ytm_radio"
    fi

    # ─────────────────────────────────────────────
    # 抓元数据，构造 ALBUM_CONFIGS[0]
    # 19 字段：ALBUM_NAME | SELECTION | url | FINAL_PATH | ALBUM_ARTIST |
    #          ENHANCED_MODE | TYPE | HAS_METADATA | MV_TITLE | MV_ARTIST |
    #          MV_ALBUM | MV_ALBUM_ARTIST | BATCH_ALBUM | (空) | (空) |
    #          NORMAL_SELECTION | MV_VIDS | MV_INFO | MV_STRATEGY
    # ─────────────────────────────────────────────
    local IS_SINGLE=false IS_PLAYLIST=false IS_ALBUM=false IS_YTM_RADIO=false
    local HAS_METADATA="False" DISPLAY_NAME="" TRACK_COUNT=0 DISPLAY_ARTIST=""
    local SONG_LIST="" SONG_LIST_FULL=""
    local SINGLE_TITLE="" SINGLE_ARTIST="" SINGLE_UPLOADER="" SINGLE_ALBUM=""
    local MV_TITLE="" MV_ARTIST="" MV_ALBUM="" MV_ALBUM_ARTIST=""
    local BATCH_ALBUM="" NORMAL_SELECTION="" MV_VIDS="" MV_INFO="" MV_STRATEGY=""
    local SELECTION="" SELECTED_COUNT=0

    case "$type" in
        album)
            IS_ALBUM=true; HAS_METADATA="True"
            INFO=$(get_album_info "$url")
            DISPLAY_NAME=$(printf '%s\n' "$INFO" | sed -n '1p')
            TRACK_COUNT=$(printf '%s\n' "$INFO" | sed -n '2p')
            [[ "$TRACK_COUNT" =~ ^[0-9]+$ ]] || TRACK_COUNT=0
            DISPLAY_ARTIST=$(printf '%s\n' "$INFO" | sed -n '3p')
            SONG_LIST=$(printf '%s\n' "$INFO" | tail -n +4)
            ;;
        ytm_radio)
            IS_YTM_RADIO=true
            INFO=$(get_playlist_info "$url")
            DISPLAY_NAME=$(printf '%s\n' "$INFO" | sed -n '1p')
            TRACK_COUNT=$(printf '%s\n' "$INFO" | sed -n '2p')
            [[ "$TRACK_COUNT" =~ ^[0-9]+$ ]] || TRACK_COUNT=0
            SONG_LIST_FULL=$(printf '%s\n' "$INFO" | tail -n +3)
            SONG_LIST=$(printf '%s\n' "$SONG_LIST_FULL" | sed 's/|.*//')
            ;;
        playlist)
            IS_PLAYLIST=true
            INFO=$(get_playlist_info "$url")
            DISPLAY_NAME=$(printf '%s\n' "$INFO" | sed -n '1p')
            TRACK_COUNT=$(printf '%s\n' "$INFO" | sed -n '2p')
            [[ "$TRACK_COUNT" =~ ^[0-9]+$ ]] || TRACK_COUNT=0
            SONG_LIST_FULL=$(printf '%s\n' "$INFO" | tail -n +3)
            SONG_LIST=$(printf '%s\n' "$SONG_LIST_FULL" | sed 's/|.*//')
            ;;
        single)
            IS_SINGLE=true
            SINGLE_INFO=$(get_single_info "$url")
            SINGLE_ALBUM=$(printf '%s\n' "$SINGLE_INFO" | sed -n '1p')
            SINGLE_TITLE=$(printf '%s\n' "$SINGLE_INFO" | sed -n '2p')
            SINGLE_ARTIST=$(printf '%s\n' "$SINGLE_INFO" | sed -n '3p')
            SINGLE_UPLOADER=$(printf '%s\n' "$SINGLE_INFO" | sed -n '4p')
            HAS_METADATA=$(printf '%s\n' "$SINGLE_INFO" | sed -n '5p')
            DISPLAY_NAME="${SINGLE_ALBUM:-$SINGLE_TITLE}"
            DISPLAY_ARTIST="${SINGLE_ARTIST:-$SINGLE_UPLOADER}"
            SONG_LIST="1. $SINGLE_TITLE"; TRACK_COUNT=1
            ;;
    esac

    [ -z "$DISPLAY_NAME" ] && {
        echo "download: could not fetch info, skipping" >&2
        write_done_file "$DONE_FILE" 3 "no metadata"
        exit 3
    }

    local SAFE_NAME
    SAFE_NAME=$(sanitize_filename "$DISPLAY_NAME")

    # ALBUM_ARTIST 解析
    local ALBUM_ARTIST=""
    if [ "$IS_ALBUM" = true ]; then
        if [ -z "$album_artist_arg" ]; then
            ALBUM_ARTIST="$artist_dir"
        elif [ "$album_artist_arg" = "skip" ]; then
            ALBUM_ARTIST=""
        else
            ALBUM_ARTIST="$album_artist_arg"
        fi
    elif [ "$IS_SINGLE" = true ]; then
        # 单曲：不传/skip = 不写专辑艺术家标签（无"默认文件夹名"兜底，CLI 不传参行为不变）
        if [ -n "$album_artist_arg" ] && [ "$album_artist_arg" != "skip" ]; then
            ALBUM_ARTIST="$album_artist_arg"
        fi
    fi

    # ENHANCED_MODE 解析
    local ENHANCED_MODE=false
    if [ "$IS_ALBUM" = true ]; then
        [ "$cover_mode" = "per-track" ] && ENHANCED_MODE=true
    else
        # single / playlist / ytm_radio 一律独立封面
        ENHANCED_MODE=true
    fi

    # 路径构造：单曲可不下子文件夹；其他类型固定子文件夹
    local ARTIST_PATH="$MF_BASE_DIR/$artist_dir"
    mkdir -p "$ARTIST_PATH"
    # v3.3: 通用子文件夹 —— 任何链接类型都可选拉一层
    # v4.1: 覆盖语义（对齐 musicfeed.sh 交互）——
    #   自定义名称 = 替换专辑层（歌手/<自定义名>）；
    #   开启但留空 = 歌手/<专辑名>；none = 直接 歌手/
    local FINAL_PATH="$ARTIST_PATH"
    if [ "$NO_ALBUM_FOLDER" != "1" ]; then
        FINAL_PATH="$ARTIST_PATH/$SAFE_NAME"
    fi
    if [ -n "$subfolder" ]; then
        local SAFE_SUB
        SAFE_SUB=$(sanitize_filename "$subfolder")
        [ -n "$SAFE_SUB" ] && FINAL_PATH="$ARTIST_PATH/$SAFE_SUB"
    fi
    mkdir -p "$FINAL_PATH"

    # 曲目选择
    if [ "$TRACK_COUNT" -le 1 ]; then
        SELECTION="ALL"; SELECTED_COUNT=1
    else
        if [ "$tracks" = "all" ] || [ -z "$tracks" ]; then
            SELECTION="ALL"; SELECTED_COUNT=$TRACK_COUNT
        else
            local P
            P=$(parse_track_selection "$tracks" "$TRACK_COUNT")
            if [[ "$P" == INVALID:* ]]; then
                echo "download: invalid --tracks: $P" >&2; exit 1
            fi
            SELECTION="$P"
            SELECTED_COUNT=$(printf '%s\n' "$SELECTION" | tr ',' '\n' | wc -l)
        fi
    fi

    # ─────────────────────────────────────────────
    # single + HAS_METADATA!=True → MV 单曲
    # v4.1: --mv-title 等手动元数据参数优先于 --mv-strategy（WebUI 单 MV 分支）
    # ─────────────────────────────────────────────
    if [ "$IS_SINGLE" = true ] && [ "$HAS_METADATA" != "True" ]; then
        if [ -n "$mv_title" ]; then
            MV_STRATEGY="1"
            MV_TITLE="$mv_title"
            MV_ARTIST="${mv_artist:-$artist_dir}"
            MV_ALBUM="${mv_album:-$mv_title}"
        else
            SI=$(extract_song_info "$SINGLE_TITLE")
            ST=$(printf '%s' "$SI" | cut -d'|' -f1)
            SA=$(printf '%s' "$SI" | cut -d'|' -f2)
            [ -z "$SA" ] && SA="$artist_dir"
            if [ "$mv_strategy" = "manual" ]; then
                MV_STRATEGY="1"
                MV_TITLE="$ST"; MV_ARTIST="$SA"; MV_ALBUM="$ST"
            else
                MV_STRATEGY="2"
                MV_TITLE="$SINGLE_TITLE"; MV_ARTIST="$SINGLE_UPLOADER"; MV_ALBUM="$SINGLE_TITLE"
            fi
        fi
    fi

    # ─────────────────────────────────────────────
    # playlist → 拆分 NORMAL_LIST / MV_LIST
    # ─────────────────────────────────────────────
    if [ "$IS_PLAYLIST" = true ]; then
        local SEL_ITEMS=""
        if [ "$SELECTION" = "ALL" ]; then
            for ((inum=1; inum<=TRACK_COUNT; inum++)); do
                SEL_ITEMS="${SEL_ITEMS}${SEL_ITEMS:+ }$inum"
            done
        else
            SEL_ITEMS=$(printf '%s' "$SELECTION" | tr ',' ' ')
        fi

        local NORMAL_LIST="" MV_LIST=""
        for inum in $SEL_ITEMS; do
            L=$(printf '%s\n' "$SONG_LIST_FULL" | sed -n "${inum}p")
            [ -z "$L" ] && continue
            # 固定字段号（行格式 N. title|vid|has_meta|uploader，title/uploader 内的
            # | 已由 get_playlist_info 替换为全角 ｜；用 $(NF-1)/$NF 会取到 has_meta/uploader）
            VID=$(printf '%s' "$L" | awk -F'|' '{print $2}')
            HAS=$(printf '%s' "$L" | awk -F'|' '{print $3}')
            if [ "$HAS" != "True" ]; then
                MV_LIST="$MV_LIST $VID"
            else
                NORMAL_LIST="${NORMAL_LIST}${NORMAL_LIST:+,}$inum"
            fi
        done

        NORMAL_SELECTION="$NORMAL_LIST"
        MV_VIDS=$(echo "$MV_LIST" | xargs)

        if [ -n "$MV_VIDS" ]; then
            if [ "$mv_strategy" = "manual" ]; then
                MV_STRATEGY="1"
                # 优先使用 --mv-meta，否则用 extract_song_info 自动填充
                if [ -n "$mv_meta" ]; then
                    MV_INFO="$mv_meta"
                else
                    MV_INFO=""
                    while IFS= read -r VID; do
                        [ -z "$VID" ] && continue
                        LINE=$(printf '%s\n' "$SONG_LIST_FULL" | grep -F -- "|$VID|")
                        [ -z "$LINE" ] && continue
                        RAW_TITLE=$(printf '%s' "$LINE" | sed 's/^[0-9]*\. //; s/|[^|]*|[^|]*$//')
                        SI=$(extract_song_info "$RAW_TITLE")
                        ST=$(printf '%s' "$SI" | cut -d'|' -f1)
                        SA=$(printf '%s' "$SI" | cut -d'|' -f2)
                        [ -z "$SA" ] && SA="$artist_dir"
                        ST=$(printf '%s' "$ST" | sed 's/|/｜/g; s/=/＝/g')
                        SA=$(printf '%s' "$SA" | sed 's/|/｜/g; s/=/＝/g')
                        ALBUM_T=$(printf '%s' "$ST" | sed 's/|/｜/g; s/=/＝/g')
                        [ -n "$MV_INFO" ] && MV_INFO="${MV_INFO};"
                        MV_INFO="${MV_INFO}${VID}=${ST}=${SA}=${ALBUM_T}"
                    done <<< "$(printf '%s\n' "$MV_VIDS" | tr ' ' '\n' | grep -v '^$')"
                fi
            else
                MV_STRATEGY="2"
                NORMAL_SELECTION="$SELECTION"; MV_VIDS=""; MV_INFO=""
            fi
        fi

        # 如果有 NORMAL_SELECTION，SELECTION 改为它
        if [ -n "$NORMAL_SELECTION" ]; then
            SELECTION="$NORMAL_SELECTION"
        else
            SELECTION=""
        fi
    fi

    # ─────────────────────────────────────────────
    # 拼装 ALBUM_CONFIGS
    # ─────────────────────────────────────────────
    local ALBUM_CONFIGS_STR
    # v3.3: 曲目总数（进度百分比分母）——选择展开后的 normal 数 + mv 数
    local TOTAL_TRACKS=0
    if [ -n "$NORMAL_SELECTION" ]; then
        TOTAL_TRACKS=$(printf '%s' "$NORMAL_SELECTION" | awk -F',' '{n=0; for(i=1;i<=NF;i++){ if($i ~ /-/) {split($i,a,"-"); n+=a[2]-a[1]+1} else if($i!="") n++ }} END{print n}')
    fi
    if [ -n "$MV_VIDS" ]; then
        TOTAL_TRACKS=$((TOTAL_TRACKS + $(echo "$MV_VIDS" | wc -w)))
    fi
    [ "$TOTAL_TRACKS" -eq 0 ] && TOTAL_TRACKS="$TRACK_COUNT"
    [ "$TOTAL_TRACKS" -eq 0 ] && TOTAL_TRACKS=1

    ALBUM_CONFIGS_STR="$(safe_field "$SAFE_NAME")|${SELECTION}|${url}|${FINAL_PATH}|$(safe_field "$ALBUM_ARTIST")|${ENHANCED_MODE}|${type}|${HAS_METADATA}|$(safe_field "$MV_TITLE")|$(safe_field "$MV_ARTIST")|$(safe_field "$MV_ALBUM")|$(safe_field "$MV_ALBUM_ARTIST")|$(safe_field "$BATCH_ALBUM")|${TOTAL_TRACKS}||${NORMAL_SELECTION}|${MV_VIDS}|$(safe_field "$MV_INFO")|${MV_STRATEGY}"

    # ─────────────────────────────────────────────
    # 生成 worker 脚本
    # ─────────────────────────────────────────────
    local WORKER_SH
    WORKER_SH=$(mktemp /tmp/musicfeed_batch_worker_XXXXXX.sh)
    chmod +x "$WORKER_SH"
    CLEANUP_FILES+=("$WORKER_SH")

    cat > "$WORKER_SH" << 'WORKEREOF'
#!/bin/bash
# worker（mf_batch.sh 生成）
YTDLP="__YTDLP__"
NODE_ARGS="__NODE_ARGS__"
LOG_FILE="__LOG_FILE__"
AUDIO_FORMAT="__AUDIO_FORMAT__"
DONE_FILE="__DONE_FILE__"
JSON_OUTPUT="__JSON_OUTPUT__"

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

write_done() {
    local ec="${1:-0}" ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ' | sed -E 's/(\.[0-9]{6})[0-9]+Z$/\1Z/')
    jq -n --argjson ec "$ec" --arg ts "$ts" \
        '{exitCode:$ec, finishedAt:$ts}' > "$DONE_FILE" 2>/dev/null \
        || printf '{"exitCode": %s, "finishedAt": "%s"}\n' "$ec" "$ts" > "$DONE_FILE"
}

on_worker_exit() {
    local ec=$?
    cleanup_worker
    write_done "$ec"
}
trap on_worker_exit EXIT

# 错误追踪：yt-dlp 失败时累加 WORKER_ERROR，最终以非零退出码反映失败
WORKER_ERROR=0

log() {
    local msg="$1"
    local level="${2:-info}"
    local event="${3:-}"
    local line
    if [ "$JSON_OUTPUT" = "1" ]; then
        local ts
        ts=$(date -u '+%Y-%m-%dT%H:%M:%S.%NZ' | sed -E 's/(\.[0-9]{6})[0-9]+Z$/\1Z/')
        msg="${msg//$'\n'/ }"; msg="${msg//$'\r'/ }"
        line=$(jq -cn --arg ts "$ts" --arg level "$level" --arg event "$event" --arg msg "$msg" \
            '{ts:$ts, level:$level, event:$event, msg:$msg}')
    else
        line="[$(date '+%H:%M:%S')] $msg"
    fi
    echo "$line"
    echo "$line" >> "$LOG_FILE"
}

# 包装 yt-dlp 调用：失败时记录错误、发出 error 事件，但不中断后续流程
# v3.3: --newline 逐行解析输出 —— 下载阶段实时发出 ytdlp_dest（开始拉某曲）
# 与 ytdlp_frac（总体进度百分比）事件，WebUI 进度条全程平滑。
# 全局计数（由专辑循环头重置）：
#   TOTAL_TRACKS 本专辑曲目总数（选择展开后的 normal + mv 数）
#   DEST_COUNT   已出现 Destination 行数（≈已开拉的曲目数，含当前曲）
#   LAST_FRAC    上次发出的整数百分比（防事件风暴）
DEST_COUNT=0; LAST_FRAC=-1; TOTAL_TRACKS=1
ytdlp_run() {
    local st="/tmp/ytdlp_st_$$" attempt rc=1 dest0
    # v4.1: 瞬时失败自动重试一次（YouTube 反爬 "Sign in to confirm" / 403 间歇出现，
    # 数秒后重试通常成功——WebUI 无人值守场景必须自愈）。重试前回滚 DEST_COUNT，
    # 进度百分比不因重跑虚增。两次都失败才置 WORKER_ERROR。
    for attempt in 1 2; do
        dest0=$DEST_COUNT
        while IFS= read -r line; do
            echo "$line" >> "$LOG_FILE"
            case "$line" in
                *"[download] Destination:"*)
                    DEST_COUNT=$((DEST_COUNT+1))
                    log "Fetching: ${line##*Destination: }" "info" "ytdlp_dest"
                    ;;
                *"[download] "*"%"*)
                    local pct
                    pct=$(printf '%s' "$line" | sed -n 's/^\[download\] *\([0-9][0-9.]*\)%.*/\1/p')
                    if [ -n "$pct" ]; then
                        local frac
                        frac=$(awk -v d="$DEST_COUNT" -v p="$pct" -v t="${TOTAL_TRACKS:-1}" \
                            'BEGIN{f=(d-1+p/100)/t; if(f<0)f=0; if(f>0.99)f=0.99; printf "%d", f*100}')
                        if [ "$frac" != "$LAST_FRAC" ]; then
                            LAST_FRAC="$frac"
                            log "Downloading $frac%" "info" "ytdlp_frac"
                        fi
                    fi
                    ;;
            esac
        # --trim-filenames: 超长标题（宣传文案类）文件名截断，避免 +.info.json 后超 255 字节
        # （Errno 36）。注意 yt-dlp 按字符数截断而文件系统按字节数限制，中文 UTF-8 每字 3 字节，
        # 78 字符 ≈ 最坏全中文 234 字节，是保证安全上限；只截文件名，不影响标签内容
        done < <("$YTDLP" --newline --trim-filenames 78 "$@" 2>&1; echo $? > "$st")
        rc=$(cat "$st" 2>/dev/null || echo 1)
        rm -f "$st"
        if [ "$rc" = "0" ]; then return 0; fi
        log "yt-dlp exit=$rc" "error" "ytdlp_error"
        if [ "$attempt" -lt 2 ]; then
            DEST_COUNT=$dest0
            log "Transient failure — retrying once in 10s..." "warn" "ytdlp_retry"
            sleep 10
        fi
    done
    WORKER_ERROR=1
    return "$rc"
}

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

log "worker_started pid=$$ ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "info" "worker_start"
WORKEREOF

    # ─────────────────────────────────────────────
    # token 替换
    # ─────────────────────────────────────────────
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
    replace_token "__DONE_FILE__" "$DONE_FILE"
    replace_token "__JSON_OUTPUT__" "$json_output"

    # ─────────────────────────────────────────────
    # 追加 ALBUM_CONFIGS 和主循环
    # ─────────────────────────────────────────────
    {
        echo 'ALBUMS=('
        printf ' %q\n' "$ALBUM_CONFIGS_STR"
        echo ')'
    } >> "$WORKER_SH"

    cat >> "$WORKER_SH" << 'LOOPEOF'
for album_entry in "${ALBUMS[@]}"; do
    ALBUM_NAME=$(echo "$album_entry" | cut -d'|' -f1)
    SELECTION=$(echo "$album_entry" | cut -d'|' -f2)
    url=$(echo "$album_entry" | cut -d'|' -f3)
    FINAL_PATH=$(echo "$album_entry" | cut -d'|' -f4)
    ALBUM_ARTIST=$(echo "$album_entry" | cut -d'|' -f5)
    ENHANCED_MODE=$(echo "$album_entry" | cut -d'|' -f6)
    TYPE=$(echo "$album_entry" | cut -d'|' -f7)
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

    # 统一封面临时目录清理（放循环头而非尾部，兼容下方所有 continue 路径）
    [ -n "$CTD" ] && rm -rf "$CTD" 2>/dev/null
    CTD=""; UNIFIED_COVER=""; DEST_COUNT=0; LAST_FRAC=-1
    TOTAL_TRACKS=$(echo "$album_entry" | cut -d'|' -f14)
    [ -z "$TOTAL_TRACKS" ] && TOTAL_TRACKS=1

    log "========================================" "info" "section"
    log "ALBUM=$ALBUM_NAME | PATH=$FINAL_PATH | TYPE=$TYPE" "info" "album_start"
    mkdir -p "$FINAL_PATH"

    IS_MV_SINGLE=false
    [ "$TYPE" = "single" ] && [ "$HAS_METADATA" != "True" ] && [ -n "$MV_TITLE" ] && IS_MV_SINGLE=true

    ls "$FINAL_PATH"/*.$AUDIO_EXT 2>/dev/null > /tmp/existing_before_$$.txt

    if [ "$ENHANCED_MODE" != "true" ]; then
        log "Unified cover..." "info" "cover_unified_start"
        CTD=$(mktemp -d)
        ytdlp_run $NODE_ARGS --no-warnings --write-thumbnail --skip-download --convert-thumbnails jpg \
            --playlist-items 1 -o "$CTD/%(id)s" "$url"
        CS=$(find "$CTD" -name "*.jpg" -type f -exec ls -la {} \; 2>/dev/null | sort -k5 -rn | head -1 | awk '{print $NF}')
        if [ -n "$CS" ]; then
            # v3.3: 封面全程留在临时目录，最终目录不再落 cover.jpg
            # （专辑平铺进歌手大文件夹时，多个 cover.jpg 会互相覆盖）
            if cover_compress "$CS" "$CTD/cover.jpg" 2>/dev/null && [ -f "$CTD/cover.jpg" ]; then
                UNIFIED_COVER="$CTD/cover.jpg"
                log "Unified cover (compressed)" "info" "cover_unified_done"
            else
                UNIFIED_COVER="$CS"
                log "Unified cover (compression failed, keeping original)" "warn" "cover_compress_failed"
            fi
        else
            log "Could not fetch unified cover" "warn" "cover_unified_failed"
        fi
    fi

    MV_DATA=()
    parse_mv_info "$MV_INFO"

    if [ "$IS_MV_SINGLE" = true ]; then
        log "MV single (temp)..." "info" "download_mv_single"
        ytdlp_run $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            --embed-metadata --no-embed-thumbnail --windows-filenames --write-info-json \
            "${FORMAT_ARGS[@]}" \
            -o "temp_mv_%(id)s.%(ext)s" -P "$FINAL_PATH" "$url"

    elif [ "$MV_STRATEGY" = "2" ]; then
        log "Default mode batch..." "info" "download_default_batch"
        PLAYLIST_ARGS=()
        if [ "$SELECTION" != "ALL" ] && [ -n "$SELECTION" ]; then
            PLAYLIST_ARGS=(--playlist-items "$SELECTION")
        fi
        ytdlp_run $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
            --embed-metadata --no-embed-thumbnail --windows-filenames --yes-playlist \
            --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json \
            "${FORMAT_ARGS[@]}" \
            "${PLAYLIST_ARGS[@]}" \
            -o "%(artist,uploader).50s - %(title).25s.%(ext)s" -P "$FINAL_PATH" "$url"

    else
        if [ -n "$NORMAL_SELECTION" ]; then
            log "Normal track batch..." "info" "download_normal_batch"
            ytdlp_run $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                --embed-metadata --no-embed-thumbnail --windows-filenames --yes-playlist \
                --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json \
                "${FORMAT_ARGS[@]}" \
                --playlist-items "$NORMAL_SELECTION" \
                -o "%(artist,uploader).50s - %(title).25s.%(ext)s" -P "$FINAL_PATH" "$url"
        fi

        if [ -n "$MV_VIDS" ] && [ "$MV_STRATEGY" = "1" ]; then
            while IFS= read -r VID; do
                [ -z "$VID" ] && continue
                SINGLE_URL="https://www.youtube.com/watch?v=$VID"
                log "MV track: $VID" "info" "download_mv_track"
                ytdlp_run $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                    --embed-metadata --no-embed-thumbnail --windows-filenames --write-info-json \
                    "${FORMAT_ARGS[@]}" \
                    -o "temp_mv_%(id)s.%(ext)s" -P "$FINAL_PATH" "$SINGLE_URL"
            done <<< "$(echo "$MV_VIDS" | tr ' ' '\n' | grep -v '^$')"
        fi

        if [ -z "$NORMAL_SELECTION" ] && [ -z "$MV_VIDS" ]; then
            log "Downloading..." "info" "download_simple"
            PLAYLIST_ARGS=()
            [ "$SELECTION" != "ALL" ] && [ -n "$SELECTION" ] && PLAYLIST_ARGS=(--playlist-items "$SELECTION")
            ytdlp_run $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                --embed-metadata --no-embed-thumbnail --windows-filenames --yes-playlist \
                --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json \
                "${FORMAT_ARGS[@]}" "${PLAYLIST_ARGS[@]}" \
                -o "%(artist,uploader).50s - %(title).25s.%(ext)s" -P "$FINAL_PATH" "$url"
        fi
    fi

    log "Download complete" "info" "download_complete"

    if [ "$IS_MV_SINGLE" = true ]; then
        log "MV single post-processing..." "info" "postproc_mv_single"
        for mv_f in "$FINAL_PATH"/temp_mv_*.$AUDIO_EXT; do
            [ -f "$mv_f" ] || continue
            SAFE_ARTIST=$(echo "$MV_ARTIST" | sed 's/[\/:*?"<>|]/-/g')
            SAFE_TITLE=$(echo "$MV_TITLE" | sed 's/[\/:*?"<>|]/-/g')
            NEW_NAME="${SAFE_ARTIST} - ${SAFE_TITLE}.$AUDIO_EXT"
            NEW_PATH="$FINAL_PATH/$NEW_NAME"
            # v4.1: 目标已存在 → 去重（丢弃新副本），保证重复任务幂等
            if [ -f "$NEW_PATH" ]; then
                rm -f "$mv_f"
                log "Duplicate: exists $NEW_NAME, new copy removed" "info" "dedupe"
                echo "$NEW_PATH" >> /tmp/existing_before_$$.txt
                continue
            fi
            mv "$mv_f" "$NEW_PATH"
            log "Renamed: $(basename "$mv_f") -> $NEW_NAME" "info" "rename"
            CF=""; JSON_FILE="${NEW_PATH%.$AUDIO_EXT}.info.json"
            [ ! -f "$JSON_FILE" ] && JSON_FILE=$(find "$FINAL_PATH" -name "temp_mv_*.info.json" 2>/dev/null | head -1)
            if [ -f "$JSON_FILE" ]; then
                if download_cover "$JSON_FILE" CF; then
                    CC="/tmp/cover_$$_compressed.jpg"
                    cover_compress "$CF" "$CC" 2>/dev/null
                    if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "Cover compressed" "info" "cover_compress"; fi
                fi
                rm -f "$JSON_FILE"
            fi
            mv_write_id3 "$NEW_PATH" "$MV_TITLE" "$MV_ARTIST" "$MV_ALBUM" "" "$CF"
            [ -n "$CF" ] && rm -f "$CF"
            echo "$NEW_PATH" >> /tmp/existing_before_$$.txt
            log "Track OK: $(basename "$NEW_PATH")" "info" "track_done"
        done
        rm -f "$FINAL_PATH"/temp_mv_* "$FINAL_PATH"/*.webm 2>/dev/null
        log "Done: $ALBUM_NAME" "info" "album_done"
        continue
    fi

    if [ "$MV_STRATEGY" = "2" ]; then
        log "Default mode post-processing..." "info" "postproc_default"
        for f in "$FINAL_PATH"/*.$AUDIO_EXT; do
            [ -f "$f" ] || continue
            [[ "$(basename "$f")" == temp_* ]] && continue
            [[ "$f" == *.temp.* ]] && continue
            if grep -qxF "$f" /tmp/existing_before_$$.txt 2>/dev/null; then
                # 已存在的跳过不计入本次进度（分母=本次选择数，历史曲目计入会造成 6/1 这类溢出）
                log "Skipping existing: $(basename "$f")" "info" "skip_existing"
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
            # v4.3: 电台/社区列表无元数据曲目 —— 新提取算法
            # （uploader 匹配 → 盲猜 → 书名号/括号规则，extract_nm_info 见 mf_lib.sh）
            if [ "$TYPE" = "ytm_radio" ] && [ "$HS" != "true" ] && [ -f "$JSON_FILE" ]; then
                NM_UP=$(jq -r '.uploader // ""' "$JSON_FILE" 2>/dev/null)
                NM_INFO=$(extract_nm_info "$TITLE" "$NM_UP")
                FORCE_TITLE=$(printf '%s' "$NM_INFO" | cut -d'|' -f1)
                FORCE_ARTIST=$(printf '%s' "$NM_INFO" | cut -d'|' -f2)
                log "Title extracted: '$FORCE_ARTIST' / '$FORCE_TITLE'" "info" "title_extract"
            fi
            CF=""
            if [ -f "$JSON_FILE" ]; then
                if download_cover "$JSON_FILE" CF; then
                    if [ "$HS" = "true" ]; then
                        CC="/tmp/cover_$$_cropped.jpg"
                        cover_crop_center "$CF" "$CC" 2>/dev/null
                        if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "Cover cropped (metadata)" "info" "cover_crop"; fi
                    else
                        CC="/tmp/cover_$$_compressed.jpg"
                        cover_compress "$CF" "$CC" 2>/dev/null
                        if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "Cover compressed (no metadata)" "info" "cover_compress"; fi
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
                        # 否则重命名会破坏 yt-dlp 按文件名判重的幂等性，重复下载会在文件夹里堆积原名副本
                        rm -f "$f"
                        f="$FINAL_PATH/$NEW_NAME"
                        log "Duplicate: exists $NEW_NAME, new copy removed" "info" "duplicate_skip"
                    else
                        mv "$f" "$FINAL_PATH/$NEW_NAME"
                        f="$FINAL_PATH/$NEW_NAME"
                        log "Renamed: $NEW_NAME" "info" "rename"
                    fi
                fi
            fi
            echo "$f" >> /tmp/existing_before_$$.txt
            log "Track OK: $(basename "$f")" "info" "track_done"
        done
        rm -f "$FINAL_PATH"/*.info.json "$FINAL_PATH"/*.webm "$FINAL_PATH"/*.temp.* 2>/dev/null
        rm -f /tmp/existing_before_$$.txt
        log "Done: $ALBUM_NAME" "info" "album_done"
        continue
    fi

    if [ -n "$MV_VIDS" ] && [ "$MV_STRATEGY" = "1" ]; then
        log "MV track post-processing..." "info" "postproc_mv_tracks"
        for mv_f in "$FINAL_PATH"/temp_mv_*.$AUDIO_EXT; do
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
                    log "Metadata found, overriding MV manual info" "info" "meta_override"
                fi
                SAFE_ARTIST=$(echo "$ARTIST" | sed 's/[\/:*?"<>|]/-/g')
                SAFE_TITLE=$(echo "$TITLE" | sed 's/[\/:*?"<>|]/-/g')
                NEW_NAME="${SAFE_ARTIST} - ${SAFE_TITLE}.$AUDIO_EXT"
                NEW_PATH="$FINAL_PATH/$NEW_NAME"
                [ -f "$NEW_PATH" ] && NEW_PATH="$FINAL_PATH/${SAFE_ARTIST} - ${SAFE_TITLE}_$(date +%s).$AUDIO_EXT"
                mv "$mv_f" "$NEW_PATH"
                log "Renamed: $(basename "$mv_f") -> $NEW_NAME" "info" "rename"
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
                            if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "Cover cropped (metadata fallback)" "info" "cover_crop"; fi
                        else
                            CC="/tmp/cover_$$_compressed.jpg"
                            cover_compress "$CF" "$CC" 2>/dev/null
                            if [ -f "$CC" ]; then rm -f "$CF"; CF="$CC"; log "Cover compressed (no metadata)" "info" "cover_compress"; fi
                        fi
                    fi
                fi
                FINAL_ALBUM="${ALBUM:-$TITLE}"
                mv_write_id3 "$NEW_PATH" "$TITLE" "$ARTIST" "$FINAL_ALBUM" "" "$CF"
                [ -n "$CF" ] && rm -f "$CF"
                echo "$NEW_PATH" >> /tmp/existing_before_$$.txt
                log "Track OK: $(basename "$NEW_PATH")" "info" "track_done"
            fi
            [ -f "$JSON_FILE" ] && rm -f "$JSON_FILE"
        done
    fi

    log "Post-processing..." "info" "postproc_normal"
    for f in "$FINAL_PATH"/*.$AUDIO_EXT; do
        [ -f "$f" ] || continue
        [[ "$(basename "$f")" == temp_* || "$(basename "$f")" == temp_mv_* ]] && continue
        [[ "$f" == *.temp.* ]] && continue
        if grep -qxF "$f" /tmp/existing_before_$$.txt 2>/dev/null; then
            # 同上：跳过历史已存在曲目不发计数事件
            log "Skipping existing: $(basename "$f")" "info" "skip_existing"
            continue
        fi
        ORIG_ALBUM=""; CF=""; HC="false"; FORCE_TITLE=""; FORCE_ARTIST=""
        if [ "$ENHANCED_MODE" = "true" ]; then
            JSON_FILE="${f%.$AUDIO_EXT}.info.json"
            if [ -f "$JSON_FILE" ]; then
                ORIG_ALBUM=$(jq -r '.album // ""' "$JSON_FILE" 2>/dev/null)
                SA=$(jq -r '.artist // ""' "$JSON_FILE" 2>/dev/null)
                HS=false
                [ -n "$ORIG_ALBUM" ] && [ -n "$SA" ] && HS=true
                log "Metadata: $HS" "info" "metadata_check"
                # v4.3: 电台/社区列表无元数据曲目 —— 新提取算法（extract_nm_info，同 postproc_default）
                if [ "$TYPE" = "ytm_radio" ] && [ "$HS" != true ]; then
                    TITLE_RAW=$(jq -r '.title // ""' "$JSON_FILE" 2>/dev/null)
                    NM_UP=$(jq -r '.uploader // ""' "$JSON_FILE" 2>/dev/null)
                    NM_INFO=$(extract_nm_info "$TITLE_RAW" "$NM_UP")
                    FORCE_TITLE=$(printf '%s' "$NM_INFO" | cut -d'|' -f1)
                    FORCE_ARTIST=$(printf '%s' "$NM_INFO" | cut -d'|' -f2)
                    log "Title extracted: '$FORCE_ARTIST' / '$FORCE_TITLE'" "info" "title_extract"
                fi
                if download_cover "$JSON_FILE" CF; then
                    if [ "$HS" = "true" ]; then
                        CC="/tmp/cover_$$_cropped.jpg"
                        if cover_crop_center "$CF" "$CC"; then
                            rm -f "$CF"; CF="$CC"; HC="true"
                            log "Cover cropped (1:1)" "info" "cover_crop"
                        else
                            log "Crop failed, using original" "warn" "cover_crop_failed"
                            HC="true"
                        fi
                    else
                        CC="/tmp/cover_$$_compressed.jpg"
                        if cover_compress "$CF" "$CC"; then
                            rm -f "$CF"; CF="$CC"; HC="true"
                            log "Cover compressed" "info" "cover_compress"
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
                log "Using unified cover" "info" "cover_unified_use"
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
                    log "Duplicate: exists $NEW_NAME, new copy removed" "info" "duplicate_skip"
                else
                    mv "$f" "$FINAL_PATH/$NEW_NAME"
                    f="$FINAL_PATH/$NEW_NAME"
                    log "Renamed: $NEW_NAME" "info" "rename"
                fi
            fi
        fi
        log "Track OK: $(basename "$f")" "info" "track_done"
    done
    rm -f "$FINAL_PATH"/*.info.json "$FINAL_PATH"/*.webm "$FINAL_PATH"/*.temp.* 2>/dev/null
    rm -f /tmp/existing_before_$$.txt
    log "Done: $ALBUM_NAME" "info" "album_done"
done

# 最后一轮的封面临时目录清理（循环头清理覆盖不到末轮）
[ -n "$CTD" ] && rm -rf "$CTD" 2>/dev/null

if [ "$WORKER_ERROR" != "0" ]; then
    log "worker_finished exit=11 worker_error=$WORKER_ERROR" "error" "worker_end_with_errors"
    exit 11
else
    log "worker_finished exit=0" "info" "worker_end"
    exit 0
fi
LOOPEOF

    # ─────────────────────────────────────────────
    # 启动 worker（前台运行）
    # ─────────────────────────────────────────────
    bash "$WORKER_SH"
    local worker_ec=$?

    # worker 的 EXIT trap 已经写了 DONE_FILE，这里只是透传退出码
    rm -f "$WORKER_SH"
    exit $worker_ec
}

# ─────────────────────────────────────────────
# 主入口
# ─────────────────────────────────────────────
main() {
    local subcmd="${1:-}"
    if [ -z "$subcmd" ]; then
        cat >&2 <<EOF
Usage: mf_batch.sh <preview|download> [options]

  preview   — 预览链接元数据（不下载），输出 JSON 到 stdout
  download  — 启动下载任务（前台运行），输出 JSON 进度行到 stdout

Run 'mf_batch.sh preview --help' or 'mf_batch.sh download --help' for details.
EOF
        exit 1
    fi
    shift
    case "$subcmd" in
        preview) preview_cmd "$@";;
        download) download_cmd "$@";;
        --help|-h|help)
            cat <<EOF
mf_batch.sh — musicfeed 非交互入口

Subcommands:
  preview   预览链接元数据
  download  启动下载任务

Run 'mf_batch.sh <subcommand> --help' for subcommand options.
EOF
            exit 0;;
        *) echo "Unknown subcommand: $subcmd" >&2; exit 1;;
    esac
}

main "$@"
