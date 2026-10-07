#!/bin/bash
# ─────────────────────────────────────────────
# mfui 容器 entrypoint
# 职责：
#   1. yt-dlp 独立官方二进制：缺失则下载到 /config/bin 卷；频道（stable/nightly）
#      由 MF_YTDLP_CHANNEL 配置选择；AUTOUPDATE=1（默认）时每次启动对比最新版本，
#      有更新才下载（v4.1 内核无 python，venv/mutagen 已移除）
#   2. mf_config.sh：/config 卷有持久化副本则还原；否则把镜像默认配置写入
#      /config（首次启动落盘，之后配置改动随卷持久化）；
#      $MF_DIR/mf_config.sh 变为指向 /config 的符号链接（非 root 可写）
#   3. 目录属主修正到运行用户（MFUI_UID/MFUI_GID，默认 1000:1000）
#   4. 以非 root 用户（gosu 降权）启动 job-runner + Next standalone，
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
fetch_ytdlp() {
    curl -fsSL --retry 3 -o "$1" \
        "https://github.com/$YTDLP_REPO/releases/latest/download/$YTDLP_ASSET" && chmod +x "$1"
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
