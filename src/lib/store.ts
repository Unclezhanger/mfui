/**
 * musicfeed - zustand 全局 store
 *
 * Task 5+9：从 mock 切换到真实后端
 *  - initApp() 并发拉取 dependencies/config/jobs/folders
 *  - previewLink() 调 mini-service preview
 *  - startDownload() 调 createJob + subscribeJob（socket.io 实时日志）
 *  - cancelJob / saveConfig / deleteJob 走真实 API
 *
 * mock.ts 保留：仅 detectLinkType 用于客户端快速校验。
 */
'use client'

import { create } from 'zustand'
import type { UiLang } from './i18n'
import { detectLinkType } from './mock'
import * as api from './api'
import { subscribeJob, getSocket, type SubscribeHandlers } from './socket'
import type {
  AudioFormat,
  CoverMode,
  Dependencies,
  Job,
  LinkPreview,
  LogEntry,
  MfConfig,
  MvStrategy,
  PlaylistMode,
  TabKey,
} from './types'

// ---------- 默认空值（未 initApp 之前用） ----------

const emptyDeps: Dependencies = {
  ytdlp: { installed: false, required: true },
  ffmpeg: { installed: false, required: true },
  python3: { installed: false, required: true },
  mutagen: { installed: false, required: true },
  node: { installed: false, required: false },
}

const emptyConfig: MfConfig = {
  MF_LANG: 'zh',
  MF_BASE_DIR: '',
  MF_DEFAULT_ARTIST_DIR: 'musicfeed',
  MF_AUDIO_FORMAT: 'opus',
  MF_HIDDEN_DIRS: [],
  MF_YTDLP: 'yt-dlp',
  MF_NODE_PATH: '',
}

// ---------- 表单 ----------

interface DownloadFormState {
  url: string
  artistDir: string
  isNewFolder: boolean
  newFolderName: string
  coverMode: CoverMode
  albumArtist: string
  /** v4.1: 子文件夹开关（关 = 不建专辑层，直接下载到歌手文件夹） */
  subfolderEnabled: boolean
  subfolder: string
  format: AudioFormat
  playlistMode: PlaylistMode
  mvStrategy: MvStrategy
  /** v4.3: MV 播放列表「手动输入歌曲信息」开关（关 = 预填 uploader/歌名；开 = CLI 分支1 规则） */
  mvManualEdit: boolean
  /** v4.1: 单 MV 链接手动元数据（分支1），空 = 走视频默认值（分支2） */
  mvTitle: string
  mvArtist: string
  mvAlbum: string
  /** v4.3: MV 播放列表逐曲手动元数据，key=vid；未列出的 MV 曲目用视频默认值 */
  mvTracks: Record<string, { title: string; artist: string; album: string }>
}

interface DownloadQueueItem {
  url: string
  preview: LinkPreview
  form: DownloadFormState
  selectedTracks: number[]
}

const initialForm: DownloadFormState = {
  url: '',
  artistDir: 'musicfeed',
  isNewFolder: false,
  newFolderName: '',
  coverMode: 'unified',
  albumArtist: '',
  subfolderEnabled: true,
  subfolder: '',
  format: 'opus',
  playlistMode: 'mv',
  mvStrategy: 'manual',
  mvManualEdit: false,
  mvTitle: '',
  mvArtist: '',
  mvAlbum: '',
  mvTracks: {},
}

// ---------- MV 标题提取（与内核 extract_song_info 对齐，v4.3 去掉 " - " 拆分） ----------
// 书名号 → 引号 → 去前缀截 50 字符；都命中不了返回原标题
export function extractMvTitleGuess(raw: string): string {
  const book = raw.match(/《([^》]+)》/)
  if (book?.[1]?.trim()) return book[1].trim()
  const quote = raw.match(/"([^"]+)"/)
  if (quote?.[1]?.trim()) return quote[1].trim()
  const cleaned = raw
    .replace(/^【[^】]*】/, '')
    .replace(/^Stage: /, '')
    .replace(/^纯享[：:]/, '')
    .trim()
  return cleaned.slice(0, 50) || raw
}

// mv-meta 串：VID=T=A=AL;...（字段内 | = ; 必须替换为全角，与 CLI 一致）
function sanitizeMvField(v: string): string {
  return v.replace(/\|/g, '｜').replace(/=/g, '＝').replace(/;/g, '；')
}

