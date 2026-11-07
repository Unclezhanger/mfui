#!/bin/bash
# ─────────────────────────────────────────────
# mfui 容器 entrypoint
# 职责：
#   1. yt-dlp 独立官方二进制：缺失则下载到 /config/bin 卷；频道（stable/nightly）
#      由 MF_YTDLP_CHANNEL 配置选择；AUTOUPDATE=1（默认）时每次启动对比最新版本，
#      有更新才下载（v4.1 内核无 python，venv/mutagen 已移除）
#   2. node sidecar：镜像烤入的 node 落后于 MF_NODE_MAJOR 线最新版时（典型场景：
#      yt-dlp 自更新后抬高 EJS 运行时要求，如 2026.10 要求 node>=22 而镜像还是 20），
#      从 nodejs.org 下载官方二进制到 /config/node 卷，免重烤镜像；
#      校验 SHA256，失败回退镜像自带 node，不阻塞启动；跨 major 不自动跳
#   3. mf_config.sh：/config 卷有持久化副本则还原；否则把镜像默认配置写入
#      /config（首次启动落盘，之后配置改动随卷持久化）；
#      $MF_DIR/mf_config.sh 变为指向 /config 的符号链接（非 root 可写）
#   4. 目录属主修正到运行用户（MFUI_UID/MFUI_GID，默认 1000:1000）
#   5. 以非 root 用户（gosu 降权）启动 job-runner + Next standalone，
#      下载的文件与宿主机用户属主一致；SIGTERM 全组退出
# ─────────────────────────────────────────────
set -e

APP=/app
MF_DIR="$APP/musicfeed"
RUN_UID="${MFUI_UID:-1000}"
RUN_GID="${MFUI_GID:-1000}"

# yt-dlp 独立二进制的路径与架构（频道在配置里选择）
BIN_DIR="/config/bin"
YTDLP_BIN="$BIN_DIR/yt-dlp"
VER_FILE="$YTDLP_BIN.version"
case "$(uname -m)" in
    aarch64|arm64) YTDLP_ASSET="yt-dlp_linux_aarch64" ;;
    *)             YTDLP_ASSET="yt-dlp_linux" ;;
esac

# ── 1. 配置持久化（先于 yt-dlp：频道选择存在配置里）──
mkdir -p /config
if [ -f /config/mf_config.sh ]; then
    echo "[entrypoint] mf_config.sh found on /config volume"
else
    cp "$MF_DIR/mf_config.sh" /config/mf_config.sh
    echo "[entrypoint] seeded /config/mf_config.sh (defaults)"
fi
# 旧版本卷里的配置可能没有 MF_YTDLP（python venv 时代靠 PATH 解析）：
# 缺失时补写指向 /config/bin 的独立二进制，不覆盖用户已设置的值
if ! grep -q '^MF_YTDLP=' /config/mf_config.sh; then
    echo "MF_YTDLP=\"$YTDLP_BIN\"" >> /config/mf_config.sh
    echo "[entrypoint] added MF_YTDLP=$YTDLP_BIN to config (python-free kernel)"
fi
# yt-dlp 更新频道（stable / nightly），旧配置缺省补 stable
if ! grep -q '^MF_YTDLP_CHANNEL=' /config/mf_config.sh; then
    echo 'MF_YTDLP_CHANNEL="stable"' >> /config/mf_config.sh
fi
# node sidecar 自动升级开关，旧配置缺省补 1（默认开）。
# MF_NODE_MAJOR（钉定的 major 线）不写进配置：默认跟镜像 ENV 走，
# 用户想跨大版本时自己在配置里加一行 MF_NODE_MAJOR="24" 即可，避免旧卷被冻结在旧 major。
if ! grep -q '^MF_NODE_AUTOUPDATE=' /config/mf_config.sh; then
    echo 'MF_NODE_AUTOUPDATE="1"' >> /config/mf_config.sh
fi

