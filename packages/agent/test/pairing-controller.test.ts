import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
// @ts-expect-error 客户端控制器为纯 JS 模块
import { PairingController } from '../client/pairing-controller.js'

function fakeApi(initial: string) {
  const state = { svg: initial, fail: false }
  return {
    state,
    read: async () => {
      if (state.fail) throw Object.assign(new Error('boom'), { code: 'failed' })
      return { qrSvg: state.svg, maskedToken: 'dsh-solo-••••', browserUrl: null, relayConnected: true }
    },
    reveal: async () => ({ token: 'dshpair1.secret' }),
    reset: async () => ({ qrSvg: state.svg, maskedToken: 'dsh-solo-••••', browserUrl: null, relayConnected: true }),
  }
}

beforeEach(() => vi.useFakeTimers())
afterEach(() => vi.useRealTimers())

describe('PairingController 静默轮询（桌面配对面板二维码自动刷新）', () => {
  it('启动取数；密钥轮换后 5s 内静默换图，不触发 loading/ busy 闪烁', async () => {
    const api = fakeApi('<svg v1>')
    const ctl = new PairingController(api)
    ctl.start()
    await vi.advanceTimersByTimeAsync(0)
    expect(ctl.snapshot.data.qrSvg).toBe('<svg v1>')
    expect(ctl.snapshot.loading).toBe(false)

    api.state.svg = '<svg v2>'
    await vi.advanceTimersByTimeAsync(5000)
    expect(ctl.snapshot.data.qrSvg).toBe('<svg v2>')
    expect(ctl.snapshot.loading).toBe(false)
    expect(ctl.snapshot.busy).toBe(false)
    expect(ctl.snapshot.error).toBeNull()
    ctl.stop()
  })

  it('二维码无变化时不通知订阅者（不打扰 UI）', async () => {
    const api = fakeApi('<svg v1>')
    const ctl = new PairingController(api)
    ctl.start()
    await vi.advanceTimersByTimeAsync(0)
    let notifications = 0
    ctl.subscribe(() => notifications++)
    await vi.advanceTimersByTimeAsync(10000)
    expect(notifications).toBe(0)
    ctl.stop()
  })

  it('轮询失败保留旧图不报错；stop 后不再轮询', async () => {
    const api = fakeApi('<svg v1>')
    const ctl = new PairingController(api)
    ctl.start()
    await vi.advanceTimersByTimeAsync(0)
    api.state.fail = true
    await vi.advanceTimersByTimeAsync(5000)
    expect(ctl.snapshot.data.qrSvg).toBe('<svg v1>')
    expect(ctl.snapshot.error).toBeNull()
    ctl.stop()
    api.state.fail = false
    api.state.svg = '<svg v3>'
    await vi.advanceTimersByTimeAsync(10000)
    expect(ctl.snapshot.data).toBeNull() // stop 已清空且不再取数
  })

  it('轮换后已展开的明文配对码被收起（避免复制失效码）', async () => {
    const api = fakeApi('<svg v1>')
    const ctl = new PairingController(api)
    ctl.start()
    await vi.advanceTimersByTimeAsync(0)
    await ctl.toggleToken()
    expect(ctl.snapshot.token).toBe('dshpair1.secret')
    api.state.svg = '<svg v2>'
    await vi.advanceTimersByTimeAsync(5000)
    expect(ctl.snapshot.token).toBeNull()
    expect(ctl.snapshot.data.qrSvg).toBe('<svg v2>')
    ctl.stop()
  })
})