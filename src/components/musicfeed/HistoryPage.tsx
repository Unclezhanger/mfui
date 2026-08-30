'use client'

import { useState, useEffect, useCallback } from 'react'
import { toast } from 'sonner'
import {
  Trash2,
  FileText,
  History as HistoryIcon,
  Download,
  Loader2,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Card, CardContent } from '@/components/ui/card'
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Tabs, TabsList, TabsTrigger } from '@/components/ui/tabs'
import { Progress } from '@/components/ui/progress'
import { useT } from '@/lib/i18n'
import { useMusicFeedStore } from '@/lib/store'
import { fetchJobLogs } from '@/lib/api'
import type { Job, JobStatus, LogEntry } from '@/lib/types'
import { StatusBadge } from './StatusBadge'
import { LinkTypeBadge } from './LinkTypeBadge'
import { Badge } from '@/components/ui/badge'
import { LogConsole } from './LogConsole'

type FilterKey = 'all' | 'running' | 'completed' | 'failed'

function fmtDateTime(ts?: string) {
  if (!ts) return '—'
  try {
    return new Date(ts).toLocaleString('zh-CN', { hour12: false })
  } catch {
    return ts
  }
}

export function HistoryPage() {
  const t = useT()
  const { jobs, deleteJob, setTab, refreshJobs } = useMusicFeedStore()
  const [filter, setFilter] = useState<FilterKey>('all')
  const [logJob, setLogJob] = useState<Job | null>(null)
  const [logEntries, setLogEntries] = useState<LogEntry[]>([])
  const [logsLoading, setLogsLoading] = useState(false)
  const [confirmDelete, setConfirmDelete] = useState<Job | null>(null)

  useEffect(() => {
    void refreshJobs()
  }, [refreshJobs])

  const openLogs = useCallback(async (job: Job) => {
    setLogJob(job)
    setLogsLoading(true)
    setLogEntries([])
    try {
      const entries = await fetchJobLogs(job.id)
      setLogEntries(entries)
    } catch (e) {
      toast.error(t('加载日志失败：{m}', { m: e instanceof Error ? e.message : String(e) }))
    } finally {
      setLogsLoading(false)
    }
  }, [])

  const filtered = jobs.filter((j) => {
    if (filter === 'all') return true
    if (filter === 'running') return j.status === 'running' || j.status === 'pending'
    // 部分失败（completed + errorMessage）计入「失败/取消」，不计入「已完成」
    if (filter === 'completed') return j.status === 'completed' && !j.errorMessage
    if (filter === 'failed')
      return j.status === 'failed' || j.status === 'cancelled' || (j.status === 'completed' && !!j.errorMessage)
    return true
  })

  const handleConfirmDelete = async () => {
    if (!confirmDelete) return
    try {
      await deleteJob(confirmDelete.id)
      toast.success(t('已删除任务记录'))
      setConfirmDelete(null)
    } catch (e) {
      toast.error(t('删除失败：{m}', { m: e instanceof Error ? e.message : String(e) }))
    }
  }

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="flex items-center gap-2 text-lg font-semibold">
          <HistoryIcon className="size-5 text-emerald-600 dark:text-emerald-400" />
          {t('下载历史')}
        </h2>
        <Tabs value={filter} onValueChange={(v) => setFilter(v as FilterKey)}>
          <TabsList>
            <TabsTrigger value="all">{t("全部")}</TabsTrigger>
            <TabsTrigger value="running">{t("进行中")}</TabsTrigger>
            <TabsTrigger value="completed">{t("已完成")}</TabsTrigger>
            <TabsTrigger value="failed">{t("失败/取消")}</TabsTrigger>
          </TabsList>
        </Tabs>
      </div>

      <Card>
        <CardContent className="p-0">
          {filtered.length === 0 ? (
            <div className="flex flex-col items-center gap-3 py-16 text-center">
              <div className="flex size-12 items-center justify-center rounded-full bg-muted text-muted-foreground">
                <HistoryIcon className="size-6" />
              </div>
              <p className="text-sm text-muted-foreground">
                {t('还没有下载记录，去下载页开始吧')}
              </p>
              <Button
                variant="outline"
                onClick={() => setTab('download')}
                className="border-emerald-500/40 text-emerald-700 hover:bg-emerald-500/10 dark:text-emerald-300"
              >
                <Download className="size-4" />
                {t('开始下载')}
              </Button>
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead className="min-w-32">{t("标题")}</TableHead>
                  <TableHead>{t("类型")}</TableHead>
                  <TableHead>{t("歌手文件夹")}</TableHead>
                  <TableHead>{t("格式")}</TableHead>
                  <TableHead className="min-w-32">{t("进度")}</TableHead>
                  <TableHead>{t("状态")}</TableHead>
                  <TableHead className="min-w-36">{t("创建时间")}</TableHead>
                  <TableHead className="text-right">{t("操作")}</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {filtered.map((j) => {
                  const total = j.trackCount ?? 0
                  const percent = total > 0 ? (j.downloadedCount / total) * 100 : 0
                  return (
                    <TableRow key={j.id}>
                      <TableCell className="max-w-44">
                        <div className="flex flex-col">
                          <span className="truncate font-medium" title={j.title}>
                            {j.title ?? t('未命名')}
                          </span>
                          {j.artist && (
                            <span className="truncate text-xs text-muted-foreground">
                              {j.artist}
                            </span>
                          )}
                        </div>
                      </TableCell>
                      <TableCell>
                        <LinkTypeBadge type={j.linkType} />
                      </TableCell>
                      <TableCell className="text-sm">
                        <div className="flex flex-col">
                          <span className="truncate">{j.artistDir}</span>
                          {j.subfolder && j.subfolder !== 'none' && (
                            <span className="text-xs text-muted-foreground">
                              /{j.subfolder}
                            </span>
                          )}
                        </div>
                      </TableCell>
                      <TableCell>
                        <span className="font-mono text-xs uppercase">
                          {j.format}
                        </span>
                      </TableCell>
                      <TableCell>
                        <div className="flex items-center gap-2">
                          <Progress
                            value={percent}
                            className="h-1.5 w-16 bg-emerald-500/15 [&>div]:bg-emerald-600 dark:[&>div]:bg-emerald-500"
                          />
                          <span className="text-xs tabular-nums text-muted-foreground">
                            {j.downloadedCount}/{total || '?'}
                          </span>
                        </div>
                      </TableCell>
                      <TableCell>
                        <div className="flex items-center gap-1.5">
                          <StatusBadge status={j.status} />
                          {j.status === 'completed' && j.errorMessage && (
                            <Badge
                              variant="outline"
                              className="border-amber-500/30 bg-amber-500/10 text-[10px] text-amber-700 dark:text-amber-300"
                            >
                              {t('部分失败')}
                            </Badge>
                          )}
                        </div>
                      </TableCell>
                      <TableCell className="text-xs text-muted-foreground">
                        {fmtDateTime(j.createdAt)}
                      </TableCell>
                      <TableCell className="text-right">
                        <div className="flex justify-end gap-1">
                          <Button
                            variant="ghost"
                            size="icon"
                            aria-label={t("查看日志")}
                            onClick={() => void openLogs(j)}
                          >
                            <FileText className="size-4" />
                          </Button>
                          <Button
                            variant="ghost"
                            size="icon"
                            aria-label={t("删除")}
                            onClick={() => setConfirmDelete(j)}
                            className="text-rose-600 hover:bg-rose-500/10 hover:text-rose-700"
                          >
                            <Trash2 className="size-4" />
                          </Button>
                        </div>
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {/* 日志查看 Dialog */}
      <Dialog open={!!logJob} onOpenChange={(o) => !o && setLogJob(null)}>
        <DialogContent className="max-w-3xl p-0 sm:max-w-3xl">
          <DialogHeader className="px-6 pt-6">
            <DialogTitle className="flex items-center gap-2">
              <FileText className="size-4" />
              {logJob?.title ?? t('任务日志')}
            </DialogTitle>
            <DialogDescription>
              {logJob?.url}
            </DialogDescription>
          </DialogHeader>
          <div className="h-80 overflow-hidden rounded-b-lg border-t border-border">
            {logsLoading ? (
              <div className="flex h-full items-center justify-center gap-2 bg-zinc-950 text-zinc-400">
                <Loader2 className="size-4 animate-spin" />
                <span className="text-sm">{t('加载日志…')}</span>
              </div>
            ) : (
              <LogConsole logs={logEntries} className="h-full rounded-none" />
            )}
          </div>
        </DialogContent>
      </Dialog>

      {/* 删除确认 Dialog */}
      <Dialog
        open={!!confirmDelete}
        onOpenChange={(o) => !o && setConfirmDelete(null)}
      >
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle>{t('确认删除任务记录？')}</DialogTitle>
            <DialogDescription>
              {t('即将删除「{t}」的历史记录。此操作不可撤销，已下载的音频文件不会被删除。', { t: confirmDelete?.title ?? t('未命名') })}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setConfirmDelete(null)}>
              {t('取消')}
            </Button>
            <Button
              variant="destructive"
              onClick={() => void handleConfirmDelete()}
              className="bg-rose-600 hover:bg-rose-700"
            >
              <Trash2 className="size-4" />
              {t('删除')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  )
}

// export the JobStatus type re-exported for any callers
export type { JobStatus }
