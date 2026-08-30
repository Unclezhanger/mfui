import { NextResponse } from 'next/server'
import { execFileSync } from 'child_process'
import path from 'path'
import fs from 'fs'
import process from 'process'
import type { Dependencies, Dependency } from '@/lib/types'

const PROJECT_ROOT = process.cwd()
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

/** 安全执行命令，失败返回 null */
function tryExec(file: string, args: string[]): string | null {
  try {
    const out = execFileSync(file, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 5000,
    })
    return out.trim()
  } catch {
    return null
  }
}

function detectYtdlp(): Dependency & { _debug?: unknown } {
  // 0. 项目 venv 的 yt-dlp（v4 默认安装位置，优先级最高）
  // 1. 环境变量 MF_YTDLP（start.sh 启动时 export）
  // 2. mf_config.sh 的 MF_YTDLP
  const venvYtdlp = path.join(PROJECT_ROOT, '.venv', 'bin', 'yt-dlp')
  let bin = fs.existsSync(venvYtdlp)
    ? venvYtdlp
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
      installHint: 'pip install yt-dlp 或下载 https://github.com/yt-dlp/yt-dlp',
      _debug: dbg,
    }
  }
  const ver = tryExec(bin, ['--version'])
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

function detectPython3(): Dependency {
  const bin = findCommand('python3') || '/usr/bin/python3'
  const ver = tryExec(bin, ['--version'])
  // `python3 --version` 输出 "Python 3.12.13"
  const m = ver?.match(/Python\s+([\d.]+)/)
  return {
    installed: !!ver,
    version: m?.[1] || ver || undefined,
    required: true,
  }
}

function detectMutagen(): Dependency {
  // 优先用项目 venv 的 python3（mutagen 装在 venv 里）
  const venvPython = path.join(PROJECT_ROOT, '.venv', 'bin', 'python3')
  const bin = fs.existsSync(venvPython)
    ? venvPython
    : findCommand('python3') || '/usr/bin/python3'
  const out = tryExec(bin, [
    '-c',
    'import mutagen; print(mutagen.version_string)',
  ])
  if (!out) {
    return {
      installed: false,
      required: true,
      installHint: 'pip install mutagen',
    }
  }
  return { installed: true, version: out.trim(), required: true }
}

function detectNode(): Dependency {
  const bin = findCommand('node')
  if (!bin) {
    return {
      installed: false,
      required: true,
      installHint: '必需（v4 起 Node.js >= 20 是运行时）：NodeSource 或 nvm 安装',
    }
  }
  const ver = tryExec(bin, ['--version'])
  const major = parseInt((ver || '').replace(/^v/, ''), 10)
  return {
    installed: !!ver && major >= 20,
    version: ver || undefined,
    required: true,
  }
}

export async function GET() {
  // 收集 debug 信息，帮助诊断为什么某些命令找不到
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
    path.join(PROJECT_ROOT, '.venv', 'bin', 'yt-dlp'),
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

  const deps: Dependencies = {
    ytdlp: detectYtdlp(),
    ffmpeg: detectFfmpeg(),
    python3: detectPython3(),
    mutagen: detectMutagen(),
    node: detectNode(),
  }

  // 如果 ytdlp 检测失败，把 debug 信息也返回
  if (!deps.ytdlp.installed) {
    return NextResponse.json({
      ...deps,
      _debug: {
        ...debug,
        ytdlpInternal: (deps.ytdlp as Dependency & { _debug?: unknown })._debug,
      },
    })
  }

  return NextResponse.json(deps)
}
