'use client'

import { useEffect, useState } from 'react'
import { toast } from 'sonner'
import { Search, Sparkles, ArrowRight, Music2 } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card'
import { Textarea } from '@/components/ui/textarea'
import { Badge } from '@/components/ui/badge'
import { Checkbox } from '@/components/ui/checkbox'
import { useT } from '@/lib/i18n'
import { useMusicFeedStore } from '@/lib/store'
import { detectLinkType } from '@/lib/mock'
import { LinkTypeBadge } from './LinkTypeBadge'
import { cn } from '@/lib/utils'

const linkExamples: { type: string; label: string; example: string }[] = [
  { type: 'album', label: 'YTM 专辑', example: 'music.youtube.com/playlist?list=OLAK5uy_...' },
  { type: 'ytm_radio', label: 'YTM 电台', example: '...list=RDCLAK5uy_...' },
  { type: 'playlist', label: 'YT 播放列表', example: 'youtube.com/playlist?list=PL...' },
  { type: 'single', label: '单曲/MV', example: 'youtube.com/watch?v=...' },
]

function parseUrls(text: string): string[] {
  const lines = text
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)

  const urls: string[] = []
  const seen = new Set<string>()

  for (const line of lines) {
    const matches = line.match(/https?:\/\/[^\s)\]]+/g)
    if (matches?.length) {
      for (const raw of matches) {
        const url = raw.trim().replace(/[>,.;]+$/g, '')
        if (!seen.has(url)) {
          seen.add(url)
          urls.push(url)
        }
      }
      continue
    }

    if (/^https?:\/\//i.test(line) && !seen.has(line)) {
      seen.add(line)
      urls.push(line)
    }
  }

  return urls
}

