import { NextResponse } from 'next/server'

/**
 * PWA Web Share Target 接收端。
 * 手机上从 YouTube/浏览器「分享 → mfui」时，系统以 POST form 提交到这里；
 * 提取链接后重定向回首页（带 ?url=），前端 LinkInput 预填并自动预览。
 *
 * 注意：Share Target 需要 HTTPS（反向代理或隧道提供），
 * 参见 worklog「分发策略」与「PWA」条目。
 */
export async function POST(req: Request) {
  let target = '/'
  try {
    const form = await req.formData()
    const raw =
      (form.get('url') as string | null) ||
      (form.get('text') as string | null) ||
      (form.get('title') as string | null) ||
      ''
    // 分享文本里可能混有说明文字，提取第一个 http(s) 链接
    const m = raw.match(/https?:\/\/[^\s"'<>]+/i)
    if (m) {
      target = `/?url=${encodeURIComponent(m[0])}`
    }
  } catch {
    // 解析失败回首页
  }
  // standalone 模式下 req.url 的 host 是绑定地址（0.0.0.0），
  // 重定向必须用浏览器实际访问的 Host 头
  const host = req.headers.get('x-forwarded-host') || req.headers.get('host') || 'localhost:3010'
  return NextResponse.redirect(new URL(target, `http://${host}`), 303)
}

export async function GET(req: Request) {
  const host = req.headers.get('x-forwarded-host') || req.headers.get('host') || 'localhost:3010'
  return NextResponse.redirect(new URL('/', `http://${host}`), 303)
}
