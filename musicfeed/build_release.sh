#!/bin/bash
# build_release.sh — 生成公开发布用的自包含脚本
#
# 开发态：musicfeed.sh 依赖同目录的 mf_lib.sh（模块化好维护）
# 发布态：公开仓库只发 musicfeed.sh + mf_setup.sh 两个文件，
#         本脚本把 mf_lib.sh 全文内联到 source 位置，行为不变。
#
# 用法：bash build_release.sh [输出目录]（默认 ./dist）
set -e
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$DIR/dist}"
mkdir -p "$OUT"

SRC="$DIR/musicfeed.sh"
LIB="$DIR/mf_lib.sh"

LINE=$(grep -Fn 'source "$SCRIPT_DIR/mf_lib.sh"' "$SRC" | head -1 | cut -d: -f1)
if [ -z "$LINE" ]; then
    echo "❌ 未在 musicfeed.sh 中找到 mf_lib 的 source 行" >&2
    exit 1
fi

{
    head -n $((LINE - 1)) "$SRC"
    echo "# ══════════ mf_lib.sh（构建时内联，勿直接编辑本段）══════════"
    cat "$LIB"
    echo "# ══════════ mf_lib.sh 内联结束 ══════════"
    tail -n +$((LINE + 1)) "$SRC"
} > "$OUT/musicfeed.sh"
chmod +x "$OUT/musicfeed.sh"

cp "$DIR/mf_setup.sh" "$OUT/mf_setup.sh"
chmod +x "$OUT/mf_setup.sh"

bash -n "$OUT/musicfeed.sh" && bash -n "$OUT/mf_setup.sh"
echo "✅ 发布脚本已生成: $OUT/musicfeed.sh + $OUT/mf_setup.sh"
echo "   自包含性检查: $(grep -c 'mf_lib' "$OUT/musicfeed.sh") 处 mf_lib 引用（应为 0 之外仅注释）"
