'use client'

import { useState } from 'react'
import { toast } from 'sonner'
import {
  Save,
  RotateCcw,
  Terminal,
  FolderOpen,
  X,
  Plus,
  Languages,
  FileAudio,
  Settings as SettingsIcon,
  Loader2,
  FolderX,
} from 'lucide-react'
import { Button } from '@/components/ui/button'
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from '@/components/ui/card'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Badge } from '@/components/ui/badge'
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select'
import {
  RadioGroup,
  RadioGroupItem,
} from '@/components/ui/radio-group'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { useMusicFeedStore } from '@/lib/store'
import { useT, type UiLang } from '@/lib/i18n'
import { UI_LANGUAGES } from '@/lib/i18n-dicts'
import type { AudioFormat } from '@/lib/types'

export function SettingsPage() {
  const { config, setConfig, saveConfig, resetConfig, baseDirExists, uiLang, setUiLang } = useMusicFeedStore()
  const t = useT()
  const [newHidden, setNewHidden] = useState('')
  const [wizardOpen, setWizardOpen] = useState(false)
  const [saving, setSaving] = useState(false)

  const handleSave = async () => {
    setSaving(true)
    try {
      await saveConfig()
      toast.success(t('设置已保存'), {
        description: t('MF_BASE_DIR 等已写入 mf_config.sh'),
      })
    } catch (e) {
      toast.error(t('保存失败：{m}', { m: e instanceof Error ? e.message : String(e) }))
    } finally {
      setSaving(false)
    }
  }

  const handleReset = () => {
    resetConfig()
    toast.info(t('已恢复默认设置（需点保存才会写入）'))
  }

  const addHidden = () => {
    const v = newHidden.trim()
    if (!v) return
    if (config.MF_HIDDEN_DIRS.includes(v)) {
      toast.warning(t('该文件夹已在列表中'))
      return
    }
    setConfig({ MF_HIDDEN_DIRS: [...config.MF_HIDDEN_DIRS, v] })
    setNewHidden('')
  }

  const removeHidden = (name: string) => {
    setConfig({
      MF_HIDDEN_DIRS: config.MF_HIDDEN_DIRS.filter((d) => d !== name),
    })
  }

  return (
    <div className="flex flex-col gap-4">
      <h2 className="flex items-center gap-2 text-lg font-semibold">
        <SettingsIcon className="size-5 text-emerald-600 dark:text-emerald-400" />
        {t('设置')}
      </h2>

      {!baseDirExists && (
        <div className="flex items-start gap-2 rounded-md border border-amber-500/40 bg-amber-500/10 px-3 py-2 text-xs text-amber-700 dark:text-amber-300">
          <FolderX className="mt-0.5 size-4 shrink-0" />
          <span>
            {t('当前 MF_BASE_DIR「{d}」不存在或不可访问，请修改为有效路径后再保存（保存时会自动尝试创建子文件夹）。', { d: config.MF_BASE_DIR })}
          </span>
        </div>
      )}

      <Card>
        <CardHeader>
          <CardTitle className="text-base">{t('基础配置')}</CardTitle>
          <CardDescription>
            {t('对应 mf_config.sh 的 MF_ 变量。保存后下次启动 musicfeed 时生效。')}
          </CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-6">
          {/* 界面语言（仅 WebUI，独立于 mf_config 的 MF_LANG） */}
          <Field
            label={t('界面语言')}
            icon={<Languages className="size-4" />}
            hint={t(
              '界面语言仅作用于网页界面，不影响下载任务的日志语言（由 mf_config.sh 的 MF_LANG 决定）',
            )}
          >
            <Select
              value={uiLang}
              onValueChange={(v) => {
                setUiLang(v as UiLang)
                document.documentElement.lang = v
              }}
            >
              <SelectTrigger className="w-full sm:w-60">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {UI_LANGUAGES.map(({ value, label }) => (
                  <SelectItem key={value} value={value}>
                    {label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </Field>

          {/* 音乐根目录 */}
          <Field
            label={t('音乐根目录 (MF_BASE_DIR)')}
            icon={<FolderOpen className="size-4" />}
            hint={t('所有歌手文件夹都会在此目录下创建')}
          >
            <Input
              value={config.MF_BASE_DIR}
              onChange={(e) => setConfig({ MF_BASE_DIR: e.target.value })}
              className="font-mono text-xs"
              placeholder="/home/z/navidrome/music"
            />
          </Field>

          {/* 默认歌手文件夹 */}
          <Field
            label={t('默认歌手文件夹 (MF_DEFAULT_ARTIST_DIR)')}
            icon={<FolderOpen className="size-4" />}
            hint={t('作为选文件夹列表的第 1 项（默认选项）')}
          >
            <Input
              value={config.MF_DEFAULT_ARTIST_DIR}
              onChange={(e) =>
                setConfig({ MF_DEFAULT_ARTIST_DIR: e.target.value })
              }
              className="w-full sm:w-60"
              placeholder="musicfeed"
            />
          </Field>

          {/* 音频格式 */}
          <Field
            label={t('默认音频格式 (MF_AUDIO_FORMAT)')}
            icon={<FileAudio className="size-4" />}
            hint={t('Opus 体积小、音质优；M4A 兼容性好（iOS/Apple Music）')}
          >
            <RadioGroup
              value={config.MF_AUDIO_FORMAT}
              onValueChange={(v) => setConfig({ MF_AUDIO_FORMAT: v as AudioFormat })}
              className="grid gap-2 sm:grid-cols-2"
            >
              <RadioCard
                value="opus"
                checked={config.MF_AUDIO_FORMAT === 'opus'}
                title="Opus"
                desc={t("推荐 · 高压缩比")}
              />
              <RadioCard
                value="m4a"
                checked={config.MF_AUDIO_FORMAT === 'm4a'}
                title="M4A"
                desc={t("Apple 兼容性")}
              />
            </RadioGroup>
          </Field>

          {/* 隐藏文件夹 */}
          <Field
            label={t('隐藏文件夹 (MF_HIDDEN_DIRS)')}
            icon={<X className="size-4" />}
            hint={t('选歌手文件夹列表中要过滤掉的目录')}
          >
            <div className="flex flex-wrap items-center gap-2 rounded-md border border-border bg-muted/40 p-2">
              {config.MF_HIDDEN_DIRS.length === 0 && (
                <span className="text-xs text-muted-foreground">
                  {t('暂无隐藏文件夹')}
                </span>
              )}
              {config.MF_HIDDEN_DIRS.map((d) => (
                <Badge
                  key={d}
                  variant="secondary"
                  className="gap-1 bg-zinc-500/15 text-zinc-700 dark:text-zinc-300"
                >
                  {d}
                  <button
                    type="button"
                    onClick={() => removeHidden(d)}
                    aria-label={t("移除 {n}", { n: d })}
                    className="rounded-full p-0.5 hover:bg-zinc-500/20"
                  >
                    <X className="size-3" />
                  </button>
                </Badge>
              ))}
            </div>
            <div className="mt-2 flex gap-2">
              <Input
                value={newHidden}
                onChange={(e) => setNewHidden(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault()
                    addHidden()
                  }
                }}
                placeholder={t("输入名称后回车添加（如 @eaDir）")}
                className="font-mono text-xs"
              />
              <Button variant="outline" size="icon" onClick={addHidden} aria-label={t("添加")}>
                <Plus className="size-4" />
              </Button>
            </div>
          </Field>

          {/* yt-dlp 路径 */}
          <Field
            label={t("yt-dlp 路径 (MF_YTDLP)")}
            icon={<Terminal className="size-4" />}
            hint={t('留空则使用系统 PATH 中的 yt-dlp')}
          >
            <Input
              value={config.MF_YTDLP ?? ''}
              onChange={(e) => setConfig({ MF_YTDLP: e.target.value })}
              className="font-mono text-xs"
              placeholder="yt-dlp"
            />
          </Field>
        </CardContent>
      </Card>

      {/* 操作按钮 */}
      <div className="flex flex-wrap justify-end gap-2">
        <Button
          variant="outline"
          onClick={() => setWizardOpen(true)}
        >
          <Terminal className="size-4" />
          {t('运行设置向导')}
        </Button>
        <Button variant="outline" onClick={handleReset}>
          <RotateCcw className="size-4" />
          {t('恢复默认')}
        </Button>
        <Button
          onClick={handleSave}
          disabled={saving}
          className="bg-emerald-600 text-white hover:bg-emerald-700 dark:bg-emerald-500 dark:text-emerald-950 dark:hover:bg-emerald-400"
        >
          {saving ? (
            <>
              <Loader2 className="size-4 animate-spin" />
              {t('保存中…')}
            </>
          ) : (
            <>
              <Save className="size-4" />
              {t('保存设置')}
            </>
          )}
        </Button>
      </div>

      <p className="text-xs text-muted-foreground">
        {t('⚠️ 保存会直接覆写 musicfeed/mf_config.sh，原文件自动备份为 mf_config.sh.bak。')}
      </p>

      {/* 设置向导 Dialog */}
      <Dialog open={wizardOpen} onOpenChange={setWizardOpen}>
        <DialogContent className="sm:max-w-md">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <Terminal className="size-4" />
              {t('运行设置向导')}
            </DialogTitle>
            <DialogDescription>
              {t('设置向导需要交互式终端，无法在 Web UI 中直接运行。')}
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-2 rounded-md border border-border bg-muted/40 p-3">
            <p className="text-xs text-muted-foreground">
              {t('请在 musicfeed 项目根目录下执行：')}
            </p>
            <code className="block rounded bg-zinc-950 px-3 py-2 font-mono text-xs text-emerald-300">
              bash mf_setup.sh
            </code>
            <p className="text-xs text-muted-foreground">
              {t('向导会引导你完成语言选择、依赖检测、目录配置等步骤，并自动生成 mf_config.sh。')}
            </p>
          </div>
          <DialogFooter>
            <Button onClick={() => setWizardOpen(false)}>{t('知道了')}</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
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
}: {
  value: string
  checked: boolean
  title: string
  desc: string
}) {
  return (
    <label
      className={`flex cursor-pointer items-start gap-3 rounded-md border p-3 transition-colors hover:bg-accent ${
        checked ? 'border-emerald-500/60 bg-emerald-500/5' : 'border-border'
      }`}
    >
      <RadioGroupItem value={value} className="mt-0.5" />
      <div className="flex flex-col gap-0.5">
        <span className="text-sm font-medium">{title}</span>
        <span className="text-xs text-muted-foreground">{desc}</span>
      </div>
    </label>
  )
}
