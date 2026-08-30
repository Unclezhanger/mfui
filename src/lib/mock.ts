/**
 * musicfeed - Mock 数据
 * Task 6+7 阶段用，后端接入后由 API 替换。
 */
import type {
  Dependencies,
  Job,
  LinkPreview,
  LogEntry,
  MfConfig,
} from './types'

export const mockDependencies: Dependencies = {
  ytdlp: { installed: true, version: '2026.07.04', required: true },
  ffmpeg: { installed: true, version: '7.1.5', required: true },
  python3: { installed: true, version: '3.12.13', required: true },
  mutagen: { installed: true, version: '1.47.0', required: true },
  node: { installed: true, version: 'v24.18.0', required: false },
}

export const mockConfig: MfConfig = {
  MF_LANG: 'zh',
  MF_BASE_DIR: '/home/z/navidrome/music',
  MF_DEFAULT_ARTIST_DIR: 'musicfeed',
  MF_AUDIO_FORMAT: 'opus',
  MF_HIDDEN_DIRS: ['.DS_Store', '@eaDir', 'attachments'],
}

/** $MF_BASE_DIR 下可选的歌手文件夹（含默认 + 已有） */
export const mockFolders = [
  'musicfeed',
  '周杰伦',
  '林俊杰',
  '五月天',
  'Taylor Swift',
]

export const mockJobs: Job[] = [
  {
    id: 'j1',
    url: 'https://music.youtube.com/playlist?list=OLAK5uy_xxx',
    linkType: 'album',
    title: '范特西',
    artist: '周杰伦',
    trackCount: 10,
    artistDir: '周杰伦',
    coverMode: 'unified',
    albumArtist: '周杰伦',
    tracks: 'all',
    format: 'opus',
    status: 'completed',
    downloadedCount: 10,
    createdAt: '2026-01-15T10:00:00Z',
    startedAt: '2026-01-15T10:00:00Z',
    finishedAt: '2026-01-15T10:05:30Z',
  },
  {
    id: 'j2',
    url: 'https://www.youtube.com/watch?v=xxx',
    linkType: 'single',
    title: '晴天',
    artist: '周杰伦',
    trackCount: 1,
    artistDir: '周杰伦',
    coverMode: 'per-track',
    tracks: 'all',
    format: 'opus',
    status: 'running',
    downloadedCount: 0,
    createdAt: '2026-01-15T11:00:00Z',
    startedAt: '2026-01-15T11:00:00Z',
  },
  {
    id: 'j3',
    url: 'https://www.youtube.com/playlist?list=PLxxx',
    linkType: 'playlist',
    title: '我的歌单',
    trackCount: 25,
    artistDir: 'musicfeed',
    coverMode: 'per-track',
    tracks: '1,3,5-10',
    format: 'm4a',
    status: 'failed',
    errorMessage: 'HTTP 403: YouTube 反爬虫触发',
    downloadedCount: 3,
    createdAt: '2026-01-14T09:00:00Z',
  },
  {
    id: 'j4',
    url: 'https://www.youtube.com/watch?v=abc123',
    linkType: 'single',
    title: '稻香',
    artist: '周杰伦',
    trackCount: 1,
    artistDir: '周杰伦',
    subfolder: '魔杰座',
    coverMode: 'per-track',
    tracks: 'all',
    format: 'opus',
    status: 'completed',
    downloadedCount: 1,
    createdAt: '2026-01-13T15:20:00Z',
    startedAt: '2026-01-13T15:20:00Z',
    finishedAt: '2026-01-13T15:22:10Z',
  },
  {
    id: 'j5',
    url: 'https://music.youtube.com/playlist?list=RDCLAK5uy_yyy',
    linkType: 'ytm_radio',
    title: '今日推荐 Mix',
    trackCount: 50,
    artistDir: 'musicfeed',
    coverMode: 'per-track',
    tracks: 'all',
    format: 'opus',
    status: 'cancelled',
    downloadedCount: 12,
    createdAt: '2026-01-12T20:00:00Z',
    startedAt: '2026-01-12T20:00:00Z',
    finishedAt: '2026-01-12T20:15:00Z',
  },
]

