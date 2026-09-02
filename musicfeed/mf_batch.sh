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
    python3 -c "
import json, sys
print(json.dumps({'ok': False, 'error': sys.argv[1]}, ensure_ascii=False))
" "$1"
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
            printf '%s\n' "$info" | python3 -c '
import sys, json
raw = sys.stdin.read()
lines = raw.split("\n")
album = lines[0].strip() if len(lines) > 0 else "Unknown Album"
try:
    count = int(lines[1].strip()) if len(lines) > 1 else 0
except ValueError:
    count = 0
artist = lines[2].strip() if len(lines) > 2 else "Unknown Artist"
tracks = []
for line in lines[3:]:
    s = line.strip()
    if not s: continue
    if ". " in s:
        idx_str, title = s.split(". ", 1)
        try:
            idx = int(idx_str)
        except ValueError:
            continue
    else:
        idx = 0
        title = s
    tracks.append({"idx": idx, "title": title, "vid": "", "hasMeta": True})
print(json.dumps({
    "ok": True,
    "type": "album",
    "albumName": album,
    "artist": artist,
    "trackCount": count,
    "tracks": tracks,
    "hasMetadata": True
}, ensure_ascii=False))
'
            ;;
        playlist|ytm_radio)
            local info
            info=$(get_playlist_info "$url")
            if [ -z "$info" ]; then
                emit_json_error "preview: failed to fetch playlist metadata (yt-dlp returned empty)"
                exit 3
            fi
            printf '%s\n' "$info" | python3 -c '
import sys, json, re
raw = sys.stdin.read()
lines = raw.split("\n")
playlist = lines[0].strip() if len(lines) > 0 else "Unknown Playlist"
try:
    count = int(lines[1].strip()) if len(lines) > 1 else 0
except ValueError:
    count = 0
tracks = []
any_meta = False
display_artist = ""
for line in lines[2:]:
    s = line.strip()
    if not s: continue
    if ". " in s:
        idx_str, rest = s.split(". ", 1)
        try:
            idx = int(idx_str)
        except ValueError:
            continue
    else:
        idx = 0
        rest = s
    parts = rest.split("|")
    title = parts[0] if len(parts) > 0 else ""
    vid = parts[1] if len(parts) > 1 else ""
    has_meta = (len(parts) > 2 and parts[2] == "True")
    uploader = re.sub(r" - Topic$", "", (parts[3] if len(parts) > 3 else "")).strip()
    if has_meta: any_meta = True
    if not display_artist and uploader: display_artist = uploader
    tracks.append({"idx": idx, "title": title, "vid": vid, "hasMeta": has_meta, "uploader": uploader})
print(json.dumps({
    "ok": True,
    "type": "'"$type"'",
    "albumName": playlist,
    "artist": display_artist,
    "trackCount": count,
    "tracks": tracks,
    "hasMetadata": any_meta
}, ensure_ascii=False))
'
            ;;
        single)
            local info
            info=$(get_single_info "$url")
            if [ -z "$info" ]; then
                emit_json_error "preview: failed to fetch single metadata (yt-dlp returned empty)"
                exit 3
            fi
            printf '%s\n' "$info" | python3 -c '
import sys, json
raw = sys.stdin.read()
lines = raw.split("\n")
album = lines[0].strip() if len(lines) > 0 else ""
title = lines[1].strip() if len(lines) > 1 else "Unknown"
artist = lines[2].strip() if len(lines) > 2 else ""
uploader = lines[3].strip() if len(lines) > 3 else ""
has_meta = (len(lines) > 4 and lines[4].strip() == "True")
display_name = album if album else title
display_artist = artist if artist else uploader
tracks = [{"idx": 1, "title": title, "vid": "", "hasMeta": has_meta}]
print(json.dumps({
    "ok": True,
    "type": "single",
    "albumName": display_name,
    "artist": display_artist,
    "trackCount": 1,
    "tracks": tracks,
    "hasMetadata": has_meta
}, ensure_ascii=False))
'
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
        python3 -c "
import json, datetime
with open('$DONE_FILE', 'w') as f:
    json.dump({'exitCode': 2, 'finishedAt': datetime.datetime.utcnow().isoformat() + 'Z', 'error': 'unknown link type'}, f)
"
        exit 2
    }

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
        python3 -c "
import json, datetime
with open('$DONE_FILE', 'w') as f:
    json.dump({'exitCode': 3, 'finishedAt': datetime.datetime.utcnow().isoformat() + 'Z', 'error': 'no metadata'}, f)
"
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
    local ec="${1:-0}"
    python3 - "$DONE_FILE" "$ec" << 'PYDONE'
import json, datetime, sys, os
_done_file = sys.argv[1]
_exit_code = int(sys.argv[2])
_finished_at = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
_data = {'exitCode': _exit_code, 'finishedAt': _finished_at}
try:
    with open(_done_file, 'w') as f:
        json.dump(_data, f)
except Exception as e:
    sys.stderr.write(f'failed to write done file: {e}\n')
