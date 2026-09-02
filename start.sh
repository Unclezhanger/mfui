#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# start.sh - mfui 一键启动脚本
#
# 启动 2 个后台服务：
#   1. Next.js 前端      (port ${MF_PORT_NEXT:-3010})  日志: logs/next.log
#   2. WebSocket 服务    (port ${MF_PORT_JOB:-3001}, 仅 127.0.0.1)   日志: logs/job-runner.log
#
# 架构：
#   浏览器 → Next.js:3010 → /api/dependencies, /api/config, /api/folders, /api/jobs 等直接处理
#                        → /api/proxy/preview, /api/proxy/jobs, /api/proxy/jobs/:id/cancel 转发到 127.0.0.1:3001
#                        → /socket.io/* 通过 next.config.ts rewrites 转发到 127.0.0.1:3001
#   mini-service:3001 只监听 127.0.0.1（不对外暴露，安全性提升）
#
# 端口配置：
#   通过环境变量 MF_PORT_NEXT / MF_PORT_JOB 自定义。
#   未设置时使用默认值（3010 / 3001）。
#   启动前自动检测端口占用；如果被非本脚本进程占用，自动寻找下一个空闲端口
#   （最多尝试 50 个连续端口）。
#
# 设计原则：
#   1. 启动前检测所有依赖是否就绪（缺失则提示运行 setup.sh）
#   2. 检测端口是否被占用（占用则自动切换空闲端口，绝不擅自 kill）
#   3. 重复运行会先尝试 stop.sh 停止旧实例
#   4. PID 统一存 logs/pids/，方便 stop.sh 管理
#
# 用法：
#   bash start.sh                       # 启动（dev 模式，已运行则提示）
#   bash start.sh --prod                # 生产模式（standalone 产物，无冷编译，
#                                        #   首次自动构建；日常/手机使用推荐）
#   bash start.sh -f                    # 强制重启（先 stop 再 start）
#   bash start.sh --status              # 仅查看运行状态
#   MF_PORT_NEXT=3015 bash start.sh     # 用自定义端口启动
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_DIR="$SCRIPT_DIR/logs"
PID_DIR="$SCRIPT_DIR/logs/pids"
mkdir -p "$LOG_DIR" "$PID_DIR"

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

# ─────────────────────────────────────────────────────────────────────────────
# 端口配置（环境变量 + 默认值）
# ─────────────────────────────────────────────────────────────────────────────

PORT_NEXT="${MF_PORT_NEXT:-3010}"
PORT_JOB="${MF_PORT_JOB:-3001}"

# ─────────────────────────────────────────────────────────────────────────────
# PATH 修复：确保子进程能找到 yt-dlp/ffmpeg/python3/node 等
# setsid bash -c "..." 启动的子进程不会读 ~/.bashrc，PATH 是最小集，
# 可能找不到 /usr/local/bin/node 或项目 venv 里的 yt-dlp。
# 这里显式 export 一个完整 PATH，包含所有常见安装路径。
# ─────────────────────────────────────────────────────────────────────────────

# 项目 Python 虚拟环境（yt-dlp / mutagen 都装在里面，与系统隔离）
# venv 存在时：
#   - .venv/bin 放到 PATH 最前面（yt-dlp、python3+mutagen 都优先用 venv 的）
#   - 显式 export MF_YTDLP 指向 venv 内的 yt-dlp（mf_lib.sh 会读取）
MF_VENV_DIR="$SCRIPT_DIR/.venv"
if [[ -x "$MF_VENV_DIR/bin/yt-dlp" ]]; then
  export MF_YTDLP="$MF_VENV_DIR/bin/yt-dlp"
  info "使用项目 venv 的 yt-dlp: $MF_YTDLP"
fi

