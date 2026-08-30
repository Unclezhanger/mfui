/**
 * musicfeed job-runner mini-service
 * Port: 默认 3001，可通过 MF_PORT_JOB 环境变量自定义
 * 只监听 127.0.0.1（不对外暴露，安全性提升）
 *
 * 职责：
 *  - 同步 preview 接口（spawn mf_batch.sh preview）
 *  - 异步 download 接口（spawn mf_batch.sh download，emit 实时日志到 socket room）
 *  - 取消任务（kill 子进程）
 *
 * 通过 Next.js 内部代理暴露：
 *   - HTTP REST: 前端请求 /api/proxy/preview 等 → Next.js catch-all 转发到 127.0.0.1:3001
 *   - Socket.io : next.config.ts rewrites 把 /socket.io/* 转发到 127.0.0.1:3001
 * 这样浏览器只需访问 Next.js 一个端口（默认 3010）。
 */

import { createServer, IncomingMessage, ServerResponse } from 'http'
import { Server, Socket } from 'socket.io'
import { spawn, ChildProcess } from 'child_process'
import { PrismaClient } from '@prisma/client'
import crypto from 'crypto'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

/** 生成 jobId — 兼容 mf_batch.sh 的 [A-Za-z0-9_.-]+ 校验 */
function createId(): string {
  return crypto.randomUUID()
}

// 端口：默认 3001，支持 MF_PORT_JOB 环境变量自定义
const PORT = parseInt(process.env.MF_PORT_JOB || '3001', 10)

// 自适应项目根目录（兼容 bun/node，ESM 标准）
const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
// mini-services/job-runner/index.ts → 上两级是项目根
const PROJECT_ROOT = path.resolve(__dirname, '..', '..')
const MF_DIR = path.join(PROJECT_ROOT, 'musicfeed')
const BATCH = path.join(MF_DIR, 'mf_batch.sh')
const LOG_DIR = path.join(MF_DIR, 'log')

// 数据库连接：读主项目的 .env（在 PROJECT_ROOT/.env）
// Prisma client 默认从 cwd 读 .env，但 mini-service 在子目录，需要显式指定
const dotenvPath = path.join(PROJECT_ROOT, '.env')
try {
  const dotenvContent = fs.readFileSync(dotenvPath, 'utf8')
  const dbUrlMatch = dotenvContent.match(/^DATABASE_URL=(['"]?)([^'"\n]+)\1/m)
  if (dbUrlMatch) {
    const rawUrl = dbUrlMatch[2]
    // 把相对路径转成绝对路径（相对于 prisma/schema.prisma 所在目录）
    let dbUrl = rawUrl
    if (dbUrl.startsWith('file:')) {
      const filePath = dbUrl.slice(5)  // 去掉 file: 前缀
      if (!filePath.startsWith('/')) {
        // 相对路径，转成绝对路径（相对于 PROJECT_ROOT/prisma/）
        const absPath = path.resolve(PROJECT_ROOT, 'prisma', filePath)
        dbUrl = `file:${absPath}`
      }
    }
    process.env.DATABASE_URL = dbUrl
    console.log(`[job-runner] DATABASE_URL set to ${dbUrl}`)
  } else {
    console.warn(`[job-runner] DATABASE_URL not found in ${dotenvPath}`)
  }
} catch (e) {
  console.warn(`[job-runner] Failed to read .env: ${e}`)
}

const db = new PrismaClient({
  log: ['error', 'warn'],
})

// job 状态管理
const runningJobs = new Map<string, ChildProcess>()

// ────────────────────────────────────────────────
// 工具：读取请求 body
// ────────────────────────────────────────────────
function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = []
    req.on('data', (c) => chunks.push(c))
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')))
    req.on('error', reject)
  })
}

function sendJson(res: ServerResponse, status: number, data: unknown) {
  const body = JSON.stringify(data)
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type, XTransformPort',
  })
  res.end(body)
}

// ────────────────────────────────────────────────
// 配置读取（mini-service 不依赖主项目的 _lib，自己实现一个轻量版）
// ────────────────────────────────────────────────
const CONFIG_PATH = path.join(MF_DIR, 'mf_config.sh')

/** 子进程 PATH：项目 venv 优先（yt-dlp / python3+mutagen 都在 venv 里） */
function venvPath(): string {
  const venvBin = path.join(PROJECT_ROOT, '.venv', 'bin')
  if (fs.existsSync(venvBin)) {
    return `${venvBin}:${process.env.PATH ?? ''}`
  }
  return process.env.PATH ?? ''
}

