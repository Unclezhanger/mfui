import { NextResponse } from 'next/server'
import fs from 'fs'
import path from 'path'
import process from 'process'
import type { LogEntry, LogLevel } from '@/lib/types'
import { getJob } from '../../../_lib/jobs'

const PROJECT_ROOT = process.cwd()
const LOG_DIR = path.join(PROJECT_ROOT, 'musicfeed', 'log')

const LEVELS: LogLevel[] = ['info', 'warn', 'error', 'debug']

function toLevel(v: unknown): LogLevel {
  return LEVELS.includes(v as LogLevel) ? (v as LogLevel) : 'info'
}

/**
 * GET /api/jobs/:id/logs — 读取 mf_batch.sh 落盘的任务日志
 * （musicfeed/log/mf-<jobId>.log）。
 *
 * 文件内容是混排：log() 写的 JSON 行（含 ts/level/event/msg）+
 * yt-dlp/embed_cover 的原始文本输出（ytdlp_run 与 embed_cover 都
 * 重定向到了同一个 LOG_FILE）。逐行解析：JSON 行还原结构化条目，
 * 非 JSON 行降级为 info 条目（ts 用文件修改时间）。
 *
 * 文件不存在（日志被清理 / CLI 任务）时返回空数组，前端不报错。
 */
export async function GET(
  _req: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params
  // jobId 校验（与 mf_batch.sh 的 [A-Za-z0-9_.-]+ 一致，防路径穿越）
  if (!/^[A-Za-z0-9_.-]+$/.test(id)) {
    return NextResponse.json({ error: 'invalid job id' }, { status: 400 })
  }

  // v4.1: 优先用 job 行记录的 logFile（队列共用日期时间名），回退旧命名 mf-<jobId>.log
  let logFile: string
  try {
    const job = await getJob(id)
    logFile = job?.logFile
      ? path.join(PROJECT_ROOT, job.logFile.replace(/^log\//, 'musicfeed/log/'))
      : path.join(LOG_DIR, `mf-${id}.log`)
  } catch {
    logFile = path.join(LOG_DIR, `mf-${id}.log`)
  }
  let raw: string
  try {
    raw = fs.readFileSync(logFile, 'utf-8')
  } catch {
    return NextResponse.json([])
  }

  const mtime = new Date(fs.statSync(logFile).mtimeMs).toISOString()
  const entries: LogEntry[] = []
  for (const line of raw.split('\n')) {
    // yt-dlp 的 \r 覆盖式进度行：取最后一段
    const text = line.split('\r').pop()?.trim()
    if (!text) continue

    if (text.startsWith('{')) {
      try {
        const obj = JSON.parse(text) as Record<string, unknown>
        if (typeof obj.msg === 'string') {
          entries.push({
            ts: typeof obj.ts === 'string' ? obj.ts : mtime,
            level: toLevel(obj.level),
            event: typeof obj.event === 'string' ? obj.event : undefined,
            msg: obj.msg,
          })
          continue
        }
      } catch {
        // 不完整的 JSON 行（写一半崩溃等）→ 当普通文本
      }
    }
    entries.push({ ts: mtime, level: 'info', msg: text })
  }

  // 防超长日志拖垮前端，只保留最后 2000 条
  return NextResponse.json(entries.slice(-2000))
}
