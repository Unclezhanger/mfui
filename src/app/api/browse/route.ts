import { NextResponse } from 'next/server'
import { promises as fs } from 'fs'
import path from 'path'

/**
 * GET /api/browse?path=/some/dir
 * 目录树浏览（设置页「音乐根目录」选取器用）：列出指定目录下的子目录。
 * 自托管工具，与 CLI 的 mf_setup.sh 目录浏览器同权限语义；仅返回目录，
 * 隐藏目录（. 开头）不列出但可通过路径访问。
 */
export async function GET(request: Request) {
  const reqPath = new URL(request.url).searchParams.get('path') || '/'

  // 统一为 POSIX 风格绝对路径（服务器为 Linux）
  let target = reqPath.trim()
  if (!target.startsWith('/')) target = `/${target}`
  // 规整掉 .. / . 片段，防路径穿越式混乱输入
  const normalized = path.posix.normalize(target)

  try {
    const st = await fs.stat(normalized)
    if (!st.isDirectory()) {
      return NextResponse.json({ ok: false, dirs: [], parent: null })
    }
    const entries = await fs.readdir(normalized, { withFileTypes: true })
    const dirs = entries
      .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
      .map((e) => path.posix.join(normalized === '/' ? '' : normalized, e.name))
      .sort((a, b) => a.localeCompare(b))
    const parent = normalized === '/' ? null : path.posix.dirname(normalized)
    return NextResponse.json({ ok: true, dirs, parent, path: normalized })
  } catch {
    return NextResponse.json({ ok: false, dirs: [], parent: null })
  }
}
