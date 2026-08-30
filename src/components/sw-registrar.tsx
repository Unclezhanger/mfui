'use client'

import { useEffect } from 'react'

/**
 * 注册最小化 Service Worker（PWA 安装所需）。
 * SW 策略：纯直通（fetch 直接放行），不做缓存——下载器场景实时性优先，
 * 缓存反而容易造成任务状态滞后。将来需要离线壳再升级策略。
 */
export function ServiceWorkerRegistrar() {
  useEffect(() => {
    if ('serviceWorker' in navigator) {
      navigator.serviceWorker
        .register('/sw.js')
        .catch((e) => console.warn('[sw] register failed:', e))
    }
  }, [])
  return null
}
