import { createServer } from 'node:http'
import { afterEach, expect, it } from 'vitest'
import { PairingServer } from '../src/pairing.js'
// @ts-expect-error Browser discovery is distributed as plain JavaScript.
import { discoverPairingPages } from '../client/discovery.js'

let pairing: PairingServer | undefined
let blocker: ReturnType<typeof createServer> | undefined
afterEach(async () => {
  pairing?.stop()
  if (blocker?.listening) await new Promise<void>(resolve => blocker!.close(() => resolve()))
})

it('discovers the next available port without exposing credentials through discovery CORS', async () => {
  blocker = createServer()
  await new Promise<void>(resolve => blocker!.listen(0, '127.0.0.1', resolve))
  const basePort = (blocker.address() as { port: number }).port
  pairing = new PairingServer({ basePort, maxPort: basePort + 20, getToken: () => 'private-pairing-token', getRelayUrl: () => 'wss://private.example/ws', resetToken: async () => 'new-token' })
  pairing.start()
  const deadline = Date.now() + 4000
  while (!pairing.address && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10))
  expect(pairing.address).toBeTruthy()
  expect(pairing.address).not.toBe(`http://127.0.0.1:${basePort}`)
  const status = await fetch(`${pairing.address}/api/status`)
  expect(status.headers.get('access-control-allow-origin')).toBe('*')
  expect(await status.json()).toEqual({ service: 'dsh-solo-pairing', url: pairing.address })
  const credentials = await fetch(`${pairing.address}/api/token`)
  expect(credentials.headers.get('access-control-allow-origin')).toBeNull()
  expect((await credentials.json()).token).toBe('private-pairing-token')
})

it('ignores unrelated responses and refuses a discovery response that redirects outside loopback', async () => {
  const fetcher = async (url: string) => {
    if (url.includes(':8791/')) return { ok: true, json: async () => ({ service: 'dsh-solo-pairing', url: 'http://127.0.0.1:8791' }) }
    if (url.includes(':8792/')) return { ok: true, json: async () => ({ service: 'dsh-solo-pairing', url: 'https://other.example' }) }
    return { ok: true, json: async () => ({ service: 'unrelated' }) }
  }
  expect(await discoverPairingPages({ fetcher })).toEqual(['http://127.0.0.1:8791'])
})

it('returns no pages when discovery has been cancelled', async () => {
  const controller = new AbortController()
  controller.abort()
  expect(await discoverPairingPages({ signal: controller.signal, fetcher: () => { throw new Error('Must not fetch') } })).toEqual([])
})


it('does not leave a pairing listener running when stopped during startup', async () => {
  pairing = new PairingServer({ basePort: 0, getToken: () => 'test', getRelayUrl: () => 'ws://test.invalid/ws', resetToken: async () => 'test' })
  pairing.start()
  pairing.stop()
  await new Promise(resolve => setTimeout(resolve, 20))
  expect(pairing.address).toBeNull()
})
