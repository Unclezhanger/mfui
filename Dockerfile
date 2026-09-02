# ─────────────────────────────────────────────
# mfui — single-container build
# Next.js standalone + job-runner + bash kernel + python venv + ffmpeg
# ─────────────────────────────────────────────

# ── Stage 1: dependencies ────────────────────────────────────────────────
# 国内构建可加速：docker build --build-arg NPM_REGISTRY=https://registry.npmmirror.com --build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn .
FROM node:20-bookworm-slim AS deps
ARG NPM_REGISTRY=https://registry.npmjs.org
# openssl CLI：prisma 用它探测平台版本（slim 镜像缺失时误判为 1.1.x）
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm config set registry "$NPM_REGISTRY" \
    && npm config set fetch-retries 5 \
    && npm config set fetch-retry-mintimeout 20000 \
    && npm config set fetch-retry-maxtimeout 120000 \
    && npm config set fetch-timeout 600000 \
    && npm config set maxsockets 3 \
    && npm ci --no-audit --no-fund

# ── Stage 2: build Next.js standalone ────────────────────────────────────
FROM deps AS builder
COPY . .
# job-runner 有独立 package.json（tsx 等），单独安装；
# 删除其自带 @prisma/client/.prisma，让它向上解析到根目录已 generate 的 client
# （避免双层 prisma 生成引擎版本错乱）
RUN cd mini-services/job-runner \
    && npm ci --no-audit --no-fund \
    && rm -rf node_modules/@prisma/client node_modules/.prisma \
    && cd /app \
    && npx prisma generate \
    && npm run build
# prepare_standalone 等价操作：删掉构建快照，换成指向源目录的符号链接
# （与 start.sh 保持一致，防止 API 读到构建时刻的旧 db/musicfeed 数据）
RUN cd .next/standalone \
    && rm -rf musicfeed db \
    && ln -sfn ../../musicfeed musicfeed \
    && ln -sfn ../../db db \
    && echo 'DATABASE_URL="file:../db/custom.db"' > .env

# ── Stage 3: runtime ─────────────────────────────────────────────────────
FROM node:20-bookworm-slim AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg python3 python3-venv python3-pip ca-certificates curl tini \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV NODE_ENV=production \
    PORT=3010 \
    HOSTNAME=0.0.0.0 \
    MF_PORT_JOB=3001 \
    MF_YTDLP_AUTOUPDATE=1

# Next standalone（含 static，构建期已复制）+ 运行期依赖（tsx/prisma client/socket.io）
COPY --from=builder /app/.next/standalone ./.next/standalone
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/mini-services ./mini-services
COPY --from=builder /app/mini-services/job-runner/node_modules ./mini-services/job-runner/node_modules
COPY --from=builder /app/musicfeed ./musicfeed
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/package.json ./package.json

# .env（DATABASE_URL 相对 prisma/ 解析）与目录占位；entrypoint 会在缺失时兜底
RUN mkdir -p db musicfeed/log \
    && echo 'DATABASE_URL="file:../db/custom.db"' > .env

# mf_config.sh：镜像内置一份默认配置，运行期由 /config 卷持久化（见 entrypoint）
RUN printf 'MF_BASE_DIR="/music"\nMF_DEFAULT_ARTIST_DIR="musicfeed"\nMF_AUDIO_FORMAT="opus"\nMF_LANG="en"\nMF_HIDDEN_DIRS=(attachments "@eaDir" ".DS_Store")\n' > musicfeed/mf_config.sh

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 持久化：数据库 / 日志 / 配置 / yt-dlp venv（防重建丢自动更新）
VOLUME ["/app/db", "/app/musicfeed/log", "/config", "/app/.venv"]

EXPOSE 3010
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3010)+'/api/runtime').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
