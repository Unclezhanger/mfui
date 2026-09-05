'use client'

import { useEffect, useRef } from 'react'
import { toast } from 'sonner'
import {
  ArrowLeft,
  Download,
  FolderPlus,
  Image as ImageIcon,
  Music,
  FileAudio,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Switch } from '@/components/ui/switch'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectSeparator,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import {
  RadioGroup,
  RadioGroupItem,
} from '@/components/ui/radio-group'
import { Badge } from '@/components/ui/badge'
import { useT } from '@/lib/i18n'
import { useMusicFeedStore, guessMvTrackInfo, artistDirName, extractMvTitleGuess } from '@/lib/store'
import type { CoverMode, AudioFormat } from '@/lib/types'
import { LinkTypeBadge } from './LinkTypeBadge'

export function DownloadOptions() {
  const {
    preview,
    form,
    setForm,
    folders,
    selectedTracks,
    startQueuedDownloads,
    resetForm,
    hasDownloadQueueNext,
    confirmTracks,
    } = useMusicFeedStore()
  const t = useT()

  // 进入 step 2 时根据 linkType 自动设置合理的默认值
  useEffect(() => {
    if (!preview?.type || !confirmTracks) return
    if (preview.type === 'album') {
      if (form.coverMode !== 'per-track') setForm({ coverMode: 'unified' })
      // 专辑艺术家不自动预填：留空 = 不写入（与表单提示一致），
      // 想用就自己填，预填会让"留空跳过"失效
    } else {
      setForm({ coverMode: 'per-track' })
    }
    // v4.1 子文件夹开关默认值（对齐 musicfeed.sh）：
    // 单曲 / MV 单曲 → 关；播放列表 / 专辑 / YTM 电台 → 开
    setForm({ subfolderEnabled: preview.type !== 'single' })
    // v4.3: 单 MV（无元数据）进入配置页 —— 开关复位为关，并按关闭规则预填默认值
    if (preview.type === 'single' && preview.hasMetadata === false) {
      setForm({ mvManualEdit: false })
    }
  }, [preview?.type, confirmTracks])

  // v4.3: 单 MV（无元数据）预填 —— 与 MV 播放列表开关同构：
  //   关（默认）：歌手 = 视频上传频道名，歌名/专辑 = 完整原始标题（内核分支2 默认值，提交时不传 mvTitle）
  //   开：歌手 = 所选歌手文件夹名，歌名 = 《》提取（引号 → 去前缀 → fallback 标题），专辑 = 歌名（内核分支1 语义）
  // 开关切换时覆盖已预填值（视为重新预填）
  useEffect(() => {
    if (!preview?.type || !confirmTracks) return
    if (preview.type !== 'single' || preview.hasMetadata !== false) return
    const raw = preview.tracks?.[0]?.title ?? preview.albumName ?? ''
    const uploader = preview.tracks?.[0]?.uploader ?? preview.artist ?? ''
    if (form.mvManualEdit) {
      const title = extractMvTitleGuess(raw)
      setForm({ mvTitle: title, mvArtist: artistDirName(form), mvAlbum: title })
    } else {
      setForm({ mvTitle: raw, mvArtist: uploader, mvAlbum: raw })
    }
  }, [preview?.type, confirmTracks, form.mvManualEdit])

  // v4.3: MV 播放列表（mv 模式）——为选中的无元数据曲目预填逐曲元数据：
  //   开关关（默认）：歌手 = 视频上传频道名，歌名 = 标题拆分，专辑 = 歌名（CLI 分支2 语义）
  //   开关开：歌手 = 所选歌手文件夹名，歌名 = 《》提取（fallback 标题），专辑 = 歌名（CLI 分支1 语义）
  // 开关切换时覆盖所有已预填条目（视为重新预填）；有 meta 的曲目交给内核自动抓取
  const lastManualRef = useRef(form.mvManualEdit)
  useEffect(() => {
    if (!preview?.type || !confirmTracks) return
    if (preview.type !== 'playlist' || form.playlistMode !== 'mv') return
    const manualChanged = lastManualRef.current !== form.mvManualEdit
    lastManualRef.current = form.mvManualEdit
    const cur = form.mvTracks ?? {}
    let changed = false
    const next: typeof cur = { ...cur }
    const dirName = artistDirName(form)
    for (const t of preview.tracks ?? []) {
      if (t.hasMeta || !selectedTracks.includes(t.idx) || !t.vid) continue
      if (!next[t.vid] || manualChanged) {
        next[t.vid] = guessMvTrackInfo(t, form.mvManualEdit, dirName)
        changed = true
      }
    }
    if (changed) setForm({ mvTracks: next })
  }, [preview?.type, confirmTracks, form.playlistMode, form.mvManualEdit])

  if (!preview) return null

  const isAlbum = preview.type === 'album'
  const isSingle = preview.type === 'single'
  const isPlaylist = preview.type === 'playlist'

  const handleStart = async () => {
    if (form.isNewFolder && !form.newFolderName.trim()) {
      toast.warning(t('请输入新文件夹名称'))
      return
    }
    try {
      if (hasDownloadQueueNext()) {
        await useMusicFeedStore.getState().advanceDownloadQueue()
        toast.success(t('已进入下一个链接的配置'))
      } else {
        await startQueuedDownloads()
        toast.success(t('已开始下载任务'))
      }
    } catch (e) {
      toast.error(t('启动失败：{m}', { m: e instanceof Error ? e.message : String(e) }))
    }
  }

  const handleBack = () => {
    // 回到选曲步骤，保留预览结果（曲目列表还在，无需重新解析链接）
    useMusicFeedStore.getState().setConfirmTracks(false)
    resetForm()
  }

  return (
    <Card>
      <CardHeader>
        <div className="flex flex-wrap items-center gap-3">
          <Button
            variant="ghost"
            size="sm"
            onClick={handleBack}
            className="text-muted-foreground"
          >
            <ArrowLeft className="size-4" />
            {t('编辑曲目')}
          </Button>
          <CardTitle className="text-base">{t('配置下载选项')}</CardTitle>
          <div className="ml-auto flex min-w-0 flex-1 items-center justify-end gap-2 pl-4 text-sm text-muted-foreground">
            <LinkTypeBadge type={preview.type} />
            {/* v4.3: 标题+歌手占满中间区域，长名截断并悬浮显示全名 */}
            <span className="flex min-w-0 flex-1 flex-col items-end leading-tight">
              <span className="max-w-full truncate font-medium text-foreground" title={preview.albumName ?? ''}>
                {preview.albumName ?? t('未命名')}
              </span>
              {preview.artist && (
                <span className="max-w-full truncate text-xs" title={preview.artist}>
                  {preview.artist}
                </span>
              )}
            </span>
            <span className="shrink-0">{t('已选 {n} 首', { n: selectedTracks.length })}</span>
          </div>
        </div>
      </CardHeader>
      <CardContent className="flex flex-col gap-6">
        {/* 歌手文件夹 */}
        <Field
          label={t("歌手文件夹")}
          icon={<Music className="size-4" />}
          hint={t("音频文件会归档到此文件夹下")}
        >
          <Select
            value={form.isNewFolder ? '__new__' : form.artistDir}
            onValueChange={(v) => {
              if (v === '__new__') {
                setForm({ isNewFolder: true, newFolderName: '' })
              } else {
                setForm({ isNewFolder: false, artistDir: v, newFolderName: '' })
              }
            }}
          >
            <SelectTrigger className="w-full sm:w-72">
              <SelectValue placeholder={t("选择或新建文件夹")} />
            </SelectTrigger>
            <SelectContent>
              {/* 当前值不在列表里（如配置的默认文件夹还没建）也要能显示 */}
              {form.artistDir && !folders.includes(form.artistDir) && !form.isNewFolder && (
                <SelectItem value={form.artistDir}>
                  📁 {form.artistDir}（{t('默认，未创建')}）
                </SelectItem>
              )}
              {folders.map((f) => (
                <SelectItem key={f} value={f}>
                  📁 {f}
                </SelectItem>
              ))}
              <SelectSeparator />
              <SelectItem value="__new__">
                <FolderPlus className="size-3.5" />
                {t('新建文件夹…')}
              </SelectItem>
            </SelectContent>
          </Select>
          {form.isNewFolder && (
            <Input
              value={form.newFolderName}
              onChange={(e) => setForm({ newFolderName: e.target.value })}
              placeholder={t("输入新文件夹名称（如：陈奕迅）")}
              className="mt-2 w-full sm:w-72"
              aria-label={t("新文件夹名")}
            />
          )}
        </Field>

        {/* 单 MV 手动元数据（v4.3：开关默认关，与 MV 播放列表开关对齐） */}
        {preview.type === 'single' && preview.hasMetadata === false && (
          <Field
            label={t("歌曲信息（MV 无音乐元数据）")}
            icon={<Music className="size-4" />}
            hint={
              form.mvManualEdit
                ? t('开启：歌手 = 所选歌手文件夹名，歌名 = 《》内文字（无则引号/原标题），专辑 = 歌名')
                : t('关闭（默认）：歌手 = 视频上传频道名，歌名/专辑 = 完整原始标题')
            }
          >
            <div className="flex flex-col gap-3">
              <div className="flex items-center gap-3">
                <Switch
                  checked={form.mvManualEdit}
                  onCheckedChange={(v) => setForm({ mvManualEdit: v })}
                />
                <span className="text-sm">
                  {form.mvManualEdit ? t('已开启（手动规则预填）') : t('已关闭（按频道名默认值）')}
                </span>
              </div>
              <div className="flex flex-col gap-2">
                <Input
                  value={form.mvTitle}
                  onChange={(e) => setForm({ mvTitle: e.target.value })}
                  placeholder={t("歌名")}
                  disabled={!form.mvManualEdit}
                  className="w-full sm:w-72 disabled:opacity-60"
                  aria-label={t("歌名")}
                />
                <Input
                  value={form.mvArtist}
                  onChange={(e) => setForm({ mvArtist: e.target.value })}
                  placeholder={t("歌手")}
                  disabled={!form.mvManualEdit}
                  className="w-full sm:w-72 disabled:opacity-60"
                  aria-label={t("歌手")}
                />
                <Input
                  value={form.mvAlbum}
                  onChange={(e) => setForm({ mvAlbum: e.target.value })}
                  placeholder={t("专辑（留空 = 同歌名）")}
                  disabled={!form.mvManualEdit}
                  className="w-full sm:w-72 disabled:opacity-60"
                  aria-label={t("专辑")}
                />
              </div>
            </div>
          </Field>
        )}

        {/* 子文件夹开关（v4.1：对齐 musicfeed.sh，单曲默认关，列表/专辑/电台默认开） */}
        <Field
          label={t("子文件夹")}
          icon={<FolderPlus className="size-4" />}
          hint={
            form.subfolderEnabled
              ? t('开启：填写名称则下载到 歌手/<该名称>；留空 = 歌手/<专辑名>')
              : t('关闭：直接下载到 歌手/')
          }
        >
          <div className="flex items-center gap-3">
            <Switch
              checked={form.subfolderEnabled}
              onCheckedChange={(v) => setForm({ subfolderEnabled: v })}
            />
            <span className="text-sm">
              {form.subfolderEnabled ? t('已开启') : t('已关闭')}
            </span>
          </div>
          {form.subfolderEnabled && (
            <Input
              value={form.subfolder}
              onChange={(e) => setForm({ subfolder: e.target.value })}
              placeholder={`${t('留空则使用')}：${preview.albumName ?? t('专辑名')}`}
              className="mt-2 w-full sm:w-72"
            />
          )}
        </Field>

        {/* Album Artist（仅 album） */}
        {(isAlbum || isSingle) && (
          <Field
            label={t("专辑艺术家")}
            icon={<Music className="size-4" />}
            hint={t("写入 ID3 ALBUMARTIST 标签，留空则跳过")}
          >
            <Input
              value={form.albumArtist}
              onChange={(e) => setForm({ albumArtist: e.target.value })}
              placeholder={t("如：Taylor Swift")}
              className="w-full sm:w-72"
            />
          </Field>
        )}

        {/* 封面模式 */}
        <Field
          label={t("封面模式")}
          icon={<ImageIcon className="size-4" />}
          hint={
            isAlbum
              ? t('专辑推荐「统一封面」（裁剪首曲缩略图作为整张专辑封面）')
              : t('电台/播放列表/单曲强制「独立封面」（每首歌用各自缩略图）')
          }
        >
          <RadioGroup
            value={form.coverMode}
            onValueChange={(v) => setForm({ coverMode: v as CoverMode })}
            className="grid gap-2 sm:grid-cols-2"
          >
            <RadioCard
              value="unified"
              checked={form.coverMode === 'unified'}
              title={t("统一封面")}
              desc={t("一张封面用于整张专辑")}
              disabled={!isAlbum}
            />
            <RadioCard
              value="per-track"
              checked={form.coverMode === 'per-track'}
              title={t("独立封面")}
              desc={t("每首歌使用各自缩略图")}
            />
          </RadioGroup>
        </Field>

        {/* 音频格式 */}
        <Field
          label={t("音频格式")}
          icon={<FileAudio className="size-4" />}
          hint={t("Opus 体积小、音质优；M4A 兼容性好（iOS/Apple Music）")}
        >
          <RadioGroup
            value={form.format}
            onValueChange={(v) => setForm({ format: v as AudioFormat })}
            className="grid gap-2 sm:grid-cols-2"
          >
            <RadioCard
              value="opus"
              checked={form.format === 'opus'}
              title="Opus"
              desc={t("推荐 · 高压缩比")}
            />
            <RadioCard
              value="m4a"
              checked={form.format === 'm4a'}
              title="M4A"
              desc={t("Apple 兼容性")}
            />
          </RadioGroup>
        </Field>

        {/* 播放列表模式（仅 playlist） */}
        {isPlaylist && (
          <Field
            label={t("播放列表类型")}
            icon={<Music className="size-4" />}
            hint={t("选择列表中曲目的处理方式")}
          >
            <RadioGroup
              value={form.playlistMode}
              onValueChange={(v) =>
                setForm({ playlistMode: v as 'mv' | 'ytm' })
              }
              className="grid gap-2 sm:grid-cols-2"
            >
              <RadioCard
                value="mv"
                checked={form.playlistMode === 'mv'}
                title={t("MV 模式")}
                desc={t("YouTube 视频播放列表")}
              />
              <RadioCard
                value="ytm"
                checked={form.playlistMode === 'ytm'}
                title={t("YouTube Music 社区播放列表")}
                desc={t("用户自建列表（无官方专辑元数据时按 MV 拆分处理）")}
              />
            </RadioGroup>
          </Field>
        )}

        {/* v4.3: MV 模式「手动输入歌曲信息」开关（对齐 CLI 分支1/分支2） */}
        {isPlaylist && form.playlistMode === 'mv' && (
          <Field
            label={t("手动输入 MV 歌曲信息")}
            icon={<Music className="size-4" />}
            hint={
              form.mvManualEdit
                ? t('开启：歌手 = 所选歌手文件夹名，歌名 = 《》内文字（无则引号/原标题），专辑 = 歌名')
                : t('关闭（默认）：歌手 = 视频上传频道名，歌名 = 完整原始标题，专辑 = 原始标题；有元数据的曲目自动抓取')
            }
          >
            <div className="flex items-center gap-3">
              <Switch
                checked={form.mvManualEdit}
                onCheckedChange={(v) => setForm({ mvManualEdit: v })}
              />
              <span className="text-sm">
                {form.mvManualEdit ? t('已开启（手动规则预填）') : t('已关闭（按频道名预填）')}
              </span>
            </div>
          </Field>
        )}

        {/* v4.3: MV 播放列表逐曲元数据（mv 模式且有选中的无元数据曲目） */}
        {isPlaylist &&
          form.playlistMode === 'mv' &&
          (preview.tracks ?? []).filter(
            (t) => !t.hasMeta && selectedTracks.includes(t.idx),
          ).length > 0 && (
            <Field
              label={t("MV 曲目元数据")}
              icon={<Music className="size-4" />}
              hint={t("预填规则由上方「手动输入 MV 歌曲信息」开关决定，可逐首修改；列表内曲目将按 歌手 - 歌名 重命名并写标签")}
            >
              <div className="flex flex-col gap-3">
                {(preview.tracks ?? [])
                  .filter((tr) => !tr.hasMeta && selectedTracks.includes(tr.idx))
                  .map((tr) => {
                    const t2 = tr
                    const edit = form.mvTracks[tr.vid] ?? guessMvTrackInfo(tr, form.mvManualEdit, artistDirName(form))
                    const set = (patch: Partial<typeof edit>) =>
                      setForm({
                        mvTracks: {
                          ...form.mvTracks,
                          [tr.vid]: { ...edit, ...patch },
                        },
                      })
                    return (
                      <div
                        key={tr.vid}
                        className="rounded-md border border-border bg-card/60 p-3"
                      >
                        <div className="mb-2 flex items-center gap-2 text-xs text-muted-foreground">
                          <Badge
                            variant="outline"
                            className="border-amber-500/30 bg-amber-500/10 text-amber-700 dark:text-amber-300"
                          >
                            {tr.idx}
                          </Badge>
                          <span className="truncate" title={tr.title}>
                            {t('原标题：{t}', { t: t2.title })}
                          </span>
                        </div>
                        <div className="grid gap-2 sm:grid-cols-3">
                          <Input
                            value={edit.title}
                            onChange={(e) => set({ title: e.target.value })}
                            placeholder={t("歌名")}
                            aria-label={t("第 {n} 首歌名", { n: t2.idx })}
                          />
                          <Input
                            value={edit.artist}
                            onChange={(e) => set({ artist: e.target.value })}
                            placeholder={t("歌手")}
                            aria-label={t("第 {n} 首歌手", { n: t2.idx })}
                          />
                          <Input
                            value={edit.album}
                            onChange={(e) => set({ album: e.target.value })}
                            placeholder={t("专辑（留空 = 同歌名）")}
                            aria-label={t("第 {n} 首专辑", { n: t2.idx })}
                          />
                        </div>
                      </div>
                    )
                  })}
              </div>
            </Field>
          )}

        {/* 曲目选择摘要 */}
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-border bg-muted/40 p-3">
          <div className="flex items-center gap-2 text-sm">
            <Badge
              variant="outline"
              className="border-emerald-500/30 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"
            >
              {t('{n} 首', { n: selectedTracks.length })}
            </Badge>
            <span className="text-muted-foreground">{t('曲目已选中')}</span>
            <span className="text-xs text-muted-foreground">
              ·{' '}
              {selectedTracks.length === preview.tracks?.length
                ? t('全部')
                : selectedTracks.join(',')}
            </span>
          </div>
          <Button
            size="lg"
            onClick={handleStart}
            className="bg-emerald-600 text-white shadow-sm hover:bg-emerald-700 dark:bg-emerald-500 dark:text-emerald-950 dark:hover:bg-emerald-400"
          >
            <Download className="size-4" />
            {hasDownloadQueueNext() ? t('配置下个链接') : t('开始下载')}
          </Button>
        </div>
      </CardContent>
    </Card>
  )
}

