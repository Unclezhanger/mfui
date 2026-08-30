'use client'

import { Loader2 } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import { useT } from '@/lib/i18n'
import type { JobStatus } from '@/lib/types'

const statusConfig: Record<
  JobStatus,
  { label: string; className: string; spinner?: boolean }
> = {
  pending: {
    label: '待运行',
    className:
      'border-transparent bg-zinc-500/15 text-zinc-700 dark:text-zinc-300',
  },
  running: {
    label: '进行中',
    className:
      'border-transparent bg-emerald-500/15 text-emerald-700 dark:text-emerald-300',
    spinner: true,
  },
  completed: {
    label: '已完成',
    className:
      'border-transparent bg-emerald-600/15 text-emerald-700 dark:text-emerald-300',
  },
  failed: {
    label: '失败',
    className:
      'border-transparent bg-rose-500/15 text-rose-700 dark:text-rose-300',
  },
  cancelled: {
    label: '已取消',
    className:
      'border-transparent bg-amber-500/15 text-amber-700 dark:text-amber-300',
  },
}

export function StatusBadge({
  status,
  className,
}: {
  status: JobStatus
  className?: string
}) {
  const t = useT()
  const cfg = statusConfig[status]
  return (
    <Badge variant="outline" className={cn(cfg.className, className)}>
      {cfg.spinner && <Loader2 className="size-3 animate-spin" />}
      {t(cfg.label)}
    </Badge>
  )
}
