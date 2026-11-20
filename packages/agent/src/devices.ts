import { randomBytes } from 'node:crypto'
import { mkdir, readFile, writeFile, rename, chmod } from 'node:fs/promises'
import { join } from 'node:path'
import { decodeKey } from './e2ee.js'

/**
 * 已配对设备注册表（<stateDir>/devices.json，0600）。
 *
 * 每台手机首次连接时用 QR 里的主配对密钥完成 E2EE 握手，随后发送
 * device.register 领取**设备专属密钥**；插件同时轮换主密钥（配对页二维码
 * 随之更新）。此后该手机用设备密钥握手，撤销 = 删除设备密钥，被撤销设备
 * 既无有效设备密钥、也无最新主密钥，无法再建立加密会话——除非重新扫码。
 *
 * 旧版 App 不注册设备，继续用主密钥握手（向后兼容），无法单独撤销。
 */
export interface DeviceRecord {
  /** 32 位 hex，App 生成并持久化 */
  id: string
  name: string
  /** 设备专属 E2EE 密钥（base64url 32B） */
  key: string
  pairedAt: number
  lastSeen: number
}

export interface PublicDevice {
  id: string
  name: string
  pairedAt: number
  lastSeen: number
}

const ID_PATTERN = /^[0-9a-f]{32}$/
/** lastSeen 落盘节流：频繁指令不反复写盘 */
const TOUCH_PERSIST_INTERVAL_MS = 60_000

export class DeviceRegistry {
  private devices: DeviceRecord[] = []
  private loaded = false
  private lastPersist = 0

  constructor(private readonly stateDir: string) {}

  private get path(): string {
    return join(this.stateDir, 'devices.json')
  }

  async load(): Promise<void> {
    if (this.loaded) return
    this.loaded = true
    try {
      const raw = JSON.parse(await readFile(this.path, 'utf8'))
      if (Array.isArray(raw?.devices)) {
        this.devices = raw.devices.filter(
          (d: any) => ID_PATTERN.test(d?.id ?? '') && typeof d?.key === 'string' && (() => { try { decodeKey(d.key); return true } catch { return false } })(),
        ).map((d: any) => ({
          id: d.id,
          name: typeof d.name === 'string' ? d.name : '',
          key: d.key,
          pairedAt: Number(d.pairedAt) || 0,
          lastSeen: Number(d.lastSeen) || 0,
        }))
      }
      await chmod(this.path, 0o600)
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
        console.error('[dsh-solo-agent] cannot read device registry; starting empty:', (error as Error).message)
      }
    }
  }

  private async persist(): Promise<void> {
    await mkdir(this.stateDir, { recursive: true, mode: 0o700 })
    const temporary = `${this.path}.${randomBytes(8).toString('hex')}.tmp`
    await writeFile(temporary, JSON.stringify({ devices: this.devices }), { mode: 0o600 })
    await rename(temporary, this.path)
    this.lastPersist = Date.now()
  }

  /**
   * 注册（或幂等重注册）设备。created=true 表示新设备——调用方应轮换主密钥；
   * 重注册返回既有设备密钥，不轮换（容忍 App 注册响应丢失后的重试）。
   */
  async register(deviceId: string, name: string): Promise<{ deviceKey: string; created: boolean }> {
    await this.load()
    if (!ID_PATTERN.test(deviceId)) throw new Error('Invalid device id')
    const cleanName = name.trim().slice(0, 64)
    const existing = this.devices.find(d => d.id === deviceId)
    if (existing) {
      if (cleanName) existing.name = cleanName
      existing.lastSeen = Date.now()
      await this.persist()
      return { deviceKey: existing.key, created: false }
    }
    if (this.devices.length >= 64) throw new Error('Too many paired devices; revoke one first')
    const key = randomBytes(32).toString('base64url')
    const now = Date.now()
    this.devices.push({ id: deviceId, name: cleanName || `Phone ${deviceId.slice(0, 4)}`, key, pairedAt: now, lastSeen: now })
    await this.persist()
    return { deviceKey: key, created: true }
  }

  async revoke(deviceId: string): Promise<boolean> {
    await this.load()
    const before = this.devices.length
    this.devices = this.devices.filter(d => d.id !== deviceId)
    if (this.devices.length === before) return false
    await this.persist()
    return true
  }

  async rename(deviceId: string, name: string): Promise<boolean> {
    await this.load()
    const device = this.devices.find(d => d.id === deviceId)
    if (!device) return false
    device.name = name.trim().slice(0, 64) || device.name
    await this.persist()
    return true
  }

  /** 令牌重置等场景：清空全部设备（所有手机需重新扫码） */
  async clear(): Promise<void> {
    await this.load()
    this.devices = []
    await this.persist()
  }

  list(): PublicDevice[] {
    return this.devices.map(({ id, name, pairedAt, lastSeen }) => ({ id, name, pairedAt, lastSeen }))
  }

  /** ws-client 多密钥握手用 */
  keys(): Array<{ id: string; key: string }> {
    return this.devices.map(d => ({ id: d.id, key: d.key }))
  }

  has(deviceId: string): boolean {
    return this.devices.some(d => d.id === deviceId)
  }

  /** 更新最近在线时间（节流落盘） */
  async touch(deviceId: string): Promise<void> {
    const device = this.devices.find(d => d.id === deviceId)
    if (!device) return
    device.lastSeen = Date.now()
    if (Date.now() - this.lastPersist >= TOUCH_PERSIST_INTERVAL_MS) {
      await this.persist().catch(() => {})
    }
  }
}