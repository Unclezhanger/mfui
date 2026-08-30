# musicfeed job-runner mini-service

独立 bun 服务，负责长任务（download）和同步 preview，并把 worker 的实时 JSON 日志推送给前端。

## 端口

- **3001**，只监听 `127.0.0.1`（不对外暴露，安全性提升）

## 路由

| Method | Path | 说明 |
|--------|------|------|
| POST   | `/api/preview` | body `{ url, lang? }` → `LinkPreview` |
| POST   | `/api/jobs`    | body `DownloadParams` → `{ jobId }` |
| POST   | `/api/jobs/:id/cancel` | 取消任务，杀子进程 |
| GET    | `/` 或 `/health` | 健康检查 |

> 自 v0.1.0 起不再用 Caddy 转发。前端通过 Next.js 内部代理：
>   - HTTP REST: `fetch('/api/proxy/preview', ...)` → Next.js catch-all → 127.0.0.1:3001
>   - Socket.io : next.config.ts rewrites `/socket.io/*` → 127.0.0.1:3001

## WebSocket

```ts
import { io } from 'socket.io-client'
// 用相对路径，Next.js rewrites 会转发到 127.0.0.1:3001
const sock = io({ path: '/socket.io', transports: ['websocket','polling'] })
sock.emit('subscribe', jobId)
sock.on('log', (entry) => { ... })       // LogEntry
sock.on('progress', (p) => { ... })      // { downloadedCount, trackCount? }
sock.on('done', (p) => { ... })          // { exitCode, downloadedCount }
sock.on('error', (p) => { ... })         // { exitCode, message? }
sock.on('cancelled', (p) => { ... })     // { jobId }
```

## 启动

```bash
cd mini-services/job-runner
bun install
bunx prisma generate --schema=../../prisma/schema.prisma
bun run dev
```

热重载由 `bun --hot` 提供。

## 依赖

- `socket.io` — WebSocket 服务
- `@prisma/client` — 写 Job 表
- `cuid` — 生成 jobId

## 安全性

mini-service 只监听 `127.0.0.1:3001`，外部网络无法直接访问。
所有请求都经过 Next.js 内部代理（`/api/proxy/*` 或 `/socket.io/*` rewrites）转发，
浏览器只需访问 Next.js 一个端口（默认 3010）。
