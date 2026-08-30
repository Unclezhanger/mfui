import { NextRequest, NextResponse } from 'next/server'

const JOB_RUNNER_URL = process.env.JOB_RUNNER_URL || 'http://127.0.0.1:3001'

/**
 * Catch-all 代理 route，把请求转发到 mini-service (127.0.0.1:3001)
 *
 * 路径映射：
 *   /api/proxy/preview → http://127.0.0.1:3001/api/preview
 *   /api/proxy/jobs → http://127.0.0.1:3001/api/jobs
 *   /api/proxy/jobs/:id/cancel → http://127.0.0.1:3001/api/jobs/:id/cancel
 *
 * 这样浏览器只需访问 Next.js 一个端口（默认 3010），不用 caddy 转发。
 * mini-service 只监听 127.0.0.1，不对外暴露，更安全。
 *
 * Socket.io 不走这里，由 next.config.ts 的 rewrites 直接转发 /socket.io/* 到 3001。
 */
export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ path: string[] }> },
) {
  return proxyRequest(req, params)
}

export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ path: string[] }> },
) {
  return proxyRequest(req, params)
}

export async function DELETE(
  req: NextRequest,
  { params }: { params: Promise<{ path: string[] }> },
) {
  return proxyRequest(req, params)
}

export async function PUT(
  req: NextRequest,
  { params }: { params: Promise<{ path: string[] }> },
) {
  return proxyRequest(req, params)
}

async function proxyRequest(
  req: NextRequest,
  params: Promise<{ path: string[] }>,
) {
  const { path } = await params
  const targetPath = '/api/' + path.join('/')
  const searchParams = req.nextUrl.searchParams.toString()
  const url = `${JOB_RUNNER_URL}${targetPath}${searchParams ? '?' + searchParams : ''}`

  try {
    const headers = new Headers()
    req.headers.forEach((value, key) => {
      // 不转发 host 头，避免后端拒绝
      if (key.toLowerCase() !== 'host') {
        headers.set(key, value)
      }
    })

    const body =
      req.method !== 'GET' && req.method !== 'HEAD'
        ? await req.text()
        : undefined

    const resp = await fetch(url, {
      method: req.method,
      headers,
      body,
    })

    const respBody = await resp.text()

    // 复制响应头
    const finalHeaders = new Headers()
    resp.headers.forEach((value, key) => {
      finalHeaders.set(key, value)
    })

    return new NextResponse(respBody, {
      status: resp.status,
      headers: finalHeaders,
    })
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    return NextResponse.json(
      { ok: false, error: `proxy error: ${msg}` },
      { status: 502 },
    )
  }
}
