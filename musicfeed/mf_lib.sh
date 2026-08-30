#!/bin/bash
# mf_lib.sh - musicfeed 纯函数库（无交互）
# 被 mf_batch.sh 和 musicfeed.sh 共用
# 抽取自 musicfeed.sh v3.2.0 line 1-389
#
# 设计原则：
#   - 被 source 时不产生任何 stdout/stderr 输出
#   - 不调用 read / 不依赖 tty
#   - 不修改全局 trap（仅在文件被 source 时设置一次 cleanup trap）

# ─────────────────────────────────────────────
# 1. 配置加载
# ─────────────────────────────────────────────
MF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MF_CONFIG_FILE="${MF_LIB_DIR}/mf_config.sh"

if [ ! -f "$MF_CONFIG_FILE" ]; then
    echo "==================================================" >&2
    echo " ❌ 未找到配置文件: $MF_CONFIG_FILE" >&2
    echo "==================================================" >&2
    echo "📝 首次使用，请先运行配置引导脚本： bash mf_setup.sh" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$MF_CONFIG_FILE"

# 默认值兜底（line 21-29）
: "${MF_LANG:=en}"
: "${MF_BASE_DIR:=$HOME/navidrome/music}"
: "${MF_YTDLP:=yt-dlp}"
: "${MF_DEFAULT_ARTIST_DIR:=musicfeed}"
: "${MF_NODE_PATH:=}"
: "${MF_AUDIO_FORMAT:=opus}"
: "${MF_VENV:=}"

# v3.3: 独立 venv（mf_setup 可选创建）——bin 前置到 PATH，
# 使 yt-dlp 与打标签用的 python3+mutagen 都从 venv 解析，与系统隔离
if [ -n "$MF_VENV" ] && [ -d "$MF_VENV/bin" ]; then
    case ":$PATH:" in
        *":$MF_VENV/bin:"*) ;;
        *) export PATH="$MF_VENV/bin:$PATH" ;;
    esac
    # venv 存在时 yt-dlp 默认指向 venv 内（配置里显式路径优先级更高）
    if [ "$MF_YTDLP" = "yt-dlp" ] && [ -x "$MF_VENV/bin/yt-dlp" ]; then
        MF_YTDLP="$MF_VENV/bin/yt-dlp"
    fi
fi

