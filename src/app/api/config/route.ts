import { NextResponse } from 'next/server'
import { readConfig, writeConfig } from '../_lib/config'
import type { MfConfig } from '@/lib/types'

export async function GET() {
  const cfg = readConfig()
  return NextResponse.json(cfg)
}

export async function PUT(req: Request) {
  let body: Partial<MfConfig>
  try {
    body = (await req.json()) as Partial<MfConfig>
  } catch {
    return NextResponse.json({ error: 'Invalid JSON body' }, { status: 400 })
  }
  // 合并：先读旧值，再用 body 覆盖
  const old = readConfig()
  const merged: MfConfig = {
    MF_LANG: body.MF_LANG === 'en' ? 'en' : 'zh',
    MF_BASE_DIR:
      typeof body.MF_BASE_DIR === 'string' && body.MF_BASE_DIR.trim()
        ? body.MF_BASE_DIR
        : old.MF_BASE_DIR,
    MF_YTDLP:
      typeof body.MF_YTDLP === 'string' ? body.MF_YTDLP : old.MF_YTDLP,
    MF_NODE_PATH:
      typeof body.MF_NODE_PATH === 'string'
        ? body.MF_NODE_PATH
        : old.MF_NODE_PATH,
    MF_DEFAULT_ARTIST_DIR:
      typeof body.MF_DEFAULT_ARTIST_DIR === 'string' &&
      body.MF_DEFAULT_ARTIST_DIR.trim()
        ? body.MF_DEFAULT_ARTIST_DIR
        : old.MF_DEFAULT_ARTIST_DIR,
    MF_AUDIO_FORMAT:
      body.MF_AUDIO_FORMAT === 'm4a' ? 'm4a' : 'opus',
    MF_HIDDEN_DIRS: Array.isArray(body.MF_HIDDEN_DIRS)
      ? body.MF_HIDDEN_DIRS.filter((d) => typeof d === 'string' && d.trim())
      : old.MF_HIDDEN_DIRS,
  }
  try {
    writeConfig(merged)
  } catch (e) {
    return NextResponse.json(
      { error: `Failed to write config: ${(e as Error).message}` },
      { status: 500 },
    )
  }
  return NextResponse.json(merged)
}
