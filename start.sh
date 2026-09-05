#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# start.sh - mfui One-click Start Script
#
# Starts 2 background services:
#   1. Next.js frontend   (port ${MF_PORT_NEXT:-3010})  log: logs/next.log
#   2. WebSocket service  (port ${MF_PORT_JOB:-3001}, 127.0.0.1 only)   log: logs/job-runner.log
#
# Architecture:
#   Browser → Next.js:3010 → /api/dependencies, /api/config, /api/folders, /api/jobs etc. handled directly
#                        → /api/proxy/preview, /api/proxy/jobs, /api/proxy/jobs/:id/cancel forwarded to 127.0.0.1:3001
#                        → /socket.io/* forwarded to 127.0.0.1:3001 via next.config.ts rewrites
#   mini-service:3001 only listens on 127.0.0.1 (not exposed externally, improved security)
#
# Port configuration:
#   Customizable via environment variables MF_PORT_NEXT / MF_PORT_JOB.
#   Defaults (3010 / 3001) are used when not set.
#   Port occupancy is checked before startup; if occupied by a non-script process,
#   the next free port is automatically found (up to 50 consecutive ports).
#
# Design principles:
#   1. Check all dependencies before startup (prompt to run setup.sh if missing)
#   2. Check port occupancy (auto-switch to a free port if occupied, never kill arbitrarily)
#   3. Re-running will first attempt stop.sh to stop old instances
#   4. PIDs are stored in logs/pids/ for easy management by stop.sh
#
# Usage:
#   bash start.sh                       # Start (dev mode, prompt if already running)
#   bash start.sh --prod                # Production mode (standalone build, no cold compilation,
#                                        #   auto-builds on first run; recommended for daily/mobile use)
#   bash start.sh -f                    # Force restart (stop then start)
#   bash start.sh --status              # Show running status only
#   MF_PORT_NEXT=3015 bash start.sh     # Start with custom port
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="$SCRIPT_DIR/logs"
PID_DIR="$SCRIPT_DIR/logs/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

# Colors
if [[ -t 1 ]] && command -v tput &>/dev/null; then
  C_RED=$(tput setaf 1); C_GREEN=$(tput setaf 2); C_YELLOW=$(tput setaf 3)
  C_BLUE=$(tput setaf 4); C_CYAN=$(tput setaf 6); C_BOLD=$(tput bold)
  C_RESET=$(tput sgr0)
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

ok()    { echo "${C_GREEN}✓${C_RESET} $1"; }
warn()  { echo "${C_YELLOW}⚠${C_RESET} $1"; }
err()   { echo "${C_RED}✗${C_RESET} $1"; }
info()  { echo "${C_CYAN}ℹ${C_RESET} $1"; }
title() { echo ""; echo "${C_BOLD}${C_BLUE}══ $1 ══${C_RESET}"; }

# ─────────────────────────────────────────────────────────────────────────────
# Port configuration (environment variables + defaults)
# ─────────────────────────────────────────────────────────────────────────────

PORT_NEXT="${MF_PORT_NEXT:-3010}"
PORT_JOB="${MF_PORT_JOB:-3001}"

# ─────────────────────────────────────────────────────────────────────────────
# PATH fix: ensure child processes can find yt-dlp/ffmpeg/python3/node etc.
# Child processes started via setsid bash -c "..." won't read ~/.bashrc,
# so PATH is minimal and may not find /usr/local/bin/node or
# yt-dlp in the project venv.
# Here we explicitly export a complete PATH with all common install paths.
# ─────────────────────────────────────────────────────────────────────────────

# Project Python virtual environment (yt-dlp / mutagen are installed here, isolated from system)
# When venv exists:
#   - .venv/bin is placed at the front of PATH (yt-dlp, python3+mutagen from venv take priority)
#   - explicitly export MF_YTDLP pointing to yt-dlp inside venv (mf_lib.sh reads this)
MF_VENV_DIR="$SCRIPT_DIR/.venv"
if [[ -x "$MF_VENV_DIR/bin/yt-dlp" ]]; then
  export MF_YTDLP="$MF_VENV_DIR/bin/yt-dlp"
  info "Using project venv yt-dlp: $MF_YTDLP"
fi

