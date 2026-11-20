import { mkdtemp, rm, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { DeviceRegistry } from '../src/devices'
import { acceptSecureHello, SecureInitiator, rotatePairingKey, resolvePairingKey } from '../src/e2ee'

const TOKEN = 'dsh-solo-test-token'
const deviceId = () => 'a'.repeat(32)

let dir: string
beforeEach(async () => { dir = await mkdtemp(join(tmpdir(), 'dsh-dev-')) })
afterEach(async () => { await rm(dir, { recursive: true, force: true }) })

describe('DeviceRegistry', () => {
  it('注册生成设备密钥；重注册幂等返回同一密钥（created=false）', async () => {
    const reg = new DeviceRegistry(dir)
    const first = await reg.register(deviceId(), '我的手机')
    expect(first.created).toBe(true)
    expect(first.deviceKey).toMatch(/^[A-Za-z0-9_-]{43}$/)
    const again = await reg.register(deviceId(), '')
    expect(again.created).toBe(false)
    expect(again.deviceKey).toBe(first.deviceKey)
    expect(reg.list()).toHaveLength(1)
    expect(reg.list()[0].name).toBe('我的手机')
  })

  it('非法 deviceId 拒绝；撤销后密钥失效且列表移除', async () => {
    const reg = new DeviceRegistry(dir)
    await expect(reg.register('short', '')).rejects.toThrow('Invalid device id')
    const { deviceKey } = await reg.register(deviceId(), '')
    expect(reg.keys()[0].key).toBe(deviceKey)
    expect(await reg.revoke(deviceId())).toBe(true)
    expect(await reg.revoke(deviceId())).toBe(false)
    expect(reg.list()).toHaveLength(0)
    expect(reg.keys()).toHaveLength(0)
  })

  it('持久化跨实例恢复；clear 清空（令牌重置场景）', async () => {
    const reg = new DeviceRegistry(dir)
    await reg.register(deviceId(), 'phone')
    const restored = new DeviceRegistry(dir)
    await restored.load()
    expect(restored.has(deviceId())).toBe(true)
    await restored.clear()
    const again = new DeviceRegistry(dir)
    await again.load()
    expect(again.list()).toHaveLength(0)
  })

  it('重命名与在线追踪', async () => {
    const reg = new DeviceRegistry(dir)
    await reg.register(deviceId(), '')
    expect(await reg.rename(deviceId(), '办公室手机')).toBe(true)
    expect(reg.list()[0].name).toBe('办公室手机')
    await reg.touch(deviceId())
    expect(reg.list()[0].lastSeen).toBeGreaterThan(0)
  })
})

describe('设备密钥 E2EE 与主密钥轮换', () => {
  it('设备密钥可独立握手；主密钥轮换后旧 QR 密钥失效、设备密钥仍可用', async () => {
    const master = await resolvePairingKey(dir, TOKEN)
    const reg = new DeviceRegistry(dir)
    const { deviceKey } = await reg.register(deviceId(), '')

    // 设备密钥握手成功
    const initiator = new SecureInitiator(TOKEN, deviceKey)
    const accepted = acceptSecureHello(TOKEN, deviceKey, initiator.hello())
    expect(accepted.welcome.id).toBe(initiator.id)

    // 模拟新设备注册后轮换主密钥
    const rotated = await rotatePairingKey(dir, TOKEN)
    expect(rotated).not.toBe(master)

    // 旧主密钥（被撤销设备持有的 QR 密钥）握手失败
    const oldQr = new SecureInitiator(TOKEN, master)
    expect(() => acceptSecureHello(TOKEN, rotated, oldQr.hello())).toThrow()
    // 设备密钥不受轮换影响（ws-client 用设备密钥验证，而非轮换后的主密钥）
    const stillOk = new SecureInitiator(TOKEN, deviceKey)
    expect(() => acceptSecureHello(TOKEN, deviceKey, stillOk.hello())).not.toThrow()
    // 持久化的主密钥确已更新
    expect(await resolvePairingKey(dir, TOKEN)).toBe(rotated)
  })

  it('devices.json 不含明文令牌，密钥文件权限 0600', async () => {
    const reg = new DeviceRegistry(dir)
    await reg.register(deviceId(), '')
    const raw = await readFile(join(dir, 'devices.json'), 'utf8')
    expect(raw).not.toContain(TOKEN)
    expect(JSON.parse(raw).devices[0].key).toMatch(/^[A-Za-z0-9_-]{43}$/)
  })
})