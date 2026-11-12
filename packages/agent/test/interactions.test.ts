import { expect, it } from 'vitest'
import { InteractionBroker } from '../src/interactions.js'

function fixture() {
  const hooks = new Map<string, Function[]>()
  const ctx: any = {
    on(name: string, fn: Function, options?: { prepend?: boolean }) {
      const list = hooks.get(name) ?? []; hooks.set(name, list)
      if (options?.prepend) list.unshift(fn); else list.push(fn)
      return () => list.splice(list.indexOf(fn), 1)
    },
    waterfall(scope: unknown, event: string, req: unknown, fallback: Function) {
      const list = [...hooks.get(event) ?? []]
      const next = (): unknown => (list.shift() ?? fallback).call(scope, req, next)
      return next()
    },
  }
  let desktop: ((value: unknown) => void) | undefined
  let withdrawn = false
  ctx.on('approval/request', (req: any) => new Promise(resolve => {
    desktop = resolve
    req.signal.addEventListener('abort', () => { withdrawn = true; resolve('cancelled') })
  }))
  const broker = new InteractionBroker({ changed() {}, mobileAvailable: () => true })
  broker.install(ctx)
  const signal = new AbortController()
  const request = (event = 'approval/request', extra = {}) => ctx.waterfall({}, event,
    { agent: { sessionId: 'session-a' }, toolName: 'pwsh', signal: signal.signal, ...extra }, () => 'unavailable')
  return { broker, signal, request, desktop: (value: unknown) => desktop!(value), withdrawn: () => withdrawn }
}
const tick = () => new Promise(r => setTimeout(r, 0))

it('explicit, session-bound decisions settle once and withdraw the losing desktop request', async () => {
  const f = fixture(); const result = f.request(); await tick()
  const id = f.broker.snapshot()[0].id
  expect(() => f.broker.respond('wrong-session', id, { approved: true })).toThrow()
  expect(() => f.broker.respond('session-a', id, { approved: 1 })).toThrow()
  f.broker.respond('session-a', id, { approved: false })
  await expect(result).resolves.toBe('rejected')
  expect(f.withdrawn()).toBe(true)
  expect(f.signal.signal.aborted).toBe(false)
  expect(() => f.broker.respond('session-a', id, { approved: true })).toThrow()
  f.broker.dispose()
})

it('desktop settlement and parent cancellation remove reconnectable pending snapshots', async () => {
  const f = fixture(); const a = f.request(); await tick()
  expect(f.broker.snapshot()).toHaveLength(1)
  f.desktop('allowed-once'); await expect(a).resolves.toBe('allowed-once')
  expect(f.broker.snapshot()).toHaveLength(0)
  const b = f.request(); await tick(); f.signal.abort()
  await expect(b).resolves.toBe('cancelled'); expect(f.broker.snapshot()).toHaveLength(0)
  f.broker.dispose()
})

it('validates question IDs, options and multi-select; malformed answers leave the request pending', async () => {
  const f = fixture()
  const result = f.request('user-questions/request', { questions: [
    { id: 'q', question: 'Which page?', options: [{ label: 'Dashboard' }, { label: 'Game' }] },
  ] }); await tick()
  const id = f.broker.snapshot()[0].id
  expect(() => f.broker.respond('session-a', id, { answers: [{ id: 'q', selected: ['fake'] }] })).toThrow()
  expect(() => f.broker.respond('session-a', id, { answers: [{ id: 'q', selected: ['Dashboard', 'Game'] }] })).toThrow()
  expect(f.broker.snapshot()).toHaveLength(1)
  f.broker.respond('session-a', id, { answers: [{ id: 'q', selected: ['Game'], custom: 'snake' }] })
  await expect(result).resolves.toEqual({ answers: [{ id: 'q', selected: ['Game'], custom: 'snake' }] })
  f.broker.dispose()
})
