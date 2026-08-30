import { db } from '@/lib/db'
import type { Job, LinkType, JobStatus, CoverMode, AudioFormat, PlaylistMode, MvStrategy } from '@/lib/types'

/**
 * Prisma Job → API Job
 * - 时间戳转 ISO 字符串
 * - 枚举字段强类型化
 */
export function toApiJob(j: {
  id: string
  url: string
  linkType: string
  title: string | null
  artist: string | null
  trackCount: number | null
  artistDir: string
  subfolder: string | null
  coverMode: string
  albumArtist: string | null
  tracks: string
  format: string
  playlistMode: string | null
  mvStrategy: string | null
  status: string
  pid: number | null
  logFile: string | null
  downloadedCount: number
  errorMessage: string | null
  createdAt: Date
  startedAt: Date | null
  finishedAt: Date | null
}): Job {
  return {
    id: j.id,
    url: j.url,
    linkType: j.linkType as LinkType,
    title: j.title ?? undefined,
    artist: j.artist ?? undefined,
    trackCount: j.trackCount ?? undefined,
    artistDir: j.artistDir,
    subfolder: j.subfolder ?? undefined,
    coverMode: j.coverMode as CoverMode,
    albumArtist: j.albumArtist ?? undefined,
    tracks: j.tracks,
    format: j.format as AudioFormat,
    playlistMode: (j.playlistMode as PlaylistMode) ?? undefined,
    mvStrategy: (j.mvStrategy as MvStrategy) ?? undefined,
    status: j.status as JobStatus,
    pid: j.pid ?? undefined,
    logFile: j.logFile ?? undefined,
    downloadedCount: j.downloadedCount,
    errorMessage: j.errorMessage ?? undefined,
    createdAt: j.createdAt.toISOString(),
    startedAt: j.startedAt?.toISOString(),
    finishedAt: j.finishedAt?.toISOString(),
  }
}

export async function listJobs(): Promise<Job[]> {
  const rows = await db.job.findMany({
    orderBy: { createdAt: 'desc' },
  })
  return rows.map(toApiJob)
}

export async function getJob(id: string): Promise<Job | null> {
  const row = await db.job.findUnique({ where: { id } })
  return row ? toApiJob(row) : null
}

export async function deleteJobRow(id: string): Promise<boolean> {
  try {
    await db.job.delete({ where: { id } })
    return true
  } catch {
    return false
  }
}
