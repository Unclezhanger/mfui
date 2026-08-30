/**
 * musicfeed - 前端 API 调用封装
 *
 * - 静态资源（dependencies/config/folders/jobs/logs/runtime）走 Next.js API（同源 /api/*）
 * - 长任务（preview/jobs/cancel）走 Next.js 内部代理 /api/proxy/* → mini-service (127.0.0.1:3001)
 *
 * 浏览器只需访问 Next.js 一个端口（默认 3010）。
 * mini-service 只监听 127.0.0.1，不对外暴露，更安全。
 *
 * 端口信息（portNext/portJob）由 GET /api/runtime 动态获取，用于显示。
 */

import type {
  Dependencies,
  Job,
  LinkPreview,
  LogEntry,
  MfConfig,
} from './types'

// ───────────────────────────────────────────
// 运行时端口配置（lazy fetch + cache，仅用于显示）
// ───────────────────────────────────────────

export interface RuntimePorts {
  portNext: number
  portJob: number
}

let runtimeConfig: RuntimePorts | null = null
let runtimePromise: Promise<RuntimePorts> | null = null

/**
 * 获取当前实例的端口配置（仅用于显示，不再影响请求 URL）。
 * 第一次调用会 fetch /api/runtime，后续直接返回缓存。
 * 失败时 fallback 到默认值 (3010/3001)，保证向后兼容。
 */
export async function getRuntime(): Promise<RuntimePorts> {
  if (runtimeConfig) return runtimeConfig
  if (!runtimePromise) {
    runtimePromise = (async () => {
      try {
        const res = await fetch('/api/runtime')
        if (!res.ok) throw new Error(`runtime HTTP ${res.status}`)
        const data = (await res.json()) as Partial<RuntimePorts>
        runtimeConfig = {
          portNext: typeof data.portNext === 'number' ? data.portNext : 3010,
          portJob: typeof data.portJob === 'number' ? data.portJob : 3001,
        }
      } catch (e) {
        console.warn('[getRuntime] failed, fallback to defaults:', e)
        runtimeConfig = {
          portNext: 3010,
          portJob: 3001,
        }
      }
      return runtimeConfig
    })()
  }
  return runtimePromise
}

/**
 * 重置运行时缓存（仅在测试或显式重连时调用）。
 */
export function resetRuntime(): void {
  runtimeConfig = null
  runtimePromise = null
}

// ───────────────────────────────────────────
// Next.js API（同源 /api/*）
// ───────────────────────────────────────────

/**
 * 带超时 + 重试的 fetch（GET 专用）。
 * dev 模式下 API route 首次访问需要现场编译（局域网首开可能 >10s），
 * 或网络瞬时抖动；失败后自动重试，避免首屏数据全空。
 */
async function fetchWithRetry(
  url: string,
  { retries = 3, timeoutMs = 20000 }: { retries?: number; timeoutMs?: number } = {},
): Promise<Response> {
  let lastErr: unknown
  for (let i = 0; i <= retries; i++) {
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), timeoutMs)
    try {
      const res = await fetch(url, { signal: ctrl.signal })
      clearTimeout(timer)
      if (res.ok) return res
      // 5xx 可重试；4xx 是确定性错误，直接抛
      if (res.status < 500) throw new Error(`HTTP ${res.status} @ ${url}`)
      lastErr = new Error(`HTTP ${res.status} @ ${url}`)
    } catch (e) {
      clearTimeout(timer)
      lastErr = e
      if (e instanceof Error && e.message.startsWith('HTTP 4')) throw e
    }
    if (i < retries) await new Promise((r) => setTimeout(r, 1500 * (i + 1)))
  }
  throw lastErr instanceof Error ? lastErr : new Error(`fetch failed @ ${url}`)
}

export async function fetchDependencies(): Promise<Dependencies> {
  const res = await fetchWithRetry('/api/dependencies')
  return (await res.json()) as Dependencies
}

export async function fetchConfig(): Promise<MfConfig> {
  const res = await fetchWithRetry('/api/config')
  return (await res.json()) as MfConfig
}

export async function updateConfig(cfg: MfConfig): Promise<MfConfig> {
  const res = await fetch('/api/config', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(cfg),
  })
  if (!res.ok) throw new Error(`updateConfig: ${res.status}`)
  return (await res.json()) as MfConfig
}

export async function fetchFolders(): Promise<{ exists: boolean; folders: string[] }> {
  const res = await fetchWithRetry('/api/folders')
  if (!res.ok) throw new Error(`fetchFolders: ${res.status}`)
  return (await res.json()) as { exists: boolean; folders: string[] }
}

export async function fetchJobs(): Promise<Job[]> {
  const res = await fetchWithRetry('/api/jobs')
  if (!res.ok) throw new Error(`fetchJobs: ${res.status}`)
  return (await res.json()) as Job[]
}

export async function fetchJob(id: string): Promise<Job> {
  const res = await fetch(`/api/jobs/${encodeURIComponent(id)}`)
  if (!res.ok) throw new Error(`fetchJob: ${res.status}`)
  return (await res.json()) as Job
}

export async function deleteJob(id: string): Promise<void> {
  const res = await fetch(`/api/jobs/${encodeURIComponent(id)}`, {
    method: 'DELETE',
  })
  if (!res.ok) throw new Error(`deleteJob: ${res.status}`)
}

export async function fetchJobLogs(id: string): Promise<LogEntry[]> {
  const res = await fetch(`/api/jobs/${encodeURIComponent(id)}/logs`)
  if (!res.ok) throw new Error(`fetchJobLogs: ${res.status}`)
  return (await res.json()) as LogEntry[]
}

// ───────────────────────────────────────────
// Mini-service (通过 Next.js 代理 /api/proxy/*)
// ───────────────────────────────────────────

export async function previewLink(url: string, lang?: 'zh' | 'en'): Promise<LinkPreview> {
  const res = await fetch('/api/proxy/preview', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ url, lang }),
  })
  if (!res.ok) {
    let msg = `preview HTTP ${res.status}`
    try {
      const body = await res.json()
      if (body?.error) msg = body.error
    } catch {}
    return { ok: false, error: msg }
  }
  return (await res.json()) as LinkPreview
}

export interface CreateJobParams {
  url: string
  artistDir: string
  subfolder?: string
  coverMode: 'unified' | 'per-track'
  albumArtist?: string
  tracks: string
  format: 'opus' | 'm4a'
  playlistMode?: 'mv' | 'ytm'
  mvStrategy?: 'manual' | 'default'
  /** v4.1: 单 MV 手动元数据（mvTitle 非空 = manual 分支） */
  mvTitle?: string
  mvArtist?: string
  mvAlbum?: string
  /** v4.3: MV 播放列表逐曲元数据 "VID=T=A=AL;..."（非空 = manual 分支） */
  mvMeta?: string
  /** v4.1: 日志文件名（日期时间），队列内多任务共用一个 log */
  logId?: string
  lang?: 'zh' | 'en'
  title?: string
  artist?: string
  linkType?: string
  trackCount?: number | null
}

export async function createJob(
  params: CreateJobParams,
): Promise<{ jobId: string }> {
  const res = await fetch('/api/proxy/jobs', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(params),
  })
  if (!res.ok) {
    let msg = `createJob HTTP ${res.status}`
    try {
      const body = await res.json()
      if (body?.error) msg = body.error
    } catch {}
    throw new Error(msg)
  }
  return (await res.json()) as { jobId: string }
}

export async function cancelJob(id: string): Promise<void> {
  await fetch(`/api/proxy/jobs/${encodeURIComponent(id)}/cancel`, {
    method: 'POST',
  })
}
