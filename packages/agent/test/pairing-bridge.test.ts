import { describe, expect, it, vi } from 'vitest'
import QRCode from 'qrcode'
import { registerPairingBridge } from '../src/pairing-bridge.js'
import { pairUri } from '../src/pairing.js'
// @ts-expect-error Browser helpers are distributed as JavaScript.
import { createPairingApi, localBrowserUrl } from '../client/pairing-api.js'
// @ts-expect-error Browser controller is distributed as JavaScript.
import { PairingController } from '../client/pairing-controller.js'

function bridge() {
  const routes = new Map<string, any>()
  let token = 'dsh-solo-private-token'
  let active = true
  const reset = vi.fn(async () => { token = 'dsh-solo-new-token'; return token })
  const dispose = registerPairingBridge({ fetch: { register: (route) => {
    routes.set(route.path, route)
    return () => routes.delete(route.path)
  } } }, {
    getToken: () => token, getRelayUrl: () => 'wss://relay.example/ws',
    getBrowserUrl: () => 'http://127.0.0.1:8793', isConnected: () => true,
    isActive: () => active, resetToken: reset,
  })
  const request = async (operation: string, payload: unknown = {}, signal?: AbortSignal) => {
    const method = `dsh-solo-pairing/${operation}`
    return routes.get(`/api/${method}`).fetch(new Request(`http://host/api/${method}`, {
      method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ type: 'client-request', rpcId: 'request-1', method, payload }), signal,
    }))
  }
  return { routes, request, reset, dispose, deactivate: () => { active = false } }
}

describe('authenticated pairing bridge', () => {
  it('uses only owner-only Connection routes, masks the token and does not cache responses', async () => {
    const b = bridge()
    expect([...b.routes.keys()]).toEqual(['/api/dsh-solo-pairing/read', '/api/dsh-solo-pairing/reveal', '/api/dsh-solo-pairing/reset'])
    const response = await b.request('read')
    expect(response.headers.get('cache-control')).toBe('no-store')
    expect(response.headers.get('access-control-allow-origin')).toBeNull()
    const { result } = await response.json()
    expect(result.value.maskedToken).not.toContain('private-token')
    expect(result.value.token).toBeUndefined()
    expect(result.value.qrSvg).toBe(await QRCode.toString(pairUri('wss://relay.example/ws', 'dsh-solo-private-token'), { type: 'svg', margin: 1 }))
    expect(b.reset).not.toHaveBeenCalled()
    b.dispose()
    expect(b.routes.size).toBe(0)
  })
  it('reveals only on explicit request and rebuilds the QR from the rotated token', async () => {
    const b = bridge()
    expect((await (await b.request('reveal')).json()).result.value.token).toBe('dsh-solo-private-token')
    const data = (await (await b.request('reset')).json()).result.value
    expect(b.reset).toHaveBeenCalledTimes(1)
    expect(data.qrSvg).toBe(await QRCode.toString(pairUri('wss://relay.example/ws', 'dsh-solo-new-token'), { type: 'svg', margin: 1 }))
    expect((await (await b.request('reveal')).json()).result.value.token).toBe('dsh-solo-new-token')
    b.dispose()
  })
  it('refuses malformed, aborted and disposed requests without rotating credentials', async () => {
    const b = bridge()
    expect((await b.request('reset', { unexpected: true })).status).toBe(400)
    const controller = new AbortController(); controller.abort()
    expect((await (await b.request('reset', {}, controller.signal)).json()).result.ok).toBe(false)
    b.deactivate()
    expect((await (await b.request('reset')).json()).result.ok).toBe(false)
    expect(b.reset).not.toHaveBeenCalled()
    b.dispose()
  })
})

describe('embedded pairing client', () => {
  const data = { qrSvg: '<svg></svg>', maskedToken: '••••', relayConnected: true }
  it('uses the selected Host API and never opens a loopback link for a remote browser', async () => {
    const call = vi.fn(async () => ({ ok: true, value: data }))
    await createPairingApi({ rpc: { call } }).read()
    expect(call).toHaveBeenCalledWith('/api', 'dsh-solo-pairing/read', {}, undefined)
    expect(localBrowserUrl('http://127.0.0.1:8790', false)).toBeNull()
    expect(localBrowserUrl('https://evil.example', true)).toBeNull()
    expect(localBrowserUrl('http://127.0.0.1:8790/?token=secret', true)).toBeNull()
    expect(localBrowserUrl('http://127.0.0.1:8793', true)).toBe('http://127.0.0.1:8793')
  })
  it('clears revealed credentials and ignores late results after leaving the panel', async () => {
    let finish!: (value: unknown) => void
    const model = new PairingController({
      read: async () => data, reveal: () => new Promise(resolve => { finish = resolve }),
    })
    model.start()
    await vi.waitFor(() => expect(model.getSnapshot().data).toBe(data))
    const pending = model.toggleToken()
    model.stop()
    finish({ token: 'must-not-reappear' })
    await pending
    expect(model.getSnapshot().data).toBeNull()
    expect(model.getSnapshot().token).toBeNull()
  })
  it('hides the old QR immediately on reset, refreshes it, and supports hiding a revealed token', async () => {
    let finish!: (value: unknown) => void
    const model = new PairingController({ read: async () => data,
      reset: () => new Promise(resolve => { finish = resolve }), reveal: async () => ({ token: 'revealed' }) })
    model.start()
    await vi.waitFor(() => expect(model.getSnapshot().data).toBe(data))
    await model.toggleToken()
    expect(model.getSnapshot().token).toBe('revealed')
    await model.toggleToken()
    expect(model.getSnapshot().token).toBeNull()
    const pending = model.reset()
    expect(model.getSnapshot().data).toBeNull()
    const fresh = { ...data, qrSvg: '<svg id="new"></svg>' }
    finish(fresh)
    await pending
    expect(model.getSnapshot().data).toBe(fresh)
    model.stop()
  })
  it('times out cleanly and discards superseded refresh responses', async () => {
    let finish!: (value: unknown) => void
    const read = vi.fn().mockImplementationOnce(() => new Promise(resolve => { finish = resolve })).mockResolvedValue(data)
    const model = new PairingController({ read }, { timeoutMs: 50 })
    model.start()
    await vi.waitFor(() => expect(model.getSnapshot().error).toBe('failed'))
    await model.refresh()
    finish({ ...data, qrSvg: '<svg id="stale"></svg>' })
    await Promise.resolve()
    expect(model.getSnapshot().data).toBe(data)
    expect(model.getSnapshot().error).toBeNull()
    model.stop()
  })
})