# Collect all possible bin paths, deduplicate and assemble a complete PATH
PATH_DIRS=(
  "$MF_VENV_DIR/bin"             # Project Python venv (highest priority)
  "/usr/local/bin"
  "/usr/bin"
  "/bin"
  "/usr/local/sbin"
  "/usr/sbin"
  "/sbin"
  "$HOME/.local/bin"             # pip --user / pipx installed commands
  "$HOME/.npm-global/bin"        # npm -g installed commands
  "$HOME/.nvm/versions/current/bin"  # node installed via nvm (if symlinked)
  "$HOME/.cargo/bin"             # rust cargo installed commands
  "$HOME/.venv/bin"              # User-level Python venv
)
NEW_PATH=""
for d in "${PATH_DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  case ":$NEW_PATH:" in
    *":$d:"*) ;;  # already exists, skip
    *) NEW_PATH="${NEW_PATH:+$NEW_PATH:}$d" ;;
  esac
done
# Merge the original PATH as well (appended, lower priority)
for d in $(echo "$PATH" | tr ':' ' '); do
  case ":$NEW_PATH:" in
    *":$d:"*) ;;
    *) NEW_PATH="$NEW_PATH:$d" ;;
  esac
done
export PATH="$NEW_PATH"
info "PATH expanded: $PATH"

# ─────────────────────────────────────────────────────────────────────────────
# Dependency check (pre-startup sanity check)
# ─────────────────────────────────────────────────────────────────────────────

check_dependencies() {
  title "Pre-startup dependency check"
  local missing=()

  command -v node &>/dev/null || missing+=("node (>=20)")
  command -v ffmpeg &>/dev/null || missing+=("ffmpeg")
  command -v python3 &>/dev/null || missing+=("python3")
  command -v curl &>/dev/null || missing+=("curl (needed for cover art download)")
  # yt-dlp / mutagen: prefer project venv, fall back to system install
  if [[ -n "${MF_YTDLP:-}" ]]; then
    "$MF_YTDLP" --version &>/dev/null || missing+=("yt-dlp in venv")
  else
    command -v yt-dlp &>/dev/null || missing+=("yt-dlp (or run setup.sh to create venv)")
  fi
  if [[ -x "$MF_VENV_DIR/bin/python3" ]]; then
    "$MF_VENV_DIR/bin/python3" -c "import mutagen" 2>/dev/null || missing+=("mutagen in venv")
  else
    python3 -c "import mutagen" 2>/dev/null || missing+=("mutagen")
  fi

  if [[ ! -d "$SCRIPT_DIR/node_modules" ]]; then
    missing+=("main project node_modules (npm install)")
  fi
  if [[ ! -d "$SCRIPT_DIR/mini-services/job-runner/node_modules" ]]; then
    missing+=("mini-service node_modules")
  fi
  if [[ ! -f "$SCRIPT_DIR/musicfeed/mf_config.sh" ]]; then
    missing+=("musicfeed/mf_config.sh (run mf_setup.sh)")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "The following dependencies are missing, cannot start:"
    for m in "${missing[@]}"; do
      echo "    - $m"
    done
    echo ""
    warn "Please run first: ${C_BOLD}bash setup.sh${C_RESET}"
    return 1
  fi
  ok "All dependencies ready"
}

# ─────────────────────────────────────────────────────────────────────────────
# Port occupancy detection
# ─────────────────────────────────────────────────────────────────────────────

