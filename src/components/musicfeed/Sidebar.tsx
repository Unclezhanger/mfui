'use client'

import { useEffect, useState } from 'react'
import { useTheme } from 'next-themes'
import {
  LayoutDashboard,
  Download,
  History,
  Settings,
  Music,
  Sun,
  Moon,
  Github,
} from 'lucide-react'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Badge } from '@/components/ui/badge'
import { useMusicFeedStore } from '@/lib/store'
import { useT } from '@/lib/i18n'
import type { TabKey } from '@/lib/types'

const navItems: {
  key: TabKey
  label: string
  Icon: React.ComponentType<{ className?: string }>
}[] = [
  { key: 'dashboard', label: '仪表盘', Icon: LayoutDashboard },
  { key: 'download', label: '下载', Icon: Download },
  { key: 'history', label: '历史', Icon: History },
  { key: 'settings', label: '设置', Icon: Settings },
]

/**
 * 桌面端侧边栏：仅 md+ 显示
 * 包含 logo、垂直导航、底部主题/GitHub 按钮
 */
export function Sidebar() {
  const currentTab = useMusicFeedStore((s) => s.currentTab)
  const t = useT()
  const setTab = useMusicFeedStore((s) => s.setTab)
  const { theme, setTheme } = useTheme()
  // next-themes 推荐模式：客户端挂载后才读取实际 theme
  const [mounted, setMounted] = useState(false)

  useEffect(() => {
    setMounted(true)
  }, [])

  return (
    <aside className="sticky top-0 hidden h-screen w-60 flex-col gap-3 border-r border-border bg-sidebar p-4 md:flex">
      {/* Logo */}
      <div className="flex items-center gap-2 px-1 py-2">
        <img src="/logo.png" alt="mfui logo" className="size-9 rounded-lg shadow-sm" />
        <div className="flex flex-col">
          <span className="font-semibold leading-tight">mfui</span>
          <span className="text-[10px] text-muted-foreground">v4.4.2 · {t('内核')} v3.5.1</span>
        </div>
        <Badge
          variant="outline"
          className="ml-auto border-emerald-500/30 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"
        >
          Web UI
        </Badge>
      </div>

      {/* 导航 */}
      <nav className="flex flex-col gap-1">
        {navItems.map(({ key, label, Icon }) => {
          const active = currentTab === key
          return (
            <button
              key={key}
              onClick={() => setTab(key)}
              aria-current={active ? 'page' : undefined}
              className={cn(
                'group flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium transition-colors',
                active
                  ? 'bg-emerald-600 text-emerald-50 shadow-sm'
                  : 'text-muted-foreground hover:bg-accent hover:text-accent-foreground'
              )}
            >
              <Icon className="size-4 shrink-0" />
              <span>{t(label)}</span>
            </button>
          )
        })}
      </nav>

      <div className="mt-auto flex items-center gap-2 border-t border-border pt-3">
        <Button
          variant="ghost"
          size="icon"
          aria-label={t('切换主题')}
          onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')}
          className="text-muted-foreground hover:text-foreground"
        >
          {mounted && theme === 'dark' ? (
            <Sun className="size-4" />
          ) : (
            <Moon className="size-4" />
          )}
        </Button>
        <Button
          variant="ghost"
          size="icon"
          aria-label={t('GitHub 仓库')}
          asChild
          className="text-muted-foreground hover:text-foreground"
        >
          <a
            href="https://github.com/Unclezhanger/musicfeed"
            target="_blank"
            rel="noreferrer"
          >
            <Github className="size-4" />
          </a>
        </Button>
        <span className="ml-auto text-[10px] text-muted-foreground">
          © Unclezhanger
        </span>
      </div>
    </aside>
  )
}

/**
 * 移动端顶部 tab bar：仅 < md 显示
 * 紧凑的水平导航 + 主题切换
 */
export function MobileTabBar() {
  const currentTab = useMusicFeedStore((s) => s.currentTab)
  const t = useT()
  const setTab = useMusicFeedStore((s) => s.setTab)
  const { theme, setTheme } = useTheme()
  const [mounted, setMounted] = useState(false)

  useEffect(() => {
    setMounted(true)
  }, [])

  return (
    <div className="flex items-center gap-1 border-b border-border bg-sidebar px-2 py-2 md:hidden">
      <div className="flex size-7 items-center justify-center rounded-md bg-emerald-600 text-emerald-50">
        <Music className="size-4" />
      </div>
      <nav className="flex flex-1 items-center gap-1 overflow-x-auto">
        {navItems.map(({ key, label, Icon }) => {
          const active = currentTab === key
          return (
            <button
              key={key}
              onClick={() => setTab(key)}
              aria-current={active ? 'page' : undefined}
              className={cn(
                'flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-medium transition-colors',
                active
                  ? 'bg-emerald-600 text-emerald-50'
                  : 'text-muted-foreground hover:bg-accent hover:text-accent-foreground'
              )}
            >
              <Icon className="size-3.5" />
              <span className="whitespace-nowrap">{t(label)}</span>
            </button>
          )
        })}
      </nav>
      <Button
        variant="ghost"
        size="icon"
        aria-label={t('切换主题')}
        onClick={() => setTheme(theme === 'dark' ? 'light' : 'dark')}
        className="shrink-0 text-muted-foreground"
      >
        {mounted && theme === 'dark' ? (
          <Sun className="size-4" />
        ) : (
          <Moon className="size-4" />
        )}
      </Button>
    </div>
  )
}
