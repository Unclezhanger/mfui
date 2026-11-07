#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# setup.sh - mfui Initial Setup & Environment Detection Script
#
# Design Principles:
#   1. Strict "show-then-act" — show current state before any install/upgrade
#   2. Installed tools are not upgraded by default (avoid breaking other projects)
#   3. Missing tools are installed by default (user can refuse)
#   4. yt-dlp special handling: separate prompt for nightly (prevent YouTube anti-scrape)
#   5. All sudo/apt/pip commands are printed before execution for confirmation
#
# Note: v4.0.0 onwards:
#   - Runtime switched from bun to Node.js (>= 20)
#   - yt-dlp / mutagen installed to project-local Python venv (.venv/), no system pollution
#   - Caddy dependency removed, using Next.js internal proxy forwarding to mini-service
#
# Usage:
#   bash setup.sh           # Interactive (detect + prompt for install)
#   bash setup.sh --check   # Show detection only, no prompts/install
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

# Project root directory (where setup.sh is located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
if [[ -t 1 ]] && command -v tput &>/dev/null; then
  C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3)
  C_BLUE=$(tput setaf 4); C_CYAN=$(tput setaf 6); C_BOLD=$(tput bold)
  C_RESET=$(tput sgr0)
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

# Utility functions
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
      *) echo "  Please enter y or n" ;;
    esac
  done
}

# 多选一：返回被选中的选项文本；Esc/空 = 默认项
ask_choice() {
  # 显示全部走 stderr（调用处用 $( ) 捕获答案，stdout 只允许出现最终选项）
  local prompt="$1" default="$2"; shift 2
  local opts=("$@") i ans
  echo "${C_BOLD}${prompt}${C_RESET}" >&2
  for i in "${!opts[@]}"; do
    [[ "${opts[$i]}" == "$default" ]] \
      && echo "  $((i+1)). ${opts[$i]} (default)" >&2 \
      || echo "  $((i+1)). ${opts[$i]}" >&2
  done
  while true; do
    read -rp "  Select [1-${#opts[@]}, Enter=default]: " ans
    ans=${ans:-$default}
    for i in "${!opts[@]}"; do
      [[ "$ans" == "${opts[$i]}" || "$ans" == "$((i+1))" ]] && { echo "${opts[$i]}"; return 0; }
    done
    echo "  Invalid choice" >&2
  done
}