# Get process info occupying a port (returns "PID|CMD" or empty)
#   Note: non-root users cannot see other users' process info via ss -p,
#   so we first use ss -tln (without -p) to check if the port is actually
#   in LISTEN state, then use ss -tlnp to try to get process info.
#   When pid cannot be obtained, returns "unknown|unknown" as a placeholder
#   to let the caller know the port is occupied but owner is unavailable.
port_owner() {
  local port="$1"
  local pid=""
  local cmd=""
  if command -v ss &>/dev/null; then
    # Check if port is in LISTEN state (no root required)
    # Column $4 of ss -tln is "Local Address:Port" (e.g. "*:81" or "127.0.0.1:3000")
    # Use :$port$ regex anchor to avoid matching :810 / :8100 etc.
    if ! ss -tln 2>/dev/null | awk -v p=":$port\$" '
      BEGIN { found=0 }
      $4 ~ p { found=1 }
      END { exit (found ? 0 : 1) }
    '; then
      # awk exit code 1 = port not in LISTEN → free, return empty
      return 0
    fi
    # Port occupied, try to get pid/cmd (ok if unavailable)
    local line=$(ss -tlnp 2>/dev/null | grep -E ":$port\s" | head -1)
    if [[ -n "$line" ]]; then
      pid=$(echo "$line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
      if echo "$line" | grep -qoE 'users:\(\("[^"]+'; then
        cmd=$(echo "$line" | grep -oE 'users:\(\("[^"]+' | sed 's/users:(("//' | head -1)
      fi
    fi
    # Even if pid is unavailable, return non-empty placeholder to let caller know port is occupied
    echo "${pid:-unknown}|${cmd:-unknown}"
  elif command -v lsof &>/dev/null; then
    pid=$(lsof -ti :"$port" 2>/dev/null | head -1)
    if [[ -n "$pid" ]]; then
      cmd=$(ps -p "$pid" -o comm= 2>/dev/null)
      echo "${pid}|${cmd}"
    else
      # lsof not finding pid may be a permissions issue, but port is indeed occupied
      if lsof -i :"$port" 2>/dev/null | tail -n +2 | grep -q .; then
        echo "unknown|unknown"
      fi
    fi
  fi
}

# Find a free port, starting from $1, searching up to $2 ports
#   Non-root users cannot bind ports < 1024, auto-skip
find_free_port() {
  local start="$1" max_try="${2:-20}"
  local p
  # Non-root: skip privileged ports (0-1023), start from 1024
  if [[ "$(id -u)" -ne 0 ]] && [[ "$start" -lt 1024 ]]; then
    start=1024
  fi
  for ((p=start; p<start+max_try; p++)); do
    if [[ -z "$(port_owner "$p")" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# Check if port is occupied (if occupied by own service, can continue;
# if occupied by another process, needs handling)
# Return: 0=free, 2=own old instance (stop first), 3=occupied by another process
check_port() {
  local port="$1" name="$2" expected_pid_file="$3"
  local owner=$(port_owner "$port")

  if [[ -z "$owner" ]]; then
    return 0  # free
  fi

  local owner_pid="${owner%%|*}"
  local owner_cmd="${owner##*|}"

  # Check if it's our own old instance
  if [[ -f "$expected_pid_file" ]]; then
    local my_pid=$(cat "$expected_pid_file" 2>/dev/null)
    if [[ "$owner_pid" == "$my_pid" ]] || kill -0 "$my_pid" 2>/dev/null; then
      warn "$name (port $port) occupied by this script's old instance (PID $owner_pid), will stop first"
      return 2  # own old instance
    fi
  fi

  # Occupied by another process
  err "$name (port $port) occupied by another process:"
  echo "    PID:  $owner_pid"
  echo "    CMD:  $owner_cmd"
  return 3
}

# ─────────────────────────────────────────────────────────────────────────────
# Process management: start / stop / check alive
# ─────────────────────────────────────────────────────────────────────────────

is_pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Start a single service
#   $1 name   $2 port   $3 pidfile   $4 logfile   $5 cmd   $6 cwd
start_service() {
  local name="$1" port="$2" pidfile="$3" logfile="$4" cmd="$5" cwd="$6"

  # Check if old instance is still alive
  if [[ -f "$pidfile" ]]; then
    local old_pid=$(cat "$pidfile" 2>/dev/null)
    if is_pid_alive "$old_pid"; then
      warn "$name already running (PID $old_pid), skipping"
      return 0
    else
      rm -f "$pidfile"
    fi
  fi

  # Start - use setsid to create a new process group, so stop.sh can kill the entire process tree
  info "Starting $name (port $port) ..."
  (
    cd "$cwd"
    # setsid makes the child process a new session leader, PID = process group PGID
    setsid bash -c "$cmd" >> "$logfile" 2>&1 &
    echo $! > "$pidfile"
  )
  sleep 1

  local new_pid=$(cat "$pidfile" 2>/dev/null)
  if is_pid_alive "$new_pid"; then
    ok "$name started (PID $new_pid, PGID $new_pid)"
  else
    err "$name failed to start, check log: $logfile"
    return 1
  fi
}

# Resolve the final port to use (if default port is occupied by another process,
# automatically find a free port)
#   $1 name   $2 port   $3 pidfile
# Returns port number via stdout; non-zero on failure
#   Non-root users trying to use ports < 1024 auto-switch to 8080 onwards (avoid 1024 boundary)
resolve_port() {
  local name="$1" port="$2" pidfile="$3"

  # Non-root check: privileged ports (< 1024) switch directly to 8080 onwards
  # 8080 is a common HTTP alternative port, more predictable than searching from 1024
  if [[ "$(id -u)" -ne 0 ]] && [[ "$port" -lt 1024 ]]; then
    warn "$name: port $port < 1024 requires root privileges"
    info "Non-root user, auto-switching to 8080 onwards..."
    local new_port
    new_port=$(find_free_port 8080 50)
    if [[ -z "$new_port" ]]; then
      err "$name: 50 consecutive ports from 8080 are all occupied, startup failed"
      err "Please specify a free port via environment variable: MF_PORT_NEXT=9090 bash start.sh"
      return 1
    fi
    warn "$name: switching to port $new_port"
    echo "$new_port"
    return 0
  fi

  check_port "$port" "$name" "$pidfile"
  local rc=$?
  if [[ $rc -eq 3 ]]; then
    # Occupied by another process, auto-find free port (search 50 consecutive ports from current port)
    warn "$name: port $port occupied, auto-searching for a free port..."
    local new_port
    new_port=$(find_free_port "$port" 50)
    if [[ -z "$new_port" ]]; then
      err "$name: 50 consecutive ports from $port are all occupied, startup failed"
      err "Please specify a port via environment variable: MF_PORT_NEXT=9090 bash start.sh"
      return 1
    fi
    warn "$name: switching to port $new_port"
    echo "$new_port"
  else
    # rc=0 (free) or rc=2 (own old instance, stop.sh already handled) → use original port
    echo "$port"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Production mode: standalone build needs to access source directory's musicfeed/ db/ .venv/.env,
# using symlinks to bridge (standalone runs with cwd in .next/standalone)
# ─────────────────────────────────────────────────────────────────────────────
prepare_standalone() {
  local sa="$SCRIPT_DIR/.next/standalone"
  [ -d "$sa" ] || { err "standalone directory does not exist"; return 1; }
  # Next build copies db/ musicfeed/ as dependency snapshots into standalone,
  # causing API to read stale data from build time — delete snapshots first,
  # then replace with symlinks pointing to the source directory
  for name in musicfeed db; do
    rm -rf "$sa/$name"
    ln -sfn "../../$name" "$sa/$name"
  done
  ln -sfn ../../.venv "$sa/.venv"
  ln -sfn ../../.env "$sa/.env"
  ok "standalone symlinks ready (musicfeed/db/.venv/.env)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Start all services
# ─────────────────────────────────────────────────────────────────────────────

start_all() {
  title "Starting mfui"

  info "Port configuration (from environment variables / defaults):"
  echo "    Next.js      : $PORT_NEXT  (env MF_PORT_NEXT)"
  echo "    Job Runner   : $PORT_JOB   (env MF_PORT_JOB, 127.0.0.1 only)"

  # 1. Next.js
  #   dev: start directly with ./node_modules/.bin/next to ensure consistent PATH
  #       (API routes need to find yt-dlp etc.)
  #   prod: standalone build (node server.js, no cold compilation)
  PORT_NEXT=$(resolve_port "Next.js" "$PORT_NEXT" "$PID_DIR/next.pid") || return 1
  export MF_PORT_NEXT="$PORT_NEXT"
  if [[ "$MF_MODE" == "production" ]]; then
    prepare_standalone || return 1
    start_service "Next.js(prod)" "$PORT_NEXT" \
      "$PID_DIR/next.pid" "$LOG_DIR/next.log" \
      "NODE_ENV=production HOSTNAME=0.0.0.0 PORT=$PORT_NEXT node server.js" \
      "$SCRIPT_DIR/.next/standalone" || return 1
  else
    start_service "Next.js" "$PORT_NEXT" \
      "$PID_DIR/next.pid" "$LOG_DIR/next.log" \
      "./node_modules/.bin/next dev -p $PORT_NEXT -H 0.0.0.0" "$SCRIPT_DIR" || return 1
  fi

  # 2. WebSocket mini-service
  #   Use project-local tsx to run index.ts directly (Node runtime)
  #   Listens on 127.0.0.1, not exposed externally
  PORT_JOB=$(resolve_port "Job Runner" "$PORT_JOB" "$PID_DIR/job-runner.pid") || return 1
  export MF_PORT_JOB="$PORT_JOB"
  start_service "Job Runner" "$PORT_JOB" \
    "$PID_DIR/job-runner.pid" "$LOG_DIR/job-runner.log" \
    "./node_modules/.bin/tsx index.ts" "$SCRIPT_DIR/mini-services/job-runner" || return 1

  # Wait for services to be ready
  title "Waiting for services to be ready"
  sleep 2

  # Verify ports
  local all_ok=true
  # Access hint differs by mode: dev binds localhost only, prod binds 0.0.0.0 (LAN/remote OK)
  local access_hint
  if [[ "$MF_MODE" == "production" ]]; then
    access_hint="  ${C_BOLD}LAN / remote access:${C_RESET} http://<this-machine-ip>:${PORT_NEXT}
  (production mode — reachable from other devices; find IP with: hostname -I)"
  else
    access_hint="  ${C_BOLD}Note:${C_RESET} development mode is reachable from THIS machine only.
  For LAN/remote access from other devices, stop and run: ${C_BOLD}bash start.sh --prod${C_RESET}"
  fi
  for pair in "Next.js:$PORT_NEXT" "Job Runner:$PORT_JOB"; do
    local name="${pair%%:*}" port="${pair##*:}"
    if [[ -n "$(port_owner "$port")" ]]; then
      ok "$name (port $port) listening"
    else
      err "$name (port $port) not listening, may have failed to start"
      all_ok=false
    fi
  done

  if $all_ok; then
    title "✅ Startup successful"
    cat <<EOF

  ${C_BOLD}Open in browser:${C_RESET}  ${C_GREEN}http://localhost:${PORT_NEXT}${C_RESET}

${access_hint}

  ${C_BOLD}Ports in use:${C_RESET}
    Next.js      : $PORT_NEXT  (access this in browser)
    Job Runner   : $PORT_JOB   (internal 127.0.0.1, not exposed externally)

  ${C_BOLD}Architecture:${C_RESET}
    Browser → Next.js:${PORT_NEXT}
              ├── /api/dependencies, /api/config, /api/folders, /api/jobs handled directly
              ├── /api/proxy/preview, /api/proxy/jobs etc. forwarded to 127.0.0.1:${PORT_JOB}
              └── /socket.io/* forwarded to 127.0.0.1:${PORT_JOB} via next.config.ts rewrites

  ${C_BOLD}Live logs:${C_RESET}
    tail -f logs/next.log
    tail -f logs/job-runner.log

  ${C_BOLD}Stop services:${C_RESET}
    bash stop.sh

  ${C_BOLD}View status:${C_RESET}
    bash start.sh --status

EOF
  else
    title "⚠️  Some services failed to start"
    warn "Please check the corresponding log files for details"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Status view
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
  title "mfui running status"

  printf "  %-15s %-8s %-10s %-30s\n" "Service" "Port" "Status" "PID"
  printf "  %-15s %-8s %-10s %-30s\n" "------------" "------" "--------" "----------"

  for pair in "Next.js:$PORT_NEXT:$PID_DIR/next.pid" \
              "Job Runner:$PORT_JOB:$PID_DIR/job-runner.pid"; do
    local name="${pair%%:*}"
    local rest="${pair#*:}"
    local port="${rest%%:*}"
    local pidfile="${rest##*:}"
    local pid=$(cat "$pidfile" 2>/dev/null || echo "-")
    local status

    if [[ "$pid" != "-" ]] && is_pid_alive "$pid"; then
      status="${C_GREEN}Running${C_RESET}"
    elif [[ -n "$(port_owner "$port")" ]]; then
      local owner=$(port_owner "$port")
      pid="${owner%%|*}"
      status="${C_YELLOW}Occupied by other process${C_RESET}"
    else
      pid="-"
      status="${C_RED}Not running${C_RESET}"
    fi

    printf "  %-15s %-8s %-22s %-10s\n" "$name" "$port" "$(echo -e "$status")" "$pid"
  done

  echo ""
  echo "  Log directory: $LOG_DIR"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Main flow
# ─────────────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo "${C_BOLD}${C_CYAN}╔════════════════════════════════════════════════════════════╗${C_RESET}"
  echo "${C_BOLD}${C_CYAN}║   mfui - One-click Start                            ║${C_RESET}"
  echo "${C_BOLD}${C_CYAN}╚════════════════════════════════════════════════════════════╝${C_RESET}"

  # --status mode
  if [[ "${1:-}" == "--status" ]]; then
    show_status
    return 0
  fi

  # --prod production mode (Next uses standalone build, no cold compilation, suitable for daily/mobile/LAN use)
  if [[ "${1:-}" == "--prod" || "${1:-}" == "-p" ]]; then
    MF_MODE=production
    info "Production mode: using .next/standalone build"
    if [[ ! -f "$SCRIPT_DIR/.next/standalone/server.js" ]]; then
      warn "Build not found, running build first (npm run build)..."
      (cd "$SCRIPT_DIR" && npm run build) || { err "Build failed"; return 1; }
    fi
  else
    MF_MODE=development
  fi
  export MF_MODE

  # -f force restart mode
  if [[ "${1:-}" == "-f" || "${1:-}" == "--force" ]]; then
    info "Force restart mode: stopping old instances first"
    FORCE=true
    if [[ -f "$SCRIPT_DIR/stop.sh" ]]; then
      bash "$SCRIPT_DIR/stop.sh" --quiet || true
      sleep 1
    fi
  fi

  # Dependency check
  check_dependencies || return 1

  # Start
  start_all
}

main "$@"
