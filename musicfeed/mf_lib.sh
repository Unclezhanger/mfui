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

# 隐藏文件夹完全由用户在 mf_setup 中勾选，为空 = 不隐藏任何目录

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
        part="${part#"${part%%[![:space:]]*}"}"   # 去前导空白（不要用 xargs：它会解释引号/反斜杠）
        part="${part%"${part##*[![:space:]]}"}"   # 去尾随空白
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
    # 调用方（ui_checklist / ui_pick_tracks）已把"回车/a = 全选"转成显式 ALL；
    # 走到这里 result 为空只可能是解析失败（如孤立引号），不能当成全选。
    [ -z "$result" ] && { echo "INVALID:empty"; return 1; }
    echo "$result"
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
    local raw album count artist idx=0 line title
    raw=$(jq -r '.title // ""' "$tmp_json")
    # 去掉形如 "Artist - " 的首个前缀（非贪婪语义：用 bash 最短前缀截断实现，等价于原 re.sub(r'^.+? - ','')）
    album="${raw#*" - "}"
    album="$(printf '%s' "$album" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/|/｜/g')"
    [ -z "$album" ] && album="Unknown Album"
    count=$(jq -r '.playlist_count // 0' "$tmp_json")
    artist=$(jq -r '(.entries[0].uploader // "")' "$tmp_json")
    artist="${artist%" - Topic"}"
    artist="$(printf '%s' "$artist" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/|/｜/g')"
    [ -z "$artist" ] && artist="Unknown Artist"
    echo "$album"; echo "$count"; echo "$artist"
    while IFS= read -r line; do
        idx=$((idx+1))
        title="${line#*" - "}"
        title="${title//|/｜}"
        echo "${idx}. ${title}"
    # v4.0.4: 之前 '.entries[]?.title // "Unknown"' 在 entries 为空数组时，因 jq 的
    # 替代运算符优先级，整表达式落到 "Unknown"，凭空多出一行幽灵曲目 "1. Unknown"；
    # 加管道后 // 只作用于单条 entry，空数组即零行输出
    done < <(jq -r '.entries[]? | (.title // "Unknown")' "$tmp_json")
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
    local playlist count idx=0 title vid uploader_raw has_album has_artist is_topic has_meta uploader
    playlist=$(jq -r '.title // ""' "$tmp_json")
    playlist="$(printf '%s' "$playlist" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/|/｜/g')"
    [ -z "$playlist" ] && playlist="Unknown Playlist"
    count=$(jq -r '.playlist_count // 0' "$tmp_json")
    echo "$playlist"; echo "$count"
    # 每条 entry 一行 TSV：title \t id \t uploader/channel \t album \t artist；entry 为 null 时首字段标记 NULL
    # v4.0.4: tab 属于 IFS 空白字符，连续 tab 会被折叠成单个分隔符——空字段丢失导致
    # uploader/album/artist 字段整体左移（实测 uploader 为空时 uploader 读到 album 的值，
    # has_meta 误判为 False）。改用单元分隔符 \x1f（非空白，逐个精确分列）；@tsv 输出
    # 里的真实 tab 由 sed 统一转成 \x1f，@tsv 对值内 \t/\n/\\ 的转义语义保持不变
    while IFS=$'\x1f' read -r title vid uploader_raw has_album has_artist; do
        idx=$((idx+1))
        if [ "$title" = "NULL" ] && [ -z "$vid" ]; then
            echo "${idx}. [unavailable]||False"
            continue
        fi
        [ -z "$title" ] && title="Track $idx"
        title="${title//|/｜}"
        # v4.3: flat-playlist 看不到 album/artist，但 " - Topic"（YTM 歌手自动频道）
        # 的曲目下载时 info.json 必带完整 meta——预览阶段按 Topic 预判 has_meta
        is_topic=0
        [[ "$uploader_raw" == *" - Topic"* ]] && is_topic=1
        has_meta="False"
        if [ -n "$has_album" ] || [ -n "$has_artist" ] || [ "$is_topic" -eq 1 ]; then has_meta="True"; fi
        uploader="${uploader_raw%" - Topic"}"
        uploader="$(printf '%s' "$uploader" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/|/｜/g')"
        echo "${idx}. ${title}|${vid}|${has_meta}|${uploader}"
    done < <(jq -r '.entries[] | if . == null then "NULL\t\t\t\t" else ([(.title // ""), (.id // ""), ((.uploader // .channel) // ""), (.album // ""), (.artist // "")] | @tsv) end' "$tmp_json" | sed $'s/\t/\x1f/g')
    rm -f "$tmp_json"
}

# get_single_info: 抓单曲 info.json
# stdout 5 行：album / title / artist / uploader / has_metadata(bool)
get_single_info() {
    local url="$1"
    # 剥离 &list= 参数：watch?v=X&list=RD… 的 Mix/Radio 形态会让 yt-dlp
    # 展开整个播放列表（逐条 info.json，数百条，preview 长时间挂起）；
    # single 语义只取当前视频
    [[ "$url" == *"&list="* ]] && url="${url%%&list=*}"
    tmp_json="/tmp/ytm_single_$$"
    CLEANUP_FILES+=("${tmp_json}.info.json" "$tmp_json")
    "$MF_YTDLP" $MF_NODE_ARGS --write-info-json --skip-download -o "$tmp_json" "$url" >/dev/null 2>&1
    local json_file="${tmp_json}.info.json"
    if [ ! -f "$json_file" ]; then
        echo "Unknown"; echo "1"; echo ""; echo ""; echo "False"
        rm -f "$tmp_json" "$json_file" 2>/dev/null; return
    fi
    local album title artist uploader has_metadata
    album=$(jq -r '.album // ""' "$json_file")
    title=$(jq -r '.title // "Unknown"' "$json_file")
    artist=$(jq -r '.artist // ""' "$json_file")
    uploader=$(jq -r '.uploader // ""' "$json_file")
    if [ -n "$artist" ] && [ -n "$album" ]; then has_metadata="True"; else has_metadata="False"; fi
    echo "$album"; echo "$title"; echo "$artist"; echo "$uploader"; echo "$has_metadata"
    rm -f "$tmp_json" "$json_file" 2>/dev/null
}