export function LinkInput() {
  const {
    preview,
    previewLoading,
    previewLink,
    setForm,
    selectedTracks,
    toggleTrack,
    selectAllTracks,
    clearTracks,
    form,
  } = useMusicFeedStore()
  const t = useT()

  const [urlInput, setUrlInput] = useState(form.url)

  useEffect(() => {
    const q = new URLSearchParams(window.location.search).get('url')
    if (q && detectLinkType(q) !== 'unknown') {
      const state = useMusicFeedStore.getState()
      state.setForm({ url: q })
      void state.previewLink(q)
      window.history.replaceState(null, '', '/')
    }
  }, [])

  const handlePreview = async () => {
    const urls = parseUrls(urlInput)
    if (urls.length === 0) {
      toast.warning(t('请粘贴链接'))
      return
    }

    const firstUrl = urls[0]
    if (detectLinkType(firstUrl) === 'unknown') {
      toast.error(t('无法识别的链接，请检查格式'))
      return
    }

    setForm({ url: firstUrl })

    try {
      if (urls.length > 1) {
        await useMusicFeedStore.getState().initDownloadQueue(urls)
        toast.success(t('已识别 {n} 个链接，开始逐个配置', { n: urls.length }))
        return
      }

      await previewLink(firstUrl)
      const p = useMusicFeedStore.getState().preview
      if (p?.ok) {
        toast.success(t('预览成功 · {n} 首', { n: p.trackCount ?? 0 }))
      } else if (p?.error) {
        toast.error(t('预览失败：{m}', { m: p.error }))
      }
    } catch (e) {
      toast.error(t('预览失败：{m}', { m: e instanceof Error ? e.message : String(e) }))
    }
  }

  const handleNext = () => {
    if (selectedTracks.length === 0) {
      toast.warning(t('请至少选择 1 首曲目'))
      return
    }
    useMusicFeedStore.getState().setConfirmTracks(true)
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-base">
          <Music2 className="size-4 text-emerald-600 dark:text-emerald-400" />
          {t('粘贴链接')}
        </CardTitle>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        <div className="flex flex-col gap-2">
          <Textarea
            value={urlInput}
            onChange={(e) => setUrlInput(e.target.value)}
            placeholder={`https://music.youtube.com/playlist?list=OLAK5uy_xxx\n${t('支持多链接输入（每行一个，最多 10 条）')}`}
            className="min-h-32 font-mono text-xs"
            aria-label={t("链接输入")}
          />
          <div className="flex flex-wrap gap-1.5">
            {linkExamples.map((ex) => (
              <Badge
                key={ex.type}
                variant="outline"
                className="border-border bg-muted/50 text-[10px] text-muted-foreground"
                title={ex.example}
              >
                {t(ex.label)}
              </Badge>
            ))}
          </div>
        </div>

        <div className="flex justify-end">
          <Button
            onClick={handlePreview}
            disabled={previewLoading}
            className="bg-emerald-600 text-white hover:bg-emerald-700 dark:bg-emerald-500 dark:text-emerald-950 dark:hover:bg-emerald-400"
          >
            {previewLoading ? (
              <>
                <Sparkles className="size-4 animate-pulse" />
                {t('解析中…')}
              </>
            ) : (
              <>
                <Search className="size-4" />
                {t('预览')}
              </>
            )}
          </Button>
        </div>

        {preview && preview.ok && (
          <div className="flex flex-col gap-3 rounded-lg border border-emerald-500/30 bg-emerald-500/5 p-4">
            <div className="flex flex-wrap items-center gap-2">
              <LinkTypeBadge type={preview.type ?? 'unknown'} />
              <span className="text-base font-semibold">
                {preview.albumName ?? t('未命名')}
              </span>
              {preview.artist && (
                <span className="text-sm text-muted-foreground">· {preview.artist}</span>
              )}
              <Badge
                variant="outline"
                className="ml-auto border-emerald-500/30 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"
              >
                {preview.trackCount ?? 0} {t('首')}
              </Badge>
            </div>

            <div className="flex items-center justify-between rounded-md border border-border bg-card/60 px-3 py-2">
              <div className="flex items-center gap-2">
                <Checkbox
                  id="select-all"
                  checked={preview.tracks && selectedTracks.length === preview.tracks.length}
                  onCheckedChange={(v) => (v ? selectAllTracks() : clearTracks())}
                />
                <label htmlFor="select-all" className="text-sm cursor-pointer">
                  {t('全选')} ({selectedTracks.length}/{preview.tracks?.length ?? 0})
                </label>
              </div>
              <Button
                variant="ghost"
                size="sm"
                onClick={() => clearTracks()}
                className="text-xs text-muted-foreground hover:text-foreground"
              >
                {t('清空')}
              </Button>
            </div>

            <div className="thin-scroll max-h-64 overflow-y-auto rounded-md border border-border bg-card">
              <ul className="divide-y divide-border">
                {preview.tracks?.map((tr) => {
                  const checked = selectedTracks.includes(tr.idx)
                  return (
                    <li key={tr.idx}>
                      <label
                        className={cn(
                          'flex cursor-pointer items-center gap-3 px-3 py-2 text-sm transition-colors hover:bg-accent',
                          checked && 'bg-emerald-500/5'
                        )}
                      >
                        <Checkbox checked={checked} onCheckedChange={() => toggleTrack(tr.idx)} />
                        <span className="w-6 shrink-0 text-xs text-muted-foreground tabular-nums">
                          {tr.idx}
                        </span>
                        <span className="min-w-0 flex-1 truncate">{tr.title}</span>
                        {tr.hasMeta ? (
                          <Badge
                            variant="outline"
                            className="shrink-0 border-emerald-500/30 bg-emerald-500/10 text-[10px] text-emerald-700 dark:text-emerald-300"
                          >
                            {t('元数据')}
                          </Badge>
                        ) : (
                          <Badge
                            variant="outline"
                            className="shrink-0 border-amber-500/30 bg-amber-500/10 text-[10px] text-amber-700 dark:text-amber-300"
                          >
                            MV
                          </Badge>
                        )}
                      </label>
                    </li>
                  )
                })}
              </ul>
            </div>

            <div className="flex items-center justify-between">
              <span className="text-xs text-muted-foreground">{t('已选 {n} 首', { n: selectedTracks.length })}</span>
              <Button
                onClick={handleNext}
                disabled={selectedTracks.length === 0}
                className="bg-emerald-600 text-white hover:bg-emerald-700 dark:bg-emerald-500 dark:text-emerald-950 dark:hover:bg-emerald-400"
              >
                {t('下一步 · 配置选项')}
                <ArrowRight className="size-4" />
              </Button>
            </div>
          </div>
        )}

        {preview && !preview.ok && (
          <div className="rounded-lg border border-rose-500/30 bg-rose-500/5 p-3 text-sm text-rose-700 dark:text-rose-300">
            {t('解析失败：{m}', { m: preview.error })}
          </div>
        )}
      </CardContent>
    </Card>
  )
}
