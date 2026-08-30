'use client'

import { Disc3, ListMusic, Radio, Music2, HelpCircle } from 'lucide-react'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import { useT } from '@/lib/i18n'
import type { LinkType } from '@/lib/types'

const typeConfig: Record<
  LinkType,
  { label: string; className: string; Icon: React.ComponentType<{ className?: string }> }
> = {
  album: {
    label: '专辑',
    className:
      'border-transparent bg-emerald-500/15 text-emerald-700 dark:text-emerald-300',
    Icon: Disc3,
  },
  ytm_radio: {
    label: 'YTM 电台',
    className:
      'border-transparent bg-rose-500/15 text-rose-700 dark:text-rose-300',
    Icon: Radio,
  },
  playlist: {
    label: '播放列表',
    className:
      'border-transparent bg-amber-500/15 text-amber-700 dark:text-amber-300',
    Icon: ListMusic,
  },
  single: {
    label: '单曲',
    className:
      'border-transparent bg-sky-500/15 text-sky-700 dark:text-sky-300',
    Icon: Music2,
  },
  unknown: {
    label: '未知',
    className:
      'border-transparent bg-zinc-500/15 text-zinc-700 dark:text-zinc-300',
    Icon: HelpCircle,
  },
}

export function LinkTypeBadge({
  type,
  className,
  showIcon = true,
}: {
  type: LinkType
  className?: string
  showIcon?: boolean
}) {
  const t = useT()
  const cfg = typeConfig[type]
  return (
    <Badge variant="outline" className={cn(cfg.className, className)}>
      {showIcon && <cfg.Icon className="size-3" />}
      {t(cfg.label)}
    </Badge>
  )
}
