/**
 * musicfeed - socket.io 客户端封装
 *
 * 通过 Next.js rewrites 转发到 mini-service (127.0.0.1:3001):
 *   next.config.ts 中: /socket.io/:path* → http://127.0.0.1:3001/socket.io/:path*
 *   前端: io({ path: '/socket.io' })
 *
 * 浏览器只需访问 Next.js 一个端口（默认 3010）。
 * mini-service 只监听 127.0.0.1，不对外暴露，更安全。
 */

import { io, type Socket } from 'socket.io-client'
import type { LogEntry } from './types'

let socket: Socket | null = null
let socketPromise: Promise<Socket> | null = null

/**
 * 初始化并返回 socket 实例。使用相对路径，由 Next.js rewrites 转发到 3001。
 */
export async function getSocket(): Promise<Socket> {
  if (socket) return socket
  if (!socketPromise) {
    socketPromise = (async () => {
      socket = io({
        path: '/socket.io',
        transports: ['websocket', 'polling'],
        reconnection: true,
        reconnectionAttempts: 10,
        reconnectionDelay: 1000,
        timeout: 10000,
      })
      return socket
    })()
  }
  return socketPromise
}

export interface SubscribeHandlers {
  onLog: (entry: LogEntry) => void
  onProgress?: (p: {
    downloadedCount: number
    trackCount?: number | null
    /** v3.3: 下载阶段平滑进度小数（0-1，track_done 之前的实时占比） */
    frac?: number
  }) => void
  onDone?: (p: { exitCode: number; downloadedCount: number }) => void
  onError?: (p: { exitCode: number; message?: string }) => void
  onCancelled?: () => void
}

/**
 * 订阅某个 job 的实时事件，返回 unsubscribe 函数。
 * 同一 socket 上可同时订阅多个 job（room 互不影响）。
 *
 * 异步：需要先 ensure socket 实例。
 */
export async function subscribeJob(
  jobId: string,
  handlers: SubscribeHandlers,
): Promise<() => void> {
  const sock = await getSocket()
  sock.emit('subscribe', jobId)

  // 为每个 handler 绑定 jobId 过滤（room 广播时不会跨 job，但保险起见）
  const onLog = (entry: LogEntry) => {
    handlers.onLog(entry)
  }
  const onProgress = (p: {
    downloadedCount: number
    trackCount?: number | null
    frac?: number
  }) => {
    handlers.onProgress?.(p)
  }
  const onDone = (p: { exitCode: number; downloadedCount: number }) => {
    handlers.onDone?.(p)
  }
  const onError = (p: { exitCode: number; message?: string }) => {
    handlers.onError?.(p)
  }
  const onCancelled = (p: { jobId?: string }) => {
    if (!p?.jobId || p.jobId === jobId) handlers.onCancelled?.()
  }

  sock.on('log', onLog)
  sock.on('progress', onProgress)
  sock.on('done', onDone)
  sock.on('error', onError)
  sock.on('cancelled', onCancelled)

  return () => {
    sock.emit('unsubscribe', jobId)
    sock.off('log', onLog)
    sock.off('progress', onProgress)
    sock.off('done', onDone)
    sock.off('error', onError)
    sock.off('cancelled', onCancelled)
  }
}

/** 主动断开 socket 连接（一般在 app 卸载时调） */
export function disconnectSocket(): void {
  if (socket) {
    socket.disconnect()
    socket = null
    socketPromise = null
  }
}