/** 歌手名 = 所选歌手文件夹名称（新建文件夹时用输入的名字） */
export function artistDirName(form: { isNewFolder: boolean; newFolderName: string; artistDir: string }): string {
  return (form.isNewFolder ? form.newFolderName : form.artistDir).trim()
}

// v4.3: MV（单曲/播放列表通用）预填 —— 两种模式（对齐 CLI 分支1/分支2）：
//   手动输入关（默认，分支2 语义）：不做标题拆分——歌手 = 视频上传频道名，歌名 = 完整原始标题，专辑 = 原始标题
//   手动输入开（分支1 语义）：歌手 = 所选歌手文件夹名，歌名 = 《》提取（引号 → 去前缀截断 → fallback 标题），专辑 = 歌名
// 有 YTM 元数据（hasMeta）的曲目不进 mvMeta，由内核自动抓 meta。
export function guessMvTrackInfo(
  t: { title: string; uploader?: string },
  manual: boolean,
  artistDir: string,
): { title: string; artist: string; album: string } {
  if (manual) {
    const title = extractMvTitleGuess(t.title)
    return { title, artist: artistDir, album: title }
  }
  return { title: t.title, artist: t.uploader?.trim() || '', album: t.title }
}

function buildMvMeta(preview: LinkPreview, selected: number[], form: DownloadFormState): string | undefined {
  if (preview.type !== 'playlist' || form.playlistMode !== 'mv') return undefined
  const parts: string[] = []
  const dirName = artistDirName(form)
  for (const t of preview.tracks ?? []) {
    if (t.hasMeta || !selected.includes(t.idx) || !t.vid) continue
    const edit = form.mvTracks[t.vid]
    const guess = guessMvTrackInfo(t, form.mvManualEdit, dirName)
    const title = sanitizeMvField(edit?.title?.trim() || guess.title)
    const artist = sanitizeMvField(edit?.artist?.trim() || guess.artist || '')
    const album = sanitizeMvField(edit?.album?.trim() || title)
    parts.push(`${t.vid}=${title}=${artist}=${album}`)
  }
  return parts.length > 0 ? parts.join(';') : undefined
}

