/* mfui 最小 Service Worker：直通模式（不缓存），仅满足 PWA 安装条件 */
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (e) => e.waitUntil(self.clients.claim()))
self.addEventListener('fetch', () => {
  /* 直通：不做任何拦截 */
})
