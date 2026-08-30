// 额外语言词典聚合（en 内置于 i18n.ts，zh 为 key 语言无需词典）
import type { UiLang } from './i18n'
import { de } from './i18n-de'
import { es } from './i18n-es'
import { fr } from './i18n-fr'
import { ja } from './i18n-ja'
import { pt } from './i18n-pt'
import { ru } from './i18n-ru'

export const EXTRA_DICTS: Record<Exclude<UiLang, 'en' | 'zh'>, Record<string, string>> = {
  de,
  es,
  fr,
  ja,
  pt,
  ru,
}

export const UI_LANGUAGES: { value: UiLang; label: string }[] = [
  { value: 'en', label: 'English' },
  { value: 'zh', label: '中文' },
  { value: 'de', label: 'Deutsch' },
  { value: 'es', label: 'Español' },
  { value: 'fr', label: 'Français' },
  { value: 'ja', label: '日本語' },
  { value: 'pt', label: 'Português (BR)' },
  { value: 'ru', label: 'Русский' },
]
