#!/bin/bash
# ─────────────────────────────────────────────
# mfui 容器 entrypoint
# 职责：
#   1. yt-dlp venv：缺失则创建；MF_YTDLP_AUTOUPDATE=1（默认）时升级 yt-dlp
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
VENV="$APP/.venv"
RUN_UID="${MFUI_UID:-1000}"
RUN_GID="${MFUI_GID:-1000}"

# ── 1. venv（root 执行：写入卷内）─────────────
if [ ! -x "$VENV/bin/yt-dlp" ]; then
    echo "[entrypoint] creating venv + installing yt-dlp/mutagen ..."
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --no-cache-dir yt-dlp mutagen
elif [ "${MF_YTDLP_AUTOUPDATE:-1}" = "1" ]; then
    echo "[entrypoint] auto-updating yt-dlp ..."
    "$VENV/bin/pip" install --no-cache-dir -qU yt-dlp || echo "[entrypoint] update failed, keep current version"
fi
export PATH="$VENV/bin:$PATH"

# ── 2. 配置持久化 ────────────────────────────
mkdir -p /config
if [ -f /config/mf_config.sh ]; then
    echo "[entrypoint] mf_config.sh found on /config volume"
else
    cp "$MF_DIR/mf_config.sh" /config/mf_config.sh
    echo "[entrypoint] seeded /config/mf_config.sh (defaults)"
fi
# $MF_DIR/mf_config.sh 指向 /config：Web UI 保存配置（非 root）写入
# 该符号链接即落在 /config 卷；内核脚本按原路径读取，行为不变。
# standalone 快照目录里还有一份副本（API 的 getProjectRoot 会写到那里），
# 同样符号链接到 /config，保证内核与 API 读写同一份配置。
ln -sf /config/mf_config.sh "$MF_DIR/mf_config.sh"
STANDALONE_MF="$APP/.next/standalone/musicfeed"
if [ -d "$STANDALONE_MF" ]; then
    ln -sf /config/mf_config.sh "$STANDALONE_MF/mf_config.sh"
    chown -R "$RUN_UID:$RUN_GID" "$STANDALONE_MF"
fi

mkdir -p "$APP/db" "$MF_DIR/log"

# ── 3. 运行目录属主修正（服务以 RUN_UID 写入）──
chown -R "$RUN_UID:$RUN_GID" "$APP/db" "$MF_DIR/log" /config

# ── 3.4 prisma 引擎自愈（万一构建期生成错平台）────────────
if [ ! -f "$APP/node_modules/.prisma/client/libquery_engine-debian-openssl-3.0.x.so.node" ]; then
    echo "[entrypoint] prisma engine missing, regenerating ..."
    cd "$APP" && npx prisma generate && cd /
fi

# ── 3.5 建表（root 建库后修正属主，服务以 RUN_UID 读写）────────────
echo "[entrypoint] ensuring database schema ..."
cd "$APP" && npx prisma db push --skip-generate --accept-data-loss >/dev/null 2>&1 \
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
