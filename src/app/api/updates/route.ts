import { NextResponse } from 'next/server'
import fs from 'fs'
import { execFileSync } from 'child_process'
import { CONFIG_PATH } from '../_lib/config'
import { getProjectRoot } from '@/lib/paths'
import type { UpdateCheck, UpdateRow } from '@/lib/types'

export const dynamic = 'force-dynamic'

/**
 * 更新检查（WebUI 依赖面板"检查更新"按钮的数据源）。
 *
 * 对比三项与上游最新版，让容器用户能主动发现"该重启了"：
 *   - app：本项目 package.json 版本 vs GitHub Releases 最新 tag
 *   - yt-dlp：本地独立二进制（sidecar 版本文件）vs 所选频道的最新 release
 *   - node：运行时 node vs 其 major 线最新版（容器内 entrypoint 的 node sidecar
 *     在重启时会自动补齐差距，见 docker/entrypoint.sh 2.5 节）
 *
 * 所有网络请求 8s 超时、失败置 null（UI 显示"—"），永不阻塞/报错整个接口；
 * 结果缓存 60s，防止连点按钮打爆 GitHub API 匿名限额（60 次/小时/IP）。
 */

const GH_HEADERS = { Accept: 'application/vnd.github+json', 'User-Agent': 'mfui-updates' } as const

/** 点分版本号比较（忽略 v 前缀与后缀），a<b 返回负数 */
function cmpVer(a: string, b: string): number {
  const pa = a.replace(/^v/, '').split(/[.+-]/).map((n) => parseInt(n, 10) || 0)
  const pb = b.replace(/^v/, '').split(/[.+-]/).map((n) => parseInt(n, 10) || 0)
  const len = Math.max(pa.length, pb.length)
  for (let i = 0; i < len; i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0)
    if (d) return d
  }
  return 0
}

/**
 * 回退：github.com releases/latest 的 302 Location 自带版本号，
 * 不消耗 api.github.com 匿名配额（60 次/小时/IP，超额时 API 全 403）
 */
async function ghLatestTagViaRedirect(repo: string): Promise<string | null> {
  try {
    const r = await fetch(`https://github.com/${repo}/releases/latest`, {
      method: 'HEAD',
      redirect: 'manual',
      headers: GH_HEADERS,
      signal: AbortSignal.timeout(8000),
    })
    const loc = r.headers.get('location') ?? ''
    const tag = loc.split('/tag/')[1]?.split(/[?#]/)[0] ?? ''
    return tag ? tag.replace(/^v/, '') : null
  } catch {
    return null
  }
}

async function ghLatestTag(repo: string): Promise<string | null> {
  try {
    const r = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, {
      headers: GH_HEADERS,
      signal: AbortSignal.timeout(8000),
    })
    if (r.ok) {
      const j = (await r.json()) as { tag_name?: string }
      const tag = j.tag_name?.replace(/^v/, '')
      if (tag) return tag
    }
  } catch {
    /* fall through to redirect probe */
  }
  return ghLatestTagViaRedirect(repo)
}

async function latestNodeInMajor(major: number): Promise<string | null> {
  try {
    const r = await fetch('https://nodejs.org/dist/index.json', { signal: AbortSignal.timeout(8000) })
    if (!r.ok) return null
    const list = (await r.json()) as Array<{ version: string }>
    const hit = list.find((e) => e.version.startsWith(`v${major}.`))
    return hit ? hit.version.replace(/^v/, '') : null
  } catch {
    return null
  }
}

function readRawConfig(): string {
  try {
    return fs.readFileSync(CONFIG_PATH, 'utf8')
  } catch {
    return ''
  }
}

function configVar(raw: string, key: string): string {
  const m = raw.match(new RegExp(`^${key}=(?:"([^"]*)"|'([^']*)'|([^\\s#]+))`, 'm'))
  return (m?.[1] ?? m?.[2] ?? m?.[3] ?? '').trim()
}

/** yt-dlp 当前版本：优先 sidecar 版本文件（与 entrypoint/start.sh 写入的基准一致），回退执行 --version */
function ytdlpInstalledVersion(bin: string): string | null {
  const root = getProjectRoot()
  const sidecars = bin.includes('/')
    ? [`${bin}.version`]
    : [`${root}/musicfeed/bin/yt-dlp.version`]
  for (const f of sidecars) {
    try {
      const v = fs.readFileSync(f, 'utf8').trim()
      if (v) return v
    } catch {
      /* fall through */
    }
  }
  try {
    return execFileSync(bin, ['--version'], { timeout: 5000 }).toString().trim() || null
  } catch {
    return null
  }
}

function row(current: string | null, latest: string | null): UpdateRow {
  return {
    current,
    latest,
    updateAvailable: current && latest ? cmpVer(current, latest) < 0 : null,
  }
}

// 简单模块级缓存（防连点；跨进程重启即失效，无需持久化）
let _cache: { at: number; data: UpdateCheck } | null = null
const CACHE_TTL_MS = 60_000

export async function GET() {
  if (_cache && Date.now() - _cache.at < CACHE_TTL_MS) {
    return NextResponse.json(_cache.data)
  }

  const runtime = fs.existsSync('/.dockerenv') ? 'container' : 'bare-metal'

  // app：项目根 package.json 的 version（容器内 getProjectRoot 解析到 /app）
  let appVersion: string | null = null
  try {
    const pkg = JSON.parse(fs.readFileSync(`${getProjectRoot()}/package.json`, 'utf8')) as {
      version?: string
    }
    appVersion = pkg.version ?? null
  } catch {
    /* keep null */
  }

  // yt-dlp：频道决定对比仓库；二进制路径来自配置（裸值 = PATH 解析）
  const raw = readRawConfig()
  const channel = configVar(raw, 'MF_YTDLP_CHANNEL') || 'stable'
  const ytdlpBin = configVar(raw, 'MF_YTDLP') || 'yt-dlp'
  const ytdlpRepo = channel === 'nightly' ? 'yt-dlp/yt-dlp-nightly-builds' : 'yt-dlp/yt-dlp'

  // node：API 自身运行时 = job-runner/worker 实际使用的 node（entrypoint PATH 决定）
  const nodeMajor = parseInt(process.versions.node, 10)

  const [appLatest, ytdlpLatest, nodeLatest] = await Promise.all([
    ghLatestTag('Unclezhanger/mfui'),
    ghLatestTag(ytdlpRepo),
    latestNodeInMajor(nodeMajor),
  ])

  const data: UpdateCheck = {
    runtime,
    app: row(appVersion, appLatest),
    ytdlp: {
      ...row(ytdlpInstalledVersion(ytdlpBin), ytdlpLatest),
      channel,
    },
    node: row(process.version, nodeLatest),
    checkedAt: new Date().toISOString(),
  }
  _cache = { at: Date.now(), data }
  return NextResponse.json(data)
}