# Get command version (fault-tolerant)
get_version() {
  local cmd="$1" ver_cmd="$2"
  if command -v "$cmd" &>/dev/null; then
    eval "$ver_cmd" 2>/dev/null | head -1 | tr -d '\n' || echo "(installed)"
  else
    echo ""
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 1: System Information
# ─────────────────────────────────────────────────────────────────────────────

print_system_info() {
  title "System Information"
  echo "  OS:        $(uname -sr)"
  echo "  Distro:    $([ -f /etc/os-release ] && . /etc/os-release && echo "$PRETTY_NAME")"
  echo "  Kernel:    $(uname -r)"
  echo "  Arch:      $(uname -m)"
  echo "  Shell:     $SHELL ($(bash --version | head -1))"
  echo "  Project:   $SCRIPT_DIR"
  echo "  User:      $(whoami)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 2: Dependency Detection (show only, no action)
# ─────────────────────────────────────────────────────────────────────────────

collect_dep_info() {
  # musicfeed v4.1 内核依赖：node>=22（WebUI 运行时；内核 yt-dlp EJS 运行时最低要求）、ffmpeg、jq、curl、
  # yt-dlp（项目内独立二进制 musicfeed/bin/yt-dlp 优先）。python3/venv/mutagen 已移除。
  # 项目内隔离安装目录（tools/bin 为 node 链接，musicfeed/bin 为 yt-dlp/ffmpeg/jq 静态件）
  TOOLS_BIN="$SCRIPT_DIR/tools/bin"
  MF_BIN_DIR="$SCRIPT_DIR/musicfeed/bin"
  [[ -x "$TOOLS_BIN/node" ]] && export PATH="$TOOLS_BIN:$PATH"
  # 项目内 ffmpeg/jq 静态件与系统同权优先（与 start.sh 的 PATH 顺序一致）
  [[ -x "$MF_BIN_DIR/ffmpeg" || -x "$MF_BIN_DIR/jq" ]] && export PATH="$MF_BIN_DIR:$PATH"

  DEP_FFMPEG_VER=$(ffmpeg -version 2>/dev/null | head -1 | sed -E "s/ffmpeg version ([^ ]+).*/\1/")
  DEP_JQ_VER=$(get_version jq "jq --version")
  DEP_NODE_VER=$(get_version node "node --version")
  # 标注 ffmpeg/jq 来源（项目内 musicfeed/bin / 系统）
  [[ -n "$DEP_FFMPEG_VER" && "$(command -v ffmpeg)" == "$MF_BIN_DIR/"* ]] && DEP_FFMPEG_VER="$DEP_FFMPEG_VER (project)"
  [[ -n "$DEP_JQ_VER" && "$(command -v jq)" == "$MF_BIN_DIR/"* ]] && DEP_JQ_VER="$DEP_JQ_VER (project)"

  # 标志位先初始化为 0（set -u 下未赋值变量引用会报 unbound）
  DEP_FFMPEG_INSTALLED=0
  DEP_JQ_INSTALLED=0
  DEP_CURL_INSTALLED=0
  DEP_YTDLP_INSTALLED=0

  command -v ffmpeg &>/dev/null && DEP_FFMPEG_INSTALLED=1
  command -v jq &>/dev/null && DEP_JQ_INSTALLED=1
  command -v curl &>/dev/null && DEP_CURL_INSTALLED=1

  if command -v node &>/dev/null; then
    DEP_NODE_VER=$(node --version 2>/dev/null)
    major=$(node --version 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')
    [[ -n "$major" && "$major" -ge 22 ]] && DEP_NODE_OK=1 || DEP_NODE_OK=0
    # 标注 node 来源（系统 / 项目内）
    [[ "$(command -v node)" == "$SCRIPT_DIR/tools/"* ]] && DEP_NODE_VER="$DEP_NODE_VER (project)" || DEP_NODE_VER="$DEP_NODE_VER (system)"
  else
    DEP_NODE_OK=0
  fi

  # yt-dlp：项目内独立二优先，回退系统 PATH
  MF_BIN_DIR="$SCRIPT_DIR/musicfeed/bin"
  if [[ -x "$MF_BIN_DIR/yt-dlp" ]]; then
    DEP_BIN_YTDLP_VER=$("$MF_BIN_DIR/yt-dlp" --version 2>/dev/null)
    DEP_BIN_YTDLP_INSTALLED=1
  else
    DEP_BIN_YTDLP_INSTALLED=0
  fi
  command -v yt-dlp &>/dev/null && DEP_YTDLP_INSTALLED=1
  DEP_YTDLP_VER=$(get_version yt-dlp "yt-dlp --version")
}

print_dep_row() {
  local name="$1" ver="${2:-}" installed="$3" required="${4:-true}" status
  if [[ $installed -eq 1 ]]; then
    status="${C_GREEN}✓${C_RESET}"
  elif [[ "$required" == "true" ]]; then
    status="${C_RED}✗${C_RESET}"
  else
    status="${C_YELLOW}○${C_RESET}"
  fi
  printf '  │ %-22s │ %-28s │   %s  │\n' "$name" "${ver:--}" "$status"
}

print_dep_table() {
  echo "  ┌────────────────────────┬──────────────────────────────┬────────┐"
  echo "  │ Dependency             │ Version                      │ Status │"
  echo "  ├────────────────────────┼──────────────────────────────┼────────┤"
  print_dep_row "node>=22 (WebUI)" "$DEP_NODE_VER"   $DEP_NODE_OK           true
  print_dep_row "ffmpeg"  "$DEP_FFMPEG_VER"  $DEP_FFMPEG_INSTALLED  true
  print_dep_row "jq"      "$DEP_JQ_VER"      $DEP_JQ_INSTALLED      true
  if [[ $DEP_BIN_YTDLP_INSTALLED -eq 1 ]]; then
    print_dep_row "yt-dlp(bin)" "project: $DEP_BIN_YTDLP_VER" 1 true
  elif [[ $DEP_YTDLP_INSTALLED -eq 1 ]]; then
    print_dep_row "yt-dlp" "system: ${DEP_YTDLP_VER}" $DEP_YTDLP_INSTALLED true
  else
    print_dep_row "yt-dlp" "(not installed)" 0 true
  fi
  echo "  └────────────────────────┴──────────────────────────────┴────────┘"
  echo "  (python3 / venv / mutagen — no longer needed by the v4.1 kernel)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 3: System Dependency Install/Upgrade (show first, prompt, then execute)
# ─────────────────────────────────────────────────────────────────────────────

install_system_deps() {
  title "System Dependency Install/Upgrade"

  # Subfunction: print command, prompt, then execute
  run_install() {
    local name="$1" current_ver="$2" action="$3" cmd="$4" default_yn="${5:-y}"
    echo ""
    echo "  ${C_BOLD}[$name]${C_RESET}"
    echo "    Current version: ${current_ver:-(not installed)}"
    echo "    Action:          $action"
    echo "    Will execute:"
    echo "$cmd" | sed 's/^/      /'
    if ask_yn "    Confirm execution?" "$default_yn"; then
      info "Executing..."
      if eval "$cmd"; then
        ok "$name install/upgrade complete"
      else
        err "$name install failed (exit=$?)"
        warn "Please check manually and retry, or skip this dependency"
      fi
    else
      warn "Skipped $name"
    fi
  }

  # ── Missing required dependencies ──
  # 隔离优先策略：优先装到项目目录（tools/bin 与 musicfeed/bin，删目录即卸载、
  # 不与系统工具串用）；用户明确选择才装进系统。
  MF_BIN_DIR="$SCRIPT_DIR/musicfeed/bin"
  mkdir -p "$MF_BIN_DIR"

  download_static_ffmpeg() {
    local dest="$MF_BIN_DIR/ffmpeg" asset
    case "$(uname -m)" in
      aarch64|arm64) asset="ffmpeg-release-arm64-static" ;;
      *)             asset="ffmpeg-release-amd64-static" ;;
    esac
    info "Downloading static ffmpeg ($asset)..."
    curl -fsSL --retry 3 "https://johnvansickle.com/ffmpeg/releases/$asset.tar.xz" -o /tmp/ff.tar.xz \
      && tar -xJf /tmp/ff.tar.xz -C /tmp --strip-components=1 --wildcards '*/ffmpeg' '*/ffprobe' \
      && mv /tmp/ffmpeg "$dest" && mv /tmp/ffprobe "$MF_BIN_DIR/ffprobe" \
      && chmod +x "$dest" "$MF_BIN_DIR/ffprobe" && rm -f /tmp/ff.tar.xz
  }

  download_static_jq() {
    local dest="$MF_BIN_DIR/jq" asset
    case "$(uname -m)" in
      aarch64|arm64) asset="jq-linux-arm64" ;;
      *)             asset="jq-linux-amd64" ;;
    esac
    info "Downloading static jq ($asset)..."
    curl -fsSL --retry 3 "https://github.com/jqlang/jq/releases/latest/download/$asset" -o "$dest" \
      && chmod +x "$dest"
  }

  install_project_node() {
    local ver="22.23.4" asset dir
    case "$(uname -m)" in
      aarch64|arm64) asset="linux-arm64" ;;
      *)             asset="linux-x64" ;;
    esac
    info "Downloading Node.js v$ver ($asset) to project tools/..."
    mkdir -p "$SCRIPT_DIR/tools/bin"
    curl -fsSL --retry 3 "https://nodejs.org/dist/v$ver/node-v$ver-$asset.tar.xz" -o /tmp/node.tar.xz \
      && tar -xJf /tmp/node.tar.xz -C "$SCRIPT_DIR/tools" \
      && dir="$SCRIPT_DIR/tools/node-v$ver-$asset" \
      && ln -sfn "$dir/bin/node" "$SCRIPT_DIR/tools/bin/node" \
      && ln -sfn "$dir/bin/npm" "$SCRIPT_DIR/tools/bin/npm" \
      && ln -sfn "$dir/bin/npx" "$SCRIPT_DIR/tools/bin/npx" \
      && rm -f /tmp/node.tar.xz \
      && ok "project node: $($SCRIPT_DIR/tools/bin/node --version 2>/dev/null)"
  }

  if [[ $DEP_FFMPEG_INSTALLED -eq 0 ]]; then
    echo ""
    echo "  ${C_BOLD}[ffmpeg]${C_RESET} — 未检测到"
    case "$(ask_choice "    How should ffmpeg be installed? (project-local is isolated: delete the folder to uninstall, never touches system tools)" "Project-local (static build, recommended)" "Project-local (static build, recommended)" "System (sudo apt)")" in
      "System (sudo apt)")
        run_install "ffmpeg" "$DEP_FFMPEG_VER" "Install ffmpeg (system)" \
          "sudo apt update && sudo apt install -y ffmpeg" "y" ;;
      *)
        run_install "ffmpeg (project)" "" "Download static ffmpeg → $MF_BIN_DIR" \
          "download_static_ffmpeg" "y" ;;
    esac
  fi

  if [[ $DEP_JQ_INSTALLED -eq 0 ]]; then
    echo ""
    echo "  ${C_BOLD}[jq]${C_RESET} — 未检测到（v4.1 内核 JSON 解析必需）"
    case "$(ask_choice "    How should jq be installed?" "Project-local (static single file, recommended)" "Project-local (static single file, recommended)" "System (sudo apt)")" in
      "System (sudo apt)")
        run_install "jq" "$DEP_JQ_VER" "Install jq (system)" \
          "sudo apt update && sudo apt install -y jq" "y" ;;
      *)
        run_install "jq (project)" "" "Download static jq → $MF_BIN_DIR" \
          "download_static_jq" "y" ;;
    esac
  fi

  if [[ $DEP_CURL_INSTALLED -eq 0 ]]; then
    run_install "curl" "" "Install curl (for album art download)" \
      "sudo apt update && sudo apt install -y curl" "y"
  fi

  # ── node: required, >= 22（WebUI/job-runner 运行时；内核 yt-dlp EJS 运行时最低要求）──
  if [[ $DEP_NODE_OK -ne 1 ]]; then
    echo ""
    echo "  ${C_BOLD}[node]${C_RESET} — Requires Node.js >= 22 (current: ${DEP_NODE_VER:-not installed})"
    case "$(ask_choice "    How should Node.js be installed?" "Project-local (official binary, no sudo)" "Project-local (official binary, no sudo)" "System (NodeSource, sudo)")" in
      "System (NodeSource, sudo)")
        run_install "node 22" "$DEP_NODE_VER" "Install Node.js 22 (NodeSource)" \
          "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs" "y" ;;
      *)
        run_install "node (project)" "" "Download Node.js LTS → $SCRIPT_DIR/tools/" \
          "install_project_node" "y" ;;
    esac
  fi

  # ── yt-dlp：独立官方二进制 → 项目内 musicfeed/bin/yt-dlp（无 python/pip）──
  # 频道切换（stable/nightly）与升级统一在 mf_setup.sh 的 yt-dlp 步骤进行
  # （setup.sh 与 mf_setup 指向同一个二进制，避免两头询问互相打架）；
  # start.sh 每次启动按配置里的 MF_YTDLP_CHANNEL 自动检测所选频道的最新版本
  MF_BIN_DIR="$SCRIPT_DIR/musicfeed/bin"
  if [[ $DEP_BIN_YTDLP_INSTALLED -eq 1 ]]; then
    echo ""
    info "yt-dlp: $("$MF_BIN_DIR/yt-dlp" --version 2>/dev/null) (project bin)"
    info "Channel switching (stable/nightly) and upgrades: run ${C_BOLD}bash mf_setup.sh${C_RESET} → yt-dlp step"
  elif [[ $DEP_YTDLP_INSTALLED -eq 1 ]]; then
    echo ""
    info "yt-dlp: ${DEP_YTDLP_VER:-installed} (system PATH)"
    info "To isolate it into the project bin and manage stable/nightly switching: run ${C_BOLD}bash mf_setup.sh${C_RESET} → yt-dlp step"
  else
    echo ""
    echo "  ${C_BOLD}[yt-dlp]${C_RESET} — Standalone official binary → $MF_BIN_DIR/yt-dlp"
    echo "    (v4.1 kernel needs no python/pip; binary is self-contained)"
    if ask_yn "    Download yt-dlp (stable) to project bin?" "y"; then
      local ytdlp_asset
      case "$(uname -m)" in
        aarch64|arm64) ytdlp_asset="yt-dlp_linux_aarch64" ;;
        *)             ytdlp_asset="yt-dlp_linux" ;;
      esac
      info "Downloading yt-dlp ($ytdlp_asset)..."
      mkdir -p "$MF_BIN_DIR"
      if curl -fsSL --retry 3 -o "$MF_BIN_DIR/yt-dlp" \
          "https://github.com/yt-dlp/yt-dlp/releases/latest/download/$ytdlp_asset" \
          && chmod +x "$MF_BIN_DIR/yt-dlp"; then
        ok "yt-dlp installed: $("$MF_BIN_DIR/yt-dlp" --version 2>/dev/null)"
        cfg_file="$SCRIPT_DIR/musicfeed/mf_config.sh"
        if [[ -f "$cfg_file" ]] && ! grep -q '^MF_YTDLP_CHANNEL=' "$cfg_file"; then
          echo 'MF_YTDLP_CHANNEL="stable"' >> "$cfg_file"
        fi
        info "To upgrade or switch to the nightly channel (faster YouTube anti-scrape fixes): run ${C_BOLD}bash mf_setup.sh${C_RESET} → yt-dlp step"
      else
        err "yt-dlp download failed — check network or set MF_YTDLP manually"
        return 1
      fi
    else
      warn "Skipped yt-dlp download (start.sh will fall back to system yt-dlp, if available)"
    fi
  fi
  # ── Already-installed deps: keep system / isolate into project / upgrade ──
  # 项目内安装与系统工具互不交叉（musicfeed/bin 与 tools/bin，删目录即卸载）；
  # start.sh 会把这两个目录放在 PATH 最前，项目内版本自动优先于系统。
  title "Installed Tools — Keep / Project-local / Upgrade"
  warn "System-installed tools can stay untouched, be isolated into the project, or be upgraded."

  if [[ "$(command -v ffmpeg 2>/dev/null)" == "$MF_BIN_DIR/"* ]]; then
    ok "ffmpeg: already project-local (${DEP_FFMPEG_VER%% *})"
  elif [[ $DEP_FFMPEG_INSTALLED -eq 1 ]]; then
    case "$(ask_choice "  ffmpeg ${DEP_FFMPEG_VER%% *}: keep system version, install project-local, or upgrade?" "Keep current (system)" "Keep current (system)" "Install project-local (static build)" "Upgrade system (sudo apt)")" in
      "Install project-local (static build)")
        run_install "ffmpeg (project)" "$DEP_FFMPEG_VER" "Download static ffmpeg → $MF_BIN_DIR" \
          "download_static_ffmpeg" "y" ;;
      "Upgrade system (sudo apt)")
        run_install "ffmpeg" "$DEP_FFMPEG_VER" "Upgrade" \
          "sudo apt update && sudo apt install --only-upgrade -y ffmpeg" "y" ;;
    esac
  fi

  if [[ "$(command -v jq 2>/dev/null)" == "$MF_BIN_DIR/"* ]]; then
    ok "jq: already project-local (${DEP_JQ_VER%% *})"
  elif [[ $DEP_JQ_INSTALLED -eq 1 ]]; then
    case "$(ask_choice "  jq ${DEP_JQ_VER%% *}: keep system version, install project-local, or upgrade?" "Keep current (system)" "Keep current (system)" "Install project-local (static single file)" "Upgrade system (sudo apt)")" in
      "Install project-local (static single file)")
        run_install "jq (project)" "$DEP_JQ_VER" "Download static jq → $MF_BIN_DIR" \
          "download_static_jq" "y" ;;
      "Upgrade system (sudo apt)")
        run_install "jq" "$DEP_JQ_VER" "Upgrade" \
          "sudo apt update && sudo apt install -y jq" "y" ;;
    esac
  fi

  if [[ "$(command -v node 2>/dev/null)" == "$SCRIPT_DIR/tools/"* ]]; then
    ok "node: already project-local (${DEP_NODE_VER%% *})"
  elif [[ $DEP_NODE_OK -eq 1 ]]; then
    case "$(ask_choice "  node ${DEP_NODE_VER%% *}: keep system version, install project-local, or upgrade?" "Keep current (system)" "Keep current (system)" "Install project-local (official binary, no sudo)" "Upgrade system (NodeSource, sudo)")" in
      "Install project-local (official binary, no sudo)")
        run_install "node (project)" "$DEP_NODE_VER" "Download Node.js LTS → $SCRIPT_DIR/tools/" \
          "install_project_node" "y" ;;
      "Upgrade system (NodeSource, sudo)")
        run_install "node 22" "$DEP_NODE_VER" "Install Node.js 22 (NodeSource)" \
          "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs" "y" ;;
    esac
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 4: Project File Status Detection
# ─────────────────────────────────────────────────────────────────────────────

