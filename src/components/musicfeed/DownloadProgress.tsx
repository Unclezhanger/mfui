'use client'

import { toast } from 'sonner'
import {
  XCircle,
  CheckCircle2,
  Loader2,
  History as HistoryIcon,
  LayoutDashboard,
  Music,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Progress } from '@/components/ui/progress'
import { useT } from '@/lib/i18n'
import { useMusicFeedStore } from '@/lib/store'
import { StatusBadge } from './StatusBadge'
import { LogConsole } from './LogConsole'

export function DownloadProgress() {
  const t = useT()
  const {
    activeJob,
    activeFrac,
    logs,
    cancelJob,
    resetDownloadFlow,
    setTab,
    queueRun,
  } = useMusicFeedStore()

  if (!activeJob) {
    return (
      <Card>
        <CardContent className="flex flex-col items-center gap-3 py-12 text-center">
          <Music className="size-10 text-muted-foreground" />
          <p className="text-sm text-muted-foreground">{t('没有正在运行的任务')}</p>
          <Button variant="outline" onClick={() => setTab('download')}>
            {t('去新建任务')}
          </Button>
        </CardContent>
      </Card>
    )
  }

  // v4.1 队列聚合进度
  const inQueue = !!queueRun && queueRun.total > 1
  const qTotal = queueRun?.totalTracks ?? 0
  const qDone = queueRun?.doneTracks ?? 0

  const total = activeJob.trackCount ?? 0
  const isRunning = activeJob.status === 'running' || activeJob.status === 'pending'
  const isCompleted = activeJob.status === 'completed'
  // 显示口径：已完成曲目数 + 下载阶段平滑小数（activeFrac，0-1）
  const done = activeJob.downloadedCount + (isRunning ? activeFrac * Math.max(total, 1) : 0)
  const shownDone = Math.min(Math.floor(done), total || Math.floor(done))
  // 完成态强制 100%（避免个别 track_done 丢失导致 97% 卡住）
  const percent = isCompleted
    ? 100
    : inQueue
      ? (qTotal > 0 ? Math.min(100, Math.round((qDone / qTotal) * 100)) : 0)
      : total > 0
        ? Math.min(100, Math.round((Math.min(done, total) / total) * 100))
        : 0

  const handleCancel = async () => {
    await cancelJob()
    toast.info(t('已取消下载任务'))
  }

  return (
    <div className="flex flex-col gap-4">
      {/* 顶部任务信息 */}
      <Card>
        <CardHeader>
          <div className="flex flex-wrap items-center gap-3">
            <CardTitle className="flex items-center gap-2 text-base">
              {isRunning && (
                <Loader2 className="size-4 animate-spin text-emerald-600 dark:text-emerald-400" />
              )}
              {activeJob.status === 'completed' && (
                <CheckCircle2 className="size-4 text-emerald-600 dark:text-emerald-400" />
              )}
              {activeJob.status === 'cancelled' && (
                <XCircle className="size-4 text-amber-500" />
              )}
              <span className="truncate">{activeJob.title ?? t('未命名任务')}</span>
            </CardTitle>
            <StatusBadge status={activeJob.status} className="ml-auto" />
            {isRunning && (
              <Button variant="outline" size="sm" onClick={handleCancel}>
                <XCircle className="size-4" />
                {t('取消')}
              </Button>
            )}
          </div>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
            <span className="font-mono">{activeJob.url}</span>
            <span>·</span>
            <span>📁 {activeJob.artistDir}</span>
            {activeJob.subfolder && activeJob.subfolder !== 'none' && (
              <>
                <span>/</span>
                <span>{activeJob.subfolder}</span>
              </>
            )}
            <span>·</span>
            <span>{activeJob.format.toUpperCase()}</span>
            <span>·</span>
            <span>
              {activeJob.coverMode === 'unified' ? t('统一封面') : t('独立封面')}
            </span>
          </div>

          <div className="flex items-center gap-3">
            <Progress
              value={percent}
              className="h-2.5 flex-1 bg-emerald-500/15 [&>div]:bg-emerald-600 dark:[&>div]:bg-emerald-500"
            />
            <span className="shrink-0 font-mono text-sm font-medium tabular-nums">
              {inQueue ? `${qDone}/${qTotal}` : `${shownDone}/${total}`}
            </span>
            <span className="shrink-0 w-12 text-right text-sm font-medium tabular-nums text-emerald-600 dark:text-emerald-400">
              {percent}%
            </span>
            {inQueue && (
              <span className="shrink-0 text-xs text-muted-foreground">
                {t('队列 {i}/{n}', { i: queueRun?.index ?? 0, n: queueRun?.total ?? 0 })}
              </span>
            )}
          </div>

          {activeJob.errorMessage && (
            <div className="rounded-md border border-rose-500/30 bg-rose-500/5 px-3 py-2 text-xs text-rose-700 dark:text-rose-300">
              ⚠ {activeJob.errorMessage}
            </div>
          )}
        </CardContent>
      </Card>

      {/* 实时日志 */}
      <Card className="overflow-hidden">
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-base">
            <span className="size-2 rounded-full bg-emerald-500 animate-pulse" />
            {t('实时日志')}
          </CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          <LogConsole logs={logs} className="max-h-96 min-h-64 rounded-b-xl" />
        </CardContent>
      </Card>

      {/* 底部操作 */}
      <div className="flex flex-wrap justify-end gap-2">
        <Button variant="outline" onClick={() => setTab('dashboard')}>
          <LayoutDashboard className="size-4" />
          {t('返回仪表盘')}
        </Button>
        {isCompleted && (
          <Button variant="outline" onClick={resetDownloadFlow}>
            <Music className="size-4" />
            {t('再下载一个')}
          </Button>
        )}
        <Button
          variant="outline"
          onClick={() => setTab('history')}
        >
          <HistoryIcon className="size-4" />
          {t('查看历史')}
        </Button>
      </div>
    </div>
  )
}
