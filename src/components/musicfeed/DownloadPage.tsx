'use client'

import { Check, Loader2, Link2, SlidersHorizontal, Download } from 'lucide-react'
import { cn } from '@/lib/utils'
import { useT } from '@/lib/i18n'
import { useMusicFeedStore } from '@/lib/store'
import { LinkInput } from './LinkInput'
import { DownloadOptions } from './DownloadOptions'
import { DownloadProgress } from './DownloadProgress'

const steps = [
  { key: 1, label: '链接输入', Icon: Link2 },
  { key: 2, label: '配置选项', Icon: SlidersHorizontal },
  { key: 3, label: '下载进度', Icon: Download },
] as const

export function DownloadPage() {
  const preview = useMusicFeedStore((s) => s.preview)
  const activeJob = useMusicFeedStore((s) => s.activeJob)
  const confirmTracks = useMusicFeedStore((s) => s.confirmTracks)
  const t = useT()

  // 步骤推算：
  // step 3 = 有活动任务
  // step 2 = 有预览且用户已在选曲页点了「下一步」（不自动跳，否则选不了曲目）
  // step 1 = 无预览或未确认选曲
  const step = activeJob ? 3 : preview && confirmTracks ? 2 : 1
  // 任务已在终态时第 3 步不再转圈（显示完成态）
  const jobRunning =
    activeJob?.status === 'running' || activeJob?.status === 'pending'

  return (
    <div className="flex flex-col gap-6">
      {/* Stepper */}
      <div className="flex items-center gap-2 rounded-lg border border-border bg-card p-3 sm:gap-4 sm:p-4">
        {steps.map(({ key, label, Icon }, idx) => {
          const done = step > key
          const current = step === key
          return (
            <div key={key} className="flex flex-1 items-center gap-2 sm:gap-4">
              <div
                className={cn(
                  'flex items-center gap-2',
                  current && 'text-emerald-600 dark:text-emerald-400'
                )}
              >
                <span
                  className={cn(
                    'flex size-7 items-center justify-center rounded-full text-xs font-semibold transition-colors sm:size-8',
                    done && 'bg-emerald-600 text-white dark:bg-emerald-500 dark:text-emerald-950',
                    current &&
                      'bg-emerald-600/15 text-emerald-600 dark:text-emerald-400 ring-2 ring-emerald-500/40',
                    !done && !current && 'bg-muted text-muted-foreground'
                  )}
                >
                  {done ? (
                    <Check className="size-4" />
                  ) : current && key === 3 ? (
                    jobRunning ? (
                      <Loader2 className="size-4 animate-spin" />
                    ) : (
                      <Icon className="size-3.5" />
                    )
                  ) : (
                    <Icon className="size-3.5" />
                  )}
                </span>
                <span
                  className={cn(
                    'hidden text-sm font-medium sm:inline',
                    !done && !current && 'text-muted-foreground'
                  )}
                >
                  {t(label)}
                </span>
              </div>
              {idx < steps.length - 1 && (
                <div
                  className={cn(
                    'h-px flex-1 transition-colors',
                    done ? 'bg-emerald-500/40' : 'bg-border'
                  )}
                />
              )}
            </div>
          )
        })}
      </div>

      {/* Step 内容 */}
      {step === 1 && <LinkInput />}
      {step === 2 && <DownloadOptions />}
      {step === 3 && <DownloadProgress />}
    </div>
  )
}
