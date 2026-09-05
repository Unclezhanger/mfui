#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# stop.sh - mfui one-click stop script
#
# Gracefully stops 2 background services:
#   1. Next.js frontend   (port ${MF_PORT_NEXT:-3010})
#   2. WebSocket service  (port ${MF_PORT_JOB:-3001}, 127.0.0.1 only)
#
# Stop strategy:
#   1. Read logs/pids/*.pid for process IDs
#   2. SIGTERM graceful stop (5s timeout)
#   3. SIGKILL if still alive
#   4. Clean up pid files
#   5. Fall back to port-based lookup when pid file is missing
#
# Usage:
#   bash stop.sh           # Stop all services
#   bash stop.sh --quiet   # Quiet mode (no banner, for start.sh -f)
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_DIR="$SCRIPT_DIR/logs/pids"

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

is_pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Stop a single service
stop_service() {
  local name="$1" pidfile="$2" port="$3"
  local pid=$(cat "$pidfile" 2>/dev/null || echo "")

  if [[ -z "$pid" ]]; then
    # pid file missing, try port-based lookup
    if command -v ss &>/dev/null; then
      local line=$(ss -tlnp 2>/dev/null | grep ":$port " | head -1)
      if [[ -n "$line" ]]; then
        local port_pid=$(echo "$line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
        if [[ -n "$port_pid" ]]; then
          warn "$name: pid file missing, but port $port is held by PID $port_pid"
          if ask_kill "$name" "$port_pid"; then
            do_kill "$port_pid" "$name"
          fi
        else
          ok "$name: not running"
        fi
      else
        ok "$name: not running"
      fi
    else
      ok "$name: not running"
    fi
    return 0
  fi

  if ! is_pid_alive "$pid"; then
    ok "$name: already stopped (cleaning stale pid file)"
    rm -f "$pidfile"
    return 0
  fi

  # SIGTERM first (kill entire process group since start.sh uses setsid)
  info "$name (PID $pid): sending SIGTERM to process group ..."
  # Negative PID kills the process group (PGID = PID, because setsid)
  kill -TERM -$pid 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true

  # Wait up to 5 seconds
  local i
  for i in 1 2 3 4 5; do
    sleep 1
    if ! is_pid_alive "$pid"; then
      ok "$name: stopped"
      rm -f "$pidfile"
      return 0
    fi
    printf "  waiting %ds...\r" "$((5 - i))"
  done

  # Still alive — SIGKILL (process group)
  warn "$name: no response after 5s, sending SIGKILL"
  kill -KILL -$pid 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  sleep 1

  if is_pid_alive "$pid"; then
    err "$name: cannot stop (PID $pid still alive)"
    return 1
  else
    ok "$name: force-stopped"
    rm -f "$pidfile"
  fi
}

# Ask whether to kill (interactive mode)
ask_kill() {
  local name="$1" pid="$2" ans=""
  if [[ "${QUIET:-false}" == "true" ]]; then
    return 0  # Quiet mode: kill directly
  fi
  # If stdin is not a tty (pipe/redirect), default to not killing to avoid accidental kills
  if [[ ! -t 0 ]]; then
    warn "$name: non-interactive mode, skipping (run bash stop.sh directly to stop)"
    return 1
  fi
  read -rp "  Stop PID $pid? [y/N] " ans
  [[ "${ans}" =~ ^[Yy] ]]
}

do_kill() {
  local pid="$1" name="$2"
  kill -TERM "$pid" 2>/dev/null
  sleep 2
  if is_pid_alive "$pid"; then
    kill -KILL "$pid" 2>/dev/null
    sleep 1
  fi
  ok "$name: stopped (PID $pid)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main flow
# ─────────────────────────────────────────────────────────────────────────────

main() {
  if [[ "${1:-}" != "--quiet" ]]; then
    echo ""
    echo "${C_BOLD}${C_CYAN}╔════════════════════════════════════════════════════════════╗${C_RESET}"
    echo "${C_BOLD}${C_CYAN}║   mfui - Stop Services                                    ║${C_RESET}"
    echo "${C_BOLD}${C_CYAN}╚════════════════════════════════════════════════════════════╝${C_RESET}"
  else
    QUIET=true
  fi

  title "Stopping services"

  # Stop in reverse order: job-runner → next (inner service first)
  # Port fallback: when pid file is missing, look up by env var / default port
  stop_service "Job Runner"  "$PID_DIR/job-runner.pid"   "${MF_PORT_JOB:-3001}"
  stop_service "Next.js"     "$PID_DIR/next.pid"         "${MF_PORT_NEXT:-3010}"

  title "All services stopped"
  echo "  To restart:"
  echo "    ${C_BOLD}bash start.sh --prod${C_RESET}  # Recommended: production mode — required for LAN/remote access"
  echo "    ${C_BOLD}bash start.sh${C_RESET}         # Development mode — this machine (localhost) only"
  echo ""
}

main "$@"
