'use client'

import { useState } from 'react'
import { toast } from 'sonner'
import {
  Save,
  RotateCcw,
  FolderOpen,
  X,
  Languages,
  FileAudio,
  Settings as SettingsIcon,
  Loader2,
  FolderX,
  FolderTree,
  ChevronUp,
  Folder,
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
import { Checkbox } from '@/components/ui/checkbox'
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
import { ScrollArea } from '@/components/ui/scroll-area'
import { useMusicFeedStore } from '@/lib/store'
import { useT, type UiLang } from '@/lib/i18n'
import { UI_LANGUAGES } from '@/lib/i18n-dicts'
import * as api from '@/lib/api'
import type { AudioFormat } from '@/lib/types'

export function SettingsPage() {
  const { config, setConfig, saveConfig, resetConfig, baseDirExists, uiLang, setUiLang } = useMusicFeedStore()
  const folders = useMusicFeedStore((s) => s.folders)
  const t = useT()
  const [saving, setSaving] = useState(false)
  // 目录树选取器
  const [pickerOpen, setPickerOpen] = useState(false)
  const [pickerPath, setPickerPath] = useState('/')
  const [pickerParent, setPickerParent] = useState<string | null>(null)
  const [pickerDirs, setPickerDirs] = useState<string[]>([])
  const [pickerLoading, setPickerLoading] = useState(false)
  const [pickerManual, setPickerManual] = useState('')

  const handleSave = async () => {
    // 主文件夹不允许为空（隐藏文件夹/下载目录都依赖它）
    if (!config.MF_BASE_DIR.trim()) {
      toast.warning(t('音乐根目录不能为空'))
      return
    }
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
    // 恢复 = 回滚到页面初始化时 mf_config.sh 的原始快照（store.resetConfig），
    // 仍需点保存才写入
    resetConfig()
    toast.info(t('已恢复默认设置（需点保存才会写入）'))
  }

  const openPicker = async () => {
    setPickerOpen(true)
    const start = config.MF_BASE_DIR.trim() || '/'
    setPickerPath(start)
    await loadDirs(start)
  }

  const loadDirs = async (dir: string) => {
    setPickerLoading(true)
    try {
      const res = await api.browseDirs(dir)
      setPickerPath(res.path || dir)
      setPickerParent(res.parent)
      setPickerDirs(res.dirs)
    } catch {
      setPickerDirs([])
      toast.error(t('无法读取该目录'))
    } finally {
      setPickerLoading(false)
    }
  }

  const toggleHidden = (name: string) => {
    if (config.MF_HIDDEN_DIRS.includes(name)) {
      setConfig({ MF_HIDDEN_DIRS: config.MF_HIDDEN_DIRS.filter((d) => d !== name) })
    } else {
      setConfig({ MF_HIDDEN_DIRS: [...config.MF_HIDDEN_DIRS, name] })
    }
  }

  // checklist 条目：已选置顶（排序，含不在根目录列表中的历史配置项），未选按名称排列
  const hiddenItems: string[] = [
    ...config.MF_HIDDEN_DIRS.slice().sort((a, b) => a.localeCompare(b)),
    ...folders
      .filter((f) => !config.MF_HIDDEN_DIRS.includes(f))
      .sort((a, b) => a.localeCompare(b)),
  ]

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
          <Field label={t('界面语言')} icon={<Languages className="size-4" />}>
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

          {/* 音乐根目录 + 默认歌手文件夹（左列）与隐藏文件夹（右列）两栏布局：
              隐藏文件夹盒子顶部与主目录输入框齐平、底部与歌手文件夹下拉框齐平 */}
          <div className="grid gap-6 sm:grid-cols-2">
            {/* 左列 */}
            <div className="flex flex-col gap-6">
              <Field
                label={t('音乐根目录 (MF_BASE_DIR)')}
                icon={<FolderOpen className="size-4" />}
                hint={t('所有歌手文件夹都会在此目录下创建')}
              >
                <div className="flex gap-2">
                  <Input
                    value={config.MF_BASE_DIR}
                    onChange={(e) => setConfig({ MF_BASE_DIR: e.target.value })}
                    className="font-mono text-xs"
                    placeholder="/home/user/music"
                  />
                  <Button variant="outline" onClick={openPicker} className="shrink-0">
                    <FolderTree className="size-4" />
                    {t('浏览')}
                  </Button>
                </div>
              </Field>

              <Field
                label={t('默认歌手文件夹 (MF_DEFAULT_ARTIST_DIR)')}
                icon={<FolderOpen className="size-4" />}
                hint={t('作为选文件夹列表的第 1 项（默认选项）')}
              >
                <Select
                  value={config.MF_DEFAULT_ARTIST_DIR}
                  onValueChange={(v) => setConfig({ MF_DEFAULT_ARTIST_DIR: v })}
                >
                  <SelectTrigger className="w-full">
                    <SelectValue placeholder={t('选择文件夹')} />
                  </SelectTrigger>
                  <SelectContent>
                    {/* 当前值不在列表里（配置了但还没创建）也要能显示 */}
                    {config.MF_DEFAULT_ARTIST_DIR && !folders.includes(config.MF_DEFAULT_ARTIST_DIR) && (
                      <SelectItem value={config.MF_DEFAULT_ARTIST_DIR}>
                        📁 {config.MF_DEFAULT_ARTIST_DIR}（{t('默认，未创建')}）
                      </SelectItem>
                    )}
                    {folders.map((f) => (
                      <SelectItem key={f} value={f}>
                        📁 {f}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </Field>
            </div>

            {/* 右列：隐藏文件夹（固定高度滚动盒子，与左侧两字段大致对齐） */}
            <Field
              label={t('隐藏文件夹 (MF_HIDDEN_DIRS)')}
              icon={<X className="size-4" />}
              hint={t('选歌手文件夹列表中要过滤掉的目录；可全部不选')}
            >
              <div className="h-40 overflow-y-auto rounded-md border border-border bg-muted/40 p-1.5">
                {/* 已选置顶（排序），未选按名称排列；长名截断，悬浮显示全称 */}
                {hiddenItems.map((name) => (
                  <label
                    key={name}
                    title={name}
                    className="flex cursor-pointer items-center gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-accent"
                  >
                    <Checkbox
                      checked={config.MF_HIDDEN_DIRS.includes(name)}
                      onCheckedChange={() => toggleHidden(name)}
                      aria-label={
                        config.MF_HIDDEN_DIRS.includes(name)
                          ? t('取消隐藏 {n}', { n: name })
                          : t('隐藏 {n}', { n: name })
                      }
                    />
                    <span className="truncate font-mono text-xs">{name}</span>
                  </label>
                ))}
                {hiddenItems.length === 0 && (
                  <p className="p-2 text-xs text-muted-foreground">{t('暂无隐藏文件夹')}</p>
                )}
              </div>
            </Field>
          </div>

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
        </CardContent>
      </Card>

      {/* 操作按钮 */}
      <div className="flex flex-wrap justify-end gap-2">
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

      {/* 目录树选取 Dialog */}
      <Dialog open={pickerOpen} onOpenChange={setPickerOpen}>
        <DialogContent className="sm:max-w-lg">
          <DialogHeader>
            <DialogTitle className="flex items-center gap-2">
              <FolderTree className="size-4" />
              {t('选择音乐根目录')}
            </DialogTitle>
            <DialogDescription>
              {t('点击文件夹进入，选好后点「使用此目录」。')}
            </DialogDescription>
          </DialogHeader>
          <div className="flex items-center gap-2 rounded-md border border-border bg-muted/40 px-2 py-1.5">
            <code className="flex-1 truncate font-mono text-xs">{pickerPath}</code>
            <Button
              variant="ghost"
              size="icon"
              disabled={!pickerParent || pickerLoading}
              onClick={() => pickerParent && void loadDirs(pickerParent)}
              aria-label={t('上一级')}
            >
              <ChevronUp className="size-4" />
            </Button>
          </div>
          <ScrollArea className="h-64 rounded-md border border-border">
            <div className="flex flex-col p-1">
              {pickerLoading && (
                <div className="flex items-center gap-2 p-2 text-sm text-muted-foreground">
                  <Loader2 className="size-4 animate-spin" />
                  {t('读取中…')}
                </div>
              )}
              {!pickerLoading && pickerDirs.length === 0 && (
                <p className="p-2 text-sm text-muted-foreground">
                  {t('无子文件夹（可点「使用此目录」选择当前位置）')}
                </p>
              )}
              {pickerDirs.map((d) => (
                <button
                  key={d}
                  type="button"
                  onClick={() => void loadDirs(d)}
                  className="flex items-center gap-2 rounded-md px-2 py-1.5 text-left text-sm hover:bg-accent"
                >
                  <Folder className="size-4 shrink-0 text-emerald-600 dark:text-emerald-400" />
                  <span className="truncate font-mono text-xs">{d}</span>
                </button>
              ))}
            </div>
          </ScrollArea>
          <div className="flex gap-2">
            <Input
              value={pickerManual}
              onChange={(e) => setPickerManual(e.target.value)}
              placeholder={t('或手动输入绝对路径')}
              className="font-mono text-xs"
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  e.preventDefault()
                  void loadDirs(pickerManual.trim())
                }
              }}
            />
            <Button variant="outline" onClick={() => void loadDirs(pickerManual.trim())}>
              {t('前往')}
            </Button>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setPickerOpen(false)}>
              {t('取消')}
            </Button>
            <Button
              onClick={() => {
                setConfig({ MF_BASE_DIR: pickerPath })
                setPickerOpen(false)
              }}
              className="bg-emerald-600 text-white hover:bg-emerald-700"
            >
              {t('使用此目录')}
            </Button>
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
  className,
  children,
}: {
  label: string
  hint?: string
  icon?: React.ReactNode
  className?: string
  children: React.ReactNode
}) {
  return (
    <div
      className={`flex flex-col gap-2 border-l-2 border-emerald-500/40 pl-4 ${className ?? ''}`}
    >
      <div className="flex items-center gap-2">
        {icon && (
          <span className="text-emerald-600 dark:text-emerald-400">{icon}</span>
        )}
        <Label className="text-sm font-medium">{label}</Label>
      </div>
      {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
      <div className="mt-1 min-h-0 flex-1">{children}</div>
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
