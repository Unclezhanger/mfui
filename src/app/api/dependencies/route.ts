import { NextResponse } from 'next/server'
import { execFileSync } from 'child_process'
import path from 'path'
import fs from 'fs'
import type { Dependencies, Dependency } from '@/lib/types'
import { getProjectRoot } from '@/lib/paths'

const PROJECT_ROOT = getProjectRoot()
const MF_DIR = path.join(PROJECT_ROOT, 'musicfeed')
const CONFIG_PATH = path.join(MF_DIR, 'mf_config.sh')

/** 解析 mf_config.sh 拿 MF_YTDLP（可能为空 → fallback "yt-dlp"） */
function getConfigYtdlp(): string {
  try {
    if (!fs.existsSync(CONFIG_PATH)) return 'yt-dlp'
    const raw = fs.readFileSync(CONFIG_PATH, 'utf8')
    // 按行匹配，只取当前行的值（避免匹配到换行后的其他变量）
    // 格式：MF_YTDLP="value" 或 MF_YTDLP=value 或 MF_YTDLP=
    const lines = raw.split('\n')
    for (const line of lines) {
      const m = line.match(/^MF_YTDLP=(['"]?)([^\n'"]*)\1\s*$/)
      if (m) {
        return m[2].trim() || 'yt-dlp'
      }
    }
    return 'yt-dlp'
  } catch {
    return 'yt-dlp'
  }
}

/**
 * 在 PATH 和常见安装路径中查找命令。
 * 支持传入裸名（如 "yt-dlp"）或绝对路径（如 "/usr/local/bin/yt-dlp"）。
 */
function findCommand(name: string): string | null {
  // 如果传入的是绝对路径，直接检查是否存在 + 可执行
  if (name.startsWith('/')) {
    try {
      if (fs.existsSync(name)) {
        // 验证可执行
        fs.accessSync(name, fs.constants.X_OK)
        return name
      }
    } catch {}
    return null
  }

  // 1. which（最可靠，依赖当前进程 PATH）
  try {
    const whichOut = execFileSync('which', [name], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 3000,
    })
    const found = whichOut.trim()
    if (found) return found
  } catch {}

  // 2. 常见绝对路径（项目 venv 最优先）
  const candidates = [
    path.join(PROJECT_ROOT, '.venv', 'bin', name),
    `/usr/local/bin/${name}`,
    `/usr/bin/${name}`,
    `/bin/${name}`,
    `/opt/homebrew/bin/${name}`,
    `/usr/local/opt/${name}/bin/${name}`,
    `${process.env.HOME}/.local/bin/${name}`,
    `${process.env.HOME}/.bun/bin/${name}`,
    `${process.env.HOME}/.npm-global/bin/${name}`,
  ]
  for (const p of candidates) {
    try {
      if (fs.existsSync(p)) return p
    } catch {}
  }

  // 3. exec 兜底
  try {
    execFileSync(name, ['--version'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 3000,
    })
    return name
  } catch {
    return null
  }
}

/** yt-dlp 独立二进制（PyInstaller onefile）每次启动要先解压自身，首次冷启动明显更慢
 *（Docker Desktop / 模拟层上可能超过 5s），超时会被误判为「未安装」，所以单独放宽。 */
const YTDLP_VERSION_TIMEOUT_MS = 15000

/** 安全执行命令，失败返回 null */
function tryExec(file: string, args: string[], timeoutMs = 5000): string | null {
  try {
    const out = execFileSync(file, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: timeoutMs,
    })
    return out.trim()
  } catch {
    return null
  }
}

function detectYtdlp(): Dependency & { _debug?: unknown } {
  // 0. 项目内独立二进制（v4.1：musicfeed/bin/yt-dlp，setup.sh 下载）
  // 1. 环境变量 MF_YTDLP（start.sh 启动时 export）
  // 2. mf_config.sh 的 MF_YTDLP
  const binYtdlp = path.join(MF_DIR, 'bin', 'yt-dlp')
  let bin = fs.existsSync(binYtdlp)
    ? binYtdlp
    : process.env.MF_YTDLP || getConfigYtdlp()
  const dbg = {
    configYtdlp: bin,
    findCommandResult1: null as string | null,
    findCommandResult2: null as string | null,
    finalBin: null as string | null,
    tryExecResult: null as string | null,
  }
  // 如果是裸名，尝试找到绝对路径
  if (bin && !bin.startsWith('/')) {
    const found = findCommand(bin)
    dbg.findCommandResult1 = found
    bin = found || ''
  }
  // 2. fallback：找 yt-dlp
  if (!bin) {
    const found = findCommand('yt-dlp')
    dbg.findCommandResult2 = found
    bin = found || ''
  }
  dbg.finalBin = bin
  if (!bin) {
    return {
      installed: false,
      required: true,
      installHint: '运行 setup.sh 下载独立二进制，或 https://github.com/yt-dlp/yt-dlp',
      _debug: dbg,
    }
  }
  const ver = tryExec(bin, ['--version'], YTDLP_VERSION_TIMEOUT_MS)
  dbg.tryExecResult = ver
  return {
    installed: !!ver,
    version: ver || undefined,
    required: true,
    _debug: dbg,
  }
}

function detectFfmpeg(): Dependency {
  const bin = findCommand('ffmpeg')
  if (!bin) {
    return {
      installed: false,
      required: true,
      installHint: 'apt install ffmpeg / brew install ffmpeg',
    }
  }
  const ver = tryExec(bin, ['-version'])
  const versionLine = ver?.split('\n')[0] ?? ''
  const m = versionLine.match(/version\s+([^\s]+)/)
  return {
    installed: true,
    version: m?.[1] || versionLine || undefined,
    required: true,
  }
}

function detectNode(): Dependency {
  const bin = findCommand('node')
  if (!bin) {
    return {
      installed: false,
      required: true,
      installHint: '必需（WebUI/job-runner 运行时，>=22；内核 yt-dlp EJS 运行时最低要求）：NodeSource 或 nvm 安装',
    }
  }
  const ver = tryExec(bin, ['--version'])
  const major = parseInt((ver || '').replace(/^v/, ''), 10)
  return {
    installed: !!ver && major >= 22,
    version: ver || undefined,
    required: true,
  }
}

function detectJq(): Dependency {
  const bin = findCommand('jq')
  if (!bin) {
    return {
      installed: false,
      required: true,
      installHint: 'apt install jq / brew install jq（v4.1 内核 JSON 解析必需）',
    }
  }
  const ver = tryExec(bin, ['--version'])
  return {
    installed: !!ver,
    version: ver || undefined,
    required: true,
  }
}

/**
 * 诊断信息：只在 yt-dlp 检测失败时才收集。
 * 这里会额外起好几个子进程（which / 直接执行 yt-dlp），成功路径不该每次都付出这个代价。
 */
function collectDebug() {
  const debug = {
    pid: process.pid,
    cwd: process.cwd(),
    HOME: process.env.HOME,
    PATH: process.env.PATH,
    whichYtdlp: null as string | null,
    ytdlpExists: {} as Record<string, boolean>,
    ytdlpExecTest: null as string | null,
  }

  // 测试 which yt-dlp
  try {
    const out = execFileSync('which', ['yt-dlp'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 3000,
    })
    debug.whichYtdlp = out.trim()
  } catch (e: unknown) {
    debug.whichYtdlp = `ERROR: ${(e as Error).message}`
  }

  // 测试文件存在性
  for (const p of [
    path.join(MF_DIR, 'bin', 'yt-dlp'),
    '/usr/local/bin/yt-dlp',
    '/usr/bin/yt-dlp',
    `${process.env.HOME}/.local/bin/yt-dlp`,
  ]) {
    try {
      debug.ytdlpExists[p] = fs.existsSync(p)
    } catch {
      debug.ytdlpExists[p] = false
    }
  }

  // 测试直接 exec yt-dlp --version（用绝对路径）
  try {
    const out = execFileSync('/usr/local/bin/yt-dlp', ['--version'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 5000,
    })
    debug.ytdlpExecTest = out.trim()
  } catch (e: unknown) {
    debug.ytdlpExecTest = `ERROR: ${(e as Error).message}`
  }

  return debug
}

export async function GET() {
  const deps: Dependencies = {
    ytdlp: detectYtdlp(),
    ffmpeg: detectFfmpeg(),
    jq: detectJq(),
    node: detectNode(),
  }

  // detectYtdlp 会带上内部 _debug（路径探测过程），拆出来，不随成功响应返回
  const { _debug: ytdlpInternal, ...ytdlp } = deps.ytdlp as Dependency & { _debug?: unknown }

  // 如果 ytdlp 检测失败，才收集并返回诊断信息，帮助排查为什么命令找不到
  if (!deps.ytdlp.installed) {
    return NextResponse.json({
      ...deps,
      _debug: { ...collectDebug(), ytdlpInternal },
    })
  }

  return NextResponse.json({ ...deps, ytdlp })
}
