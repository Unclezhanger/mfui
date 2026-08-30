#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# setup.sh - mfui 首次安装与环境检测脚本
#
# 设计原则：
#   1. 严格"先展示后操作"——任何安装/升级都先让用户看到当前版本
#   2. 已装工具默认不升级（避免破坏服务器其他项目的依赖版本）
#   3. 未装工具默认安装，用户可拒绝
#   4. yt-dlp 特殊处理：单独询问是否换 nightly（防 YouTube 反爬）
#   5. 所有 sudo / apt / pip 命令执行前都会再次打印，给用户最后确认机会
#
# 注意：v4.0.0 起：
#   - 运行时从 bun 换成 Node.js（>= 20）
#   - yt-dlp / mutagen 安装到项目本地 Python venv（.venv/），不污染系统
#   - 已删除 caddy 依赖，改用 Next.js 内部代理转发到 mini-service
#
# 用法：
#   bash setup.sh           # 交互式（检测 + 询问安装）
#   bash setup.sh --check   # 仅检测展示，不询问、不安装
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# 项目根目录（setup.sh 所在目录）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 颜色
if [[ -t 1 ]] && command -v tput &>/dev/null; then
  C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3)
  C_BLUE=$(tput setaf 4); C_CYAN=$(tput setaf 6); C_BOLD=$(tput bold)
  C_RESET=$(tput sgr0)
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

# 工具函数
ok()    { echo "${C_GREEN}✓${C_RESET} $1"; }
warn()  { echo "${C_YELLOW}⚠${C_RESET} $1"; }
err()   { echo "${C_RED}✗${C_RESET} $1"; }
info()  { echo "${C_CYAN}ℹ${C_RESET} $1"; }
title() { echo ""; echo "${C_BOLD}${C_BLUE}══ $1 ══${C_RESET}"; }

ask_yn() {
  local prompt="$1" default="${2:-y}" hint ans
  [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
  while true; do
    read -rp "${C_BOLD}${prompt}${C_RESET} ${hint} " ans
    ans=${ans:-$default}
    case "$ans" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      [Nn]|[Nn][Oo]) return 1 ;;
      *) echo "  请输入 y 或 n" ;;
    esac
  done
}

# 获取命令版本（容错）
get_version() {
  local cmd="$1" ver_cmd="$2"
  if command -v "$cmd" &>/dev/null; then
    eval "$ver_cmd" 2>/dev/null | head -1 | tr -d '\n' || echo "(已安装)"
  else
    echo ""
  fi
}

