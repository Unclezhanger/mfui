'use client'

import { useEffect, useRef } from 'react'
import { useT } from '@/lib/i18n'
import { cn } from '@/lib/utils'
import type { LogEntry, LogLevel } from '@/lib/types'

const levelColor: Record<LogLevel, string> = {
  info: 'text-emerald-300/90',
  warn: 'text-amber-400',
  error: 'text-rose-400',
  success: 'text-emerald-300 font-medium',
}

const levelPrefix: Record<LogLevel, string> = {
  info: 'ℹ',
  warn: '⚠',
  error: '✗',
  success: '✓',
}

function fmtTime(ts: string) {
  try {
    const d = new Date(ts)
    return d.toLocaleTimeString('zh-CN', { hour12: false })
  } catch {
    return ts
  }
}

export function LogConsole({
  logs,
  className,
  emptyText,
  autoScroll = true,
}: {
  logs: LogEntry[]
  className?: string
  emptyText?: string
  autoScroll?: boolean
}) {
  const t = useT()
  const bottomRef = useRef<HTMLDivElement>(null)
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (autoScroll && bottomRef.current) {
      bottomRef.current.scrollIntoView({ behavior: 'smooth', block: 'end' })
    }
  }, [logs.length, autoScroll])

  return (
    <div
      ref={containerRef}
      className={cn(
        'terminal-scroll h-full w-full overflow-y-auto bg-zinc-950 p-3 font-mono text-xs leading-relaxed',
        className
      )}
    >
      {logs.length === 0 ? (
        <div className="text-zinc-500">{emptyText ?? t('等待日志…')}</div>
      ) : (
        <ul className="space-y-0.5">
          {logs.map((log, i) => (
            <li
              key={`${log.ts}-${i}`}
              className={cn('flex gap-2 whitespace-pre-wrap break-all', levelColor[log.level])}
            >
              <span className="shrink-0 text-zinc-500">[{fmtTime(log.ts)}]</span>
              <span className="shrink-0 text-zinc-600">{levelPrefix[log.level]}</span>
              <span>{log.msg}</span>
            </li>
          ))}
        </ul>
      )}
      <div ref={bottomRef} />
    </div>
  )
}