# 收集所有可能的 bin 路径，去重后拼成完整 PATH
PATH_DIRS=(
  "$MF_VENV_DIR/bin"             # 项目 Python venv（最高优先级）
  "/usr/local/bin"
  "/usr/bin"
  "/bin"
  "/usr/local/sbin"
  "/usr/sbin"
  "/sbin"
  "$HOME/.local/bin"             # pip --user / pipx 安装的命令
  "$HOME/.npm-global/bin"        # npm -g 安装的命令
  "$HOME/.nvm/versions/current/bin"  # nvm 安装的 node（若做了 symlink）
  "$HOME/.cargo/bin"             # rust cargo 安装的命令
  "$HOME/.venv/bin"              # 用户级 Python venv
)
NEW_PATH=""
for d in "${PATH_DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  case ":$NEW_PATH:" in
    *":$d:"*) ;;  # 已存在，跳过
    *) NEW_PATH="${NEW_PATH:+$NEW_PATH:}$d" ;;
  esac
done
# 把原有 PATH 也合并进来（放后面，优先级低）
for d in $(echo "$PATH" | tr ':' ' '); do
  case ":$NEW_PATH:" in
    *":$d:"*) ;;
    *) NEW_PATH="$NEW_PATH:$d" ;;
  esac
done
export PATH="$NEW_PATH"
info "PATH 已扩展: $PATH"

# ─────────────────────────────────────────────────────────────────────────────
# 依赖检测（启动前 sanity check）
# ─────────────────────────────────────────────────────────────────────────────

check_dependencies() {
  title "启动前依赖检测"
  local missing=()

  command -v node &>/dev/null || missing+=("node (>=20)")
  command -v ffmpeg &>/dev/null || missing+=("ffmpeg")
  command -v python3 &>/dev/null || missing+=("python3")
  command -v curl &>/dev/null || missing+=("curl (封面下载需要)")
  # yt-dlp / mutagen：优先用项目 venv，没有则回退系统安装
  if [[ -n "${MF_YTDLP:-}" ]]; then
    "$MF_YTDLP" --version &>/dev/null || missing+=("venv 内 yt-dlp")
  else
    command -v yt-dlp &>/dev/null || missing+=("yt-dlp (或运行 setup.sh 创建 venv)")
  fi
  if [[ -x "$MF_VENV_DIR/bin/python3" ]]; then
    "$MF_VENV_DIR/bin/python3" -c "import mutagen" 2>/dev/null || missing+=("venv 内 mutagen")
  else
    python3 -c "import mutagen" 2>/dev/null || missing+=("mutagen")
  fi

  if [[ ! -d "$SCRIPT_DIR/node_modules" ]]; then
    missing+=("主项目 node_modules (npm install)")
  fi
  if [[ ! -d "$SCRIPT_DIR/mini-services/job-runner/node_modules" ]]; then
    missing+=("mini-service node_modules")
  fi
  if [[ ! -f "$SCRIPT_DIR/musicfeed/mf_config.sh" ]]; then
    missing+=("musicfeed/mf_config.sh (运行 mf_setup.sh)")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    err "以下依赖缺失，无法启动："
    for m in "${missing[@]}"; do
      echo "    - $m"
    done
    echo ""
    warn "请先运行: ${C_BOLD}bash setup.sh${C_RESET}"
    return 1
  fi
  ok "所有依赖就绪"
}

# ─────────────────────────────────────────────────────────────────────────────
# 端口占用检测
# ─────────────────────────────────────────────────────────────────────────────