// v4.1: 队列共用的日志文件名（日期时间，如 20260827-153045）
function tsRunId(): string {
  const d = new Date()
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`
}

// ---------- 多链接队列聚合进度 ----------
// 队列逐个启动任务时，跨任务累计已完成曲目数，前端显示「队列 i/N + 总进度」
interface QueueRunState {
  total: number
  index: number
  doneTracks: number
  totalTracks: number
}

// ---------- 任务状态轮询兜底 ----------
// socket.io 事件在极端情况下可能丢失（dev 模式 rewrites 不支持 WebSocket upgrade、
// 断线重连后 room 订阅失效等），轮询保证 activeJob 最终收敛到真实状态。
let jobPollTimer: ReturnType<typeof setInterval> | null = null

function stopJobPolling() {
  if (jobPollTimer) {
    clearInterval(jobPollTimer)
    jobPollTimer = null
  }
}

function cloneForm(form: DownloadFormState): DownloadFormState {
  return { ...form }
}

function startJobPolling(jobId: string) {
  stopJobPolling()
  jobPollTimer = setInterval(async () => {
    try {
      const job = await api.fetchJob(jobId)
      const s = useMusicFeedStore.getState()
      if (!s.activeJob || s.activeJob.id !== jobId) {
        stopJobPolling()
        return
      }
      if (job.status !== 'running' && job.status !== 'pending') {
        stopJobPolling()
        useMusicFeedStore.setState({ activeJob: job, activeFrac: 0 })
        void useMusicFeedStore.getState().refreshJobs()
      } else {
        // 后处理开始后（有 track_done 入库）平滑小数失效，归零防虚高
        useMusicFeedStore.setState((s) => ({
          activeJob: job,
          activeFrac: job.downloadedCount > 0 ? 0 : s.activeFrac,
        }))
      }
    } catch {
      // 网络抖动等临时错误：保留轮询，下次再试
    }
  }, 4000)
}

// ---------- store 接口 ----------

interface MusicFeedState {
  currentTab: TabKey
  setTab: (tab: TabKey) => void

  // WebUI 界面语言（独立于 mf_config 的 MF_LANG；localStorage 持久化，默认英文）
  uiLang: UiLang
  setUiLang: (lang: UiLang) => void

  // 下载向导：预览成功后停在选曲步骤，用户点「下一步」才进配置
  confirmTracks: boolean
  setConfirmTracks: (b: boolean) => void

  // 静态资源
  dependencies: Dependencies
  folders: string[]
  baseDirExists: boolean
  jobs: Job[]
  initialized: boolean
  initApp: () => Promise<void>
  refreshJobs: () => Promise<void>

  // config
  config: MfConfig
  setConfig: (cfg: Partial<MfConfig>) => void
  resetConfig: () => void
  saveConfig: () => Promise<void>

  // 表单
  form: DownloadFormState
  setForm: (patch: Partial<DownloadFormState>) => void
  resetForm: () => void
  initDownloadQueue: (urls: string[]) => Promise<void>
  advanceDownloadQueue: () => Promise<boolean>
  hasDownloadQueueNext: () => boolean
  startQueuedDownloads: () => Promise<void>

  // 预览
  preview: LinkPreview | null
  previewLoading: boolean
  setPreviewLoading: (b: boolean) => void
  setPreview: (p: LinkPreview | null) => void
  previewLink: (url: string) => Promise<void>

  // 选中曲目
  selectedTracks: number[]
  toggleTrack: (idx: number) => void
  selectAllTracks: () => void
  clearTracks: () => void
  setSelectedTracks: (arr: number[]) => void

  // 活动任务 + 日志
  activeJob: Job | null
  /** 下载阶段平滑进度小数（0-1），来自 ytdlp_frac 事件；后处理阶段为 0 */
  activeFrac: number
  logs: LogEntry[]
  unsubscribeSocket: (() => void) | null
  queueUrls: string[]
  queueIndex: number
  queueDrafts: DownloadQueueItem[]
  /** 多链接队列聚合进度（非队列下载时为 null） */
  queueRun: QueueRunState | null
  startDownload: (baseOffset?: number, grandTotal?: number, logId?: string) => Promise<void>
  cancelJob: () => Promise<void>
  resetDownloadFlow: () => void
  appendLog: (entry: LogEntry) => void
  setProgress: (downloadedCount: number) => void

  // history
  deleteJob: (id: string) => Promise<void>
}

export const useMusicFeedStore = create<MusicFeedState>((set, get) => ({
  currentTab: 'dashboard',
  uiLang: 'en',
  setUiLang: (lang) => {
    if (typeof window !== 'undefined') window.localStorage.setItem('mfui-ui-lang', lang)
    set({ uiLang: lang })
  },
  setTab: (tab) => set({ currentTab: tab }),

  confirmTracks: false,
  setConfirmTracks: (b) => set({ confirmTracks: b }),

  dependencies: emptyDeps,
  folders: [],
  baseDirExists: true,
  jobs: [],
  initialized: false,

  initApp: async () => {
    if (get().initialized) return
    // 界面语言从 localStorage 恢复（默认英文；不写 mf_config.sh，与内核语言解耦）
    const stored = typeof window !== 'undefined' ? window.localStorage.getItem('mfui-ui-lang') : null
    set({ uiLang: (stored as UiLang | null) ?? 'en' })
    // allSettled：任何一个接口失败不拖垮其余数据
    // （dev 模式首次访问各 API route 需要现编译，局域网首开可能有个别请求超时）
    const [depsR, cfgR, foldersR, jobsR] = await Promise.allSettled([
      api.fetchDependencies(),
      api.fetchConfig(),
      api.fetchFolders(),
      api.fetchJobs(),
    ])
    const deps = depsR.status === 'fulfilled' ? depsR.value : emptyDeps
    const cfg = cfgR.status === 'fulfilled' ? cfgR.value : { ...emptyConfig }
    const foldersRes =
      foldersR.status === 'fulfilled' ? foldersR.value : { folders: [], exists: true }
    const jobs = jobsR.status === 'fulfilled' ? jobsR.value : []
    set((s) => ({
      dependencies: deps,
      config: cfg,
      folders: foldersRes.folders,
      baseDirExists: foldersRes.exists,
      jobs,
      initialized: true,
      // 表单默认歌手文件夹 = 配置里的 MF_DEFAULT_ARTIST_DIR（未被用户改动过才回填）
      form: {
        ...s.form,
        artistDir:
          s.form.artistDir === 'musicfeed' || !s.form.artistDir
            ? cfg.MF_DEFAULT_ARTIST_DIR || 'musicfeed'
            : s.form.artistDir,
      },
    }))
    // 触发 socket 预连接（提升首屏体验；getSocket 异步，但不阻塞 init）
    try {
      void getSocket()
    } catch {}
    // 有失败的请求打日志，便于排查（比如局域网首开编译超时）
    for (const [name, r] of [
      ['dependencies', depsR],
      ['config', cfgR],
      ['folders', foldersR],
      ['jobs', jobsR],
    ] as const) {
      if (r.status === 'rejected') console.error(`[initApp] ${name} failed:`, r.reason)
    }
  },

  refreshJobs: async () => {
    try {
      const jobs = await api.fetchJobs()
      set({ jobs })
    } catch (e) {
      console.error('[refreshJobs] failed:', e)
    }
  },

  config: { ...emptyConfig },
  setConfig: (cfg) => set((s) => ({ config: { ...s.config, ...cfg } })),
  resetConfig: () => set({ config: { ...emptyConfig } }),
  saveConfig: async () => {
    const cfg = get().config
    try {
      const updated = await api.updateConfig(cfg)
      set({ config: updated })
      // 同步刷新 folders
      const foldersRes = await api.fetchFolders()
      set({ folders: foldersRes.folders, baseDirExists: foldersRes.exists })
    } catch (e) {
      console.error('[saveConfig] failed:', e)
      throw e
    }
  },

  form: { ...initialForm },
  setForm: (patch) => set((s) => ({ form: { ...s.form, ...patch } })),
  // 重置时保留链接，歌手文件夹回填配置里的默认值（MF_DEFAULT_ARTIST_DIR）
  resetForm: () =>
    set((s) => ({
      form: {
        ...initialForm,
        url: s.form.url,
        artistDir: s.config.MF_DEFAULT_ARTIST_DIR || 'musicfeed',
      },
    })),

  initDownloadQueue: async (urls) => {
    const cleanUrls = urls.map((u) => u.trim()).filter(Boolean)
    if (cleanUrls.length === 0) return
    const firstUrl = cleanUrls[0]
    set({
      queueUrls: cleanUrls,
      queueIndex: 0,
      queueDrafts: [],
      // v4.1: 队列也停在选曲步骤（confirmTracks=false），恢复多链接选曲
      confirmTracks: false,
      previewLoading: true,
    })
    try {
      const p = await api.previewLink(firstUrl)
      if (!p.ok || !p.type) throw new Error(p.error || 'preview failed')
      set((s) => ({
        preview: p,
        previewLoading: false,
        selectedTracks: p.tracks?.map((t) => t.idx) ?? [],
        form: {
          ...s.form,
          url: firstUrl,
        },
      }))
    } catch (e) {
      set({ previewLoading: false })
      throw e
    }
  },

  advanceDownloadQueue: async () => {
    const state = get()
    if ((state.queueUrls?.length ?? 0) <= 1) return false
    if (!state.preview || !state.preview.type) return false

    const currentDraft: DownloadQueueItem = {
      url: state.form.url,
      preview: state.preview,
      form: cloneForm(state.form),
      selectedTracks: [...state.selectedTracks],
    }
    const nextIndex = state.queueIndex + 1
    const nextUrl = state.queueUrls[nextIndex]
    if (!nextUrl) return false

    const nextPreview = await api.previewLink(nextUrl)
    if (!nextPreview.ok || !nextPreview.type) {
      throw new Error(nextPreview.error || `preview failed for ${nextUrl}`)
    }

    set((s) => ({
      queueDrafts: [...s.queueDrafts, currentDraft],
      queueIndex: nextIndex,
      preview: nextPreview,
      selectedTracks: nextPreview.tracks?.map((t) => t.idx) ?? [],
      // 停在选曲步骤，逐链接确认曲目
      confirmTracks: false,
      previewLoading: false,
      form: {
        ...initialForm,
        artistDir: s.config.MF_DEFAULT_ARTIST_DIR || 'musicfeed',
        url: nextUrl,
      },
    }))
    return true
  },

  hasDownloadQueueNext: () => {
    const s = get()
    return (s.queueUrls?.length ?? 0) > s.queueIndex + 1
  },

  startQueuedDownloads: async () => {
    const state = get()
    const drafts: DownloadQueueItem[] = [...(state.queueDrafts ?? [])]
    if (state.preview && state.preview.type) {
      drafts.push({
        url: state.form.url,
        preview: state.preview,
        form: cloneForm(state.form),
        selectedTracks: [...state.selectedTracks],
      })
    }
    if (drafts.length === 0) {
      await get().startDownload()
      return
    }

    // v4.1: 队列聚合 —— 总曲目数 = 各链接选中数之和，日志跨任务连续不重置；
    // 整个队列共用一个日期时间命名的 log 文件；任务严格串行（等前一个终态再启动）
    const tracksOf = (d: DownloadQueueItem) =>
      d.selectedTracks.length || d.preview.trackCount || 0
    const totalTracks = drafts.reduce((acc, d) => acc + tracksOf(d), 0)
    const runId = tsRunId()
    set({ queueRun: { total: drafts.length, index: 0, doneTracks: 0, totalTracks } })

    let baseOffset = 0
    for (let i = 0; i < drafts.length; i++) {
      const draft = drafts[i]
      set((s) => ({
        preview: draft.preview,
        form: draft.form,
        selectedTracks: draft.selectedTracks,
        confirmTracks: true,
        queueRun: s.queueRun ? { ...s.queueRun, index: i + 1 } : s.queueRun,
      }))
      await get().startDownload(baseOffset, totalTracks, runId)
      baseOffset += tracksOf(draft)
    }
  },

  preview: null,
  previewLoading: false,
  setPreviewLoading: (b) => set({ previewLoading: b }),
  setPreview: (p) => set({ preview: p }),

  previewLink: async (url) => {
    set({ previewLoading: true, confirmTracks: false })
    try {
      const p = await api.previewLink(url)
      set({ preview: p })
      if (p.ok && p.tracks?.length) {
        // 默认全选
        set({ selectedTracks: p.tracks.map((t) => t.idx) })
      }
    } finally {
      set({ previewLoading: false })
    }
  },

  selectedTracks: [],
  toggleTrack: (idx) =>
    set((s) => {
      const exists = s.selectedTracks.includes(idx)
      return {
        selectedTracks: exists
          ? s.selectedTracks.filter((i) => i !== idx)
          : [...s.selectedTracks, idx].sort((a, b) => a - b),
      }
    }),
  selectAllTracks: () =>
    set((s) => ({
      selectedTracks:
        s.preview?.tracks?.map((t) => t.idx) ?? [],
    })),
  clearTracks: () => set({ selectedTracks: [] }),
  setSelectedTracks: (arr) => set({ selectedTracks: [...arr].sort((a, b) => a - b) }),

  activeJob: null,
  activeFrac: 0,
  logs: [],
  unsubscribeSocket: null,
  queueUrls: [],
  queueIndex: 0,
  queueDrafts: [],

  appendLog: (entry) =>
    set((s) => ({ logs: [...s.logs, entry] })),

  setProgress: (downloadedCount) =>
    set((s) => ({
      activeJob: s.activeJob
        ? {
            ...s.activeJob,
            downloadedCount: s.activeJob.trackCount
              ? Math.min(downloadedCount, s.activeJob.trackCount)
              : downloadedCount,
          }
        : s.activeJob,
    })),

  resetDownloadFlow: () => {
    stopJobPolling()
    const unsubscribeSocket = get().unsubscribeSocket
    if (unsubscribeSocket) unsubscribeSocket()
    set({
      activeJob: null,
      activeFrac: 0,
      logs: [],
      unsubscribeSocket: null,
      preview: null,
      previewLoading: false,
      confirmTracks: false,
      selectedTracks: [],
      queueUrls: [],
      queueIndex: 0,
      queueDrafts: [],
      queueRun: null,
      // v4.1: 表单也回到初始值（上次链接/文件夹选择不留存），歌手文件夹回填配置默认
      form: {
        ...initialForm,
        artistDir: get().config.MF_DEFAULT_ARTIST_DIR || 'musicfeed',
      },
    })
  },

  queueRun: null,

  startDownload: async (baseOffset = 0, grandTotal = 0, logId?: string) => {
    const state = get()
    const { preview, form, selectedTracks } = state
    if (!preview || !preview.type) return

    // 队列模式下日志连续合并（跨任务不重置）
    const inQueue = state.queueRun !== null

    // 取消旧订阅
    if (state.unsubscribeSocket) {
      state.unsubscribeSocket()
      set({ unsubscribeSocket: null })
    }

    const tracksStr =
      selectedTracks.length === preview.tracks?.length
        ? 'all'
        : selectedTracks.join(',')

    const artistDir = form.isNewFolder ? form.newFolderName.trim() : form.artistDir
    if (!artistDir) {
      throw new Error('artistDir is empty')
    }

    // 部分选择时总数按选中数算（否则进度永远到不了 100%）
    const effectiveTotal = selectedTracks.length || preview.trackCount || 0
    // UI 语义：专辑艺术家留空 = 不写入（mf_batch.sh 用 "skip" 表示跳过；
    // 不传参会默认用文件夹名，那是 CLI 时代的行为，与 Web UI 提示不符）
    // v4.3: 单曲也支持专辑艺术家（留空同样 skip）
    const effectiveAlbumArtist =
      (preview.type === 'album' || preview.type === 'single') && form.albumArtist.trim()
        ? form.albumArtist.trim()
        : 'skip'

    // v4.1: 子文件夹开关 —— 关 = "none"（mf_batch 不建专辑层，直接下载到歌手文件夹）
    const effectiveSubfolder = form.subfolderEnabled
      ? form.subfolder.trim() || undefined
      : 'none'

    // v4.3: MV 播放列表逐曲元数据（非空即 manual 分支）
    const mvMetaStr = buildMvMeta(preview, selectedTracks, form)

    // 临时设置 activeJob（pending），等真实 jobId 回填
    const tempId = `pending-${Date.now()}`
    const now = new Date().toISOString()
    const tempJob: Job = {
      id: tempId,
      url: form.url,
      linkType: preview.type,
      title: preview.albumName,
      artist: preview.artist,
      trackCount: effectiveTotal,
      artistDir,
      // v4.1: 开关关闭时不显示子文件夹；开启未自定义 = 专辑名（后端默认）
      subfolder: form.subfolderEnabled ? form.subfolder.trim() || undefined : undefined,
      coverMode: form.coverMode,
      albumArtist:
        (preview.type === 'album' || preview.type === 'single') && form.albumArtist.trim()
          ? form.albumArtist.trim()
          : undefined,
      tracks: tracksStr,
      format: form.format,
      playlistMode: preview.type === 'playlist' ? form.playlistMode : undefined,
      mvStrategy: undefined,
      status: 'pending',
      downloadedCount: 0,
      createdAt: now,
    }
    // 队列模式下日志连续（多任务合并成一条流），单任务才清空
    set(inQueue ? { activeJob: tempJob, activeFrac: 0 } : { activeJob: tempJob, activeFrac: 0, logs: [] })

    try {
      const { jobId } = await api.createJob({
        url: form.url,
        artistDir,
        subfolder: effectiveSubfolder,
        coverMode: form.coverMode,
        albumArtist: effectiveAlbumArtist,
        tracks: tracksStr,
        format: form.format,
        playlistMode: preview.type === 'playlist' ? form.playlistMode : undefined,
        // v4.1: 单 MV 手动元数据（分支1）——开关开启且填了歌名才走 manual；
        // 开关关闭时不传 → 内核默认分支（歌手=uploader，歌名/专辑=完整标题）
        mvTitle:
          preview.type === 'single' && form.mvManualEdit && form.mvTitle.trim()
            ? form.mvTitle.trim()
            : undefined,
        mvArtist:
          preview.type === 'single' && form.mvManualEdit && form.mvTitle.trim()
            ? form.mvArtist.trim() || undefined
            : undefined,
        mvAlbum:
          preview.type === 'single' && form.mvManualEdit && form.mvTitle.trim()
            ? form.mvAlbum.trim() || undefined
            : undefined,
        // v4.3: MV 播放列表逐曲元数据（有内容即 manual 分支，逐曲重命名）
        mvMeta: mvMetaStr,
        mvStrategy: mvMetaStr ? 'manual' : undefined,
        logId,
        lang: state.config.MF_LANG,
        title: preview.albumName,
        artist: preview.artist,
        linkType: preview.type,
        trackCount: effectiveTotal || null,
      })

      // 拉一次后端最新状态，回填 id 等真实字段
      const realJob = await api.fetchJob(jobId)
      set({ activeJob: { ...realJob, status: 'running' } })

      // 订阅 socket
      // v4.1: 队列串行 —— 三个终态 handler 都会 resolve terminal promise
      let resolveTerminal: () => void = () => {}
      const handlers: SubscribeHandlers = {
        onLog: (entry) => {
          set((s) => ({ logs: [...s.logs, entry] }))
        },
        onProgress: (p) => {
          set((s) => ({
            activeJob: s.activeJob
              ? {
                  ...s.activeJob,
                  downloadedCount: p.downloadedCount,
                  trackCount: p.trackCount ?? s.activeJob.trackCount,
                }
              : s.activeJob,
            activeFrac: p.frac ?? 0,
            // 队列聚合：已完成 = 前序链接完成数 + 当前任务完成数
            queueRun:
              s.queueRun && grandTotal > 0
                ? { ...s.queueRun, doneTracks: baseOffset + p.downloadedCount }
                : s.queueRun,
          }))
        },
        onDone: async () => {
          stopJobPolling()
          useMusicFeedStore.setState({ activeFrac: 0 })
          // 队列聚合：当前任务完成，计入全部选中曲目
          useMusicFeedStore.setState((s) => ({
            queueRun:
              s.queueRun && grandTotal > 0
                ? { ...s.queueRun, doneTracks: baseOffset + effectiveTotal }
                : s.queueRun,
          }))
          // 拉最终状态
          try {
            const finalJob = await api.fetchJob(jobId)
            set({
              activeJob: { ...finalJob, status: 'completed' },
            })
          } catch (e) {
            console.error('[onDone] fetchJob failed:', e)
          }
          // 刷新 jobs 列表
          void get().refreshJobs()
          resolveTerminal()
        },
        onError: async (p) => {
          stopJobPolling()
          useMusicFeedStore.setState({ activeFrac: 0 })
          try {
            const finalJob = await api.fetchJob(jobId)
            set({
              activeJob: {
                ...finalJob,
                status: finalJob.status === 'completed' ? 'failed' : finalJob.status,
                errorMessage: p.message ?? finalJob.errorMessage,
              },
            })
          } catch (e) {
            console.error('[onError] fetchJob failed:', e)
          }
          void get().refreshJobs()
          resolveTerminal()
        },
        onCancelled: async () => {
          stopJobPolling()
          useMusicFeedStore.setState({ activeFrac: 0 })
          try {
            const finalJob = await api.fetchJob(jobId)
            set({ activeJob: { ...finalJob, status: 'cancelled' } })
          } catch (e) {
            console.error('[onCancelled] fetchJob failed:', e)
          }
          void get().refreshJobs()
          resolveTerminal()
        },
      }
      const unsub = await subscribeJob(jobId, handlers)
      set({ unsubscribeSocket: unsub })
      // socket 事件丢失时的兜底：轮询任务状态直到终态
      startJobPolling(jobId)

      // v4.1: 队列串行 —— 等终态（完成/失败/取消）才返回；
      // socket 断连时由 activeJob 状态轮询兜底解锁
      await new Promise<void>((r) => {
        resolveTerminal = r
        const t = setInterval(() => {
          const aj = get().activeJob
          if (aj && aj.id === jobId && aj.status !== 'running' && aj.status !== 'pending') {
            clearInterval(t)
            r()
          }
        }, 4000)
      })
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      set((s) => ({
        activeJob: s.activeJob
          ? {
              ...s.activeJob,
              status: 'failed',
              errorMessage: msg,
              finishedAt: new Date().toISOString(),
            }
          : s.activeJob,
      }))
      throw e
    }
  },

  cancelJob: async () => {
    const state = get()
    const { activeJob, unsubscribeSocket } = state
    if (!activeJob) return
    if (activeJob.id.startsWith('pending-')) {
      // 还没拿到真实 id
      return
    }
    try {
      await api.cancelJob(activeJob.id)
    } catch (e) {
      console.error('[cancelJob] failed:', e)
    }
    stopJobPolling()
    if (unsubscribeSocket) {
      unsubscribeSocket()
      set({ unsubscribeSocket: null })
    }
    set((s) => ({
      activeJob: s.activeJob
        ? {
            ...s.activeJob,
            status: 'cancelled',
            finishedAt: new Date().toISOString(),
          }
        : s.activeJob,
    }))
    void get().refreshJobs()
  },

  deleteJob: async (id) => {
    try {
      await api.deleteJob(id)
      set((s) => ({ jobs: s.jobs.filter((j) => j.id !== id) }))
    } catch (e) {
      console.error('[deleteJob] failed:', e)
      throw e
    }
  },
}))
