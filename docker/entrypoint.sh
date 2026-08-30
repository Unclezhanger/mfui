#!/bin/bash
# ─────────────────────────────────────────────
# mfui 容器 entrypoint
# 职责：
#   1. yt-dlp venv：缺失则创建；MF_YTDLP_AUTOUPDATE=1（默认）时升级 yt-dlp
#   2. mf_config.sh：/config 卷有持久化副本则还原；否则把镜像默认配置写入
#      /config（首次启动落盘，之后配置改动随卷持久化）
#   3. 启动 job-runner（后台）+ Next standalone（前台），SIGTERM 全组退出
# ─────────────────────────────────────────────
set -e

APP=/app
MF_DIR="$APP/musicfeed"
VENV="$APP/.venv"

# ── 1. venv ──────────────────────────────────
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
    cp /config/mf_config.sh "$MF_DIR/mf_config.sh"
    echo "[entrypoint] restored mf_config.sh from /config volume"
else
    cp "$MF_DIR/mf_config.sh" /config/mf_config.sh
    echo "[entrypoint] seeded /config/mf_config.sh (defaults)"
fi

mkdir -p "$APP/db" "$MF_DIR/log"

# ── 2.4 prisma 引擎自愈（万一构建期生成错平台）────────────
if [ ! -f "$APP/node_modules/.prisma/client/libquery_engine-debian-openssl-3.0.x.so.node" ]; then
    echo "[entrypoint] prisma engine missing, regenerating ..."
    cd "$APP" && npx prisma generate && cd /
fi

# ── 2.5 建表（全新数据库时创建 Job 等表；已有数据时为无操作同步）────────────
echo "[entrypoint] ensuring database schema ..."
cd "$APP" && npx prisma db push --skip-generate --accept-data-loss >/dev/null 2>&1 \
    || echo "[entrypoint] WARN: db push failed (continuing; db may already be initialized)"
cd /

# ── 2.5 配置回写同步（Web UI 保存配置后写的是 $MF_DIR/mf_config.sh，定期拷回 /config）──
(
    while true; do
        sleep 30
        if ! cmp -s "$MF_DIR/mf_config.sh" /config/mf_config.sh 2>/dev/null; then
            cp "$MF_DIR/mf_config.sh" /config/mf_config.sh
            echo "[entrypoint] config changed, synced to /config"
        fi
    done
) &
PIDS+=($!)

# ── 3. 启动服务 ──────────────────────────────
PIDS=()
shutdown() {
    echo "[entrypoint] SIGTERM, shutting down ..."
    kill "${PIDS[@]}" 2>/dev/null
    wait 2>/dev/null
    exit 0
}
trap shutdown SIGTERM SIGINT

echo "[entrypoint] starting job-runner (port ${MF_PORT_JOB:-3001}) ..."
cd "$APP/mini-services/job-runner"
./node_modules/.bin/tsx index.ts &
PIDS+=($!)

echo "[entrypoint] starting Next.js standalone (port ${PORT:-3010}) ..."
cd "$APP/.next/standalone"
node server.js &
PIDS+=($!)

wait -n "${PIDS[@]}"
# 任一进程退出即整体退出（容器由重启策略拉起）
shutdown