# ── 2. yt-dlp 独立二进制（root 执行：写入 /config 卷）──
# MF_YTDLP_CHANNEL=stable|nightly（用户在配置里选择）；AUTOUPDATE=1 时每次启动
# 用 GitHub API 查所选频道的最新版本号，与本地 sidecar 比对，有新版才下载
mkdir -p "$BIN_DIR"
YTDLP_CHANNEL=$(grep '^MF_YTDLP_CHANNEL=' /config/mf_config.sh | sed -E 's/^MF_YTDLP_CHANNEL="?([^"]*)"?.*/\1/')
YTDLP_CHANNEL=${YTDLP_CHANNEL:-stable}
case "$YTDLP_CHANNEL" in
    nightly) YTDLP_REPO="yt-dlp/yt-dlp-nightly-builds" ;;
    *)       YTDLP_REPO="yt-dlp/yt-dlp" ;;
esac
# 下载到 $1.part 临时文件，校验 --version 通过后才原子替换到 $1：
#   - --retry-all-errors：DNS 未就绪/连接被拒等瞬时错误也重试（Docker Desktop 刚启动时常见）
#   - --connect-timeout/--max-time：网络卡住时不会无限阻塞容器启动
#   - 失败时清理临时文件，不会留下半截二进制
fetch_ytdlp() {
    local out="$1.part"
    rm -f "$out"
    if curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
            --connect-timeout 15 --max-time 600 -o "$out" \
            "https://github.com/$YTDLP_REPO/releases/latest/download/$YTDLP_ASSET" \
        && chmod +x "$out" \
        && timeout 60 "$out" --version >/dev/null 2>&1 \
        && mv -f "$out" "$1"; then
        return 0
    fi
    rm -f "$out"
    return 1
}
# 轻量查最新版本号（GitHub API；失败返回空 → 跳过更新）
latest_ytdlp_version() {
    curl -fsSL --max-time 8 "https://api.github.com/repos/$YTDLP_REPO/releases/latest" 2>/dev/null \
        | jq -r '.tag_name // empty' 2>/dev/null
}
installed_ytdlp_version() {
    [ -f "$VER_FILE" ] && cat "$VER_FILE" || echo ""
}
if [ ! -x "$YTDLP_BIN" ]; then
    echo "[entrypoint] downloading standalone yt-dlp ($YTDLP_CHANNEL/$YTDLP_ASSET) ..."
    fetch_ytdlp "$YTDLP_BIN" \
        && latest_ytdlp_version > "$VER_FILE" \
        || echo "[entrypoint] WARN: yt-dlp download failed — set MF_YTDLP in config manually"
elif [ "${MF_YTDLP_AUTOUPDATE:-1}" = "1" ]; then
    LATEST=$(latest_ytdlp_version)
    INSTALLED=$(installed_ytdlp_version)
    if [ -n "$LATEST" ] && [ "$LATEST" != "$INSTALLED" ]; then
        echo "[entrypoint] yt-dlp $YTDLP_CHANNEL update: ${INSTALLED:-none} -> $LATEST ..."
        fetch_ytdlp "$YTDLP_BIN.new" \
            && echo "$LATEST" > "$VER_FILE" && mv -f "$YTDLP_BIN.new" "$YTDLP_BIN" \
            || echo "[entrypoint] update failed, keep current version"
    else
        echo "[entrypoint] yt-dlp $YTDLP_CHANNEL up to date ($INSTALLED)"
    fi
fi
[ -x "$YTDLP_BIN" ] && export PATH="$BIN_DIR:$PATH"

