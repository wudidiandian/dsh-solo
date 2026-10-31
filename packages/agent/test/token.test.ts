import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { TOKEN_FILE_NAME, TOKEN_PREFIX, generateToken, resolveDeviceToken } from '../src/token'

describe('device token', () => {
  it('generateToken: dsh-solo- 前缀 + 48 位 hex，两次生成不同', () => {
    const a = generateToken()
    const b = generateToken()
    expect(a).toMatch(/^dsh-solo-[0-9a-f]{48}$/)
    expect(b).toMatch(/^dsh-solo-[0-9a-f]{48}$/)
    expect(a).not.toBe(b)
  })

  it('解析顺序：显式配置优先于持久化文件', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dsh-token-'))
    try {
      await writeFile(join(dir, TOKEN_FILE_NAME), 'dsh-solo-from-file\n', 'utf8')
      const token = await resolveDeviceToken('dsh-solo-explicit', dir)
      expect(token).toBe('dsh-solo-explicit')
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })

  it('解析顺序：无显式配置时读持久化文件（容忍尾部换行）', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dsh-token-'))
    try {
      await writeFile(join(dir, TOKEN_FILE_NAME), 'dsh-solo-persisted\n', 'utf8')
      const token = await resolveDeviceToken(undefined, dir)
      expect(token).toBe('dsh-solo-persisted')
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })

  it('解析顺序：文件缺失时自动生成并原子写入（下次可直接读回）', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'dsh-token-'))
    try {
      const token = await resolveDeviceToken(undefined, dir)
      expect(token).toMatch(new RegExp(`^${TOKEN_PREFIX}[0-9a-f]{48}$`))
      const onDisk = (await readFile(join(dir, TOKEN_FILE_NAME), 'utf8')).trim()
      expect(onDisk).toBe(token)
      // 第二次解析应命中持久化文件而不是再生成
      const again = await resolveDeviceToken(undefined, dir)
      expect(again).toBe(token)
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })
})
