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

# Get command version (fault-tolerant)
get_version() {
  local cmd="$1" ver_cmd="$2"
  if command -v "$cmd" &>/dev/null; then
    eval "$ver_cmd" 2>/dev/null | head -1 | tr -d '\n' || echo "(installed)"
  else
    echo ""
  fi
}

# Check Python module
check_python_module() {
  local mod="$1"
  python3 -c "import ${mod}" 2>/dev/null && echo "1" || echo "0"
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

# Global variables: store detection results for later install functions
DEP_BASH_VER="" DEP_YTDLP_VER="" DEP_FFMPEG_VER=""
DEP_PYTHON_VER="" DEP_NODE_VER="" DEP_MUTAGEN_VER=""
DEP_VENV_YTDLP_VER="" DEP_VENV_MUTAGEN_VER=""
DEP_BASH_INSTALLED=0 DEP_YTDLP_INSTALLED=0 DEP_FFMPEG_INSTALLED=0
DEP_PYTHON_INSTALLED=0 DEP_NODE_INSTALLED=0 DEP_MUTAGEN_INSTALLED=0
DEP_CURL_INSTALLED=0

MF_VENV_DIR="$SCRIPT_DIR/.venv"

detect_dependencies() {
  title "Dependency Detection (Current State)"

  # Required commands
  DEP_BASH_VER=$(get_version bash "bash --version")
  DEP_FFMPEG_VER=$(get_version ffmpeg "ffmpeg -version")
  DEP_PYTHON_VER=$(get_version python3 "python3 --version")
  DEP_NODE_VER=$(get_version node "node --version")

  command -v bash &>/dev/null && DEP_BASH_INSTALLED=1
  command -v ffmpeg &>/dev/null && DEP_FFMPEG_INSTALLED=1
  command -v python3 &>/dev/null && DEP_PYTHON_INSTALLED=1
  command -v node &>/dev/null && DEP_NODE_INSTALLED=1
  command -v curl &>/dev/null && DEP_CURL_INSTALLED=1

  # node version check (Next.js 16 requires >= 20)
  DEP_NODE_OK=0
  if [[ $DEP_NODE_INSTALLED -eq 1 ]]; then
    local major
    major=$(node --version 2>/dev/null | sed 's/v\([0-9]*\).*/\1/')
    [[ "$major" =~ ^[0-9]+$ ]] && [[ "$major" -ge 20 ]] && DEP_NODE_OK=1
  fi

  # yt-dlp: check project venv first
  if [[ -x "$MF_VENV_DIR/bin/yt-dlp" ]]; then
    DEP_VENV_YTDLP_VER=$("$MF_VENV_DIR/bin/yt-dlp" --version 2>/dev/null)
  fi
  command -v yt-dlp &>/dev/null && DEP_YTDLP_INSTALLED=1
  DEP_YTDLP_VER=$(get_version yt-dlp "yt-dlp --version")

  # mutagen: check project venv first
  if [[ -x "$MF_VENV_DIR/bin/python3" ]]; then
    if "$MF_VENV_DIR/bin/python3" -c "import mutagen" &>/dev/null; then
      DEP_VENV_MUTAGEN_VER=$("$MF_VENV_DIR/bin/python3" -c "import mutagen; print(mutagen.version_string)" 2>/dev/null)
    fi
  fi
  if [[ $(check_python_module mutagen) == "1" ]]; then
    DEP_MUTAGEN_INSTALLED=1
    DEP_MUTAGEN_VER=$(python3 -c "import mutagen; print(mutagen.version_string)" 2>/dev/null)
  fi

  # Print table (version truncated to reasonable length to maintain alignment)
  echo ""
  printf "  ${C_BOLD}%-12s %-26s %-12s %-8s${C_RESET}\n" "Dependency" "Current Version" "Status" "Required"
  printf "  %-12s %-26s %-12s %-8s\n" "----------" "------------------------" "----------" "------"

  print_dep_row "bash"    "$DEP_BASH_VER"    $DEP_BASH_INSTALLED    true
  print_dep_row "node>=20" "$DEP_NODE_VER"   $DEP_NODE_OK           true
  print_dep_row "ffmpeg"  "$DEP_FFMPEG_VER"  $DEP_FFMPEG_INSTALLED  true
  print_dep_row "python3" "$DEP_PYTHON_VER" $DEP_PYTHON_INSTALLED true
  print_dep_row "curl"    ""                 $DEP_CURL_INSTALLED    true
  # python3-venv: project venv exists → ok; otherwise check if system can create venv (ensurepip available)
  if [[ -x "$MF_VENV_DIR/bin/pip" ]]; then
    print_dep_row "venv(python)" "Project .venv created" 1 true
  elif python3 -c "import ensurepip" &>/dev/null; then
    print_dep_row "venv(python)" "Available (ensurepip)" 1 true
  else
    print_dep_row "venv(python)" "Missing python3-venv" 0 true
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
      status="✓ Installed"; color="$C_GREEN"
    else
      status="✓ Installed"; color="$C_CYAN"
    fi
  else
    if [[ "$required" == "true" ]]; then
      status="✗ Missing"; color="$C_RED"
    else
      status="⚠ Missing"; color="$C_YELLOW"
    fi
  fi
  local req_str; [[ "$required" == "true" ]] && req_str="Required" || req_str="Optional"
  # Truncate version to 24 characters
  local short_ver="${ver:-(empty)}"
  if [[ ${#short_ver} -gt 24 ]]; then
    short_ver="${short_ver:0:23}…"
  fi
  printf "  %-12s %-26s ${color}%-12s${C_RESET} %-8s\n" \
    "$name" "$short_ver" "$status" "$req_str"
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
    # Multi-line commands shown indented
    echo "$cmd" | sed 's/^/      /'
    if ask_yn "    Confirm execution?" "$default_yn"; then
      info "Executing..."
      # Use eval to run multi-line commands
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
  if [[ $DEP_FFMPEG_INSTALLED -eq 0 ]]; then
    run_install "ffmpeg" "$DEP_FFMPEG_VER" "Install ffmpeg" \
      "sudo apt update && sudo apt install -y ffmpeg" "y"
  fi

  if [[ $DEP_CURL_INSTALLED -eq 0 ]]; then
    run_install "curl" "" "Install curl (for album art download)" \
      "sudo apt update && sudo apt install -y curl" "y"
  fi

  if [[ $DEP_PYTHON_INSTALLED -eq 0 ]]; then
    run_install "python3" "$DEP_PYTHON_VER" "Install python3 + venv" \
      "sudo apt update && sudo apt install -y python3 python3-venv" "y"
  fi

  # ── node: required, >= 20 (apt version usually too old, use NodeSource) ──
  if [[ $DEP_NODE_OK -ne 1 ]]; then
    echo ""
    echo "  ${C_BOLD}[node]${C_RESET} — Requires Node.js >= 20 (current: ${DEP_NODE_VER:-not installed})"
    echo "    Mint/Ubuntu apt repos typically have old nodejs versions. Recommend NodeSource 22.x"
    echo "    (Installing for other projects is fine: node is just a runtime, each project has its own node_modules)"
    if ask_yn "    Install Node.js 22 via NodeSource?" "y"; then
      run_install "node 22" "$DEP_NODE_VER" "Install Node.js 22 (NodeSource)" \
        "curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs" "y"
    else
      warn "Skipped node install (you can install >= 20 separately with nvm/n, then re-run setup.sh)"
    fi
  fi

  # ── Project Python venv (isolated yt-dlp / mutagen install, no sudo, no system pollution) ──
  echo ""
  echo "  ${C_BOLD}[Python venv]${C_RESET} — Isolated environment for yt-dlp / mutagen"
  echo "    Location: $MF_VENV_DIR (project-local, delete to fully uninstall)"
  echo "    venv:     yt-dlp ${DEP_VENV_YTDLP_VER:-not installed}, mutagen ${DEP_VENV_MUTAGEN_VER:-not installed}"
  if ask_yn "    Create/update venv and install yt-dlp + mutagen?" "y"; then
    echo ""
    info "Creating venv (reuse if exists)..."
    if python3 -m venv "$MF_VENV_DIR"; then
      ok "venv ready"
    else
      err "venv creation failed (missing python3-venv? try: sudo apt install python3-venv)"
      return 1
    fi
    info "Installing yt-dlp + mutagen to venv..."
    if "$MF_VENV_DIR/bin/pip" install --upgrade pip yt-dlp mutagen; then
      ok "yt-dlp $($MF_VENV_DIR/bin/yt-dlp --version 2>/dev/null) + mutagen installed in venv"
    else
      err "venv install failed, check network and re-run setup.sh"
      return 1
    fi

    # yt-dlp nightly option (prevent YouTube anti-scrape)
    echo ""
    echo "    Note: YouTube frequently updates anti-scrape mechanisms. yt-dlp nightly updates more frequently and better avoids 403 errors."
    if ask_yn "    Use yt-dlp nightly instead? (recommended if you encounter 403)" "n"; then
      info "Installing nightly in venv..."
      if "$MF_VENV_DIR/bin/pip" install --upgrade "yt-dlp @ https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/latest/download/yt-dlp.tar.gz"; then
        ok "nightly installed in venv: $($MF_VENV_DIR/bin/yt-dlp --version 2>/dev/null)"
      else
        warn "nightly install failed, continuing with stable version"
      fi
    fi
  else
    warn "Skipped venv (start.sh will fall back to system yt-dlp, if available)"
  fi

  # ── Already installed tools: prompt for upgrade (default N, avoid breaking other projects) ──
  title "Installed Tools Upgrade Check"
  warn "The following tools are already installed. Upgrading may affect other projects—decide carefully."

  if [[ $DEP_FFMPEG_INSTALLED -eq 1 ]]; then
    if ask_yn "  Upgrade ffmpeg? (current: ${DEP_FFMPEG_VER})" "n"; then
      run_install "ffmpeg" "$DEP_FFMPEG_VER" "Upgrade" \
        "sudo apt update && sudo apt install --only-upgrade -y ffmpeg" "y"
    fi
  fi

  if [[ $DEP_PYTHON_INSTALLED -eq 1 ]]; then
    if ask_yn "  Upgrade python3? (current: ${DEP_PYTHON_VER})" "n"; then
      run_install "python3" "$DEP_PYTHON_VER" "Upgrade" \
        "sudo apt update && sudo apt install --only-upgrade -y python3" "y"
    fi
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
      cat > "$SCRIPT_DIR/.env" <<'ENVFILE'
DATABASE_URL="file:./db/custom.db"
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
    info "Executing: npm install (mini-services/job-runner)"
    if (cd mini-services/job-runner && npm install); then
      ok "Mini-service dependencies installed"
    else
      err "Mini-service dependency install failed"
      return 1
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

# ──────────────────────────────────────────────────────────���──────────────────
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

  cat <<EOF
  When everything is ready, start the services:

    ${C_BOLD}bash start.sh${C_RESET}     # Start all services (runs 2 services in background)
    ${C_BOLD}bash stop.sh${C_RESET}      # Stop all services

  After starting, access via browser:

    ${C_BOLD}http://localhost:3010${C_RESET}

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
  detect_dependencies

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
