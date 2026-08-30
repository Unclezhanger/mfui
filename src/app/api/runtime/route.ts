import { NextResponse } from 'next/server'

/**
 * GET /api/runtime
 *
 * 返回当前实例实际使用的端口配置（仅用于前端显示）。
 *
 * 自 v4.0.0 起删除 caddy 依赖：
 *   - 浏览器只访问 Next.js 一个端口（默认 3010）
 *   - mini-service 只监听 127.0.0.1（不对外暴露）
 *   - 前端通过 /api/proxy/* 转发到 mini-service
 *
 * 两个端口都支持环境变量覆盖；未设置时使用默认值：
 *   - MF_PORT_NEXT   Next.js 前端   默认 3010
 *   - MF_PORT_JOB    job-runner     默认 3001
 *
 * 注意：本端点本身在 Next.js 进程内执行，因此 portNext 一定与前端自身监听端口
 * 一致；前端发请求时走相对路径 /api/runtime，无需指定端口。
 */
export async function GET() {
  const portNext = parseInt(process.env.MF_PORT_NEXT || '3010', 10)
  const portJob = parseInt(process.env.MF_PORT_JOB || '3001', 10)

  return NextResponse.json({
    portNext,
    portJob,
  })
}
