'use client'

import {
  CheckCircle2,
  XCircle,
  AlertTriangle,
  Terminal,
  Cpu,
  Music,
  Download,
  Activity,
  Plus,
  FolderOpen,
  Languages,
} from 'lucide-react'
import { motion } from 'framer-motion'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert'
import { Badge } from '@/components/ui/badge'
import { cn } from '@/lib/utils'
import { useMusicFeedStore } from '@/lib/store'
import { useT } from '@/lib/i18n'
import { UI_LANGUAGES } from '@/lib/i18n-dicts'
import { StatusBadge } from './StatusBadge'
import { LinkTypeBadge } from './LinkTypeBadge'

const depIcon = {
  ytdlp: Terminal,
  ffmpeg: Cpu,
  python3: Terminal,
  mutagen: Music,
  node: Cpu,
} as const

function fmtRelative(ts: string, t: (s: string, p?: Record<string, string | number>) => string) {
  const diff = Date.now() - new Date(ts).getTime()
  const min = Math.floor(diff / 60000)
  if (min < 60) return t('{n} 分钟前', { n: min })
  const hr = Math.floor(min / 60)
  if (hr < 24) return t('{n} 小时前', { n: hr })
  const day = Math.floor(hr / 24)
  return t('{n} 天前', { n: day })
}