check_file() {
  local desc="$1" path="$2" required="${3:-true}"
  if [[ -e "$path" ]]; then
    printf "  %-40s ${C_GREEN}✓ Exists${C_RESET}\n" "$desc"
    return 0
  else
    if [[ "$required" == "true" ]]; then
      printf "  %-40s ${C_RED}✗ Missing${C_RESET}\n" "$desc"
    else
      printf "  %-40s ${C_YELLOW}⚠ Not yet generated${C_RESET}\n" "$desc"
    fi
    return 1
  fi
}

print_project_files() {
  title "Project File Status"
  check_file "Main project node_modules/"       "$SCRIPT_DIR/node_modules"          true
  check_file "Mini-service node_modules/"       "$SCRIPT_DIR/mini-services/job-runner/node_modules" true
  check_file "Environment config .env"          "$SCRIPT_DIR/.env"                  false
  check_file "Music config mf_config.sh"        "$SCRIPT_DIR/musicfeed/mf_config.sh" false
  check_file "Database db/custom.db"            "$SCRIPT_DIR/db/custom.db"          false
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 5: Project Operations (no side effects: npm install / db:push)
# ─────────────────────────────────────────────────────────────────────────────

run_safe_steps() {
  title "Project Dependencies & Database"

  local do_main_deps=false do_mini_deps=false do_db_push=false

  # ── Initialize .env if missing ──
  if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
    warn ".env file not found, initializing from template..."
    if [[ -f "$SCRIPT_DIR/.env.example" ]]; then
      cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
      ok ".env file created from template"
    else
      # Fallback: create minimal .env
      # NOTE: SQLite relative paths resolve against prisma/ (schema.prisma dir),
      # so "../db/custom.db" = <project root>/db/custom.db
      cat > "$SCRIPT_DIR/.env" <<'ENVFILE'
DATABASE_URL="file:../db/custom.db"
ENVFILE
      ok ".env file created with default DATABASE_URL"
    fi
  else
    ok ".env file exists"
  fi

  if [[ -d "$SCRIPT_DIR/node_modules" ]]; then
    ok "Main project dependencies installed"
    if ask_yn "  Reinstall main project dependencies? (will override current versions)" "n"; then
      do_main_deps=true
    fi
  else
    warn "Main project dependencies not installed"
    if ask_yn "  Run npm install now?" "y"; then
      do_main_deps=true
    fi
  fi

  if [[ -d "$SCRIPT_DIR/mini-services/job-runner/node_modules" ]]; then
    ok "Mini-service dependencies installed"
    if ask_yn "  Reinstall mini-service dependencies?" "n"; then
      do_mini_deps=true
    fi
  else
    warn "Mini-service dependencies not installed"
    if ask_yn "  Run npm install (mini-services/job-runner) now?" "y"; then
      do_mini_deps=true
    fi
  fi

  if [[ -f "$SCRIPT_DIR/db/custom.db" ]]; then
    ok "Database exists"
    if ask_yn "  Regenerate schema? (will clear existing Job records)" "n"; then
      do_db_push=true
    fi
  else
    warn "Database not initialized"
    if ask_yn "  Run npm run db:push now?" "y"; then
      do_db_push=true
    fi
  fi

  if $do_main_deps; then
    echo ""
    info "Executing: npm install (main project)"
    if npm install; then
      ok "Main project dependencies installed"
    else
      err "Main project dependency install failed"
      return 1
    fi
  fi

  if $do_mini_deps; then
    echo ""
    # macOS < 12: esbuild binaries shipped with tsx 4.x are built for macOS 12+
    # (they need Security.framework _SecTrustCopyCertificateChain) and fail to
    # load with dyld errors. Pin tsx 3.14.0 there; Linux and macOS 12+ keep the
    # stock dependency set untouched.
    if [[ "$(uname -s)" == "Darwin" ]] && [[ "$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)" -lt 12 ]]; then
      info "macOS < 12 detected: installing job-runner deps with tsx pinned to 3.14.0"
      info "(esbuild in tsx 4.x requires macOS 12+; package.json is adapted locally)"
      if (cd mini-services/job-runner && npm install -D tsx@3.14.0); then
        ok "Mini-service dependencies installed (tsx 3.14.0 for macOS compatibility)"
      else
        err "Mini-service dependency install failed"
        return 1
      fi
    else
      info "Executing: npm install (mini-services/job-runner)"
      if (cd mini-services/job-runner && npm install); then
        ok "Mini-service dependencies installed"
      else
        err "Mini-service dependency install failed"
        return 1
      fi
    fi
  fi

  if $do_db_push; then
    echo ""
    info "Executing: npm run db:push"
    if npm run db:push; then
      ok "Database schema pushed successfully"
    else
      err "Database push failed"
      return 1
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 6: mf_setup.sh Prompt
# ─────────────────────────────────────────────────────────────────────────────

check_musicfeed_config() {
  if [[ ! -f "$SCRIPT_DIR/musicfeed/mf_config.sh" ]]; then
    title "Music Feed Configuration"
    warn "mf_setup.sh has not been run yet (music directory config not generated)"
    echo ""
    echo "  Next, mf_setup.sh will interactively ask for:"
    echo "    - Language (Chinese/English)"
    echo "    - Music root directory (e.g., \$HOME/navidrome/music)"
    echo "    - Default artist folder"
    echo "    - Audio format (Opus/M4A)"
    echo "    - Hidden folders list"
    echo ""
    if ask_yn "  Run mf_setup.sh now?" "y"; then
      bash musicfeed/mf_setup.sh
    else
      warn "Skipped. You can run it anytime: bash musicfeed/mf_setup.sh"
    fi
  else
    title "Music Feed Configuration"
    ok "mf_config.sh exists"
    echo ""
    echo "  Current configuration:"
    while IFS='=' read -r key value; do
      [[ -z "$key" || "$key" =~ ^# ]] && continue
      value="${value%\"}"; value="${value#\"}"
      printf "    %-25s %s\n" "$key" "$value"
    done < "$SCRIPT_DIR/musicfeed/mf_config.sh"
    echo ""
    if ask_yn "  Re-run mf_setup.sh to modify configuration?" "n"; then
      bash musicfeed/mf_setup.sh
    fi
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Phase 7: Summary
# ─────────────────────────────────────────────────────────────────────────────

print_summary() {
  title "Next Steps"

  # hostname -I is Linux-only; macOS uses ipconfig getifaddr
  local ip_hint="hostname -I | awk '{print \$1}'"
  if [[ "$(uname -s)" == "Darwin" ]]; then
    ip_hint="ipconfig getifaddr en0"
  fi

  cat <<EOF
  When everything is ready, start the services:

    ${C_BOLD}bash start.sh --prod${C_RESET}  # Recommended: production mode (standalone build)
                                #   Works from LAN and remote devices (phone, other PCs).
                                #   First run builds automatically, then starts instantly.
    ${C_BOLD}bash start.sh${C_RESET}         # Development mode: only works on THIS machine
                                #   (localhost). Other devices on the LAN will see a
                                #   broken page — use --prod if you need LAN/remote access.
    ${C_BOLD}bash stop.sh${C_RESET}          # Stop all services

  After starting (production mode), access via browser:

    ${C_BOLD}http://localhost:3010${C_RESET}           (on this machine)
    ${C_BOLD}http://<your-machine-ip>:3010${C_RESET}   (from other devices on the LAN)
                              # Find the IP with: ${ip_hint}

  Note: if other devices still cannot connect, make sure port 3010 is allowed
  through your firewall (e.g. sudo ufw allow 3010).

  After updating the code (git pull), do NOT rely on the old build:

    ${C_BOLD}bash start.sh --prod${C_RESET}  will detect the stale build and offer to rebuild
    (or rebuild manually first: ${C_BOLD}npm install && npm run build${C_RESET})

  View real-time logs:

    tail -f logs/next.log logs/job-runner.log

EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Main Flow
# ─────────────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo "${C_BOLD}${C_CYAN}╔════════════════════════════════════════════════════════╗${C_RESET}"
  echo "${C_BOLD}${C_CYAN}║   mfui - Initial Setup & Environment Detection          ║${C_RESET}"
  echo "${C_BOLD}${C_CYAN}╚════════════════════════════════════════════════════════╝${C_RESET}"

  # Phase 1: System Information
  print_system_info

  # Phase 2: Dependency Detection
  collect_dep_info
  print_dep_table

  # --check mode: show detection only, exit
  if [[ "${1:-}" == "--check" ]]; then
    echo ""
    info "--check mode: detection only, no prompts/install"
    print_project_files
    print_summary
    return 0
  fi

  # Phase 3: System Dependency Install/Upgrade
  install_system_deps

  # Phase 4: Project File Detection
  print_project_files

  # Phase 5: Project Operations
  run_safe_steps

  # Phase 6: Music Feed Config Setup
  check_musicfeed_config

  # Phase 7: Summary
  print_summary
}

main "$@"