PYDONE
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
        line=$(printf '%s' "$msg" | python3 -c '
import json, datetime, sys
msg = sys.stdin.read().replace("\n", " ").replace("\r", " ").replace("\\", "\\\\")
print(json.dumps({
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    "level": sys.argv[1],
    "event": sys.argv[2],
    "msg": msg
}, ensure_ascii=False))
' "$level" "$event" 2>/dev/null)
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
    local st="/tmp/ytdlp_st_$$"
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
    local ec
    ec=$(cat "$st" 2>/dev/null || echo 1)
    rm -f "$st"
    if [ "$ec" != "0" ]; then
        WORKER_ERROR=1
        log "yt-dlp exit=$ec" "error" "ytdlp_error"
        return "$ec"
    fi
    return 0
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
extract_nm_info() {
    python3 - "$1" "$2" << 'NM_PYEOF'
import re, sys

POLL = re.compile(r'歌詞|歌词|動態|动态|MV|Official|官方|Video|Audio|Visualizer|Live|完整版|主題曲|主题曲|片尾曲|片頭曲|片头曲', re.I)
KEEP = re.compile(r'feat|ft\.|国|國|粤|粵', re.I)
BR = re.compile(r'（([^（）()]*)）|\(([^()]*)\)|『([^『』]*)』|「([^「」]*)」|【([^【】]*)】|《([^《》]*)》|\[([^\[\]]*)\]')

def inner_of(m):
    return next(g for g in m.groups() if g is not None)

def br_proc(s):
    # 逐层（最内层优先）迭代：污染词连符号删；白名单层整体保留；
    # 其余去壳留内容。嵌套判定只看本层自身文字（剥离内层括号后再匹配）
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

# 1) 歌名书名号优先（内容被污染词清空时视为无书名号，继续走后面分支）
m = re.search(r'《([^《》]*)》', t) or re.search(r'【([^【】]*)】', t) or re.search(r'\[([^\[\]]*)\]', t)
if m:
    song = br_proc(m.group(1)).strip()
    # 括号内容本身（已无括号包裹）也可能整个是污染词（如【動態歌詞】），需再扁平检查
    if song and not POLL.search(BR.sub(' ', song)):
        prefix = re.sub(r'^(\[[^\]]*\]\s*)+', '', t[:m.start()].strip())
        prefix = re.sub(r'[\s\-:：*|｜]+$', '', prefix).strip()
        # 前缀过长（宣传文案）时歌手 fallback uploader
        artist = prefix if prefix and len(prefix) <= 30 else up
        print(f"{esc(song)}|{esc(artist)}")
        sys.exit(0)

# 2) 无书名号：括号清洗后按 " - " 分段
t2 = br_proc(t)
segs = [s.strip() for s in t2.split(' - ') if s.strip()]
if len(segs) >= 2:
    if up:
        keep = [s for s in segs if not (s in up or up in s)]
        if keep and len(keep) < len(segs):
            print(f"{esc(clean(keep[0]))}|{esc(up)}")
            sys.exit(0)
    # 盲猜：左段为歌手（无法区分 歌手-歌名 / 歌名-歌手，已知局限）
    print(f"{esc(clean(' - '.join(segs[1:])))}|{esc(segs[0])}")
    sys.exit(0)

# 3) 纯歌名
print(f"{esc(clean(t2))}|{esc(up)}")
NM_PYEOF
}


mv_write_id3() {
    python3 - "$@" << 'PYEOF'
import sys, os, re

def split_artists(artist_str):
    if not artist_str:
        return ['Unknown Artist']
    artist_str = artist_str.replace('\uff0c', ',')
    patterns = [
        r'\s+feat\.\s+',
        r'\s+ft\.\s+',
        r'\s+&\s+',
        r'\s*,\s*',
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
    seen = set()
    unique = []
    for a in result:
        if a and a not in seen and a.lower() not in seen:
            seen.add(a.lower())
            unique.append(a)
    return unique if unique else ['Unknown Artist']

fpath = sys.argv[1]; title = sys.argv[2]; artist = sys.argv[3]
album = sys.argv[4]; album_artist = sys.argv[5]; cover_file = sys.argv[6] if len(sys.argv) > 6 else ""

artists_list = split_artists(artist)

if fpath.endswith('.m4a'):
    from mutagen.mp4 import MP4, MP4Cover
    audio = MP4(fpath)
    audio['\xa9nam'] = [title]
    audio['\xa9ART'] = artists_list
    if album: audio['\xa9alb'] = [album]
    elif '\xa9alb' in audio: del audio['\xa9alb']
    if album_artist: audio['aART'] = [album_artist]
    elif 'aART' in audio: del audio['aART']
    if cover_file and os.path.exists(cover_file):
        with open(cover_file, 'rb') as img:
            audio['covr'] = [MP4Cover(img.read(), imageformat=MP4Cover.FORMAT_JPEG)]
        print(f'  +Cover: {os.path.basename(fpath)}')
    else:
        print(f'  ID3: {os.path.basename(fpath)}')
    audio.save()
else:
    from mutagen.oggopus import OggOpus
    audio = OggOpus(fpath)
    audio['title'] = [title]
    audio['artist'] = artists_list
    if album: audio['album'] = [album]
    elif 'album' in audio: del audio['album']
    if album_artist: audio['ALBUMARTIST'] = [album_artist]
    elif 'ALBUMARTIST' in audio: del audio['ALBUMARTIST']
    if cover_file and os.path.exists(cover_file):
        from mutagen.flac import Picture
        import base64
        with open(cover_file, 'rb') as img:
            pic = Picture(); pic.data = img.read(); pic.type = 3; pic.mime = 'image/jpeg'
            audio['metadata_block_picture'] = [base64.b64encode(pic.write()).decode('ascii')]
        print(f'  +Cover: {os.path.basename(fpath)}')
    else:
        print(f'  ID3: {os.path.basename(fpath)}')
    audio.save()
PYEOF
}

embed_cover() {
    python3 - "$@" << 'PYEOF'
import sys, os, re, base64

def split_artists(artist_str):
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
        if artists_list:
            audio['\xa9ART'] = artists_list
        if ft: audio['\xa9nam'] = [ft]
        if em=='true' and oa and oa!='None' and not oa.startswith('%'): audio['\xa9alb'] = [oa]
        else: audio['\xa9alb'] = [an]
        if em=='true' and 'trkn' in audio: del audio['trkn']
        if hc=='true' and cf and os.path.exists(cf):
            with open(cf,'rb') as img: audio['covr'] = [MP4Cover(img.read(), imageformat=MP4Cover.FORMAT_JPEG)]
            print(f'  +Cover: {os.path.basename(fpath)}')
        else:
            print(f'  ID3: {os.path.basename(fpath)}')
        audio.save()
    else:
        from mutagen.oggopus import OggOpus
        from mutagen.flac import Picture
        audio = OggOpus(fpath)
        if aa and aa not in ('None','SKIP',''): audio['ALBUMARTIST'] = [aa]
        elif 'ALBUMARTIST' in audio: del audio['ALBUMARTIST']
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
            print(f'  +Cover: {os.path.basename(fpath)}')
        else:
            print(f'  ID3: {os.path.basename(fpath)}')
        audio.save()
except Exception as e:
    print(f'  Failed: {os.path.basename(fpath)} - {e}')
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

log "worker_started pid=$$ ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "info" "worker_start"
WORKEREOF

    # ─────────────────────────────────────────────
    # token 替换
    # ─────────────────────────────────────────────
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
            -o "%(artist,uploader)s - %(title)s.%(ext)s" -P "$FINAL_PATH" "$url"

    else
        if [ -n "$NORMAL_SELECTION" ]; then
            log "Normal track batch..." "info" "download_normal_batch"
            ytdlp_run $NODE_ARGS --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" \
                --embed-metadata --no-embed-thumbnail --windows-filenames --yes-playlist \
                --parse-metadata "%(playlist_index)s:%(track_number)s" --write-info-json \
                "${FORMAT_ARGS[@]}" \
                --playlist-items "$NORMAL_SELECTION" \
                -o "%(artist,uploader)s - %(title)s.%(ext)s" -P "$FINAL_PATH" "$url"
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
                -o "%(artist,uploader)s - %(title)s.%(ext)s" -P "$FINAL_PATH" "$url"
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
            [ -f "$NEW_PATH" ] && NEW_PATH="$FINAL_PATH/${SAFE_ARTIST} - ${SAFE_TITLE}_$(date +%s).$AUDIO_EXT"
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
                TITLE=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('title',''))" "$JSON_FILE" 2>/dev/null)
                SA=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('artist',''))" "$JSON_FILE" 2>/dev/null)
                REAL_ALBUM=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('album',''))" "$JSON_FILE" 2>/dev/null)
                [ -n "$TITLE" ] && [ -n "$SA" ] && HS=true
            fi
            # v4.3: 电台/社区列表无元数据曲目 —— 新提取算法
            # （uploader 匹配 → 盲猜 → 书名号/括号规则，extract_nm_info 见 mf_lib.sh）
            if [ "$TYPE" = "ytm_radio" ] && [ "$HS" != "true" ] && [ -f "$JSON_FILE" ]; then
                NM_UP=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('uploader',''))" "$JSON_FILE" 2>/dev/null)
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
                ORIG_ALBUM=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('album',''))" "$JSON_FILE" 2>/dev/null)
                SA=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('artist',''))" "$JSON_FILE" 2>/dev/null)
                HS=false
                [ -n "$ORIG_ALBUM" ] && [ -n "$SA" ] && HS=true
                log "Metadata: $HS" "info" "metadata_check"
                # v4.3: 电台/社区列表无元数据曲目 —— 新提取算法（extract_nm_info，同 postproc_default）
                if [ "$TYPE" = "ytm_radio" ] && [ "$HS" != true ]; then
                    TITLE_RAW=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('title',''))" "$JSON_FILE" 2>/dev/null)
                    NM_UP=$(python3 -c "import json, sys; print(json.load(open(sys.argv[1])).get('uploader',''))" "$JSON_FILE" 2>/dev/null)
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
