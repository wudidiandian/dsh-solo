import { promises as fs } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { isPathAllowed, listDirectorySafe, scanShallowDirectories } from '../src/workspace'

let tmp: string

beforeAll(async () => {
  tmp = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-ws-'))
  // 结构：
  //   tmp/a/b/c            （b 深度 2，c 深度 3）
  //   tmp/a/file.txt
  //   tmp/.hidden/x
  //   tmp/node_modules/y
  await fs.mkdir(path.join(tmp, 'a', 'b', 'c'), { recursive: true })
  await fs.writeFile(path.join(tmp, 'a', 'file.txt'), 'hi')
  await fs.mkdir(path.join(tmp, '.hidden'), { recursive: true })
  await fs.writeFile(path.join(tmp, '.hidden', 'x'), '')
  await fs.mkdir(path.join(tmp, 'node_modules'), { recursive: true })
  await fs.writeFile(path.join(tmp, 'node_modules', 'y'), '')
})

afterAll(async () => {
  await fs.rm(tmp, { recursive: true, force: true })
})

describe('scanShallowDirectories', () => {
  it('按深度扫描并忽略隐藏目录与 node_modules', async () => {
    const [root] = await scanShallowDirectories([tmp], 2)
    expect(root.name).toBe(path.basename(tmp))
    expect(root.type).toBe('dir')

    const names = root.children!.map((c) => c.name)
    expect(names).toEqual(['a']) // .hidden / node_modules 被过滤

    const a = root.children![0]
    expect(a.children!.map((c) => c.name).sort()).toEqual(['b', 'file.txt'])

    const b = a.children!.find((c) => c.name === 'b')!
    // 深度耗尽：b 不再展开（children 为空数组，c 不可见）
    expect(b.children!.map((c) => c.name)).toEqual([])
  })

  it('不可读目录返回空节点而不抛错', async () => {
    const [root] = await scanShallowDirectories([path.join(tmp, 'no-such-dir')], 2)
    expect(root.children).toEqual([])
  })
})

describe('isPathAllowed（Workspace Jail）', () => {
  it('白名单内放行', () => {
    expect(isPathAllowed(tmp, [tmp])).toBe(true)
    expect(isPathAllowed(path.join(tmp, 'a', 'b'), [tmp])).toBe(true)
    expect(isPathAllowed('~', ['~'])).toBe(true)
  })

  it('目录穿越与白名单外拒绝', () => {
    expect(isPathAllowed(path.join(tmp, '..', '..'), [tmp])).toBe(false)
    expect(isPathAllowed('C:\\Windows\\System32', [tmp])).toBe(false)
    expect(isPathAllowed('/etc', [tmp])).toBe(false)
    // 前缀相似但非子目录（如 tmp-evil）也必须拒绝
    expect(isPathAllowed(tmp + '-evil', [tmp])).toBe(false)
  })
})

describe('listDirectorySafe', () => {
  it('列出白名单内一层子项且过滤隐藏项', async () => {
    const items = await listDirectorySafe(path.join(tmp, 'a'), [tmp])
    expect(items.map((i) => i.name).sort()).toEqual(['b', 'file.txt'])
    expect(items.find((i) => i.name === 'b')!.type).toBe('dir')
    expect(items.find((i) => i.name === 'file.txt')!.type).toBe('file')
  })

  it('白名单外抛出沙盒错误', async () => {
    await expect(listDirectorySafe(path.join(tmp, '..', '..'), [tmp])).rejects.toThrow(
      /outside workspace roots/,
    )
  })
})