# 检测 Python 模块
check_python_module() {
  local mod="$1"
  python3 -c "import ${mod}" 2>/dev/null && echo "1" || echo "0"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: 系统信息
# ─────────────────────────────────────────────────────────────────────────────

print_system_info() {
  title "系统信息"
  echo "  OS:        $(uname -sr)"
  echo "  发行版:    $([ -f /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME")"
  echo "  内核:      $(uname -r)"
  echo "  架构:      $(uname -m)"
  echo "  Shell:     $SHELL ($(bash --version | head -1))"
  echo "  项目路径:  $SCRIPT_DIR"
  echo "  当前用户:  $(whoami)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: 依赖检测（仅展示，不操作）
# ─────────────────────────────────────────────────────────────────────────────

# 全局变量：存检测结果，供后续安装函数用
DEP_BASH_VER="" DEP_YTDLP_VER="" DEP_FFMPEG_VER=""
DEP_PYTHON_VER="" DEP_NODE_VER="" DEP_MUTAGEN_VER=""
DEP_VENV_YTDLP_VER="" DEP_VENV_MUTAGEN_VER=""
DEP_BASH_INSTALLED=0 DEP_YTDLP_INSTALLED=0 DEP_FFMPEG_INSTALLED=0
DEP_PYTHON_INSTALLED=0 DEP_NODE_INSTALLED=0 DEP_MUTAGEN_INSTALLED=0

MF_VENV_DIR="$SCRIPT_DIR/.venv"

detect_dependencies() {
  title "依赖检测（当前状态）"

  # 必需命令
  DEP_BASH_VER=$(get_version bash "bash --version")
  DEP_FFMPEG_VER=$(get_version ffmpeg "ffmpeg -version")
  DEP_PYTHON_VER=$(get_version python3 "python3 --version")
  DEP_NODE_VER=$(get_version node "node --version")

  command -v bash &>/dev/null && DEP_BASH_INSTALLED=1
  command -v ffmpeg &>/dev/null && DEP_FFMPEG_INSTALLED=1
  command -v python3 &>/dev/null && DEP_PYTHON_INSTALLED=1
  command -v node &>/dev/null && DEP_NODE_INSTALLED=1

  # node 版本检查（Next.js 16 需要 >= 20）
  DEP_NODE_OK=0
  if [[ $DEP_NODE_INSTALLED -eq 1 ]]; then
    local major
    major=$(node --version 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')
    [[ "$major" =~ ^[0-9]+$ ]] && [[ "$major" -ge 20 ]] && DEP_NODE_OK=1
  fi

  # yt-dlp：优先检测项目 venv
  if [[ -x "$MF_VENV_DIR/bin/yt-dlp" ]]; then
    DEP_VENV_YTDLP_VER=$("$MF_VENV_DIR/bin/yt-dlp" --version 2>/dev/null)
  fi
  command -v yt-dlp &>/dev/null && DEP_YTDLP_INSTALLED=1
  DEP_YTDLP_VER=$(get_version yt-dlp "yt-dlp --version")

  # mutagen：优先检测项目 venv
  if [[ -x "$MF_VENV_DIR/bin/python3" ]]; then
    if "$MF_VENV_DIR/bin/python3" -c "import mutagen" &>/dev/null; then
      DEP_VENV_MUTAGEN_VER=$("$MF_VENV_DIR/bin/python3" -c "import mutagen; print(mutagen.version_string)" 2>/dev/null)
    fi
  fi
  if [[ $(check_python_module mutagen) == "1" ]]; then
    DEP_MUTAGEN_INSTALLED=1
    DEP_MUTAGEN_VER=$(python3 -c "import mutagen; print(mutagen.version_string)" 2>/dev/null)
  fi

  # 打印表格（版本号截断到合理长度避免破坏对齐）
  echo ""
  printf "  ${C_BOLD}%-12s %-26s %-12s %-8s${C_RESET}\n" "依赖" "当前版本" "状态" "必需"
  printf "  %-12s %-26s %-12s %-8s\n" "----------" "------------------------" "----------" "------"

  print_dep_row "bash"    "$DEP_BASH_VER"    $DEP_BASH_INSTALLED    true
  print_dep_row "node>=20" "$DEP_NODE_VER"   $DEP_NODE_OK           true
  print_dep_row "ffmpeg"  "$DEP_FFMPEG_VER"  $DEP_FFMPEG_INSTALLED  true
  print_dep_row "python3" "$DEP_PYTHON_VER" $DEP_PYTHON_INSTALLED true
  # python3-venv：项目 venv 已建 → ok；否则检测系统能否创建 venv（ensurepip 可用即视为有）
  if [[ -x "$MF_VENV_DIR/bin/pip" ]]; then
    print_dep_row "venv(python)" "项目 .venv 已创建" 1 true
  elif python3 -c "import ensurepip" &>/dev/null; then
    print_dep_row "venv(python)" "可用（ensurepip）" 1 true
  else
    print_dep_row "venv(python)" "缺 python3-venv 包" 0 true
  fi
  if [[ -n "$DEP_VENV_YTDLP_VER" ]]; then
    print_dep_row "yt-dlp(venv)" "venv: $DEP_VENV_YTDLP_VER" 1 true
  else
    print_dep_row "yt-dlp" "system: ${DEP_YTDLP_VER}" $DEP_YTDLP_INSTALLED true
  fi
  if [[ -n "$DEP_VENV_MUTAGEN_VER" ]]; then
    print_dep_row "mutagen(venv)" "venv: $DEP_VENV_MUTAGEN_VER" 1 true
  else
    print_dep_row "mutagen" "system: ${DEP_MUTAGEN_VER}" $DEP_MUTAGEN_INSTALLED true
  fi
}

print_dep_row() {
  local name="$1" ver="$2" installed="$3" required="$4"
  local status color
  if [[ $installed -eq 1 ]]; then
    if [[ "$required" == "true" ]]; then
      status="✓ 已装"; color="$C_GREEN"
    else
      status="✓ 已装"; color="$C_CYAN"
    fi
  else
    if [[ "$required" == "true" ]]; then
      status="✗ 未装"; color="$C_RED"
    else
      status="⚠ 未装"; color="$C_YELLOW"
    fi
  fi
  local req_str; [[ "$required" == "true" ]] && req_str="必需" || req_str="可选"
  # 版本号截断到 24 字符
  local short_ver="${ver:-(空)}"
  if [[ ${#short_ver} -gt 24 ]]; then
    short_ver="${short_ver:0:23}…"
  fi
  printf "  %-12s %-26s ${color}%-12s${C_RESET} %-8s\n" \
    "$name" "$short_ver" "$status" "$req_str"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: 系统依赖安装/升级（先展示，再询问，最后执行）
# ─────────────────────────────────────────────────────────────────────────────

install_system_deps() {
  title "系统依赖安装/升级"

  # 子函数：先打印要执行的命令，再询问，最后执行
  run_install() {
    local name="$1" current_ver="$2" action="$3" cmd="$4" default_yn="${5:-y}"
    echo ""
    echo "  ${C_BOLD}[$name]${C_RESET}"
    echo "    当前版本: ${current_ver:-(未安装)}"
    echo "    操作:     $action"
    echo "    将执行:"
    # 多行命令每行缩进显示
    echo "$cmd" | sed 's/^/      /'
    if ask_yn "    确认执行？" "$default_yn"; then
      info "执行中..."
      # 用 eval 执行多行命令
      if eval "$cmd"; then
        ok "$name 安装/升级完成"
      else
        err "$name 安装失败（exit=$?）"
        warn "请手动检查后重试，或跳过此依赖"
      fi
    else
      warn "已跳过 $name"
    fi
  }

  # ── 缺失的必需依赖 ──
  if [[ $DEP_FFMPEG_INSTALLED -eq 0 ]]; then
    run_install "ffmpeg" "$DEP_FFMPEG_VER" "安装 ffmpeg" \
      "sudo apt update && sudo apt install -y ffmpeg" "y"
  fi

  if [[ $DEP_PYTHON_INSTALLED -eq 0 ]]; then
    run_install "python3" "$DEP_PYTHON_VER" "安装 python3 + venv" \
      "sudo apt update && sudo apt install -y python3 python3-venv" "y"
  fi

  # ── node：必需，>= 20（apt 版通常太旧，用 NodeSource）──
  if [[ $DEP_NODE_OK -ne 1 ]]; then
    echo ""
    echo "  ${C_BOLD}[node]${C_RESET} — 需要 Node.js >= 20（当前: ${DEP_NODE_VER:-未安装}）"
    echo "    Mint/Ubuntu 的 apt 源里 nodejs 版本通常太旧，推荐 NodeSource 安装 22.x"
    echo "    （装在其他项目也不用担心：node 只是运行时，各项目依赖都在各自的 node_modules 里）"
    if ask_yn "    通过 NodeSource 安装 Node.js 22？" "y"; then
      run_install "node 22" "$DEP_NODE_VER" "安装 Node.js 22 (NodeSource)" \
        "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs" "y"
    else
      warn "已跳过 node 安装（可自行用 nvm/n 等管理器安装 >= 20 后重跑 setup.sh）"
    fi
  fi

  # ── 项目 Python venv（yt-dlp / mutagen 隔离安装，无 sudo、不碰系统）──
  echo ""
  echo "  ${C_BOLD}[Python venv]${C_RESET} — yt-dlp / mutagen 隔离环境"
  echo "    位置:     $MF_VENV_DIR（项目内，删掉即彻底卸载）"
  echo "    venv 内:  yt-dlp ${DEP_VENV_YTDLP_VER:-未安装}, mutagen ${DEP_VENV_MUTAGEN_VER:-未安装}"
  if ask_yn "    创建/更新 venv 并安装 yt-dlp + mutagen？" "y"; then
    echo ""
    info "创建 venv（如已存在则复用）..."
    if python3 -m venv "$MF_VENV_DIR"; then
      ok "venv 就绪"
    else
      err "venv 创建失败（缺 python3-venv 包？尝试: sudo apt install python3-venv）"
      return 1
    fi
    info "安装 yt-dlp + mutagen 到 venv ..."
    if "$MF_VENV_DIR/bin/pip" install --upgrade pip yt-dlp mutagen; then
      ok "yt-dlp $($MF_VENV_DIR/bin/yt-dlp --version 2>/dev/null) + mutagen 已装入 venv"
    else
      err "venv 内安装失败，请检查网络后重跑 setup.sh"
      return 1
    fi

    # yt-dlp nightly 选项（防 YouTube 反爬）
    echo ""
    echo "    说明: YouTube 经常更新反爬机制，yt-dlp nightly 更新更频繁，能更好规避 403。"
    if ask_yn "    是否改用 yt-dlp nightly？（遇到 403 时建议开启）" "n"; then
      info "在 venv 内安装 nightly ..."
      if "$MF_VENV_DIR/bin/pip" install --upgrade "yt-dlp @ https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp.tar.gz"; then
        ok "nightly 已装入 venv: $($MF_VENV_DIR/bin/yt-dlp --version 2>/dev/null)"
      else
        warn "nightly 安装失败，继续使用稳定版"
      fi
    fi
  else
    warn "已跳过 venv（start.sh 会回退到系统 yt-dlp，若存在）"
  fi

  # ── 已装工具：询问是否升级（默认 N，避免破坏其他项目）──
  title "已装工具升级检查"
  warn "以下工具已安装。升级可能影响服务器其他项目，请谨慎决定。"

  if [[ $DEP_FFMPEG_INSTALLED -eq 1 ]]; then
    if ask_yn "  升级 ffmpeg？(当前: ${DEP_FFMPEG_VER})" "n"; then
      run_install "ffmpeg" "$DEP_FFMPEG_VER" "升级" \
        "sudo apt update && sudo apt install --only-upgrade -y ffmpeg" "y"
    fi
  fi

  if [[ $DEP_PYTHON_INSTALLED -eq 1 ]]; then
    if ask_yn "  升级 python3？(当前: ${DEP_PYTHON_VER})" "n"; then
      run_install "python3" "$DEP_PYTHON_VER" "升级" \
        "sudo apt update && sudo apt install --only-upgrade -y python3" "y"
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: 项目文件状态检测
# ─────────────────────────────────────────────────────────────────────────────

check_file() {
  local desc="$1" path="$2" required="${3:-true}"
  if [[ -e "$path" ]]; then
    printf "  %-40s ${C_GREEN}✓ 存在${C_RESET}\n" "$desc"
    return 0
  else
    if [[ "$required" == "true" ]]; then
      printf "  %-40s ${C_RED}✗ 缺失${C_RESET}\n" "$desc"
    else
      printf "  %-40s ${C_YELLOW}⚠ 尚未生成${C_RESET}\n" "$desc"
    fi
    return 1
  fi
}

print_project_files() {
  title "项目文件状态"
  check_file "主项目 node_modules/"       "$SCRIPT_DIR/node_modules"          true
  check_file "mini-service node_modules/" "$SCRIPT_DIR/mini-services/job-runner/node_modules" true
  check_file "mf_config.sh (音乐目录配置)" "$SCRIPT_DIR/musicfeed/mf_config.sh" false
  check_file "数据库 db/custom.db"        "$SCRIPT_DIR/db/custom.db"          false
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5: 项目内无副作用操作（npm install / db:push）
# ─────────────────────────────────────────────────────────────────────────────

run_safe_steps() {
  title "项目依赖与数据库"

  local do_main_deps=false do_mini_deps=false do_db_push=false

  if [[ -d "$SCRIPT_DIR/node_modules" ]]; then
    ok "主项目依赖已安装"
    if ask_yn "  重新安装主项目依赖？(覆盖现有版本)" "n"; then
      do_main_deps=true
    fi
  else
    warn "主项目依赖未安装"
    if ask_yn "  现在执行 npm install？" "y"; then
      do_main_deps=true
    fi
  fi

  if [[ -d "$SCRIPT_DIR/mini-services/job-runner/node_modules" ]]; then
    ok "mini-service 依赖已安装"
    if ask_yn "  重新安装 mini-service 依赖？" "n"; then
      do_mini_deps=true
    fi
  else
    warn "mini-service 依赖未安装"
    if ask_yn "  现在执行 npm install (mini-services/job-runner)？" "y"; then
      do_mini_deps=true
    fi
  fi

  if [[ -f "$SCRIPT_DIR/db/custom.db" ]]; then
    ok "数据库已存在"
    if ask_yn "  重新生成 schema？(会清空现有 Job 记录)" "n"; then
      do_db_push=true
    fi
  else
    warn "数据库尚未初始化"
    if ask_yn "  现在执行 npm run db:push？" "y"; then
      do_db_push=true
    fi
  fi

  if $do_main_deps; then
    echo ""
    info "执行: npm install (主项目)"
    if npm install; then
      ok "主项目依赖安装完成"
    else
      err "主项目依赖安装失败"
      return 1
    fi
  fi

  if $do_mini_deps; then
    echo ""
    info "执行: npm install (mini-services/job-runner)"
    if (cd mini-services/job-runner && npm install); then
      ok "mini-service 依赖安装完成"
    else
      err "mini-service 依赖安装失败"
      return 1
    fi
  fi

  if $do_db_push; then
    echo ""
    info "执行: npm run db:push"
    if npm run db:push; then
      ok "数据库 schema 已推送"
    else
      err "数据库推送失败"
      return 1
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6: mf_setup.sh 提示
# ─────────────────────────────────────────────────────────────────────────────

check_musicfeed_config() {
  if [[ ! -f "$SCRIPT_DIR/musicfeed/mf_config.sh" ]]; then
    title "musicfeed 配置"
    warn "尚未运行 mf_setup.sh（音乐目录等配置未生成）"
    echo ""
    echo "  接下来调起 mf_setup.sh，它会交互式询问："
    echo "    - 语言（中文/English）"
    echo "    - 音乐根目录（如 \$HOME/navidrome/music）"
    echo "    - 默认歌手文件夹"
    echo "    - 音频格式（Opus/M4A）"
    echo "    - 隐藏的目录列表"
    echo ""
    if ask_yn "  现在运行 mf_setup.sh？" "y"; then
      bash musicfeed/mf_setup.sh
    else
      warn "已跳过。之后可随时手动运行: bash musicfeed/mf_setup.sh"
    fi
  else
    title "musicfeed 配置"
    ok "mf_config.sh 已存在"
    echo ""
    echo "  当前配置："
    while IFS='=' read -r key value; do
      [[ -z "$key" || "$key" =~ ^# ]] && continue
      value="${value%\"}"; value="${value#\"}"
      printf "    %-25s %s\n" "$key" "$value"
    done < "$SCRIPT_DIR/musicfeed/mf_config.sh"
    echo ""
    if ask_yn "  重新运行 mf_setup.sh 修改配置？" "n"; then
      bash musicfeed/mf_setup.sh
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 7: 总结
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
  title "下一步"

  cat <<EOF
  所有准备就绪后，启动服务：

    ${C_BOLD}bash start.sh${C_RESET}     # 一键启动（后台运行 2 个服务）
    ${C_BOLD}bash stop.sh${C_RESET}      # 一键停止

  启动后浏览器访问：

    ${C_BOLD}http://localhost:3010${C_RESET}

  查看实时日志：

    tail -f logs/next.log logs/job-runner.log

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo "${C_BOLD}${C_CYAN}╔════════════════════════════════════════════════════════════╗${C_RESET}"
  echo "${C_BOLD}${C_CYAN}║   mfui - 首次安装与环境检测                       ║${C_RESET}"
  echo "${C_BOLD}${C_CYAN}╚════════════════════════════════════════════════════════════╝${C_RESET}"

  # Phase 1: 系统信息
  print_system_info

  # Phase 2: 依赖检测
  detect_dependencies

  # --check 模式：仅检测，到此为止
  if [[ "${1:-}" == "--check" ]]; then
    echo ""
    info "--check 模式：仅检测展示，不询问、不安装。"
    print_project_files
    print_summary
    return 0
  fi

  # Phase 3: 系统依赖安装/升级
  install_system_deps

  # Phase 4: 项目文件检测
  print_project_files

  # Phase 5: 项目内操作
  run_safe_steps

  # Phase 6: mf_setup.sh 配置
  check_musicfeed_config

  # Phase 7: 总结
  print_summary
}

main "$@"