if [ ${#MF_HIDDEN_DIRS[@]} -eq 0 ]; then
    MF_HIDDEN_DIRS=("attachments" "@eaDir" ".DS_Store")
fi

# MF_NODE_ARGS 探测（line 31-36）
MF_NODE_ARGS=""
if [ -n "$MF_NODE_PATH" ]; then
    MF_NODE_ARGS="--js-runtimes node:$MF_NODE_PATH"
elif command -v node &>/dev/null; then
    MF_NODE_ARGS="--js-runtimes node:$(command -v node)"
fi

# ─────────────────────────────────────────────
# 2. 临时文件清理
# ─────────────────────────────────────────────
CLEANUP_FILES=()
cleanup() {
    for f in "${CLEANUP_FILES[@]}"; do
        [ -f "$f" ] && rm -f "$f" 2>/dev/null
    done
}
trap cleanup EXIT

# ─────────────────────────────────────────────
# 3. 国际化
# ─────────────────────────────────────────────
is_en() { [ "$MF_LANG" = "en" ]; }

tr_text() {
    local zh="$1" en="$2"
    if is_en; then printf "%s" "$en"; else printf "%s" "$zh"; fi
}

# 注意：say/ask 面向用户输出，一律走 stderr——
# musicfeed.sh 的交互函数常被 $() 捕获返回值（如 AA_RESULT=$(input_album_artist)），
# 若提示走 stdout 会污染捕获结果、写进音乐标签
say() {
    local zh="$1" en="$2"
    tr_text "$zh" "$en" >&2
    printf "\n" >&2
}

ask() {
    local zh="$1" en="$2"
    tr_text "$zh" "$en" >&2
}

# ─────────────────────────────────────────────
# 4. 上限常量
# ─────────────────────────────────────────────
MF_MAX_LINKS_PER_RUN=10
MF_MAX_TRACKS_PER_RUN=150

# ─────────────────────────────────────────────
# 5. 工具函数（无交互）
# ─────────────────────────────────────────────
file_size() {
    local f="$1"
    if stat -c%s "$f" >/dev/null 2>&1; then stat -c%s "$f"; else stat -f%z "$f"; fi
}

sanitize_filename() {
    echo "$1" | sed 's/[\/:*?"<>|]/-/g' | sed 's/^-//' | sed 's/-$//';
}

fullwidth_to_halfwidth() {
    echo "$1" | sed 's/，/,/g' | sed 's/－/-/g';
}

safe_field() {
    echo "$1" | sed 's/|/｜/g';
}

safe_strip() {
    echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//';
}

get_term_lines() {
    if command -v tput &>/dev/null; then
        local lines=$(tput lines 2>/dev/null)
        [[ "$lines" =~ ^[0-9]+$ ]] && [ "$lines" -gt 10 ] && echo "$lines" && return
    fi
    echo 24
}

# ─────────────────────────────────────────────
# 6. 选号解析（无交互）
# ─────────────────────────────────────────────
# 输入: "1,3,5-7" 或空字符串, max=最大编号
# 输出: "1,3,5,6,7" 或 "ALL" 或 "INVALID:<part>"
parse_track_selection() {
    local input="$1" max="$2" result=""
    input=$(fullwidth_to_halfwidth "$input")
    IFS=',' read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        part=$(echo "$part" | xargs)
        [ -z "$part" ] && continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start=${BASH_REMATCH[1]}; end=${BASH_REMATCH[2]}
            if [ "$start" -ge 1 ] && [ "$end" -le "$max" ] && [ "$start" -le "$end" ]; then
                for ((i=start; i<=end; i++)); do
                    [ -n "$result" ] && result="$result,$i" || result="$i"
                done
            else echo "INVALID:$part"; return 1; fi
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            [ "$part" -ge 1 ] && [ "$part" -le "$max" ] && { [ -n "$result" ] && result="$result,$part" || result="$part"; } || { echo "INVALID:$part"; return 1; }
        else echo "INVALID:$part"; return 1; fi
    done
    [ -z "$result" ] && echo "ALL" || echo "$result"
}

# ─────────────────────────────────────────────
# 7. MV 标题解析（无交互）
# ─────────────────────────────────────────────
# 从视频标题提取 "歌名|歌手"（3 种正则依次尝试：书名号/引号/去前缀截断）
# v4.3: 移除 " - " 拆分——播放列表/电台场景信息混乱命中率极低，单曲 MV 一并统一
extract_song_info() {
    local title="$1"
    if [[ "$title" =~ 《([^》]+)》 ]]; then
        local s="${BASH_REMATCH[1]}"; s=$(echo "$s" | sed 's/|/｜/g')
        echo "${s}|"; return
    fi
    if [[ "$title" =~ \"([^\"]+)\" ]]; then
        local s="${BASH_REMATCH[1]}"; s=$(echo "$s" | sed 's/|/｜/g')
        echo "${s}|"; return
    fi
    local cleaned=$(echo "$title" | sed 's/^【[^】]*】//' | sed 's/^Stage: //' | sed 's/^纯享[：:]//')
    cleaned=$(safe_strip "$cleaned")
    cleaned=$(echo "$cleaned" | sed 's/|/｜/g')
    echo "${cleaned:0:50}|"
}

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

# ─────────────────────────────────────────────
# 8. yt-dlp 元数据抓取（无交互）
# ─────────────────────────────────────────────

# get_album_info: 抓 YTM 专辑元数据
# stdout 4+ 行：album / count / artist / "idx. title"...
get_album_info() {
    local url="$1"
    tmp_json=$(mktemp)
    CLEANUP_FILES+=("$tmp_json")
    "$MF_YTDLP" $MF_NODE_ARGS --flat-playlist --no-warnings -J "$url" > "$tmp_json" 2>/dev/null
    if [ ! -s "$tmp_json" ]; then
        echo "Unknown Album"; echo "0"; echo "Unknown Artist"
        rm -f "$tmp_json"; return
    fi
    python3 - "$tmp_json" << 'PYEOF'
import json, re, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
raw = d.get('title', '') or ''
album = re.sub(r'^.+? - ', '', raw).strip().replace('|', '｜') or 'Unknown Album'
count = d.get('playlist_count', 0)
artist = 'Unknown Artist'
entries = d.get('entries', [])
if entries:
    artist = re.sub(r' - Topic$', '', entries[0].get('uploader', '')).strip().replace('|', '｜') or 'Unknown Artist'
print(album); print(count); print(artist)
for idx, e in enumerate(entries, 1):
    t = re.sub(r'^.+? - ', '', e.get('title', 'Unknown')).replace('|', '｜')
    print(f"{idx}. {t}")
PYEOF
    rm -f "$tmp_json"
}

# get_playlist_info: 抓播放列表 / YTM 电台元数据
# stdout 3+N 行：playlist / count / "idx. title|vid|has_meta|uploader"
# （uploader 为第 4 字段，旧解析只取前 3 字段，向后兼容）
get_playlist_info() {
    local url="$1"
    tmp_json=$(mktemp)
    CLEANUP_FILES+=("$tmp_json")
    "$MF_YTDLP" $MF_NODE_ARGS --flat-playlist --no-warnings -J "$url" > "$tmp_json" 2>/dev/null
    if [ ! -s "$tmp_json" ]; then
        echo "Unknown Playlist"; echo "0"
        rm -f "$tmp_json"; return
    fi
    python3 - "$tmp_json" << 'PYEOF'
import json, re, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
playlist = d.get('title', '').strip().replace('|', '｜') or 'Unknown Playlist'
count = d.get('playlist_count', 0)
print(playlist); print(count)
entries = d.get('entries', [])
for idx, e in enumerate(entries, 1):
    if e is None:
        print(f"{idx}. [unavailable]||False"); continue
    title = e.get('title') or f'Track {idx}'
    title = title.replace('|', '｜')
    vid = e.get('id', '')
    uploader_raw = e.get('uploader') or e.get('channel') or ''
    # v4.3: flat-playlist 看不到 album/artist，但 " - Topic"（YTM 歌手自动频道）
    # 的曲目下载时 info.json 必带完整 meta——预览阶段按 Topic 预判 has_meta
    is_topic = ' - Topic' in uploader_raw
    has_meta = 'True' if (e.get('album') or e.get('artist') or is_topic) else 'False'
    uploader = re.sub(r' - Topic$', '', uploader_raw).strip().replace('|', '｜')
    print(f"{idx}. {title}|{vid}|{has_meta}|{uploader}")
PYEOF
    rm -f "$tmp_json"
}

# get_single_info: 抓单曲 info.json
# stdout 5 行：album / title / artist / uploader / has_metadata(bool)
get_single_info() {
    local url="$1"
    tmp_json="/tmp/ytm_single_$$"
    CLEANUP_FILES+=("${tmp_json}.info.json" "$tmp_json")
    "$MF_YTDLP" $MF_NODE_ARGS --write-info-json --skip-download -o "$tmp_json" "$url" >/dev/null 2>&1
    local json_file="${tmp_json}.info.json"
    if [ ! -f "$json_file" ]; then
        echo "Unknown"; echo "1"; echo ""; echo ""; echo "False"
        rm -f "$tmp_json" "$json_file" 2>/dev/null; return
    fi
    python3 - "$json_file" << 'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
album = d.get('album', '') or ''
title = d.get('title', 'Unknown')
artist = d.get('artist', '') or ''
uploader = d.get('uploader', '') or ''
has_metadata = bool(artist and album)
print(album); print(title); print(artist); print(uploader); print(has_metadata)
PYEOF
    rm -f "$tmp_json" "$json_file" 2>/dev/null
}

# ─────────────────────────────────────────────
# 9. 链接类型检测（无交互）
# ─────────────────────────────────────────────
# 输出: album | ytm_radio | playlist | single | unknown
get_link_type() {
    local url="$1"
    [[ "$url" =~ OLAK5uy_ ]] && { echo "album"; return; }
    [[ "$url" =~ RDCLAK5uy_ ]] && { echo "ytm_radio"; return; }
    if [[ "$url" =~ playlist\?list=PL ]] || [[ "$url" =~ playlist\?list=LM ]]; then echo "playlist"; return; fi
    [[ "$url" =~ youtube\.com/playlist ]] && { echo "playlist"; return; }
    [[ "$url" =~ watch\?v= ]] || [[ "$url" =~ youtu\.be/ ]] && { echo "single"; return; }
    echo "unknown"
}

# ─────────────────────────────────────────────
# 10. 交互 UI（v3.3）—— 三层降级
#     whiptail → bash 原生方向键 → 纯数字输入
#     MF_TUI: auto（默认，自动检测）/ on（强制 TUI）/ off（强制数字）
# 约定：所有 ui_* 返回码 255 = 用户要求返回上一步
# ─────────────────────────────────────────────

ui_can_tui() { [ "${MF_TUI:-auto}" != "off" ] && [ -c /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; }

# 数字层读行：能开终端就读终端（stdin 可能被条目管道占用），否则读 stdin
_ui_readline() { if ( : < /dev/tty ) 2>/dev/null; then IFS= read -r "$1" < /dev/tty; else IFS= read -r "$1"; fi; }

# whiptail 主题：黑底 + 灰色复选框 + 绿色高亮（默认紫底太晃眼），
# 按钮标签自带按键提示。通过 NEWT_COLORS_FILE 实现，不影响系统其他程序
_ensure_whiptail_theme() {
    if [ -z "${MF_WT_COMMON+x}" ]; then
        local f="${TMPDIR:-/tmp}/.mf_newt_colors_$$"
        cat > "$f" 2>/dev/null <<'C' || return 0
root=white,black
border=gray,black
window=white,black
title=green,black
textbox=white,black
button=black,lightgray
compactbutton=gray,black
actbutton=black,green
checkbox=gray,black
actcheckbox=black,green
lists=white,black
actlist=black,green
helpline=gray,black
C
        export NEWT_COLORS_FILE="$f"
        MF_WT_COMMON=(--ok-button "$(is_en && echo 'OK (Enter)' || echo '确定 (Enter)')" \
                      --cancel-button "$(is_en && echo 'Back (Esc)' || echo '返回 (Esc)')")
    fi
    return 0
}
ui_has_whiptail() { [ "$MF_TUI" != "bash" ] && ui_can_tui && command -v whiptail >/dev/null 2>&1 && _ensure_whiptail_theme; }

# 读一个按键 → KEY = up/down/left/right/enter/space/esc/单个字符
_ui_readkey() {
    local k seq
    IFS= read -rsn1 k < /dev/tty
    if [[ "$k" == $'\x1b' ]]; then
        IFS= read -rsn2 seq < /dev/tty || true
        case "$seq" in
            '[A') KEY=up ;;
            '[B') KEY=down ;;
            '[C') KEY=right ;;
            '[D') KEY=left ;;
            *)   KEY=esc ;;
        esac
    elif [[ -z "$k" ]]; then
        KEY=enter
    elif [[ "$k" == ' ' ]]; then
        KEY=space
    else
        KEY="$k"
    fi
}