# ── 2.5 node sidecar（root 执行：写入 /config/node 卷）──
# 动机：yt-dlp 经 AUTOUPDATE 自我升级后，可能抬高其 EJS JS 运行时要求
#（2026.10 起 node>=22），而镜像里烤入的 node 是构建时冻结的——重演时无需重烤镜像。
# 语义：
#   - 仅当镜像 node 落后于 MF_NODE_MAJOR 线最新版时才下载 sidecar；镜像重烤后
#     追平即自动清理旧 sidecar，不会永久占着 /config 卷（~120MB）
#   - major 线内自动跟随；跨 major 必须用户显式设置 MF_NODE_MAJOR（node 是应用
#     自身运行时，Next/Prisma 兼容性无法在启动时自动验证，不自动跳）
#   - 下载/校验任何一步失败 → 保留现状继续用镜像 node，只打 WARN 不阻塞启动
NODE_DIR="/config/node"
NODE_BIN="$NODE_DIR/bin/node"
NODE_VER_FILE="$NODE_DIR/version"
# 配置里的 MF_NODE_MAJOR 优先；其次镜像 ENV（基础镜像升大版本时同步改）；最后兜底 22
NODE_MAJOR_CFG=$(grep '^MF_NODE_MAJOR=' /config/mf_config.sh | sed -E 's/^MF_NODE_MAJOR="?([^"]*)"?.*/\1/' || true)
NODE_MAJOR=${NODE_MAJOR_CFG:-${MF_NODE_MAJOR:-22}}
case "$NODE_MAJOR" in ''|*[!0-9]*) NODE_MAJOR=22 ;; esac
NODE_AUTO=$(grep '^MF_NODE_AUTOUPDATE=' /config/mf_config.sh | sed -E 's/^MF_NODE_AUTOUPDATE="?([^"]*)"?.*/\1/' || true)
# ver_ge a b：a >= b（sort -V 语义，调用处保证两边非空）
ver_ge() { [ "$1" = "$(printf '%s\n' "$1" "$2" | sort -V | tail -1)" ]; }
# 查 MF_NODE_MAJOR 线最新版（nodejs.org dist index 按 version 降序，取首个；失败返回空）
latest_node_version() {
    curl -fsSL --connect-timeout 15 --max-time 30 "https://nodejs.org/dist/index.json" 2>/dev/null \
        | jq -r "map(select(.version | startswith(\"v$NODE_MAJOR.\"))) | .[0].version // empty" 2>/dev/null
}
# 下载官方 tar.xz → SHA256 校验（SHASUMS256.txt）→ 只抽出 bin/node，原子落位
fetch_node() {
    local ver="$1" asset tmp
    case "$(uname -m)" in
        aarch64|arm64) asset="linux-arm64" ;;
        *)             asset="linux-x64" ;;
    esac
    tmp="$NODE_DIR/.fetch.$$"
    mkdir -p "$tmp" "$NODE_DIR/bin"
    if ! curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
            --connect-timeout 15 --max-time 600 \
            -o "$tmp/node-v$ver-$asset.tar.xz" \
            "https://nodejs.org/dist/v$ver/node-v$ver-$asset.tar.xz" \
        || ! curl -fsSL --connect-timeout 15 --max-time 60 \
            -o "$tmp/SHASUMS256.txt" \
            "https://nodejs.org/dist/v$ver/SHASUMS256.txt" \
        || ! (cd "$tmp" && grep " node-v$ver-$asset.tar.xz$" SHASUMS256.txt | sha256sum -c -) >/dev/null 2>&1; then
        rm -rf "$tmp"
        return 1
    fi
    if tar -xJf "$tmp/node-v$ver-$asset.tar.xz" -C "$tmp" --strip-components=1 "node-v$ver-$asset/bin/node" \
            && mv -f "$tmp/bin/node" "$NODE_BIN" \
            && echo "$ver" > "$NODE_VER_FILE"; then
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}
NODE_BAKED=$(/usr/local/bin/node --version 2>/dev/null | sed 's/^v//')
if [ "${NODE_AUTO:-1}" != "0" ] && [ -n "$NODE_BAKED" ]; then
    NODE_LATEST=$(latest_node_version | sed 's/^v//')
    if [ -z "$NODE_LATEST" ]; then
        echo "[entrypoint] node update check failed (network?) — keep image node $NODE_BAKED"
    elif ! ver_ge "$NODE_BAKED" "$NODE_LATEST"; then
        SIDE_VER=$(cat "$NODE_VER_FILE" 2>/dev/null || true)
        if [ ! -x "$NODE_BIN" ] || [ "$SIDE_VER" != "$NODE_LATEST" ]; then
            echo "[entrypoint] node sidecar update: ${SIDE_VER:-none} -> $NODE_LATEST (image node: $NODE_BAKED, major line: v$NODE_MAJOR) ..."
            fetch_node "$NODE_LATEST" \
                && echo "[entrypoint] node sidecar ready: v$NODE_LATEST" \
                || echo "[entrypoint] WARN: node sidecar download failed — keep image node $NODE_BAKED"
        else
            echo "[entrypoint] node sidecar up to date ($SIDE_VER; image node: $NODE_BAKED)"
        fi
    elif [ -d "$NODE_DIR" ]; then
        # 镜像 node 已追平 major 线最新（重烤过）→ sidecar 冗余，清理释放卷空间
        rm -rf "$NODE_DIR"
        echo "[entrypoint] image node $NODE_BAKED >= latest v$NODE_MAJOR — stale sidecar removed"
    fi
