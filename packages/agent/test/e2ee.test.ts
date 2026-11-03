import { randomBytes } from 'node:crypto'
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { expect, it } from 'vitest'
import { acceptSecureHello, SecureInitiator, resolvePairingKey } from '../src/e2ee'
import { pairingCode, pairUri } from '../src/pairing'

const key = Buffer.alloc(32, 7).toString('base64url')
const token = 'test-token'
function pair() {
  const mobile = new SecureInitiator(token, key)
  const agent = acceptSecureHello(token, key, mobile.hello())
  return { mobile: mobile.accept(agent.welcome), agent: agent.channel }
}
it('authenticates ephemeral keys and encrypts Unicode prompts, attachments and approvals', () => {
  const { mobile, agent } = pair()
  for (const action of ['session.prompt', 'file.offer', 'file.chunk', 'approval.respond', 'session.history']) {
    const env = { v: 1, type: 'cmd.dispatch' as const, payload: { action, data: { text: '秘密：测试🚀', filename: 'private.txt' } } }
    const packet = mobile.seal(env)
    expect(JSON.stringify(packet)).not.toContain('private.txt')
    expect(JSON.stringify(packet)).not.toContain('秘密')
    expect(agent.open(packet)).toEqual(env)
    expect(mobile.open(agent.seal({ v: 1, type: 'rpc.response', payload: { ok: true } })).payload).toEqual({ ok: true })
  }
})
it('rejects a relay that knows only the connection token', () => {
  const mobile = new SecureInitiator(token, key)
  expect(() => acceptSecureHello(token, randomBytes(32).toString('base64url'), mobile.hello())).toThrow(/authentication/)
  const accepted = acceptSecureHello(token, key, mobile.hello())
  expect(() => mobile.accept({ ...accepted.welcome, publicKey: randomBytes(32).toString('base64url') })).toThrow(/authentication/)
  expect(() => acceptSecureHello('different-room', key, mobile.hello())).toThrow(/authentication/)
})
it('rejects tampering, altered counters, replay and direction reflection', () => {
  const { mobile, agent } = pair()
  const packet = mobile.seal({ v: 1, type: 'cmd.dispatch', payload: { secret: 'one' } })
  expect(() => agent.open({ ...packet, counter: 2 })).toThrow(/order/)
  const corrupted = Buffer.from(packet.ciphertext, 'base64'); corrupted[0] ^= 1
  expect(() => agent.open({ ...packet, ciphertext: corrupted.toString('base64') })).toThrow()
  expect(() => mobile.open(packet)).toThrow()
  expect(agent.open(packet).payload).toEqual({ secret: 'one' })
  expect(() => agent.open(packet)).toThrow(/Replay/)
})
it('reconnection and different phones use independent keys and cannot replay cached frames', () => {
  const first = pair(), second = pair()
  expect(first.mobile.id).not.toBe(second.mobile.id)
  const packet = first.agent.seal({ v: 1, type: 'agent.snapshot', payload: { private: true } })
  expect(() => second.mobile.open(packet)).toThrow()
  expect(first.mobile.open(packet).payload).toEqual({ private: true })
})
it('persists an independent key, rotates with the token, and never derives it from the relay token', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'dsh-e2ee-'))
  try {
    const first = await resolvePairingKey(dir, token)
    expect(await resolvePairingKey(dir, token)).toBe(first)
    const second = await resolvePairingKey(dir, token + '-reset')
    expect(second).not.toBe(first)
    const saved = await readFile(join(dir, 'pairing-key.json'), 'utf8')
    expect(saved).not.toContain(token)
    if (process.platform !== 'win32') expect((await stat(join(dir, 'pairing-key.json'))).mode & 0o777).toBe(0o600)
    const qr = new URL(pairUri('wss://example.invalid/ws', token, second))
    expect(qr.searchParams.get('key')).toBe(second)
    expect(qr.searchParams.get('e2ee')).toBe('1')
    const code = JSON.parse(Buffer.from(pairingCode('wss://example.invalid/ws', token, second).slice(9), 'base64url').toString())
    expect(code).toEqual({ relay: 'wss://example.invalid/ws', token, key: second })
  } finally { await rm(dir, { recursive: true, force: true }) }
})