/** 模拟的实时日志序列（startDownload 时按顺序 push） */
export const mockLogs: LogEntry[] = [
  { ts: '2026-01-15T10:00:00Z', level: 'info', msg: '🎵 musicfeed V3.2.0 启动' },
  { ts: '2026-01-15T10:00:01Z', level: 'info', event: 'job_start', msg: '📀 项目: 范特西' },
  { ts: '2026-01-15T10:00:02Z', level: 'info', event: 'meta_fetch', msg: '🎤 歌手: 周杰伦' },
  { ts: '2026-01-15T10:00:03Z', level: 'info', event: 'track_start', msg: '📥 [1/10] 双截棍' },
  {
    ts: '2026-01-15T10:00:30Z',
    level: 'success',
    event: 'track_done',
    msg: '✅ [1/10] 双截棍 完成 (2.3MB)',
  },
  {
    ts: '2026-01-15T10:00:31Z',
    level: 'info',
    event: 'track_start',
    msg: '📥 [2/10] 爱在西元前',
  },
  {
    ts: '2026-01-15T10:01:00Z',
    level: 'success',
    event: 'track_done',
    msg: '✅ [2/10] 爱在西元前 完成 (2.1MB)',
  },
  {
    ts: '2026-01-15T10:01:01Z',
    level: 'info',
    event: 'track_start',
    msg: '📥 [3/10] 简单爱',
  },
  {
    ts: '2026-01-15T10:01:30Z',
    level: 'success',
    event: 'track_done',
    msg: '✅ [3/10] 简单爱 完成 (2.5MB)',
  },
  {
    ts: '2026-01-15T10:01:31Z',
    level: 'info',
    event: 'cover',
    msg: '🖼️ 统一封面裁剪: cover.jpg',
  },
  {
    ts: '2026-01-15T10:02:00Z',
    level: 'success',
    event: 'cover_done',
    msg: '✅ 封面已嵌入全部曲目',
  },
  {
    ts: '2026-01-15T10:05:30Z',
    level: 'success',
    event: 'job_done',
    msg: '🎉 全部完成: 10/10',
  },
]

/** 预览接口的 mock 返回（download 页 step 1 用） */
export const mockPreview: LinkPreview = {
  ok: true,
  type: 'album',
  albumName: '范特西',
  artist: '周杰伦',
  trackCount: 10,
  hasMetadata: true,
  tracks: [
    { idx: 1, title: '双截棍', vid: 'vid1', hasMeta: true },
    { idx: 2, title: '爱在西元前', vid: 'vid2', hasMeta: true },
    { idx: 3, title: '简单爱', vid: 'vid3', hasMeta: true },
    { idx: 4, title: '忍者', vid: 'vid4', hasMeta: true },
    { idx: 5, title: '开不了口', vid: 'vid5', hasMeta: true },
    { idx: 6, title: '上海一九四三', vid: 'vid6', hasMeta: true },
    { idx: 7, title: '对不起', vid: 'vid7', hasMeta: true },
    { idx: 8, title: '威廉古堡', vid: 'vid8', hasMeta: true },
    { idx: 9, title: '双刀', vid: 'vid9', hasMeta: true },
    { idx: 10, title: '星晴', vid: 'vid10', hasMeta: true },
  ],
}

/**
 * 链接类型识别（与 bash get_link_type 一致）
 * mock 模式直接走客户端逻辑；真实环境由 API 调用 bash 函数。
 */
export function detectLinkType(url: string): LinkType {
  if (/OLAK5uy_/.test(url)) return 'album'
  if (/RDCLAK5uy_/.test(url)) return 'ytm_radio'
  if (/playlist\?list=PL/.test(url) || /playlist\?list=LM/.test(url)) return 'playlist'
  if (/youtube\.com\/playlist/.test(url)) return 'playlist'
  if (/watch\?v=/.test(url) || /youtu\.be\//.test(url)) return 'single'
  return 'unknown'
}