# ANSI 重绘：光标上移 $1 行并清屏到底
_ui_clear() { printf '\033[%dA\033[J' "$1" >&2; }

# ── 单选菜单 ─────────────────────────────────
# 用法: ui_menu "标题" "提示" 默认序号 "选项1" "选项2" ...
# 输出: 选中的序号(1 起)；返回 255 = 返回上一步
ui_menu() {
    local title="$1" prompt="$2" def="${3:-1}"; shift 3
    local items=("$@")
    local n=${#items[@]}
    [ "$n" -eq 0 ] && return 255

    if ui_has_whiptail; then
        local args=(--title "$title" --menu "$prompt" 0 60 "$n")
        local i sel rc
        for i in "${!items[@]}"; do
            args+=("$((i+1))" "${items[$i]}")
        done
        sel=$(whiptail "${args[@]}" "${MF_WT_COMMON[@]}" --default-item "$def" 3>&1 1>&2 2>&3)
        rc=$?
        [ $rc -ne 0 ] && return 255
        # 防 whiptail 输出带引号（与 checklist 同理，稳妥起见统一剥离）
        sel=${sel//\"/}
        echo "$sel"
        return 0
    fi

    if ui_can_tui; then
        local cur=$((def-1)) last=$((n-1)) redraw=1 i2
        while :; do
            if [ $redraw -eq 1 ]; then
                echo "" >&2
                printf '\033[1m%s\033[0m\n' "$title" >&2
                [ -n "$prompt" ] && printf '\033[2m%s\033[0m\n' "$prompt" >&2
                for i2 in "${!items[@]}"; do
                    if [ $i2 -eq $cur ]; then
                        printf '  \033[1;32m❯ ●\033[0m \033[1m%s\033[0m\n' "${items[$i2]}" >&2
                    else
                        printf '    ○  %s\n' "${items[$i2]}" >&2
                    fi
                done
                printf '\033[2m%s\033[0m\n' "$(is_en && echo '↑↓ move · Enter confirm · number jump · Esc/b back' || echo '↑↓ 移动 · 回车 确认 · 数字 直达 · Esc/b 返回')" >&2
                redraw=0
            fi
            _ui_readkey
            case "$KEY" in
                up)   [ $cur -gt 0 ] && { _ui_clear $((n+4)); cur=$((cur-1)); redraw=1; } ;;
                down) [ $cur -lt $last ] && { _ui_clear $((n+4)); cur=$((cur+1)); redraw=1; } ;;
                enter) echo "" >&2; echo $((cur+1)); return 0 ;;
                b|B|esc) echo "" >&2; return 255 ;;
                [1-9])
                    if [ "$KEY" -le "$n" ]; then
                        _ui_clear $((n+4))
                        echo "" >&2
                        echo "$KEY"; return 0
                    fi ;;
            esac
        done
    fi

    # 数字降级
    echo "" >&2
    printf '\033[1m%s\033[0m\n' "$title" >&2
    [ -n "$prompt" ] && echo "$prompt" >&2
    local i3 c
    for i3 in "${!items[@]}"; do
        echo "  [$((i3+1))] ${items[$i3]}" >&2
    done
    while :; do
        _ui_readline c
        if [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "$n" ]; then echo "$c"; return 0; fi
        if [[ "$c" == "0" || "$c" == "b" ]]; then return 255; fi
        echo "$(is_en && echo '  Invalid, retry (0=back)' || echo '  无效输入，重试（0=返回）')" >&2
    done
}

