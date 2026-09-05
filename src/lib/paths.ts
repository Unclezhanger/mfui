/**
 * Robust project-root resolution for both dev and standalone production.
 *
 * Dev mode:   `next dev` → process.cwd() = project root ✓
 * Standalone: `node .next/standalone/server.js`
 *   - npm run start (cwd = project root)             → process.cwd() ✓
 *   - start.sh --prod (cwd = .next/standalone/)      → process.cwd() ✗
 *   - Docker entrypoint (cwd = .next/standalone/)    → process.cwd() ✗
 *
 * In the last two cases `process.cwd()` is `.next/standalone/`, not the
 * project root. While Docker / start.sh create symlinks (musicfeed→../../musicfeed)
 * to make paths work, relying on them is fragile — and the `.env` / Prisma
 * engine still need the real project root.
 *
 * This module walks up from `process.cwd()` (or `__dirname`-based fallback)
 * to find the directory that contains `package.json` (a reliable marker that
 * exists in the real project root but NOT in `.next/standalone/`), then
 * caches it. An explicit `MF_ROOT_DIR` env var wins over everything.
 */

import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'

let _root: string | null = null

/**
 * Detect the project root by walking up from `start` until a directory
 * containing `marker` is found (up to `maxDepth` levels).
 */
function walkUp(start: string, marker: string, maxDepth = 6): string | null {
  let dir = start
  for (let i = 0; i < maxDepth; i++) {
    if (fs.existsSync(path.join(dir, marker))) return dir
    const parent = path.dirname(dir)
    if (parent === dir) break
    dir = parent
  }
  return null
}

/**
 * Return the project root directory.
 *
 * Resolution order:
 * 1. `MF_ROOT_DIR` env var (explicit override)
 * 2. Walk up from `process.cwd()` looking for `package.json`
 * 3. Walk up from this file's directory looking for `package.json`
 * 4. Fallback to `process.cwd()`
 */
export function getProjectRoot(): string {
  if (_root) return _root

  // 1. explicit env var
  if (process.env.MF_ROOT_DIR) {
    _root = process.env.MF_ROOT_DIR
    return _root
  }

  // 2. walk up from cwd — `package.json` exists in the real project root
  //    but NOT in `.next/standalone/`, so this skips the standalone dir
  const fromCwd = walkUp(process.cwd(), 'package.json')
  if (fromCwd) {
    _root = fromCwd
    return _root
  }

  // 3. walk up from this file (src/lib/ → project root)
  let thisDir: string
  try {
    thisDir = path.dirname(fileURLToPath(import.meta.url))
  } catch {
    // CJS fallback
    thisDir = __dirname
  }
  const fromFile = walkUp(thisDir, 'package.json')
  if (fromFile) {
    _root = fromFile
    return _root
  }

  // 4. fallback
  _root = process.cwd()
  return _root
}
