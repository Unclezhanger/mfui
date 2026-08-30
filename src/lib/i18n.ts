'use client'

/**
 * WebUI 轻量国际化（自研，无外部依赖）
 * - 界面语言独立于 mf_config 的 MF_LANG（内核任务语言仍走配置文件）
 * - 默认英文，持久化在 localStorage（key: mfui-ui-lang）
 * - 字典以中文原文为 key，英文为值；缺词条时回退中文
 * - 动态文案用 {n} 占位符：t('{n} 首', { n: 3 }) → "3 tracks"
 */

import { useMusicFeedStore } from '@/lib/store'
import { useCallback } from 'react'
import { EXTRA_DICTS } from './i18n-dicts'

export type UiLang = 'en' | 'zh' | 'de' | 'es' | 'fr' | 'ja' | 'pt' | 'ru'

export const UI_LANG_KEY = 'mfui-ui-lang'

/** 中文 → 英文词典（覆盖界面全部静态文案；toast/占位符/hint 均在此维护） */
const DICT: Record<string, string> = {
  // ---------- 通用 ----------
  '仪表盘': 'Dashboard',
  '下载': 'Download',
  '历史': 'History',
  '设置': 'Settings',
  '环境、任务一览': 'Environment & jobs at a glance',
  '粘贴链接 → 配置 → 下载': 'Paste a link → configure → download',
  '所有下载任务记录': 'All download jobs',
  'mf_config.sh 配置项': 'mf_config.sh options',
  '主题': 'Theme',
  '切换主题': 'Toggle theme',
  '取消': 'Cancel',
  '确认': 'Confirm',
  '保存': 'Save',
  '关闭': 'Close',
  '删除': 'Delete',
  '返回': 'Back',
  '下一步': 'Next',
  '上一步': 'Back',
  '开始下载': 'Start download',
  '下载中': 'Downloading',
  '已完成': 'Completed',
  '失败': 'Failed',
  '已取消': 'Cancelled',
  '等待中': 'Pending',
  '队列': 'Queue',
  '歌名': 'Title',
  '歌手': 'Artist',
  '专辑': 'Album',
  '语言': 'Language',
  '界面语言': 'Interface language',

  // ---------- 链接类型（YTM 官方术语） ----------
  '专辑链接': 'Album link',
  '播放列表链接': 'Playlist link',
  '单曲链接': 'Song link',
  'YTM 电台': 'YTM Radio',
  '社区播放列表': 'Community playlist',
  'MV': 'Music video',
  '元数据': 'Metadata',
  '识别为': 'Detected as',
  '链接类型': 'Link type',
  '曲目': 'Tracks',
  '首': 'tracks',

  // ---------- 下载页 ----------
  '粘贴 YouTube / YouTube Music 链接': 'Paste a YouTube / YouTube Music link',
  '支持专辑、播放列表、单曲、MV 链接，可一次粘贴多行': 'Supports albums, playlists, songs and music videos. Multiple links, one per line',
  '预览': 'Preview',
  '预览中…': 'Previewing…',
  '预览成功': 'Preview OK',
  '预览失败': 'Preview failed',
  '选曲': 'Pick tracks',
  '全选': 'Select all',
  '全不选': 'Select none',
  '已选 {n} / {total} 首': '{n} of {total} selected',
  '编辑曲目': 'Edit tracks',
  '配置': 'Configure',
  '再下载一个': 'Download another',
  '下载完成': 'Download complete',
  '队列下载完成': 'Queue finished',
  '第 {i}/{n} 个': '{i} of {n}',
  '清空': 'Clear',
  '重新预览': 'Re-preview',

  // ---------- 配置页 ----------
  '歌手文件夹': 'Artist folder',
  '作为选中文件夹列表的第一项（默认选项）': 'Shown as the first entry in the folder list (default)',
  '新建文件夹': 'New folder',
  '输入新文件夹名称（如：陈奕迅）': 'New folder name (e.g. Adele)',
  '子文件夹': 'Subfolder',
  '专辑艺术家': 'Album artist',
  '写入 ID3 ALBUMARTIST 标签，留空则跳过': 'Written to the ALBUMARTIST ID3 tag; leave empty to skip',
  '封面模式': 'Cover art',
  '统一封面': 'Unified cover',
  '独立封面': 'Per-track cover',
  '音频格式': 'Audio format',
  '播放列表类型': 'Playlist mode',
  '手动输入 MV 歌曲信息': 'Enter music video info manually',
  '歌曲信息（MV 无音乐元数据）': 'Song info (music video without metadata)',
  'MV 曲目元数据': 'Music video track info',
  '留空则使用': 'Leave empty to use',

  // ---------- 进度/日志 ----------
  '实时日志': 'Live log',
  '取消任务': 'Cancel job',
  '任务已取消': 'Job cancelled',
  '日志': 'Log',
  '复制日志': 'Copy log',
  '已复制': 'Copied',

  // ---------- 历史页 ----------
  '暂无任务': 'No jobs yet',
  '查看日志': 'View log',
  '删除任务': 'Delete job',
  '确认删除该任务记录？': 'Delete this job record?',
  '创建时间': 'Created',
  '耗时': 'Duration',

  // ---------- 设置页 ----------
  '已保存': 'Saved',
  '保存失败': 'Save failed',
  '加载中…': 'Loading…',
  '配置已写入': 'Configuration written',
  '界面语言仅作用于网页界面，不影响下载任务的日志语言（由 mf_config.sh 的 MF_LANG 决定）':
    'The interface language only affects this web UI. Download job logs follow MF_LANG in mf_config.sh',
  'English': 'English',
  '中文': '中文',

  // ---------- 补充（全量迁移扫描补齐） ----------
  'GitHub 仓库': 'GitHub repo',
  'MF_BASE_DIR 等已写入 mf_config.sh': 'MF_BASE_DIR etc. written to mf_config.sh',
  'MV 曲目元数据': 'Music video track info',
  'MV 模式': 'Music video mode',
  'url': 'url',
  '⚠️ 保存会直接覆写 musicfeed/mf_config.sh，原文件自动备份为 mf_config.sh.bak。':
    '⚠️ Saving overwrites musicfeed/mf_config.sh directly; the original is backed up as mf_config.sh.bak.',
  '、': ', ',
  '。请在终端运行 ': '. Run ',
  '一张封面用于整张专辑': 'One cover for the whole album',
  '下一步 · 配置选项': 'Next · Configure',
  '下载历史': 'Download history',
  '专辑名': 'album name',
  '专辑推荐「统一封面」（裁剪首曲缩略图作为整张专辑封面）':
    'Albums: unified cover recommended (center-crops the first thumbnail as the album cover)',
  '任务日志': 'Job log',
  '保存中…': 'Saving…',
  '保存失败：{m}': 'Save failed: {m}',
  '保存设置': 'Save settings',
  '关闭（默认）：歌手 = 视频上传频道名，歌名 = 完整原始标题，专辑 = 原始标题；有元数据的曲目自动抓取':
    'Off (default): artist = channel name, title/album = full original title; tracks with metadata are fetched automatically',
  '关闭（默认）：歌手 = 视频上传频道名，歌名/专辑 = 完整原始标题':
    'Off (default): artist = channel name, title/album = full original title',
  '关闭：直接下载到 歌手/': 'Off: download directly into artist/',
  '写入 ID3 ALBUMARTIST 标签，留空则跳过': 'Written to the ALBUMARTIST ID3 tag; leave empty to skip',
  '创建时间': 'Created',
  '删除失败：{m}': 'Delete failed: {m}',
  '加载日志…': 'Loading log…',
  '加载日志失败：{m}': 'Failed to load log: {m}',
  '即将删除「{t}」的历史记录。此操作不可撤销，已下载的音频文件不会被删除。':
    'The history record of "{t}" will be deleted. This cannot be undone; downloaded audio files are kept.',
  '原标题：{t}': 'Original title: {t}',
  '去新建任务': 'Start a new job',
  '可选': 'optional',
  '向导会引导你完成语言选择、依赖检测、目录配置等步骤，并自动生成 mf_config.sh。':
    'The wizard walks you through language, dependencies and folders, then generates mf_config.sh.',
  '启动失败：{m}': 'Failed to start: {m}',
  '基础配置': 'Basic settings',
  '失败/取消': 'Failed / cancelled',
  '如：Taylor Swift': 'e.g. Taylor Swift', '部分失败': 'Partial failure',
  '子文件夹': 'Subfolder',
  '完成安装，否则无法启动下载。': 'to install them, otherwise downloads cannot start.',
  '对应 mf_config.sh 的 MF_ 变量。保存后下次启动 musicfeed 时生效。':
    'Maps to MF_ variables in mf_config.sh. Takes effect on the next musicfeed run after saving.',
  '已关闭': 'Off',
  '已关闭（按频道名预填）': 'Off (prefill by channel name)',
  '已关闭（按频道名默认值）': 'Off (channel-name defaults)',
  '已取消下载任务': 'Download job cancelled',
  '已开启': 'On',
  '已开启（手动规则预填）': 'On (manual-rule prefill)',
  '已开始下载任务': 'Download started',
  '已恢复默认设置（需点保存才会写入）': 'Defaults restored (click Save to write)',
  '已识别 {n} 个链接，开始逐个配置': '{n} links detected, configuring one by one',
  '已进入下一个链接的配置': 'Moved to the next link',
  '已选 {n} 首': '{n} selected',
  '开启：填写名称则下载到 歌手/<该名称>；留空 = 歌手/<专辑名>':
    'On: downloads to artist/<name>; empty = artist/<album name>',
  '开启：歌手 = 所选歌手文件夹名，歌名 = 《》内文字（无则引号/原标题），专辑 = 歌名':
    'On: artist = selected folder name, title = text inside 《》 (quotes / original title as fallback), album = title',
  '当前 MF_BASE_DIR「{d}」不存在或不可访问，请修改为有效路径后再保存（保存时会自动尝试创建子文件夹）。':
    'MF_BASE_DIR "{d}" does not exist or is not accessible. Fix the path before saving (subfolders are created automatically on save).',
  '当前无任务': 'No active jobs',
  '必需依赖就绪': 'Required dependencies ready',
  '恢复默认': 'Reset',
  '所有歌手文件夹都会在此目录下创建': 'All artist folders are created under this directory',
  '手动输入 MV 歌曲信息': 'Enter music video info manually',
  '推荐 · 高压缩比': 'Recommended · high compression',
  '播放列表类型': 'Playlist mode',
  '操作': 'Actions',
  '支持 YTM 专辑 / 电台 / 播放列表 / 单曲 / MV': 'YTM albums / radios / playlists / songs / music videos',
  '支持多链接输入（每行一个，最多 10 条）': 'Multiple links supported (one per line, up to 10)',
  '新建下载任务': 'New download job',
  '新建文件夹…': 'New folder…',
  '新文件夹名': 'New folder name',
  '无法识别的链接，请检查格式': 'Unrecognized link, check the format',
  '暂无隐藏文件夹': 'No hidden folders',
  '曲目已选中': 'tracks selected',
  '未命名任务': 'Untitled job',
  '本日创建的任务数': 'Jobs created today',
  '查看历史': 'View history',
  '歌名': 'Title',
  '歌曲信息（MV 无音乐元数据）': 'Song info (music video without metadata)',
  '正在下载中…': 'Downloading…',
  '每首歌使用各自缩略图': 'Each track keeps its own thumbnail',
  '没有正在运行的任务': 'No running job',
  '活跃任务': 'Active jobs',
  '添加': 'Add',
  '清空': 'Clear',
  '独立封面': 'Per-track cover',
  '用户自建列表（无官方专辑元数据时按 MV 拆分处理）':
    'User-created lists (split as music videos when official album metadata is missing)',
  '电台/播放列表/单曲强制「独立封面」（每首歌用各自缩略图）':
    'Radios / playlists / songs force per-track covers (each track keeps its own thumbnail)',
  '留空则使用系统 PATH 中的 yt-dlp': 'Leave empty to use yt-dlp from system PATH',
  '知道了': 'Got it',
  '确认删除任务记录？': 'Delete this job record?',
  '移除 {n}': 'Remove {n}',
  '第 {n} 首专辑': 'Track {n} album',
  '第 {n} 首歌名': 'Track {n} title',
  '第 {n} 首歌手': 'Track {n} artist',
  '等待日志…': 'Waiting for logs…',
  '类型': 'Type',
  '粘贴 YouTube 链接开始下载': 'Paste a YouTube link to start',
  '粘贴链接': 'Paste link',
  '统一封面': 'Unified cover',
  '编辑曲目': 'Edit tracks',
  '缺失必需依赖': 'Required dependencies missing',
  '解析中…': 'Parsing…',
  '解析失败：{m}': 'Parse failed: {m}',
  '设置向导需要交互式终端，无法在 Web UI 中直接运行。':
    'The setup wizard needs an interactive terminal and cannot run in the web UI.',
  '设置已保存': 'Settings saved',
  '该文件夹已在列表中': 'Folder already in the list',
  '请在 musicfeed 项目根目录下执行：': 'Run this from the musicfeed project root:',
  '请粘贴链接': 'Paste a link first',
  '请至少选择 1 首曲目': 'Select at least 1 track',
  '请输入新文件夹名称': 'Enter a new folder name',
  '输入名称后回车添加（如 @eaDir）': 'Type a name and press Enter (e.g. @eaDir)',
  '输入新文件夹名称（如：陈奕迅）': 'New folder name (e.g. Adele)',
  '运行设置向导': 'Run setup wizard',
  '返回仪表盘': 'Back to dashboard',
  '还没有下载记录，去下载页开始吧': 'No download history yet — start from the Download page',
  '进度': 'Progress',
  '进行中': 'Running',
  '选择列表中曲目的处理方式': 'Choose how the tracks are processed',
  '选择或新建文件夹': 'Pick or create a folder',
  '选歌手文件夹列表中要过滤掉的目录': 'Directories to filter out of the artist folder list',
  '配置下个链接': 'Configure next link',
  '配置下载选项': 'Configure download',
  '链接输入': 'Link input',
  '队列 {i}/{n}': 'Queue {i}/{n}',
  '预填规则由上方「手动输入 MV 歌曲信息」开关决定，可逐首修改；列表内曲目将按 歌手 - 歌名 重命名并写标签':
    'Prefill follows the "Enter music video info manually" switch above and is editable per track; tracks are renamed to artist - title and tagged',
  '预览失败：{m}': 'Preview failed: {m}',
  '预览成功 · {n} 首': 'Preview OK · {n} tracks',
  '默认，未创建': 'default, not created',
  '依赖状态': 'Dependencies',
  '今日下载': 'Today',
  '以下依赖未安装：': 'Missing dependencies: ',
  '专辑艺术家': 'Album artist',
  '当前配置': 'Current config',
  '最近任务': 'Recent jobs',
  '未命名': 'Untitled',
  '快速开始': 'Quick start',
  '格式': 'Format',
  '标题': 'Title',
  '状态': 'Status',
  '封面模式': 'Cover art',
  '待运行': 'Pending',
  '隐藏文件夹 (MF_HIDDEN_DIRS)': 'Hidden folders (MF_HIDDEN_DIRS)',
  '音乐根目录 (MF_BASE_DIR)': 'Music root (MF_BASE_DIR)',
  '音频文件会归档到此文件夹下': 'Audio files are archived under this folder',
  '默认文件夹': 'Default folder',
  '默认歌手文件夹 (MF_DEFAULT_ARTIST_DIR)': 'Default artist folder (MF_DEFAULT_ARTIST_DIR)',
  '默认音频格式 (MF_AUDIO_FORMAT)': 'Default audio format (MF_AUDIO_FORMAT)',
  'YT 播放列表': 'YT Playlist',
  'YTM 专辑': 'YTM Album',
  '单曲/MV': 'Song/Music video',
  '专辑链接': 'Album link',
  'Apple 兼容性': 'Apple compatibility',
  'Opus 体积小、音质优；M4A 兼容性好（iOS/Apple Music）':
    'Opus: smaller and better quality; M4A: best compatibility (iOS/Apple Music)',
  'YouTube Music 社区播放列表': 'YouTube Music community playlist',
  'YouTube 视频播放列表': 'YouTube video playlist',
  'yt-dlp 路径 (MF_YTDLP)': 'yt-dlp path (MF_YTDLP)',
  '{n} 分钟前': '{n} min ago',
  '{n} 天前': '{n} d ago',
  '{n} 小时前': '{n} h ago',
  '专辑（留空 = 同歌名）': 'Album (empty = same as title)',
  '作为选文件夹列表的第 1 项（默认选项）': 'Shown as the first entry in the folder list (default)',
  '全部': 'All',
  '已删除任务记录': 'Job record deleted',
  '配置选项': 'Configure',
  '下载进度': 'Progress',
  '未知': 'Unknown',
  '播放列表': 'Playlist',
  '单曲': 'Song',
}

export type TFunc = (zh: string, params?: Record<string, string | number>) => string

/**
 * 返回翻译函数。zh 文案为 key，params 替换 {name} 占位符。
 * 回退链：目标语言词典 → 英文词典 → 中文原文。
 */
export function useT(): TFunc {
  const lang = useMusicFeedStore((s) => s.uiLang)
  return useCallback(
    (zh: string, params?: Record<string, string | number>) => {
      let text = zh
      if (lang === 'en') {
        text = DICT[zh] ?? zh
      } else if (lang !== 'zh') {
        const d = EXTRA_DICTS[lang]
        text = (d && d[zh]) || DICT[zh] || zh
      }
      if (params) {
        for (const [k, v] of Object.entries(params)) {
          text = text.replaceAll(`{${k}}`, String(v))
        }
      }
      return text
    },
    [lang],
  )
}