function readConfigYtdlp(): string {
  // 优先级：环境变量（start.sh export，指向 venv）> 项目 venv > mf_config.sh > PATH 里的 yt-dlp
  if (process.env.MF_YTDLP && fs.existsSync(process.env.MF_YTDLP)) {
    return process.env.MF_YTDLP
  }
  const venvYtdlp = path.join(PROJECT_ROOT, '.venv', 'bin', 'yt-dlp')
  if (fs.existsSync(venvYtdlp)) return venvYtdlp
  try {
    if (!fs.existsSync(CONFIG_PATH)) return 'yt-dlp'
    const raw = fs.readFileSync(CONFIG_PATH, 'utf8')
    const m = raw.match(/^MF_YTDLP=(?:"([^"]*)"|'([^']*)'|([^\s#]+))/m)
    const cfg = m?.[1] ?? m?.[2] ?? m?.[3] ?? ''
    // mf_config.sh 里的路径可能已失效（比如 v3 时代的系统安装位置）
    if (cfg && !cfg.includes('/') ) return cfg
    if (cfg.startsWith('/') && fs.existsSync(cfg)) return cfg
    return 'yt-dlp'
  } catch {
    return 'yt-dlp'
  }
}

function readConfigLang(): 'zh' | 'en' {
  try {
    if (!fs.existsSync(CONFIG_PATH)) return 'zh'
    const raw = fs.readFileSync(CONFIG_PATH, 'utf8')
    const m = raw.match(/^MF_LANG=(?:"([^"]*)"|'([^']*)'|([^\s#]+))/m)
    const v = m?.[1] ?? m?.[2] ?? m?.[3] ?? 'zh'
    return v === 'en' ? 'en' : 'zh'
  } catch {
    return 'zh'
  }
}

// ────────────────────────────────────────────────
// download 参数
// ────────────────────────────────────────────────
interface DownloadParams {
  url: string
  artistDir: string
  subfolder?: string
  coverMode: 'unified' | 'per-track'
  albumArtist?: string
  tracks: string // "1,3,5-7" | "all"
  format: 'opus' | 'm4a'
  playlistMode?: 'mv' | 'ytm'
  mvStrategy?: 'manual' | 'default'
  /** v4.1: 单 MV 手动元数据（mvTitle 非空 = manual 分支） */
  mvTitle?: string
  mvArtist?: string
  mvAlbum?: string
  /** v4.3: MV 播放列表逐曲元数据 "VID=T=A=AL;..."（非空 = manual 分支） */
  mvMeta?: string
  /** v4.1: 日志文件名（日期时间格式），同一次队列的多个任务共用一个 log 文件 */
  logId?: string
  lang?: 'zh' | 'en'
  title?: string
  artist?: string
  linkType?: string
  trackCount?: number | null
}

