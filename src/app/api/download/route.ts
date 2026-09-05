import { NextResponse } from 'next/server'
import fs from 'fs'
import path from 'path'
import { getProjectRoot } from '@/lib/paths'

/**
 * GET /api/download
 *
 * 强制下载 mfui.tar.gz（带 Content-Disposition: attachment 头）
 * 避免浏览器尝试渲染二进制。
 */
export async function GET() {
  const filePath = path.join(getProjectRoot(), 'public', 'mfui.tar.gz')

  if (!fs.existsSync(filePath)) {
    return new NextResponse('File not found', { status: 404 })
  }

  const fileBuffer = fs.readFileSync(filePath)

  return new NextResponse(fileBuffer, {
    status: 200,
    headers: {
      'Content-Type': 'application/gzip',
      'Content-Disposition': 'attachment; filename="mfui.tar.gz"',
      'Content-Length': fileBuffer.length.toString(),
      'Cache-Control': 'no-cache',
    },
  })
}
