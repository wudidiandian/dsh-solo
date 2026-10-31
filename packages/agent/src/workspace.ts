import os from 'node:os'
import path from 'node:path'
import { promises as fs, type Dirent } from 'node:fs'
import type { AgentSnapshotPayload, DirTreeNode } from '@dsh-solo/protocol'

const IGNORED = new Set([
  'node_modules', '.git', 'dist', 'build', 'out', '.next', '.nuxt',
  '__pycache__', '.venv', 'venv', 'target', '.gradle', '.idea',
])
const MAX_ENTRIES_PER_DIR = 200

/** 展开 `~` 为用户主目录（兼容 `~/xxx`） */
export function expandHome(p: string): string {
  if (p === '~') return os.homedir()
  if (p.startsWith('~/') || p.startsWith('~\\')) return path.join(os.homedir(), p.slice(2))
  return p
}

/** 扫描常用工作区根目录，生成浅目录树快照（默认 2 层，App 端秒开数据源） */
export async function scanShallowDirectories(roots: string[], depth = 2): Promise<DirTreeNode[]> {
  const nodes: DirTreeNode[] = []
  for (const root of roots) {
    const abs = path.resolve(expandHome(root))
    nodes.push(await scanNode(abs, path.basename(abs) || abs, depth))
  }
  return nodes
}

async function scanNode(abs: string, name: string, depth: number): Promise<DirTreeNode> {
  const node: DirTreeNode = { name, path: abs, type: 'dir' }
  const children: DirTreeNode[] = []
  node.children = children
  if (depth <= 0) return node
  let entries: Dirent[]
  try {
    entries = await fs.readdir(abs, { withFileTypes: true })
  } catch {
    return node // 无权限/不存在：返回空目录节点，不让快照整体失败
  }
  for (const entry of entries.slice(0, MAX_ENTRIES_PER_DIR)) {
    if (entry.name.startsWith('.') || IGNORED.has(entry.name)) continue
    const childAbs = path.join(abs, entry.name)
    if (entry.isDirectory()) {
      children.push(await scanNode(childAbs, entry.name, depth - 1))
    } else if (entry.isFile()) {
      children.push({ name: entry.name, path: childAbs, type: 'file' })
    }
  }
  return node
}

/**
 * 路径沙盒校验（设计文档 §7.1 Workspace Jail）：
 * 目标路径必须严格位于白名单根目录之内，严防 `../../` 目录穿越。
 * Windows 文件系统大小写不敏感，比较时归一化大小写。
 */
export function isPathAllowed(target: string, roots: string[]): boolean {
  const norm = (p: string) => {
    const abs = path.resolve(expandHome(p))
    return process.platform === 'win32' ? abs.toLowerCase() : abs
  }
  const t = norm(target)
  return roots.some((root) => {
    const r = norm(root)
    return t === r || t.startsWith(r + path.sep)
  })
}

/** 手机端展开深层目录：按需读取一层子项（含沙盒校验） */
export async function listDirectorySafe(target: string, roots: string[]): Promise<DirTreeNode[]> {
  if (!isPathAllowed(target, roots)) {
    throw new Error(`path outside workspace roots: ${target}`)
  }
  const abs = path.resolve(expandHome(target))
  const entries = await fs.readdir(abs, { withFileTypes: true })
  return entries
    .slice(0, MAX_ENTRIES_PER_DIR)
    .filter((e) => !e.name.startsWith('.'))
    .map((e) => ({
      name: e.name,
      path: path.join(abs, e.name),
      type: e.isDirectory() ? ('dir' as const) : ('file' as const),
    }))
}

export type { AgentSnapshotPayload }
