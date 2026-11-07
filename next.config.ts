import type { NextConfig } from "next";
import { readFileSync } from "fs";

// 构建期注入应用版本号（Sidebar 徽章 + layout metadata），来源 package.json，
// bump 版本后界面自动跟随，不再需要手改 UI 字符串
const APP_VERSION = (() => {
  try {
    return (JSON.parse(readFileSync("./package.json", "utf8")) as { version?: string }).version ?? "0.0.0";
  } catch {
    return "0.0.0";
  }
})();

const nextConfig: NextConfig = {
  env: {
    NEXT_PUBLIC_APP_VERSION: APP_VERSION,
  },
  output: "standalone",
  /* config options here */
  typescript: {
    ignoreBuildErrors: true,
  },
  reactStrictMode: false,
  // 不对 /socket.io/* 的请求做 trailing slash 重定向，
  // 因为 socket.io client 会发 /socket.io/?EIO=4&transport=polling，
  // mini-service 的 socket.io server 只识别 /socket.io/ 带尾斜杠的请求。
  skipTrailingSlashRedirect: true,
  // Next.js 16 dev server cross-origin protection: LAN access to /_next/static/*
  // gets 403 unless the origin is whitelisted here (dev mode only, ignored in
  // production/Docker). Add your LAN IP here if you run `next dev` on a LAN box.
  allowedDevOrigins: ["localhost", "127.0.0.1"],
  async rewrites() {
    // Socket.io 通过 Next.js rewrites 转发到 mini-service (127.0.0.1:3001)
    // 前端用相对路径 io({ path: '/socket.io' })，浏览器只访问 Next.js 一个端口。
    // mini-service 只监听 127.0.0.1，不对外暴露，更安全。
    return [
      {
        source: '/socket.io/:path*',
        destination: 'http://127.0.0.1:3001/socket.io/:path*',
      },
    ]
  },
};

export default nextConfig;
