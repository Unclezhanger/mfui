/**
 * musicfeed - 共享 TypeScript 类型
 * 前后端共享，与 Prisma schema 字段一一对应（Task 6+7）
 */

// ---------- 枚举类型 ----------

/** 链接类型 — 对应 musicfeed.sh get_link_type() */
export type LinkType =
  | 'album' // YTM 专辑（OLAK5uy_）
  | 'ytm_radio' // YTM 电台/Mix（RDCLAK5uy_）
  | 'playlist' // YT 播放列表（PL/LM/youtube.com/playlist）
  | 'single' // 单曲（watch?v= 或 youtu.be/）
  | 'unknown' // 不识别

/** 封面模式 */
export type CoverMode = 'unified' | 'per-track'

/** 音频格式 */
export type AudioFormat = 'opus' | 'm4a'

/** 播放列表模式（仅 playlist 类型用） */
export type PlaylistMode = 'mv' | 'ytm'

/** MV 处理策略 */
export type MvStrategy = 'manual' | 'default'

/** 任务状态 */
export type JobStatus =
  | 'pending'
  | 'running'
  | 'completed'
  | 'failed'
  | 'cancelled'

/** 日志级别 */
export type LogLevel = 'info' | 'warn' | 'error' | 'success'

// ---------- 依赖检测 ----------

export interface Dependency {
  installed: boolean
  version?: string
  /** true=必需（缺失则无法下载），false=可选（如 node） */
  required: boolean
  installHint?: string
}

export interface Dependencies {
  ytdlp: Dependency
  ffmpeg: Dependency
  jq: Dependency
  /** WebUI / job-runner 运行时（node>=22，内核 yt-dlp EJS 运行时最低要求）；面板列出用于环境体检 */
  node: Dependency
}

// ---------- 更新检查（/api/updates，Dashboard"检查更新"卡片） ----------

export interface UpdateRow {
  /** 当前版本；读取失败为 null */
  current: string | null
  /** 上游最新版本；网络失败为 null（UI 显示"—"） */
  latest: string | null
  /** current < latest；任一侧未知时为 null */
  updateAvailable: boolean | null
}

export interface UpdateCheck {
  /** 容器部署（重启即生效）或裸机部署（提示语不同） */
  runtime: 'container' | 'bare-metal'
  app: UpdateRow
  ytdlp: UpdateRow & { channel: string }
  node: UpdateRow
  checkedAt: string
}

// ---------- 配置（对应 mf_config.sh 的 MF_ 变量） ----------

export interface MfConfig {
  MF_LANG: 'zh' | 'en'
  MF_BASE_DIR: string
  MF_DEFAULT_ARTIST_DIR: string
  MF_AUDIO_FORMAT: AudioFormat
  /** 隐藏文件夹名列表（不显示在选文件夹列表里） */
  MF_HIDDEN_DIRS: string[]
  /** yt-dlp 可执行文件路径或名称 */
  MF_YTDLP?: string
  /** node 可执行文件路径（空则自动探测） */
  MF_NODE_PATH?: string
}

// ---------- 链接预览 ----------

export interface Track {
  /** 1-based 序号 */
  idx: number
  title: string
  /** YouTube video id */
  vid: string
  /** 是否已有 YTM 元数据（false 表示是 MV，需要手动输入元信息） */
  hasMeta: boolean
  /** 视频上传频道名（播放列表预览；空表示后端未提取到） */
  uploader?: string
}

export interface LinkPreview {
  ok: boolean
  type?: LinkType
  albumName?: string
  artist?: string
  trackCount?: number
  tracks?: Track[]
  hasMetadata?: boolean
  error?: string
}

// ---------- 任务 ----------

export interface Job {
  id: string
  url: string
  linkType: LinkType
  title?: string
  artist?: string
  trackCount?: number
  artistDir: string
  subfolder?: string
  coverMode: CoverMode
  albumArtist?: string
  /** "1,3,5-7" | "all" */
  tracks: string
  format: AudioFormat
  playlistMode?: PlaylistMode
  mvStrategy?: MvStrategy
  status: JobStatus
  pid?: number
  logFile?: string
  downloadedCount: number
  errorMessage?: string
  createdAt: string
  startedAt?: string
  finishedAt?: string
}

// ---------- 日志 ----------

export interface LogEntry {
  /** ISO timestamp */
  ts: string
  level: LogLevel
  /** 事件 key（如 job_start / track_done / cover） */
  event?: string
  msg: string
}

// ---------- Tab ----------

export type TabKey = 'dashboard' | 'download' | 'history' | 'settings'