# ── 是/否确认 ────────────────────────────────
# 用法: ui_confirm "标题" 默认(y/n)；返回 0=是 1=否 255=返回
ui_confirm() {
    local title="$1" def="${2:-y}" rc
    if ui_has_whiptail; then
        if [ "$def" = "y" ]; then
            whiptail --title "$title" --yesno "$title" 0 60 "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3
            rc=$?
        else
            whiptail --title "$title" --yesno "$title" 0 60 --defaultno "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3
            rc=$?
        fi
        [ $rc -eq 255 ] && return 255
        return $rc
    fi
    local yn
    if [ "$def" = "y" ]; then
        ask "$title [Y/n/b]: " "$title [Y/n/b]: "
    else
        ask "$title [y/N/b]: " "$title [y/N/b]: "
    fi
    _ui_readline yn
    case "$yn" in
        b|B) return 255 ;;
        n|N) return 1 ;;
        *) return 0 ;;
    esac
}

# ── 自由文本输入 ─────────────────────────────
# 用法: ui_input "标题" 默认值 ["提示行"(可选，如原始视频 title)]
# 输出: 文本（空→默认值）；返回 255 = 返回上一步（输入 < 或 b）
ui_input() {
    local title="$1" def="$2" prompt="${3:-}" v
    if ui_has_whiptail; then
        v=$(whiptail --title "$title" --inputbox "${prompt:-$title}" 0 60 "$def" "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return 255
        [ -z "$v" ] && v="$def"
        echo "$v"; return 0
    fi
    if [ -n "$prompt" ]; then printf '\033[2m🎬 %s\033[0m\n' "$prompt" >&2; fi
    if is_en; then printf '%s \033[2m[%s] (< = back)\033[0m: ' "$title" "$def" >&2
    else printf '%s \033[2m[%s]（< = 返回上一步）\033[0m: ' "$title" "$def" >&2; fi
    local v2
    _ui_readline v2
    if [ "$v2" = "<" ] || [ "$v2" = "b" ]; then return 255; fi
    [ -z "$v2" ] && v2="$def"
    echo "$v2"
}

# ── 勾选列表（v3.4：滚动编号列表 + 顶部「全选」项）──
# 用法: 条目逐行经 stdin 传入: printf '%s\n' "a" "b" | ui_checklist "标题" 每页行数
# 输出: "ALL" 或 "1,3,5"；返回 255 = 返回上一步
# 语义: 顶部「全选」项默认勾选（=下载全部）；取消全选后曲目默认全部不选，
#       用户空格逐条勾选需要的曲目
# 按键: ↑↓ 移动 · 空格 勾选 · a 全选 · n 全不选 · ←→ 翻页 · 数字 页内直达 · 回车 确认 · b 返回
ui_checklist() {
    local title="$1" page_n="${2:-12}"
    local items=() line
    while IFS= read -r line; do
        [ -n "$line" ] && items+=("$line")
    done
    local n=${#items[@]}
    [ "$n" -eq 0 ] && { echo "ALL"; return 0; }
    local total_pages=$(( (n - 1) / page_n + 1 ))
    local page=0 cur=0 i
    local -a on=()
    for i in $(seq 0 $((n-1))); do on[$i]=0; done
    local all_on=1

    _ui_sel_str() {
        local s="" c=0 i2
        for i2 in $(seq 0 $((n-1))); do
            if [ "${on[$i2]}" = "1" ]; then s="${s}${s:+,}$((i2+1))"; c=$((c+1)); fi
        done
        echo "$s"
    }
    _ui_sel_cnt() {
        local c=0 i3
        for i3 in $(seq 0 $((n-1))); do [ "${on[$i3]}" = 1 ] && c=$((c+1)); done
        echo $c
    }

    if ui_has_whiptail; then
        local res s c t lh
        lh=$((n+1)); [ $lh -gt 15 ] && lh=15
        while :; do
            local args=(--title "$title" --checklist \
                "$(is_en && echo 'ALL = download everything; untick ALL and space-select the tracks you want' || echo '勾选 ALL=下载全部；取消 ALL 后用空格勾选需要的曲目')" \
                0 78 $lh \
                "ALL" "$(is_en && echo '★ Select ALL tracks' || echo '★ 全选所有曲目')" \
                "$([ $all_on -eq 1 ] && echo on || echo off)")
            for i in "${!items[@]}"; do
                args+=("$((i+1))" "${items[$i]}" "$([ "${on[$i]}" = 1 ] && echo on || echo off)")
            done
            res=$(whiptail "${args[@]}" "${MF_WT_COMMON[@]}" 3>&1 1>&2 2>&3)
            [ $? -ne 0 ] && return 255
            # checklist 输出形如: "ALL" "1" "3" —— 剥引号后逐 tag 判断
            if printf '%s\n' "$res" | tr ' ' '\n' | tr -d '"' | grep -qx 'ALL'; then
                echo "ALL"; return 0
            fi
            s=""; c=0
            for t in $(printf '%s' "$res" | tr -d '"'); do
                if [[ "$t" =~ ^[0-9]+$ ]]; then s="${s}${s:+,}$t"; c=$((c+1)); fi
            done
            if [ $c -eq 0 ]; then
                whiptail --title "$title" --msgbox \
                    "$(is_en && echo 'Nothing selected — tick ALL or select tracks.' || echo '未选择任何曲目——勾选 ALL 或勾选具体曲目。')" \
                    0 60 "${MF_WT_COMMON[@]}"
                continue
            fi
            echo "$s"; return 0
        done
    fi

    if ui_can_tui; then
        # cur=0 是「全选」伪条目，1..n 对应曲目（显示编号 = cur）
        local redraw=1 flash="" start end i4 mark rel t2
        while :; do
            if [ $redraw -eq 1 ]; then
                [ $cur -gt 0 ] && page=$(( (cur-1) / page_n ))
                start=$((page * page_n))
                end=$((start + page_n - 1)); [ $end -ge $n ] && end=$((n-1))
                echo "" >&2
                printf '\033[1m%s\033[0m  \033[2m(%s %d/%d · %s %s/%d)\033[0m\n' \
                    "$title" "$(is_en && echo page || echo 页)" $((page+1)) $total_pages \
                    "$(is_en && echo selected || echo 已选)" \
                    "$([ $all_on -eq 1 ] && echo ALL || echo "$(_ui_sel_cnt)")" "$n" >&2
                mark="[ ]"; [ $all_on -eq 1 ] && mark="\033[32m[✓]\033[0m"
                if [ $cur -eq 0 ]; then
                    printf '\033[1;32m ❯\033[0m %s \033[1m  ★ %s\033[0m\n' "$mark" "$(is_en && echo 'Select ALL tracks' || echo '全选所有曲目')" >&2
                else
                    printf '    %s   ★ %s\n' "$mark" "$(is_en && echo 'Select ALL tracks' || echo '全选所有曲目')" >&2
                fi
                for i4 in $(seq $start $end); do
                    mark="[ ]"; [ "${on[$i4]}" = 1 ] && mark="\033[32m[✓]\033[0m"
                    if [ $i4 -eq $((cur-1)) ]; then
                        printf '\033[1;32m ❯\033[0m %s \033[1m%3d. %s\033[0m\n' "$mark" $((i4+1)) "${items[$i4]}" >&2
                    else
                        printf '    %s %3d. %s\n' "$mark" $((i4+1)) "${items[$i4]}" >&2
                    fi
                done
                if [ -n "$flash" ]; then printf '\033[33m%s\033[0m\n' "$flash" >&2; else echo "" >&2; fi
                printf '\033[2m%s\033[0m\n' "$(is_en \
                    && echo '↑↓ move · space toggle · a ALL · n NONE · ←→ page · Enter OK · b back' \
                    || echo '↑↓移动 · 空格勾选 · a全选 · n全不选 · ←→翻页 · 回车确认 · b返回')" >&2
                flash=""; redraw=0
            fi
            _ui_readkey
            case "$KEY" in
                up)   [ $cur -gt 0 ] && { cur=$((cur-1)); _ui_clear $((page_n+6)); redraw=1; } ;;
                down) [ $cur -lt $n ] && { cur=$((cur+1)); _ui_clear $((page_n+6)); redraw=1; } ;;
                left)  [ $page -gt 0 ] && { page=$((page-1)); cur=$((page*page_n+1)); _ui_clear $((page_n+6)); redraw=1; } ;;
                right) [ $page -lt $((total_pages-1)) ] && { page=$((page+1)); cur=$((page*page_n+1)); _ui_clear $((page_n+6)); redraw=1; } ;;
                space)
                    if [ $cur -eq 0 ]; then
                        all_on=$((1-all_on))
                        for i in $(seq 0 $((n-1))); do on[$i]=$all_on; done
                    else
                        on[$((cur-1))]=$((1 - on[$((cur-1))]))
                    fi
                    _ui_clear $((page_n+6)); redraw=1 ;;
                a|A) all_on=1; for i in $(seq 0 $((n-1))); do on[$i]=1; done; _ui_clear $((page_n+6)); redraw=1 ;;
                n|N) all_on=0; for i in $(seq 0 $((n-1))); do on[$i]=0; done; _ui_clear $((page_n+6)); redraw=1 ;;
                enter)
                    if [ $all_on -eq 1 ]; then echo "" >&2; echo "ALL"; return 0; fi
                    if [ "$(_ui_sel_cnt)" -eq 0 ]; then
                        flash="$(is_en && echo '⚠ nothing selected' || echo '⚠ 未选择任何条目')"
                        _ui_clear $((page_n+6)); redraw=1; continue
                    fi
                    echo "" >&2
                    _ui_sel_str; return 0 ;;
                b|B|esc) echo "" >&2; return 255 ;;
                [1-9])
                    rel=$KEY; start=$((page * page_n)); t2=$((start + rel - 1))
                    if [ $t2 -lt $n ] && [ $t2 -ge $start ]; then
                        cur=$((t2+1)); on[$t2]=$((1 - on[$t2])); _ui_clear $((page_n+6)); redraw=1
                    fi ;;
            esac
        done
    fi

    # 数字降级：编号列表 + 输入（支持 1,3,5-7；回车=全部）
    echo "" >&2
    printf '\033[1m%s\033[0m\n' "$title" >&2
    local i5 TI P
    for i5 in "${!items[@]}"; do
        printf '  %3d. %s\n' $((i5+1)) "${items[$i5]}" >&2
    done
    echo "" >&2
    while :; do
        # 提示走 stderr，避免污染 $( ) 捕获的结果
        printf '%s' "$(is_en && echo 'Numbers [Enter=all, e.g. 1,3,5-7 · 0=back]: ' || echo '编号 [回车=全部，支持 1,3,5-7 · 0=返回]: ')" >&2
        _ui_readline TI
        if [ "$TI" = "0" ] || [ "$TI" = "b" ]; then return 255; fi
        if [ -z "$TI" ] || [ "$TI" = "a" ] || [ "$TI" = "A" ]; then echo "ALL"; return 0; fi
        P=$(parse_track_selection "$TI" "$n")
        if [[ "$P" == INVALID:* ]]; then
            echo "$(is_en && echo '  Invalid selection' || echo '  选择无效')" >&2
            continue
        fi
        echo "$P"; return 0
    done
}

