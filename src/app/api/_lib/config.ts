import fs from 'fs'
import path from 'path'
import os from 'os'
import type { MfConfig } from '@/lib/types'
import { getProjectRoot } from '@/lib/paths'

const PROJECT_ROOT = getProjectRoot()
const MF_DIR = path.join(PROJECT_ROOT, 'musicfeed')
export const CONFIG_PATH = path.join(MF_DIR, 'mf_config.sh')

/**
 * 解析 mf_config.sh 内容，返回 MfConfig。
 * - MF_BASE_DIR 中的 $HOME / ${HOME} 会被展开
 * - MF_HIDDEN_DIRS bash 数组 → string[]
 */
export function parseConfig(raw: string): MfConfig {
  const getStr = (key: string): string => {
    // 匹配 KEY="..." / KEY='...' / KEY=xxx（整行）
    // 未加引号的值可能含 bash 反斜杠转义的空格（如 unclezhanger\ selected，
    // mf_setup.sh 生成的格式），取整行后再还原转义
    const re = new RegExp(`^${key}=(?:"([^"]*)"|'([^']*)'|(.+))`, 'm')
    const m = raw.match(re)
    const v = (m?.[1] ?? m?.[2] ?? m?.[3] ?? '').trim()
    // 还原 bash 转义：\空格 → 空格，\\ → \
    return v.replace(/\\ /g, ' ').replace(/\\\\/g, '\\')
  }

  const lang = getStr('MF_LANG') === 'en' ? 'en' : 'zh'
  let baseDir = getStr('MF_BASE_DIR')
  baseDir = baseDir.replace(/\$\{?HOME\}?/g, os.homedir())
  const ytdlp = getStr('MF_YTDLP') || 'yt-dlp'
  const nodePath = getStr('MF_NODE_PATH')
  const defaultArtistDir = getStr('MF_DEFAULT_ARTIST_DIR') || 'musicfeed'
  const audioFmtRaw = getStr('MF_AUDIO_FORMAT')
  const audioFormat = audioFmtRaw === 'm4a' ? 'm4a' : 'opus'

  // 解析 bash 数组：MF_HIDDEN_DIRS=("a" "b" 'c' d)
  const hiddenDirs: string[] = []
  const arrMatch = raw.match(/^MF_HIDDEN_DIRS=\(([^)]*)\)/m)
  if (arrMatch) {
    const inner = arrMatch[1]
    // 按双引号或单引号或空白 token 切
    const tokens = inner.match(/(?:"([^"]*)"|'([^']*)'|([^\s]+))/g) ?? []
    for (const tok of tokens) {
      const cleaned = tok.replace(/^["']|["']$/g, '').trim()
      if (cleaned) hiddenDirs.push(cleaned)
    }
  }

  return {
    MF_LANG: lang,
    MF_BASE_DIR: baseDir,
    MF_YTDLP: ytdlp,
    MF_NODE_PATH: nodePath,
    MF_DEFAULT_ARTIST_DIR: defaultArtistDir,
    MF_AUDIO_FORMAT: audioFormat,
    MF_HIDDEN_DIRS: hiddenDirs,
  }
}

export function readConfig(): MfConfig {
  if (!fs.existsSync(CONFIG_PATH)) {
    // 返回默认
    return {
      MF_LANG: 'zh',
      MF_BASE_DIR: path.join(os.homedir(), 'navidrome', 'music'),
      MF_YTDLP: 'yt-dlp',
      MF_NODE_PATH: '',
      MF_DEFAULT_ARTIST_DIR: 'musicfeed',
      MF_AUDIO_FORMAT: 'opus',
      MF_HIDDEN_DIRS: ['.DS_Store', '@eaDir', 'attachments'],
    }
  }
  const raw = fs.readFileSync(CONFIG_PATH, 'utf8')
  return parseConfig(raw)
}

/** bash shell-quote：保证字符串安全嵌入 bash 文件 */
function shellQuote(s: string): string {
  // 简化版 printf %q 等价：用单引号包裹，转义内部单引号
  if (s === '') return "''"
  if (/^[A-Za-z0-9_./:@=-]+$/.test(s)) return s
  return "'" + s.replace(/'/g, "'\\''") + "'"
}

export function serializeConfig(cfg: MfConfig): string {
  const lines: string[] = []
  lines.push('#!/bin/bash')
  lines.push('# musicfeed (音流) 配置文件')
  lines.push('# 由 Web UI 自动写入')
  lines.push('')
  lines.push(`MF_LANG=${shellQuote(cfg.MF_LANG === 'en' ? 'en' : 'zh')}`)
  lines.push(`MF_BASE_DIR=${shellQuote(cfg.MF_BASE_DIR)}`)
  lines.push(`MF_YTDLP=${shellQuote(cfg.MF_YTDLP || 'yt-dlp')}`)
  lines.push(`MF_NODE_PATH=${shellQuote(cfg.MF_NODE_PATH ?? '')}`)
  lines.push(
    `MF_DEFAULT_ARTIST_DIR=${shellQuote(cfg.MF_DEFAULT_ARTIST_DIR || 'musicfeed')}`,
  )
  lines.push(
    `MF_AUDIO_FORMAT=${shellQuote(cfg.MF_AUDIO_FORMAT === 'm4a' ? 'm4a' : 'opus')}`,
  )
  // 数组：(".DS_Store" "@eaDir" "attachments")
  const arr = (cfg.MF_HIDDEN_DIRS ?? [])
    .map((d) => shellQuote(d))
    .join(' ')
  lines.push(`MF_HIDDEN_DIRS=(${arr})`)
  lines.push('')
  return lines.join('\n')
}

/** WebUI 自己管理（读写）的配置项；其余键（如 MF_YTDLP_CHANNEL、MF_VENV）保存时原样保留 */
const MANAGED_KEYS = new Set([
  'MF_LANG',
  'MF_BASE_DIR',
  'MF_YTDLP',
  'MF_NODE_PATH',
  'MF_DEFAULT_ARTIST_DIR',
  'MF_AUDIO_FORMAT',
  'MF_HIDDEN_DIRS',
])

/**
 * 取出旧配置里 WebUI 不管理的单行赋值（KEY=... / declare -a KEY=...）。
 * 例如 mf_setup.sh / entrypoint.sh 写入的 MF_YTDLP_CHANNEL：
 * 若不保留，在设置页保存一次就会丢失频道选择（nightly 被悄悄降级回 stable）。
 */
function extractUnmanagedLines(raw: string): string[] {
  const out: string[] = []
  for (const line of raw.split('\n')) {
    const m = line.match(/^(?:declare\s+-a\s+)?([A-Z][A-Z0-9_]*)=/)
    if (m && !MANAGED_KEYS.has(m[1])) out.push(line)
  }
  return out
}

export function writeConfig(cfg: MfConfig): void {
  let extras: string[] = []
  // 备份原文件，并保留其中 WebUI 不管理的配置项
  if (fs.existsSync(CONFIG_PATH)) {
    const bak = CONFIG_PATH + '.bak'
    fs.copyFileSync(CONFIG_PATH, bak)
    extras = extractUnmanagedLines(fs.readFileSync(CONFIG_PATH, 'utf8'))
  }
  let content = serializeConfig(cfg)
  if (extras.length > 0) {
    content = content.replace(/\n*$/, '\n') + extras.join('\n') + '\n'
  }
  fs.writeFileSync(CONFIG_PATH, content, { encoding: 'utf8', mode: 0o755 })
}

/** 列出 MF_BASE_DIR 下的文件夹（排除 MF_HIDDEN_DIRS 和 . 开头） */
export function listFolders(): { exists: boolean; folders: string[] } {
  const cfg = readConfig()
  const base = cfg.MF_BASE_DIR
  if (!fs.existsSync(base) || !fs.statSync(base).isDirectory()) {
    return { exists: false, folders: [] }
  }
  const hidden = new Set(cfg.MF_HIDDEN_DIRS)
  let entries: fs.Dirent[]
  try {
    entries = fs.readdirSync(base, { withFileTypes: true })
  } catch {
    return { exists: false, folders: [] }
  }
  const folders = entries
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .filter((n) => !hidden.has(n) && !n.startsWith('.'))
    .sort((a, b) => a.localeCompare(b, 'zh-Hans'))
  return { exists: true, folders }
}
