'use client'

import { useEffect } from 'react'
import { Sidebar, MobileTabBar } from '@/components/musicfeed/Sidebar'
import { Dashboard } from '@/components/musicfeed/Dashboard'
import { DownloadPage } from '@/components/musicfeed/DownloadPage'
import { HistoryPage } from '@/components/musicfeed/HistoryPage'
import { SettingsPage } from '@/components/musicfeed/SettingsPage'
import { useMusicFeedStore } from '@/lib/store'
import { useT } from '@/lib/i18n'
import type { TabKey } from '@/lib/types'

const titles: Record<TabKey, { title: string; desc: string }> = {
  dashboard: { title: '仪表盘', desc: '环境、任务一览' },
  download: { title: '下载', desc: '粘贴链接 → 配置 → 下载' },
  history: { title: '历史', desc: '所有下载任务记录' },
  settings: { title: '设置', desc: 'mf_config.sh 配置项' },
}

export default function Home() {
  const currentTab = useMusicFeedStore((s) => s.currentTab)
  const initialized = useMusicFeedStore((s) => s.initialized)
  const initApp = useMusicFeedStore((s) => s.initApp)
  const t = useT()
  const title = t(titles[currentTab].title)
  const desc = t(titles[currentTab].desc)

  useEffect(() => {
    if (!initialized) {
      void initApp()
    }
  }, [initialized, initApp])

  // 浏览器标签页标题跟随界面语言
  useEffect(() => {
    document.title = `mfui - ${title}`
  }, [title])

  return (
    <div className="flex min-h-screen flex-col bg-background text-foreground md:flex-row">
      {/* 桌面侧边栏 */}
      <Sidebar />

      {/* 主内容 */}
      <div className="flex min-h-screen flex-1 flex-col">
        {/* 顶部标题栏（PWA standalone：pt 追加 iOS 状态栏安全区，避免标题与时间重叠） */}
        <header className="sticky top-0 z-10 border-b border-border bg-background/80 px-4 pb-3 pt-[calc(env(safe-area-inset-top)+0.75rem)] backdrop-blur-sm md:px-6 md:py-4 md:pt-4">
          <div className="flex items-center gap-3">
            <div className="flex flex-col">
              <h1 className="text-lg font-semibold tracking-tight md:text-xl">
                {title}
              </h1>
              <p className="text-xs text-muted-foreground">{desc}</p>
            </div>
          </div>
        </header>

        {/* 移动端 tab bar */}
        <MobileTabBar />

        {/* 内容区 */}
        <main className="flex-1 px-4 py-6 md:px-6 md:py-8">
          <div className="mx-auto max-w-6xl">
            {currentTab === 'dashboard' && <Dashboard />}
            {currentTab === 'download' && <DownloadPage />}
            {currentTab === 'history' && <HistoryPage />}
            {currentTab === 'settings' && <SettingsPage />}
          </div>
        </main>

        {/* Sticky Footer */}
        <footer className="mt-auto border-t border-border bg-background/80 px-4 py-3 backdrop-blur-sm md:px-6">
          <div className="mx-auto flex max-w-6xl flex-wrap items-center justify-between gap-2 text-xs text-muted-foreground">
            <span>
              🎵 mfui v4.4.0 ·{' '}
              <a
                href="https://github.com/Unclezhanger/mfui"
                target="_blank"
                rel="noreferrer"
                className="text-emerald-600 hover:underline dark:text-emerald-400"
              >
                GitHub
              </a>
            </span>
            <span>Powered by yt-dlp · ffmpeg · python3+mutagen</span>
          </div>
        </footer>
      </div>
    </div>
  )
}
