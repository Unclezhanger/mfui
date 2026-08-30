#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# stop.sh - mfui 一键停止脚本
#
# 优雅停止 2 个后台服务：
#   1. Next.js 前端      (port ${MF_PORT_NEXT:-3010})
#   2. WebSocket 服务    (port ${MF_PORT_JOB:-3001}, 仅 127.0.0.1)
#
# 停止策略：
#   1. 读 logs/pids/*.pid 拿到进程号
#   2. 先发 SIGTERM 优雅停止（5s 超时）
#   3. 仍存活则 SIGKILL 强制杀
#   4. 清理 pid 文件
#   5. pid 文件缺失时按端口回退（用环境变量或默认值）
#
# 用法：
#   bash stop.sh           # 停止所有服务
#   bash stop.sh --quiet   # 静默模式（不打印 banner，给 start.sh -f 调用）
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_DIR="$SCRIPT_DIR/logs/pids"

# 颜色
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

# 停止单个服务
stop_service() {
  local name="$1" pidfile="$2" port="$3"
  local pid=$(cat "$pidfile" 2>/dev/null || echo "")

  if [[ -z "$pid" ]]; then
    # pid 文件不存在，尝试按端口找
    if command -v ss &>/dev/null; then
      local line=$(ss -tlnp 2>/dev/null | grep ":$port " | head -1)
      if [[ -n "$line" ]]; then
        local port_pid=$(echo "$line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
        if [[ -n "$port_pid" ]]; then
          warn "$name: pid 文件缺失，但 port $port 被 PID $port_pid 占用"
          if ask_kill "$name" "$port_pid"; then
            do_kill "$port_pid" "$name"
          fi
        else
          ok "$name: 未运行"
        fi
      else
        ok "$name: 未运行"
      fi
    else
      ok "$name: 未运行"
    fi
    return 0
  fi

  if ! is_pid_alive "$pid"; then
    ok "$name: 已停止 (清理旧 pid 文件)"
    rm -f "$pidfile"
    return 0
  fi

  # 先 SIGTERM（杀整个进程组，因为 start.sh 用 setsid 启动）
  info "$name (PID $pid): 发送 SIGTERM 到进程组 ..."
  # 负号表示杀进程组（PGID = PID，因为 setsid）
  kill -TERM -$pid 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true

  # 等 5 秒
  local i
  for i in 1 2 3 4 5; do
    sleep 1
    if ! is_pid_alive "$pid"; then
      ok "$name: 已停止"
      rm -f "$pidfile"
      return 0
    fi
    printf "  等待 %ds...\r" "$((5 - i))"
  done

  # 仍存活，SIGKILL（进程组）
  warn "$name: 5s 未响应，发送 SIGKILL"
  kill -KILL -$pid 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  sleep 1

  if is_pid_alive "$pid"; then
    err "$name: 无法停止 (PID $pid 仍存活)"
    return 1
  else
    ok "$name: 已强制停止"
    rm -f "$pidfile"
  fi
}

# 询问是否 kill（交互模式）
ask_kill() {
  local name="$1" pid="$2" ans=""
  if [[ "${QUIET:-false}" == "true" ]]; then
    return 0  # 静默模式直接 kill
  fi
  # 如果 stdin 不是 tty（管道/重定向输入），默认不 kill，避免误杀
  if [[ ! -t 0 ]]; then
    warn "$name: 非交互模式，跳过（如需停止请直接运行 bash stop.sh）"
    return 1
  fi
  read -rp "  是否停止 PID $pid？[y/N] " ans
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
  ok "$name: 已停止 (PID $pid)"
}

# ─────────────────────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────────────────────

main() {
  if [[ "${1:-}" != "--quiet" ]]; then
    echo ""
    echo "${C_BOLD}${C_CYAN}╔════════════════════════════════════════════════════════════╗${C_RESET}"
    echo "${C_BOLD}${C_CYAN}║   mfui - 停止服务                                 ║${C_RESET}"
    echo "${C_BOLD}${C_CYAN}╚════════════════════════════════════════════════════════════╝${C_RESET}"
  else
    QUIET=true
  fi

  title "停止服务"

  # 反向停止：job-runner → next（先停内层服务）
  # 端口回退：pid 文件缺失时按环境变量 / 默认值查找占用进程
  stop_service "Job Runner"  "$PID_DIR/job-runner.pid"   "${MF_PORT_JOB:-3001}"
  stop_service "Next.js"     "$PID_DIR/next.pid"         "${MF_PORT_NEXT:-3010}"

  title "停止完成"
  echo "  如需重新启动: ${C_BOLD}bash start.sh${C_RESET}"
  echo ""
}

main "$@"
