# ─────────────────────────────────────────────
# mfui — single-container build
# Next.js standalone + job-runner + bash kernel (v4.1, python-free) + ffmpeg + jq
# ─────────────────────────────────────────────

# ── Stage 1: dependencies ────────────────────────────────────────────────
# 国内构建可加速：docker build --build-arg NPM_REGISTRY=https://registry.npmmirror.com --build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn .
# node>=22：内核 yt-dlp（EJS JS 挑战运行时）的最低要求，node 20 会被判 (unsupported)
FROM node:22-bookworm-slim AS deps
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
# 体积优化：build 之后 npm prune --omit=dev，砍掉 eslint/typescript/tailwindcss
# 等纯构建期依赖，运行时用不到。prisma 在 package.json 里属于 dependencies，
# prune 不会动它，entrypoint 里的 `npx prisma generate/db push` 自愈逻辑不受影响。
# 另外用 du -sh 实测验证过：.next/standalone/node_modules 是 Next.js standalone
# 构建自带的运行时依赖精简集（132M，已含 next/@next），根目录 node_modules 里的
# next/@next/@swc/typescript 完全是重复——entrypoint 只会在 $APP 根目录跑
# `npx prisma generate/db push`，不会读这几个包，删掉安全。
RUN cd mini-services/job-runner \
    && npm ci --no-audit --no-fund \
    && rm -rf node_modules/@prisma/client node_modules/.prisma \
    && cd /app \
    && npx prisma generate \
    && npm run build \
    && npm prune --omit=dev --no-audit --no-fund \
    && rm -rf node_modules/next node_modules/@next node_modules/@swc node_modules/typescript

# ── 最小运行时依赖集（nm_min）──
# standalone 自带被追踪依赖、job-runner 有自己的 node_modules；根目录运行期只需要：
#   - prisma CLI（entrypoint db push，node 直调）
#   - @prisma/client + .prisma 引擎（job-runner 向上解析）
#   - socket.io（防未追踪引用，体积小）
# 按 package.json 精确版本全新安装 + 重新 generate，替代 649MB 的全量树
RUN mkdir -p /app/nm_min/prisma \
    && node -e "const fs=require('fs');const p=JSON.parse(fs.readFileSync('/app/package.json','utf8')).dependencies;fs.writeFileSync('/app/nm_min/package.json',JSON.stringify({name:'mfui-runtime',private:true,dependencies:{prisma:p.prisma,'@prisma/client':p['@prisma/client'],'socket.io':p['socket.io']}}))" \
    && cp /app/prisma/schema.prisma /app/nm_min/prisma/ \
    && cd /app/nm_min && npm install --omit=dev --no-audit --no-fund \
    && node node_modules/prisma/build/index.js generate \
    && cd /app && rm -rf node_modules && mv /app/nm_min/node_modules /app/node_modules \
    && rm -rf /app/nm_min && du -sm node_modules
# prepare_standalone 等价操作：删掉构建快照，换成指向源目录的符号链接
# （与 start.sh 保持一致，防止 API 读到构建时刻的旧 db/musicfeed 数据）
RUN cd .next/standalone \
    && rm -rf musicfeed db \
    && ln -sfn ../../musicfeed musicfeed \
    && ln -sfn ../../db db \
    && echo 'DATABASE_URL="file:../db/custom.db"' > .env

# ── Stage 3: runtime ─────────────────────────────────────────────────────
FROM node:22-bookworm-slim AS runtime
# jq：musicfeed v4.1 内核的 JSON 解析/标签引擎全部基于 jq + ffmpeg + 纯 bash，
# 容器内不再有 python3/venv/mutagen（旧 .venv 卷随之移除）。
# 不装 apt ffmpeg：Debian 的 ffmpeg 会拖进 GL/LLVM/ICU/语音合成等 ~400MB 的图形链，
# 内核只用 -c:a copy / ffmetadata / mjpeg 封面 / crop——静态构建完全覆盖。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        jq ca-certificates curl xz-utils tini gosu \
    && rm -rf /var/lib/apt/lists/* /usr/share/doc/* /usr/share/man/* /var/cache/apt/*

# 静态 ffmpeg/ffprobe（johnvansickle 构建，含 libopus/mjpeg/crop 全部所需能力）
RUN case "$(uname -m)" in \
        aarch64|arm64) FF_ASSET="ffmpeg-release-arm64-static" ;; \
        *)             FF_ASSET="ffmpeg-release-amd64-static" ;; \
    esac \
    && curl -fsSL --retry 3 "https://johnvansickle.com/ffmpeg/releases/$FF_ASSET.tar.xz" -o /tmp/ff.tar.xz \
    && tar -xJf /tmp/ff.tar.xz -C /tmp --strip-components=1 --wildcards '*/ffmpeg' '*/ffprobe' \
    && mv /tmp/ffmpeg /usr/local/bin/ffmpeg && mv /tmp/ffprobe /usr/local/bin/ffprobe \
    && rm -f /tmp/ff.tar.xz && chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe \
    && ffmpeg -version | head -1 && ffprobe -version | head -1

WORKDIR /app
ENV NODE_ENV=production \
    PORT=3010 \
    HOSTNAME=0.0.0.0 \
    MF_PORT_JOB=3001 \
    MF_YTDLP_AUTOUPDATE=1 \
    # node sidecar 钉定的 major 线（entrypoint 在镜像 node 落后于该线最新版时下载）。
    # 基础镜像升大版本时同步改这里；用户可在 /config 配置里用 MF_NODE_MAJOR 覆盖。
    MF_NODE_MAJOR=22

# Next standalone（含 static，构建期已复制）+ 运行期依赖（tsx/prisma client/socket.io）
# 体积优化：mini-services 整个目录本身就包含 job-runner/node_modules（builder 阶段
# npm ci 装的），之前又单独多复制了一次同样的内容，是纯重复层，现已去掉。
COPY --from=builder /app/.next/standalone ./.next/standalone
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/mini-services ./mini-services
COPY --from=builder /app/musicfeed ./musicfeed
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/package.json ./package.json

# 删 npm/yarn/corepack：运行期 prisma 用 node 直调（见 entrypoint），无需包管理器
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
           /usr/local/lib/node_modules/yarn /usr/local/bin/npm /usr/local/bin/npx \
           /usr/local/bin/yarn /usr/local/bin/yarnpkg /usr/local/bin/corepack

# .env（DATABASE_URL 相对 prisma/ 解析）与目录占位；entrypoint 会在缺失时兜底
RUN mkdir -p db musicfeed/log \
    && echo 'DATABASE_URL="file:../db/custom.db"' > .env

# mf_config.sh：镜像内置一份默认配置，运行期由 /config 卷持久化（见 entrypoint）
# MF_YTDLP 指向 /config/bin 卷内的独立官方二进制（entrypoint 启动时下载/自更新）
RUN printf 'MF_BASE_DIR="/music"\nMF_DEFAULT_ARTIST_DIR="musicfeed"\nMF_AUDIO_FORMAT="opus"\nMF_LANG="en"\nMF_HIDDEN_DIRS=()\nMF_YTDLP="/config/bin/yt-dlp"\nMF_YTDLP_CHANNEL="stable"\n' > musicfeed/mf_config.sh

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 持久化：数据库 / 日志 / 配置 / yt-dlp venv（防重建丢自动更新）
VOLUME ["/app/db", "/app/musicfeed/log", "/config"]

EXPOSE 3010
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
    CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3010)+'/api/runtime').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
