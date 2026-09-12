'use client'

import { useEffect, useState } from 'react'
import { useTheme } from 'next-themes'
import {
  LayoutDashboard,
  Download,
  History,
  Settings,
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
          <span className="text-[10px] text-muted-foreground">
            {/* 版本号即仓库入口：WebUI 版本 → mfui 仓库，内核版本 → musicfeed 仓库 */}
            <a
              href="https://github.com/Unclezhanger/mfui"
              target="_blank"
              rel="noreferrer"
              className="hover:text-foreground hover:underline"
            >
              v4.4.4
            </a>
            {' · '}
            <a
              href="https://github.com/Unclezhanger/musicfeed"
              target="_blank"
              rel="noreferrer"
              className="hover:text-foreground hover:underline"
            >
              {t('内核')} v3.5.2
            </a>
          </span>
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
        {/* 双仓库入口：GitHub 图标 + 产品名，点击跳转对应仓库（版权标移至主页面页脚） */}
        <a
          href="https://github.com/Unclezhanger/mfui"
          target="_blank"
          rel="noreferrer"
          aria-label="mfui GitHub"
          className="ml-auto flex items-center gap-1 rounded-md px-1.5 py-1 text-xs text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
        >
          <Github className="size-3.5" />
          mfui
        </a>
        <a
          href="https://github.com/Unclezhanger/musicfeed"
          target="_blank"
          rel="noreferrer"
          aria-label="musicfeed GitHub"
          className="flex items-center gap-1 rounded-md px-1.5 py-1 text-xs text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
        >
          <Github className="size-3.5" />
          musicfeed
        </a>
        <span className="ml-auto text-[10px] text-muted-foreground">
          {/* 版权标已移至主内容区页脚右下角 */}
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
    <div className="flex items-center gap-1.5 border-b border-border bg-sidebar px-2 py-2 md:hidden">
      {/* 项目 logo（替代绿色音符图标），iOS 风格圆角 */}
      <img
        src="/logo.png"
        alt="mfui logo"
        className="size-9 shrink-0 rounded-xl shadow-sm"
      />
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