function Field({
  label,
  hint,
  icon,
  children,
}: {
  label: string
  hint?: string
  icon?: React.ReactNode
  children: React.ReactNode
}) {
  return (
    <div className="flex flex-col gap-2 border-l-2 border-emerald-500/40 pl-4">
      <div className="flex items-center gap-2">
        {icon && (
          <span className="text-emerald-600 dark:text-emerald-400">{icon}</span>
        )}
        <Label className="text-sm font-medium">{label}</Label>
      </div>
      {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
      <div className="mt-1">{children}</div>
    </div>
  )
}

function RadioCard({
  value,
  checked,
  title,
  desc,
  disabled,
}: {
  value: string
  checked: boolean
  title: string
  desc: string
  disabled?: boolean
}) {
  return (
    <label
      className={`flex cursor-pointer items-start gap-3 rounded-md border p-3 transition-colors ${
        disabled
          ? 'cursor-not-allowed opacity-50'
          : 'hover:bg-accent'
      } ${
        checked
          ? 'border-emerald-500/60 bg-emerald-500/5'
          : 'border-border'
      }`}
    >
      <RadioGroupItem value={value} disabled={disabled} className="mt-0.5" />
      <div className="flex flex-col gap-0.5">
        <span className="text-sm font-medium">{title}</span>
        <span className="text-xs text-muted-foreground">{desc}</span>
      </div>
    </label>
  )
}
