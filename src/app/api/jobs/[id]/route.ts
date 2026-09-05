import { NextResponse } from 'next/server'
import { deleteJobRow, getJob } from '../../_lib/jobs'
import path from 'path'
import fs from 'fs'
import { getProjectRoot } from '@/lib/paths'

const PROJECT_ROOT = getProjectRoot()

export async function GET(
  _req: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params
  const job = await getJob(id)
  if (!job) {
    return NextResponse.json({ error: 'Job not found' }, { status: 404 })
  }
  return NextResponse.json(job)
}

export async function DELETE(
  _req: Request,
  { params }: { params: Promise<{ id: string }> },
) {
  const { id } = await params
  const job = await getJob(id)
  // 删 log 文件（v4.1: logFile 可能是队列共用的日期时间名，不能按 jobId 拼）
  try {
    if (job?.logFile) {
      const logPath = path.join(PROJECT_ROOT, job.logFile.replace(/^log\//, 'musicfeed/log/'))
      const donePath = logPath.replace(/\.log$/, '.done')
      if (fs.existsSync(logPath)) fs.unlinkSync(logPath)
      if (fs.existsSync(donePath)) fs.unlinkSync(donePath)
    }
  } catch {
    // ignore
  }
  const ok = await deleteJobRow(id)
  if (!ok) {
    return NextResponse.json({ error: 'Job not found' }, { status: 404 })
  }
  return NextResponse.json({ ok: true })
}
