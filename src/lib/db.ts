import { PrismaClient, type Prisma } from '@prisma/client'

const globalForPrisma = globalThis as unknown as {
  prisma: PrismaClient | undefined
}

// 与 job-runner 保持一致：默认只输出 warn / error，避免每次刷新页面都刷屏 SQL。
// 排查 SQL 时设置环境变量 MF_PRISMA_LOG_QUERY=1 才打开 query 日志（开发/生产均可）。
const log: Prisma.LogLevel[] =
  process.env.MF_PRISMA_LOG_QUERY === '1' ? ['query', 'warn', 'error'] : ['warn', 'error']

export const db = globalForPrisma.prisma ?? new PrismaClient({ log })

if (process.env.NODE_ENV !== 'production') globalForPrisma.prisma = db