# ── 曲目选择（分页列表 + 输入框）─────────────────
# v3.3: 长列表勾选太累，回到"分页浏览 + 编号输入"——回车=全部，支持 1,3,5-7，
# a=全部，0/b=返回上一步。所有 UI 层统一用此交互（不依赖 whiptail）
# 用法: 条目逐行经 stdin 传入；输出 "ALL" 或 "1,3,5"；返回 255 = 返回
ui_pick_tracks() {
    local title="$1" page_n="${2:-15}"
    local items=() line
    while IFS= read -r line; do
        [ -n "$line" ] && items+=("$line")
    done
    local n=${#items[@]}
    [ "$n" -eq 0 ] && { echo "ALL"; return 0; }
    local total_pages=$(( (n - 1) / page_n + 1 ))
    local page=0 i

    # 分页浏览：回车翻页，q/直接回车到最后页后进入输入
    echo "" >&2
    printf '\033[1m%s\033[0m  (%d %s, %d %s/页)\n' "$title" "$n" \
        "$(is_en && echo tracks || echo 首)" "$page_n" >&2
    while [ $page -lt $total_pages ]; do
        local start=$((page * page_n)) end=$((start + page_n - 1))
        [ $end -ge $n ] && end=$((n - 1))
        for i in $(seq $start $end); do
            printf '  %3d. %s\n' $((i+1)) "${items[$i]}" >&2
        done
        page=$((page + 1))
        if [ $page -lt $total_pages ]; then
            printf '\033[2m%s\033[0m' "$(is_en \
                && echo "── Page $page/$total_pages · Enter=next page · q=input now ── " \
                || echo "── 第 $page/$total_pages 页 · 回车=下一页 · q=直接输入 ── ")" >&2
            local key=""
            _ui_readline key
            [ "$key" = "q" ] || [ "$key" = "Q" ] && break
        fi
    done

    # 输入框
    while :; do
        printf '%s' "$(is_en \
            && echo "Numbers [Enter/a=all, e.g. 1,3,5-7 · 0=back]: " \
            || echo "编号 [回车/a=全部，支持 1,3,5-7 · 0=返回]: ")" >&2
        local TI P
        _ui_readline TI
        if [ "$TI" = "0" ] || [ "$TI" = "b" ]; then return 255; fi
        if [ -z "$TI" ] || [ "$TI" = "a" ] || [ "$TI" = "A" ]; then echo "ALL"; return 0; fi
        P=$(parse_track_selection "$TI" "$n")
        if [[ "$P" == INVALID:* ]]; then
            printf '\033[33m%s\033[0m\n' "$(is_en && echo '  Invalid selection, retry' || echo '  选择无效，重试')" >&2
            continue
        fi
        echo "$P"; return 0
    done
}