fi
# 激活：sidecar 存在且严格新于镜像 node 才前置 PATH（相等/更旧都用镜像自带的）
if [ -x "$NODE_BIN" ] && [ -n "$NODE_BAKED" ]; then
    NODE_SIDE=$("$NODE_BIN" --version 2>/dev/null | sed 's/^v//')
    if [ -n "$NODE_SIDE" ] && [ "$NODE_SIDE" != "$NODE_BAKED" ] && ver_ge "$NODE_SIDE" "$NODE_BAKED"; then
        export PATH="$NODE_DIR/bin:$PATH"
        echo "[entrypoint] using sidecar node v$NODE_SIDE (image node: v$NODE_BAKED)"
    fi
fi
# $MF_DIR/mf_config.sh 指向 /config：Web UI 保存配置（非 root）写入
# 该符号链接即落在 /config 卷；内核脚本按原路径读取，行为不变。
# standalone 快照目录（API 的 getProjectRoot 写入路径）经构建期符号链接
# 指向 $MF_DIR，因此对 $MF_DIR 整体 chown 后两条写入路径都在 /config 收敛。
ln -sf /config/mf_config.sh "$MF_DIR/mf_config.sh"
chown -R "$RUN_UID:$RUN_GID" "$MF_DIR"

mkdir -p "$APP/db" "$MF_DIR/log"

# ── 3. 运行目录属主修正（服务以 RUN_UID 写入）──
chown -R "$RUN_UID:$RUN_GID" "$APP/db" "$MF_DIR/log" /config

# prisma CLI 直调（node node_modules/prisma/build/index.js）——容器内已无 npm/npx
PRISMA_CLI="$APP/node_modules/prisma/build/index.js"

# ── 3.4 prisma 引擎自愈（万一构建期生成错平台）────────────
if [ ! -f "$APP/node_modules/.prisma/client/libquery_engine-debian-openssl-3.0.x.so.node" ]; then
    echo "[entrypoint] prisma engine missing, regenerating ..."
    cd "$APP" && node "$PRISMA_CLI" generate && cd /
fi

# ── 3.5 建表（root 建库后修正属主，服务以 RUN_UID 读写）────────────
echo "[entrypoint] ensuring database schema ..."
cd "$APP" && node "$PRISMA_CLI" db push --skip-generate --accept-data-loss >/dev/null 2>&1 \
    || echo "[entrypoint] WARN: db push failed (continuing; db may already be initialized)"
chown -R "$RUN_UID:$RUN_GID" "$APP/db"
cd /

# ── 4. 启动服务（gosu 降权到 RUN_UID）────────
PIDS=()
shutded=0
shutdown() {
    [ "$shutded" = 1 ] && return
    shutded=1
    echo "[entrypoint] SIGTERM, shutting down ..."
    kill "${PIDS[@]}" 2>/dev/null
    wait 2>/dev/null
    exit 0
}
trap shutdown SIGTERM SIGINT

DROP="gosu $RUN_UID:$RUN_GID"

echo "[entrypoint] starting job-runner (port ${MF_PORT_JOB:-3001}) as uid $RUN_UID ..."
cd "$APP/mini-services/job-runner"
$DROP ./node_modules/.bin/tsx index.ts &
PIDS+=($!)

echo "[entrypoint] starting Next.js standalone (port ${PORT:-3010}) as uid $RUN_UID ..."
cd "$APP/.next/standalone"
$DROP node server.js &
PIDS+=($!)

wait -n "${PIDS[@]}"
# 任一进程退出即整体退出（容器由重启策略拉起）
shutdown