export function Dashboard() {
  const { dependencies, config, jobs, setTab, uiLang } = useMusicFeedStore()
  const t = useT()

  const missingRequired = (Object.keys(dependencies) as Array<keyof typeof dependencies>).filter(
    (k) => dependencies[k].required && !dependencies[k].installed
  )

  const activeJobs = jobs.filter((j) => j.status === 'running')
  const today = new Date().toDateString()
  const todayCount = jobs.filter(
    (j) => new Date(j.createdAt).toDateString() === today
  ).length
  const recentJobs = jobs.slice(0, 5)

  return (
    <div className="flex flex-col gap-6">
      {missingRequired.length > 0 && (
        <Alert variant="destructive">
          <AlertTriangle className="size-4" />
          <AlertTitle>{t('缺失必需依赖')}</AlertTitle>
          <AlertDescription>
            {t('以下依赖未安装：')}{missingRequired.join(t('、'))}{t('。请在终端运行 ')}
            <code className="rounded bg-muted px-1 py-0.5 text-xs">bash mf_setup.sh</code>{' '}
            {t('完成安装，否则无法启动下载。')}
          </AlertDescription>
        </Alert>
      )}

      {/* 4 个统计卡片 */}
      <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard
          title={t('依赖状态')}
          icon={<Terminal className="size-4" />}
          value={`${5 - missingRequired.length}/5`}
          subtitle={t('必需依赖就绪')}
        >
          <div className="flex flex-wrap gap-1.5">
            {(Object.keys(dependencies) as Array<keyof typeof dependencies>).map((k) => {
              // 跳过非依赖字段（如 _debug 调试信息）
              if (k === '_debug' || k === 'caddy') return null
              const dep = dependencies[k]
              const Icon = depIcon[k]
              if (!Icon) return null
              return (
                <Badge
                  key={k}
                  variant="outline"
                  className={cn(
                    'gap-1',
                    dep.installed
                      ? 'border-emerald-500/30 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300'
                      : 'border-rose-500/30 bg-rose-500/10 text-rose-700 dark:text-rose-300'
                  )}
                  title={dep.version}
                >
                  <Icon className="size-3" />
                  {k}
                  {dep.installed ? (
                    <CheckCircle2 className="size-3" />
                  ) : (
                    <XCircle className="size-3" />
                  )}
                  {!dep.required && (
                    <span className="ml-1 text-[9px] opacity-70">{t('可选')}</span>
                  )}
                </Badge>
              )
            })}
          </div>
        </StatCard>

        <StatCard
          title={t('当前配置')}
          icon={<FolderOpen className="size-4" />}
          value={config.MF_AUDIO_FORMAT.toUpperCase()}
          subtitle={config.MF_BASE_DIR}
        >
          <div className="flex flex-wrap items-center gap-2 text-xs text-muted-foreground">
            <span className="inline-flex items-center gap-1">
              <Languages className="size-3" />
              {UI_LANGUAGES.find((l) => l.value === uiLang)?.label ?? 'English'}
            </span>
            <span>·</span>
            <span>{t('默认文件夹')}: {config.MF_DEFAULT_ARTIST_DIR}</span>
          </div>
        </StatCard>

        <StatCard
          title={t('活跃任务')}
          icon={<Activity className="size-4" />}
          value={String(activeJobs.length)}
          subtitle={activeJobs.length > 0 ? t('正在下载中…') : t('当前无任务')}
        >
          {activeJobs.length > 0 && (
            <div className="space-y-1">
              {activeJobs.map((j) => (
                <div key={j.id} className="text-xs text-muted-foreground">
                  <span className="truncate">{j.title}</span>
                  <span className="ml-2 text-emerald-500">
                    {j.downloadedCount}/{j.trackCount ?? '?'}
                  </span>
                </div>
              ))}
            </div>
          )}
        </StatCard>

        <StatCard
          title={t('今日下载')}
          icon={<Download className="size-4" />}
          value={String(todayCount)}
          subtitle={t('本日创建的任务数')}
        />
      </div>

      {/* 左：最近任务 / 右：快速开始 */}
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle className="text-base">{t('最近任务')}</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {recentJobs.length === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">
                {t('暂无任务')}
              </p>
            ) : (
              recentJobs.map((j) => (
                <div
                  key={j.id}
                  className="flex items-center gap-3 rounded-md border border-border bg-card/50 p-2.5 transition-colors hover:bg-accent"
                >
                  <div className="flex min-w-0 flex-1 flex-col gap-1">
                    <div className="flex items-center gap-2">
                      <span className="truncate text-sm font-medium">
                        {j.title ?? t('未命名')}
                      </span>
                      <LinkTypeBadge type={j.linkType} />
                    </div>
                    <span className="text-xs text-muted-foreground">
                      {fmtRelative(j.createdAt, t)} · {j.artistDir}
                    </span>
                  </div>
                  <StatusBadge status={j.status} />
                </div>
              ))
            )}
          </CardContent>
        </Card>

        <Card className="relative overflow-hidden">
          <CardHeader>
            <CardTitle className="text-base">{t('快速开始')}</CardTitle>
          </CardHeader>
          <CardContent className="flex flex-col items-center gap-4 py-6">
            <motion.button
              type="button"
              initial={{ scale: 0.9, opacity: 0 }}
              animate={{ scale: 1, opacity: 1 }}
              whileHover={{ scale: 1.1 }}
              whileTap={{ scale: 0.95 }}
              transition={{ duration: 0.4 }}
              aria-label={t('新建下载任务')}
              onClick={() => setTab('download')}
              className="flex size-16 cursor-pointer items-center justify-center rounded-full bg-emerald-600/15 text-emerald-600 transition-colors hover:bg-emerald-600/25 dark:text-emerald-400"
            >
              <Plus className="size-8" />
            </motion.button>
            <div className="space-y-1 text-center">
              <p className="text-sm font-medium">{t('粘贴 YouTube 链接开始下载')}</p>
              <p className="text-xs text-muted-foreground">
                {t('支持 YTM 专辑 / 电台 / 播放列表 / 单曲 / MV')}
              </p>
            </div>
            <Button
              size="lg"
              className="bg-emerald-600 text-white shadow-sm hover:bg-emerald-700 dark:bg-emerald-500 dark:text-emerald-950 dark:hover:bg-emerald-400"
              onClick={() => setTab('download')}
            >
              <Download className="size-4" />
              {t('开始下载')}
            </Button>
          </CardContent>
          <div className="pointer-events-none absolute -right-8 -top-8 size-32 rounded-full bg-emerald-500/10 blur-2xl" />
        </Card>
      </div>
    </div>
  )
}

function StatCard({
  title,
  value,
  subtitle,
  icon,
  children,
}: {
  title: string
  value: string
  subtitle?: string
  icon?: React.ReactNode
  children?: React.ReactNode
}) {
  return (
    <Card className="overflow-hidden">
      <CardHeader>
        <div className="flex items-center justify-between">
          <CardTitle className="text-xs font-medium text-muted-foreground">
            {title}
          </CardTitle>
          <span className="text-emerald-600 dark:text-emerald-400">{icon}</span>
        </div>
      </CardHeader>
      <CardContent>
        <div className="flex flex-col gap-2">
          <div>
            <span className="text-2xl font-bold tracking-tight">{value}</span>
            {subtitle && (
              <p className="mt-0.5 truncate text-xs text-muted-foreground" title={subtitle}>
                {subtitle}
              </p>
            )}
          </div>
          {children}
        </div>
      </CardContent>
    </Card>
  )
}