# 获取占用端口的进程信息（返回 "PID|CMD" 或空）
#   注意：非 root 用户无法通过 ss -p 看到其他用户进程的信息，所以这里先用
#   ss -tln（无 -p）检测端口是否真的在 LISTEN 状态，再用 ss -tlnp 尝试拿
#   进程信息。拿不到 pid 时返回 "unknown|unknown" 占位，让 caller 知道
#   端口被占但无法获取 owner。
port_owner() {
  local port="$1"
  local pid=""
  local cmd=""
  if command -v ss &>/dev/null; then
    # 检测端口是否在 LISTEN 状态（不需要 root 权限）
    # ss -tln 的 $4 列是 "Local Address:Port"（如 "*:81" 或 "127.0.0.1:3000"）
    # 用 :$port$ 正则锚定避免匹配 :810 / :8100 等
    if ! ss -tln 2>/dev/null | awk -v p=":$port\$" '
      BEGIN { found=0 }
      $4 ~ p { found=1 }
      END { exit (found ? 0 : 1) }
    '; then
      # awk 退出码 1 = 端口未在 LISTEN → 空闲，返回空
      return 0
    fi
    # 端口被占，尝试拿 pid/cmd（拿不到也无所谓）
    local line=$(ss -tlnp 2>/dev/null | grep -E ":$port\s" | head -1)
    if [[ -n "$line" ]]; then
      pid=$(echo "$line" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
      if echo "$line" | grep -qoE 'users:\(\("[^"]+'; then
        cmd=$(echo "$line" | grep -oE 'users:\(\("[^"]+' | sed 's/users:(("//' | head -1)
      fi
    fi
    # 即便拿不到 pid，也返回非空占位让 caller 知道端口被占
    echo "${pid:-unknown}|${cmd:-unknown}"
  elif command -v lsof &>/dev/null; then
    pid=$(lsof -ti :"$port" 2>/dev/null | head -1)
    if [[ -n "$pid" ]]; then
      cmd=$(ps -p "$pid" -o comm= 2>/dev/null)
      echo "${pid}|${cmd}"
    else
      # lsof 拿不到 pid 也可能是权限问题，但端口确实被占
      if lsof -i :"$port" 2>/dev/null | tail -n +2 | grep -q .; then
        echo "unknown|unknown"
      fi
    fi
  fi
}

# 找一个空闲端口，从 $1 开始往后找，最多找 $2 个
#   非 root 用户无法绑定 < 1024 的端口，自动跳过
find_free_port() {
  local start="$1" max_try="${2:-20}"
  local p
  # 非 root 跳过特权端口（0-1023），从 1024 开始
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

# 检查端口是否被占（被自己的服务占用则可继续，被别的进程占用则需处理）
# 返回值：0=空闲，2=自己的旧实例（先停），3=被别的进程占用
check_port() {
  local port="$1" name="$2" expected_pid_file="$3"
  local owner=$(port_owner "$port")

  if [[ -z "$owner" ]]; then
    return 0  # 空闲
  fi

  local owner_pid="${owner%%|*}"
  local owner_cmd="${owner##*|}"

  # 检查是否是自己的旧实例
  if [[ -f "$expected_pid_file" ]]; then
    local my_pid=$(cat "$expected_pid_file" 2>/dev/null)
    if [[ "$owner_pid" == "$my_pid" ]] || kill -0 "$my_pid" 2>/dev/null; then
      warn "$name (port $port) 被本脚本旧实例占用 (PID $owner_pid)，将先停止"
      return 2  # 自己的旧实例
    fi
  fi

  # 被其他进程占用
  err "$name (port $port) 被其他进程占用:"
  echo "    PID:  $owner_pid"
  echo "    CMD:  $owner_cmd"
  return 3
}

# ─────────────────────────────────────────────────────────────────────────────
# 进程管理：启动 / 停止 / 检查存活
# ─────────────────────────────────────────────────────────────────────────────

is_pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# 启动单个服务
#   $1 name   $2 port   $3 pidfile   $4 logfile   $5 cmd   $6 cwd
start_service() {
  local name="$1" port="$2" pidfile="$3" logfile="$4" cmd="$5" cwd="$6"

  # 检查旧实例是否还活着
  if [[ -f "$pidfile" ]]; then
    local old_pid=$(cat "$pidfile" 2>/dev/null)
    if is_pid_alive "$old_pid"; then
      warn "$name 已在运行 (PID $old_pid)，跳过"
      return 0
    else
      rm -f "$pidfile"
    fi
  fi

  # 启动 - 用 setsid 创建新进程组，方便 stop.sh 杀整个进程树
  info "启动 $name (port $port) ..."
  (
    cd "$cwd"
    # setsid 让子进程成为新会话领导，PID = 进程组 PGID
    setsid bash -c "$cmd" >> "$logfile" 2>&1 &
    echo $! > "$pidfile"
  )
  sleep 1

  local new_pid=$(cat "$pidfile" 2>/dev/null)
  if is_pid_alive "$new_pid"; then
    ok "$name 已启动 (PID $new_pid, PGID $new_pid)"
  else
    err "$name 启动失败，查看日志: $logfile"
    return 1
  fi
}

# 解析最终使用的端口（如果默认端口被其他进程占，自动找空闲端口）
#   $1 name   $2 port   $3 pidfile
# 返回值通过 stdout（端口号）；失败返回非 0
#   非 root 用户若试图用 < 1024 端口，自动切到 8080 起（避开 1024 边界）
resolve_port() {
  local name="$1" port="$2" pidfile="$3"

  # 非 root 检查：特权端口（< 1024）直接切到 8080 起
  # 8080 是常用 HTTP 替代端口，比从 1024 乱找更可预测
  if [[ "$(id -u)" -ne 0 ]] && [[ "$port" -lt 1024 ]]; then
    warn "$name: 端口 $port < 1024 需要 root 权限"
    info "非 root 用户，自动切换到 8080 起..."
    local new_port
    new_port=$(find_free_port 8080 50)
    if [[ -z "$new_port" ]]; then
      err "$name: 从 8080 起连续 50 个端口均被占用，启动失败"
      err "请用环境变量指定一个空闲端口：MF_PORT_NEXT=9090 bash start.sh"
      return 1
    fi
    warn "$name: 切换到端口 $new_port"
    echo "$new_port"
    return 0
  fi

  check_port "$port" "$name" "$pidfile"
  local rc=$?
  if [[ $rc -eq 3 ]]; then
    # 被其他进程占用，自动找空闲端口（从当前 port 往后找 50 个）
    warn "$name: 端口 $port 被占，自动寻找空闲端口..."
    local new_port
    new_port=$(find_free_port "$port" 50)
    if [[ -z "$new_port" ]]; then
      err "$name: 从 $port 起连续 50 个端口均被占用，启动失败"
      err "请用环境变量指定端口：MF_PORT_NEXT=9090 bash start.sh"
      return 1
    fi
    warn "$name: 切换到端口 $new_port"
    echo "$new_port"
  else
    # rc=0 (空闲) 或 rc=2 (自己的旧实例，stop.sh 已处理) 都用原端口
    echo "$port"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 生产模式：standalone 产物需要访问源目录的 musicfeed/ db/ .venv/.env，
# 用符号链接桥接（standalone 运行时 cwd 在 .next/standalone）
# ─────────────────────────────────────────────────────────────────────────────
prepare_standalone() {
  local sa="$SCRIPT_DIR/.next/standalone"
  [ -d "$sa" ] || { err "standalone 目录不存在"; return 1; }
  # Next 构建会把 db/ musicfeed/ 当依赖文件复制成快照进 standalone，
  # 导致 API 读到构建时刻的旧数据 —— 先删快照，再换成指向源目录的符号链接
  for name in musicfeed db; do
    rm -rf "$sa/$name"
    ln -sfn "../../$name" "$sa/$name"
  done
  ln -sfn ../../.venv "$sa/.venv"
  ln -sfn ../../.env "$sa/.env"
  ok "standalone 符号链接就绪（musicfeed/db/.venv/.env）"
}

# ─────────────────────────────────────────────────────────────────────────────
# 启动所有服务
# ─────────────────────────────────────────────────────────────────────────────

start_all() {
  title "启动 mfui"

  info "端口配置 (来自环境变量 / 默认值):"
  echo "    Next.js      : $PORT_NEXT  (env MF_PORT_NEXT)"
  echo "    Job Runner   : $PORT_JOB   (env MF_PORT_JOB, 仅 127.0.0.1)"

  # 1. Next.js
  #   dev：直接用 ./node_modules/.bin/next 启动，确保 PATH 一致
  #       （API route 需要能找到 yt-dlp 等）
  #   prod：standalone 产物（node server.js，无冷编译）
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
  #   用项目本地 tsx 直接跑 index.ts（Node 运行时）
  #   监听 127.0.0.1，不对外暴露
  PORT_JOB=$(resolve_port "Job Runner" "$PORT_JOB" "$PID_DIR/job-runner.pid") || return 1
  export MF_PORT_JOB="$PORT_JOB"
  start_service "Job Runner" "$PORT_JOB" \
    "$PID_DIR/job-runner.pid" "$LOG_DIR/job-runner.log" \
    "./node_modules/.bin/tsx index.ts" "$SCRIPT_DIR/mini-services/job-runner" || return 1

  # 等待服务就绪
  title "等待服务就绪"
  sleep 2

  # 验证端口
  local all_ok=true
  for pair in "Next.js:$PORT_NEXT" "Job Runner:$PORT_JOB"; do
    local name="${pair%%:*}" port="${pair##*:}"
    if [[ -n "$(port_owner "$port")" ]]; then
      ok "$name (port $port) 监听中"
    else
      err "$name (port $port) 未监听，可能启动失败"
      all_ok=false
    fi
  done

  if $all_ok; then
    title "✅ 启动成功"
    cat <<EOF

  ${C_BOLD}浏览器访问:${C_RESET}  ${C_GREEN}http://localhost:${PORT_NEXT}${C_RESET}

  ${C_BOLD}实际使用端口:${C_RESET}
    Next.js      : $PORT_NEXT  (浏览器访问这个)
    Job Runner   : $PORT_JOB   (内部 127.0.0.1，不对外暴露)

  ${C_BOLD}架构:${C_RESET}
    浏览器 → Next.js:${PORT_NEXT}
              ├── /api/dependencies, /api/config, /api/folders, /api/jobs 直接处理
              ├── /api/proxy/preview, /api/proxy/jobs 等转发到 127.0.0.1:${PORT_JOB}
              └── /socket.io/* 通过 next.config.ts rewrites 转发到 127.0.0.1:${PORT_JOB}

  ${C_BOLD}实时日志:${C_RESET}
    tail -f logs/next.log
    tail -f logs/job-runner.log

  ${C_BOLD}停止服务:${C_RESET}
    bash stop.sh

  ${C_BOLD}查看状态:${C_RESET}
    bash start.sh --status

EOF
  else
    title "⚠️  部分服务启动失败"
    warn "请查看对应日志文件排查"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 状态查看
# ─────────────────────────────────────────────────────────────────────────────

show_status() {
  title "mfui 运行状态"

  printf "  %-15s %-8s %-10s %-30s\n" "服务" "端口" "状态" "PID"
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
      status="${C_GREEN}运行中${C_RESET}"
    elif [[ -n "$(port_owner "$port")" ]]; then
      local owner=$(port_owner "$port")
      pid="${owner%%|*}"
      status="${C_YELLOW}被其他进程占用${C_RESET}"
    else
      pid="-"
      status="${C_RED}未运行${C_RESET}"
    fi

    printf "  %-15s %-8s %-22s %-10s\n" "$name" "$port" "$(echo -e "$status")" "$pid"
  done

  echo ""
  echo "  日志目录: $LOG_DIR"
  echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo "${C_BOLD}${C_CYAN}╔════════════════════════════════════════════════════════════╗${C_RESET}"
  echo "${C_BOLD}${C_CYAN}║   mfui - 一键启动                                 ║${C_RESET}"
  echo "${C_BOLD}${C_CYAN}╚════════════════════════════════════════════════════════════╝${C_RESET}"

  # --status 模式
  if [[ "${1:-}" == "--status" ]]; then
    show_status
    return 0
  fi

  # --prod 生产模式（Next 走 standalone 构建产物，无冷编译，适合手机/局域网日常使用）
  if [[ "${1:-}" == "--prod" || "${1:-}" == "-p" ]]; then
    MF_MODE=production
    info "生产模式：使用 .next/standalone 构建产物"
    if [[ ! -f "$SCRIPT_DIR/.next/standalone/server.js" ]]; then
      warn "构建产物不存在，先执行构建（npm run build）..."
      (cd "$SCRIPT_DIR" && npm run build) || { err "构建失败"; return 1; }
    fi
  else
    MF_MODE=development
  fi
  export MF_MODE

  # -f 强制重启模式
  if [[ "${1:-}" == "-f" || "${1:-}" == "--force" ]]; then
    info "强制重启模式：先停止旧实例"
    FORCE=true
    if [[ -f "$SCRIPT_DIR/stop.sh" ]]; then
      bash "$SCRIPT_DIR/stop.sh" --quiet || true
      sleep 1
    fi
  fi

  # 依赖检测
  check_dependencies || return 1

  # 启动
  start_all
}

main "$@"