# ─────────────────────────────────────────────
# 9. 链接类型检测（无交互）
# ─────────────────────────────────────────────
# 输出: album | ytm_radio | playlist | single | unknown
get_link_type() {
    local url="$1"
    # OLAK5uy_ = YTM 分享链接；MPREb_ = YTM 专辑/发行 browse 链接
    # （从 music.youtube.com 地址栏直接复制，与 OLAK5uy 指向同一专辑实体）
    [[ "$url" =~ OLAK5uy_ ]] || [[ "$url" =~ MPREb_ ]] && { echo "album"; return; }
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
    # v4.1: 回车 = 显示的默认值（旧实现任意输入/回车一律算"是"）；非法输入重问
    while :; do
        _ui_readline yn
        case "$yn" in
            "") [ "$def" = "y" ] && return 0 || return 1 ;;
            b|B) return 255 ;;
            y|Y) return 0 ;;
            n|N) return 1 ;;
            *) echo "$(is_en && echo '  Please answer y / n / b' || echo '  请输入 y / n / b')" ;;
        esac
    done
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
    local v2 pp
    if ( : < /dev/tty ) 2>/dev/null; then
        # v4.1: 自由文本改用 readline（read -e）——普通 read 的行编辑交给内核 tty，
        # 其退格擦除按字节处理、不认中日韩字符的显示宽度，退格修改中文会列数错位
        # 出乱码甚至撕出半个字符。readline 按字符+宽度编辑，根治。
        # \001/\002 是 readline 的提示串忽略标记，让宽度计算跳过 ANSI 色码
        # （printf -v 让 \001/\033 成为真实控制字节，双引号里它们只是字面文本）
        if is_en; then printf -v pp '%s \001\033[2m\002[%s] (< = back)\001\033[0m\002: ' "$title" "$def"
        else printf -v pp '%s \001\033[2m\002[%s]（< = 返回上一步）\001\033[0m\002: ' "$title" "$def"; fi
        IFS= read -r -e -p "$pp" v2 < /dev/tty
    else
        if is_en; then printf '%s \033[2m[%s] (< = back)\033[0m: ' "$title" "$def" >&2
        else printf '%s \033[2m[%s]（< = 返回上一步）\033[0m: ' "$title" "$def" >&2; fi
        IFS= read -r v2
    fi
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
            # v4.0.2 修复：ALL 默认预勾选，用户勾了具体曲目却忘记取消 ALL 时，
            # 原逻辑一律优先 ALL 导致"选了几首却下载全部"。现在只要有具体曲目
            # 被勾选，一律以具体选择为准，ALL 仅在没有任何单曲被勾选时生效
            s=""; c=0; has_all=0
            for t in $(printf '%s' "$res" | tr -d '"'); do
                if [ "$t" = "ALL" ]; then
                    has_all=1
                elif [[ "$t" =~ ^[0-9]+$ ]]; then
                    s="${s}${s:+,}$t"; c=$((c+1))
                fi
            done
            if [ $c -gt 0 ]; then
                echo "$s"; return 0
            fi
            if [ $has_all -eq 1 ]; then
                echo "ALL"; return 0
            fi
            whiptail --title "$title" --msgbox \
                "$(is_en && echo 'Nothing selected — tick ALL or select tracks.' || echo '未选择任何曲目——勾选 ALL 或勾选具体曲目。')" \
                0 60 "${MF_WT_COMMON[@]}"
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
                        # v4.0.2 修复：一旦手动勾选/取消任意单曲，视为放弃"全选"，
                        # 避免顶部 ALL 标志位从未被显式取消、回车时把单独选的曲目吞掉
                        all_on=0
                    fi
                    _ui_clear $((page_n+6)); redraw=1 ;;
                a|A) all_on=1; for i in $(seq 0 $((n-1))); do on[$i]=1; done; _ui_clear $((page_n+6)); redraw=1 ;;
                n|N) all_on=0; for i in $(seq 0 $((n-1))); do on[$i]=0; done; _ui_clear $((page_n+6)); redraw=1 ;;
                enter)
                    # v4.0.2 修复：只要有手动勾选的具体曲目，一律以具体选择为准，
                    # 不再被可能残留的 all_on=1 覆盖成"下载全部"
                    if [ "$(_ui_sel_cnt)" -gt 0 ]; then
                        echo "" >&2
                        _ui_sel_str; return 0
                    fi
                    if [ $all_on -eq 1 ]; then echo "" >&2; echo "ALL"; return 0; fi
                    flash="$(is_en && echo '⚠ nothing selected' || echo '⚠ 未选择任何条目')"
                    _ui_clear $((page_n+6)); redraw=1; continue ;;
                b|B|esc) echo "" >&2; return 255 ;;
                [1-9])
                    rel=$KEY; start=$((page * page_n)); t2=$((start + rel - 1))
                    if [ $t2 -lt $n ] && [ $t2 -ge $start ]; then
                        cur=$((t2+1)); on[$t2]=$((1 - on[$t2])); all_on=0; _ui_clear $((page_n+6)); redraw=1
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