// ────────────────────────────────────────────────
// 启动下载任务
// ────────────────────────────────────────────────
async function startDownloadJob(params: DownloadParams): Promise<string> {
  const jobId = createId()
  const lang = params.lang ?? readConfigLang()
  // v4.1: 日志文件名优先用前端传的 logId（队列共用），校验不过退回 jobId
  const logId =
    params.logId && /^[A-Za-z0-9_.-]+$/.test(params.logId) ? params.logId : jobId

  // 1. 写 Prisma Job (status=pending)
  await db.job.create({
    data: {
      id: jobId,
      url: params.url,
      linkType: params.linkType ?? 'unknown',
      title: params.title ?? null,
      artist: params.artist ?? null,
      trackCount: params.trackCount ?? null,
      artistDir: params.artistDir,
      subfolder: params.subfolder ?? null,
      coverMode: params.coverMode,
      albumArtist: params.albumArtist ?? null,
      tracks: params.tracks,
      format: params.format,
      playlistMode: params.playlistMode ?? null,
      mvStrategy: params.mvStrategy ?? null,
      status: 'pending',
      pid: null,
      logFile: `log/mf-${logId}.log`,
      downloadedCount: 0,
      errorMessage: null,
      startedAt: null,
      finishedAt: null,
    },
  })

  // 2. 构造 mf_batch.sh download 命令参数
  const args = [
    BATCH,
    'download',
    '--url', params.url,
    '--artist-dir', params.artistDir,
    '--cover-mode', params.coverMode,
    '--tracks', params.tracks,
    '--format', params.format,
    '--lang', lang,
    '--job-id', logId,
    '--json-output',
  ]
  if (params.subfolder) {
    args.push('--subfolder', params.subfolder)
  }
  if (params.albumArtist) {
    args.push('--album-artist', params.albumArtist)
  }
  if (params.playlistMode) {
    args.push('--playlist-mode', params.playlistMode)
  }
  if (params.mvStrategy) {
    args.push('--mv-strategy', params.mvStrategy)
  }
  // v4.1: 单 MV 手动元数据
  if (params.mvTitle) {
    args.push('--mv-title', params.mvTitle)
  }
  if (params.mvArtist) {
    args.push('--mv-artist', params.mvArtist)
  }
  if (params.mvAlbum) {
    args.push('--mv-album', params.mvAlbum)
  }
  // v4.3: MV 播放列表逐曲元数据
  if (params.mvMeta) {
    args.push('--mv-meta', params.mvMeta)
  }

  // 3. spawn worker（cwd 必须是 musicfeed/ 目录）
  const child = spawn('bash', args, {
    cwd: MF_DIR,
    env: {
      ...process.env,
      // 让 worker 用 venv 里的 yt-dlp / python3(mutagen)
      PATH: venvPath(),
      MF_YTDLP: readConfigYtdlp(),
      MF_LANG: lang,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  runningJobs.set(jobId, child)

  // 4. 更新 status=running, pid
  await db.job.update({
    where: { id: jobId },
    data: { status: 'running', pid: child.pid ?? null, startedAt: new Date() },
  })

  let downloadedCount = 0
  let stdoutBuf = ''
  let stderrBuf = ''

  // 5. pipe stdout 按行解析 JSON
  child.stdout?.on('data', (chunk: Buffer) => {
    stdoutBuf += chunk.toString('utf8')
    const lines = stdoutBuf.split('\n')
    stdoutBuf = lines.pop() ?? '' // 最后一行可能不完整，留在 buffer
    for (const line of lines) {
      if (!line.trim()) continue
      let entry: {
        ts: string
        level: string
        event?: string
        msg: string
      } | null = null
      try {
        const obj = JSON.parse(line)
        if (obj && typeof obj.msg === 'string') {
          entry = {
            ts: typeof obj.ts === 'string' ? obj.ts : new Date().toISOString(),
            level: obj.level ?? 'info',
            event: typeof obj.event === 'string' ? obj.event : undefined,
            msg: obj.msg,
          }
        }
      } catch {
        // 非 JSON 行
      }
      if (!entry) {
        entry = {
          ts: new Date().toISOString(),
          level: 'info',
          msg: line,
        }
      }
      io.to(`job:${jobId}`).emit('log', entry)
      // v3.3: 下载阶段平滑进度（ytdlp_frac 的 msg 是 0-99 整数字符串）
      if (entry.event === 'ytdlp_frac') {
        const pct = parseInt(entry.msg.replace(/[^0-9]/g, ''), 10)
        if (!Number.isNaN(pct)) {
          io.to(`job:${jobId}`).emit('progress', {
            downloadedCount,
            trackCount: params.trackCount ?? null,
            frac: pct / 100,
          })
        }
      }
      if (entry.event === 'track_done') {
        downloadedCount++
        io.to(`job:${jobId}`).emit('progress', {
          downloadedCount,
          trackCount: params.trackCount ?? null,
        })
        // 同步写库：socket 不通时前端轮询 /api/jobs/:id 也能看到进度跳动
        db.job
          .update({ where: { id: jobId }, data: { downloadedCount } })
          .catch(() => {})
      }
    }
  })

  child.stderr?.on('data', (chunk: Buffer) => {
    stderrBuf += chunk.toString('utf8')
    const lines = stderrBuf.split('\n')
    stderrBuf = lines.pop() ?? ''
    for (const line of lines) {
      if (!line.trim()) continue
      io.to(`job:${jobId}`).emit('log', {
        ts: new Date().toISOString(),
        level: 'error',
        msg: line,
      })
    }
  })

  child.on('close', async (code) => {
    runningJobs.delete(jobId)
    const ec = code ?? 0
    // ec=11 = worker 有错误：下载计数 >0 → completed + errorMessage（部分失败，
    // 历史页归入失败清单）；计数 =0 → 全军覆没，直接 failed
    const status: 'completed' | 'failed' =
      ec === 0 || (ec === 11 && downloadedCount > 0) ? 'completed' : 'failed'
    const errMsg =
      ec !== 0
        ? ec === 11
          ? 'Worker finished with errors (partial failure)'
          : `Worker exited with code ${ec}`
        : null
    await db.job.update({
      where: { id: jobId },
      data: {
        status,
        downloadedCount,
        finishedAt: new Date(),
        errorMessage: errMsg,
      },
    })
    if (status === 'completed') {
      io.to(`job:${jobId}`).emit('done', {
        exitCode: ec,
        downloadedCount,
      })
    } else {
      io.to(`job:${jobId}`).emit('error', {
        exitCode: ec,
        downloadedCount,
        message: errMsg ?? 'Worker failed',
      })
    }
  })

  child.on('error', async (err) => {
    runningJobs.delete(jobId)
    await db.job.update({
      where: { id: jobId },
      data: {
        status: 'failed',
        finishedAt: new Date(),
        errorMessage: `Spawn error: ${err.message}`,
      },
    })
    io.to(`job:${jobId}`).emit('error', {
      exitCode: -1,
      message: `Spawn error: ${err.message}`,
    })
  })

  return jobId
}

// ────────────────────────────────────────────────
// 同步 preview
// ────────────────────────────────────────────────
interface PreviewPayload {
  url: string
  lang?: 'zh' | 'en'
}

async function runPreview(
  payload: PreviewPayload,
): Promise<{ status: number; body: unknown }> {
  if (!payload.url || typeof payload.url !== 'string') {
    return { status: 400, body: { ok: false, error: 'url is required' } }
  }
  const lang = payload.lang ?? readConfigLang()
  const args = [BATCH, 'preview', '--url', payload.url, '--lang', lang]
  return new Promise((resolve) => {
    const child = spawn('bash', args, {
      cwd: MF_DIR,
      env: {
        ...process.env,
        PATH: venvPath(),
        MF_YTDLP: readConfigYtdlp(),
        MF_LANG: lang,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    })
    let stdout = ''
    let stderr = ''
    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL')
      } catch {}
      resolve({
        status: 504,
        body: { ok: false, error: 'preview timeout (30s)' },
      })
    }, 30000)

    child.stdout?.on('data', (c: Buffer) => (stdout += c.toString('utf8')))
    child.stderr?.on('data', (c: Buffer) => (stderr += c.toString('utf8')))
    child.on('close', (code) => {
      clearTimeout(timer)
      const out = stdout.trim()
      if (!out) {
        resolve({
          status: 502,
          body: {
            ok: false,
            error: `preview produced no output (code=${code})`,
            stderr: stderr.trim().slice(0, 500),
          },
        })
        return
      }
      // 尝试解析最后一行 JSON（mf_batch.sh preview 输出是单行 JSON）
      const lastLine = out.split('\n').pop() ?? out
      try {
        const obj = JSON.parse(lastLine)
        if (obj && typeof obj.ok === 'boolean') {
          resolve({ status: 200, body: obj })
          return
        }
      } catch {
        // fallthrough
      }
      resolve({
        status: 502,
        body: { ok: false, error: 'invalid preview output', raw: out.slice(0, 500) },
      })
    })
    child.on('error', (err) => {
      clearTimeout(timer)
      resolve({
        status: 502,
        body: { ok: false, error: `spawn error: ${err.message}` },
      })
    })
  })
}

// ────────────────────────────────────────────────
// 取消任务
// ────────────────────────────────────────────────
async function cancelJob(jobId: string): Promise<{ ok: boolean; error?: string }> {
  const child = runningJobs.get(jobId)
  if (!child) {
    return { ok: false, error: 'job not running (or server restarted)' }
  }
  try {
    // 杀整个进程组（mf_batch.sh 可能 spawn 了 worker.sh）
    try {
      process.kill(-child.pid!, 'SIGTERM')
    } catch {
      try {
        child.kill('SIGTERM')
      } catch {}
    }
  } catch (e) {
    return { ok: false, error: `kill failed: ${(e as Error).message}` }
  }
  runningJobs.delete(jobId)
  try {
    await db.job.update({
      where: { id: jobId },
      data: {
        status: 'cancelled',
        finishedAt: new Date(),
      },
    })
  } catch {}
  io.to(`job:${jobId}`).emit('cancelled', { jobId })
  return { ok: true }
}

// ────────────────────────────────────────────────
// HTTP server + socket.io
// ────────────────────────────────────────────────
const httpServer = createServer(async (req, res) => {
  // CORS preflight
  if (req.method === 'OPTIONS') {
    res.writeHead(204, {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type, XTransformPort',
    })
    res.end()
    return
  }

  const url = req.url ?? ''
  const u = new URL(url, `http://localhost:${PORT}`)
  const pathname = u.pathname

  // POST /api/preview
  if (req.method === 'POST' && pathname === '/api/preview') {
    const bodyStr = await readBody(req)
    let payload: PreviewPayload
    try {
      payload = JSON.parse(bodyStr) as PreviewPayload
    } catch {
      sendJson(res, 400, { ok: false, error: 'invalid JSON body' })
      return
    }
    const r = await runPreview(payload)
    sendJson(res, r.status, r.body)
    return
  }

  // POST /api/jobs
  if (req.method === 'POST' && pathname === '/api/jobs') {
    const bodyStr = await readBody(req)
    let params: DownloadParams
    try {
      params = JSON.parse(bodyStr) as DownloadParams
    } catch {
      sendJson(res, 400, { ok: false, error: 'invalid JSON body' })
      return
    }
    if (!params.url || !params.artistDir) {
      sendJson(res, 400, {
        ok: false,
        error: 'url and artistDir are required',
      })
      return
    }
    try {
      const jobId = await startDownloadJob(params)
      sendJson(res, 200, { jobId })
    } catch (e) {
      sendJson(res, 500, {
        ok: false,
        error: `failed to start job: ${(e as Error).message}`,
      })
    }
    return
  }

  // POST /api/jobs/:id/cancel
  const cancelMatch = req.method === 'POST' && pathname.match(/^\/api\/jobs\/([^/]+)\/cancel$/)
  if (cancelMatch) {
    const jobId = cancelMatch[1]
    const r = await cancelJob(jobId)
    sendJson(res, r.ok ? 200 : 404, r)
    return
  }

  // GET / — 健康检查
  if (req.method === 'GET' && (pathname === '/' || pathname === '/health')) {
    sendJson(res, 200, {
      service: 'mfui-job-runner',
      port: PORT,
      runningJobs: Array.from(runningJobs.keys()),
      uptime: process.uptime(),
    })
    return
  }

  sendJson(res, 404, { error: 'not found', path: pathname })
})

const io = new Server(httpServer, {
  // 默认 path=/socket.io，避免和 HTTP REST 路由冲突
  // addTrailingSlash: false 让 engine.io 接受 /socket.io 和 /socket.io/ 两种 URL，
  // 这样 Next.js rewrites（会自动 strip trailing slash）也能正常转发。
  cors: {
    origin: '*',
    methods: ['GET', 'POST'],
  },
  pingTimeout: 60000,
  pingInterval: 25000,
  addTrailingSlash: false,
})

io.on('connection', (socket: Socket) => {
  socket.on('subscribe', (jobId: string) => {
    if (typeof jobId !== 'string' || !jobId) return
    socket.join(`job:${jobId}`)
    // 也回一个 ack 给客户端
    socket.emit('subscribed', { jobId })
  })
  socket.on('unsubscribe', (jobId: string) => {
    if (typeof jobId === 'string') socket.leave(`job:${jobId}`)
  })
  socket.on('disconnect', () => {
    // socket.io 自动清理 rooms
  })
})

httpServer.listen(PORT, '127.0.0.1', () => {
  console.log(`[job-runner] listening on 127.0.0.1:${PORT}`)
  console.log(`[job-runner] mf_batch.sh: ${BATCH}`)
  console.log(`[job-runner] cwd: ${MF_DIR}`)
  console.log(`[job-runner] log dir: ${LOG_DIR}`)
})

// 优雅退出
async function shutdown(sig: string) {
  console.log(`[job-runner] received ${sig}, shutting down...`)
  // kill 所有 running jobs
  for (const [id, child] of runningJobs.entries()) {
    try {
      process.kill(-child.pid!, 'SIGTERM')
    } catch {
      try {
        child.kill('SIGTERM')
      } catch {}
    }
    try {
      await db.job.update({
        where: { id },
        data: { status: 'failed', errorMessage: `server shutdown (${sig})`, finishedAt: new Date() },
      })
    } catch {}
  }
  runningJobs.clear()
  io.close()
  httpServer.close(() => {
    db.$disconnect().finally(() => process.exit(0))
  })
}
process.on('SIGTERM', () => shutdown('SIGTERM'))
process.on('SIGINT', () => shutdown('SIGINT'))
