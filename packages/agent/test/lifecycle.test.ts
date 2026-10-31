import { afterEach, expect, it, vi } from 'vitest'
import type { Context } from 'cordis'

const mocks = vi.hoisted(() => ({
  token: vi.fn(),
  options: null as any,
  coreStart: vi.fn(), coreStop: vi.fn(),
  relayStart: vi.fn(), relayStop: vi.fn(),
  pairingStart: vi.fn(), pairingStop: vi.fn(),
}))
vi.mock('../src/token.js', () => ({ resolveDeviceToken: mocks.token }))
vi.mock('node:fs/promises', () => ({ mkdir: vi.fn(async () => {}) }))
vi.mock('../src/core.js', () => ({ AgentCore: class {
  constructor(_client: unknown, opts: unknown) { mocks.options = opts }
  publishSnapshot = vi.fn(async () => {})
  start = mocks.coreStart
  stop = mocks.coreStop
} }))
vi.mock('../src/ws-client.js', () => ({ SoloRelayClient: class {
  on() {}
  start = mocks.relayStart
  stop = mocks.relayStop
} }))
vi.mock('../src/pairing.js', () => ({ PairingServer: class {
  start = mocks.pairingStart
  stop = mocks.pairingStop
} }))
import { apply } from '../src/index.js'

let cleanup: (() => void) | undefined
afterEach(() => { cleanup?.(); cleanup = undefined; vi.clearAllMocks() })
function context() {
  return {
    effect(setup: () => () => void) { cleanup = setup() },
    on: vi.fn(),
    agentDefaultModel: { currentSelection: () => ({ provider: 'test', model: 'test' }) },
    llm: {},
    connection: { fetch: { register: vi.fn(() => vi.fn()) } },
    agentPresets: { resolve: vi.fn(async () => ({ id: 'desktop-default' })), mount: vi.fn(async () => {}) },
  } as unknown as Context
}

it('registers resource cleanup with Cordis effects, without a dispose event', async () => {
  const ctx = context()
  const previousListeners = process.listenerCount('uncaughtException')
  mocks.token.mockResolvedValue('test-token')
  apply(ctx, { stateDir: '/test', relayUrl: 'ws://localhost.invalid/ws' })
  await vi.waitFor(() => expect(mocks.relayStart).toHaveBeenCalledOnce())
  expect((ctx as any).on).not.toHaveBeenCalledWith('dispose', expect.anything())
  cleanup!()
  cleanup = undefined
  expect(mocks.coreStop).toHaveBeenCalledOnce()
  expect(mocks.relayStop).toHaveBeenCalledOnce()
  expect(mocks.pairingStop).toHaveBeenCalledOnce()
  expect(process.listenerCount('uncaughtException')).toBe(previousListeners)
})

it('does not resurrect a disposed plugin when asynchronous token loading finishes', async () => {
  let resolve!: (token: string) => void
  mocks.token.mockReturnValue(new Promise<string>(r => { resolve = r }))
  apply(context(), { stateDir: '/test' })
  cleanup!()
  cleanup = undefined
  resolve('test-token')
  await Promise.resolve()
  await Promise.resolve()
  expect(mocks.relayStart).not.toHaveBeenCalled()
  expect(mocks.coreStart).not.toHaveBeenCalled()
  expect(mocks.pairingStart).not.toHaveBeenCalled()
})


it('lists registered available projects and binds a new session to the selected workspace', async () => {
  const project = { id: 'demo', title: 'Demo', path: 'D:/work/demo', status: vi.fn(async () => 'ok'), attachSession: vi.fn(async () => {}) }
  const missing = { ...project, id: 'missing', status: vi.fn(async () => 'missing-dir') }
  const handle = { agent: { session: { header: { id: 'created' } } }, dispose: vi.fn() }
  const create = vi.fn(async (_opts: unknown) => handle)
  const ctx = Object.assign(context(), {
    workspaceRegistry: { list: () => [project, missing], get: (id: string) => id === 'demo' ? project : undefined },
    agents: { create },
  })
  mocks.token.mockResolvedValue('test-token')
  apply(ctx, { stateDir: '/test' })
  await vi.waitFor(() => expect(mocks.relayStart).toHaveBeenCalledOnce())
  expect(await mocks.options.services.listProjects()).toEqual([{ id: 'demo', title: 'Demo' }])
  await mocks.options.services.createSession({ projectId: 'demo', cwd: 'D:/forged' })
  expect(create.mock.calls[0][0]).toMatchObject({ meta: { cwd: 'D:/work/demo' } })
  expect(project.attachSession).toHaveBeenCalledWith('created')
  await expect(mocks.options.services.createSession({ projectId: 'forged' })).rejects.toThrow('Project unavailable')
  expect(create).toHaveBeenCalledTimes(1)
  project.status.mockResolvedValue('missing-dir')
  await expect(mocks.options.services.createSession({ projectId: 'demo' })).rejects.toThrow('Project unavailable')
  expect(create).toHaveBeenCalledTimes(1)
})


it('mounts the desktop default preset before a mobile-created agent is published or prompted', async () => {
  const scope = { name: 'unpublished-agent-scope' }
  const availableTools: string[] = []
  const followup = vi.fn(() => expect(availableTools).toEqual(['pwsh', 'read_file']))
  const agent = { session: { header: { id: 'preset-session' } }, followup }
  const mount = vi.fn(async (ctx, id) => {
    expect(ctx).toBe(scope)
    expect(id).toBe('user-selected-preset')
    availableTools.push('pwsh', 'read_file')
  })
  const resolve = vi.fn(async () => ({ id: 'user-selected-preset' }))
  const create = vi.fn(async (opts) => {
    expect(opts.meta.agentPreset).toBe('user-selected-preset')
    expect(availableTools).toHaveLength(0)
    await opts.setup(scope, agent)
    expect(availableTools).toHaveLength(2)
    return { agent, dispose: vi.fn() }
  })
  const ctx = Object.assign(context(), { agents: { create }, agentPresets: { resolve, mount } })
  mocks.token.mockResolvedValue('test-token')
  apply(ctx, { stateDir: '/test' })
  await vi.waitFor(() => expect(mocks.relayStart).toHaveBeenCalledOnce())
  const session = await mocks.options.services.createSession({ cwd: 'D:/work/demo' })
  await session.submitPrompt('list project files')
  expect(resolve).toHaveBeenCalledWith()
  expect(mount).toHaveBeenCalledOnce()
  expect(followup).toHaveBeenCalledOnce()
})

it('fails creation when the desktop preset cannot mount instead of publishing a tool-less agent', async () => {
  const mount = vi.fn(async () => { throw new Error('preset activation failed') })
  const published = vi.fn()
  const create = vi.fn(async (opts) => {
    await opts.setup({}, {})
    published()
    return { agent: { session: { header: { id: 'broken' } } } }
  })
  const ctx = Object.assign(context(), {
    agents: { create },
    agentPresets: { resolve: async () => ({ id: 'broken-preset' }), mount },
  })
  mocks.token.mockResolvedValue('test-token')
  apply(ctx, { stateDir: '/test' })
  await vi.waitFor(() => expect(mocks.relayStart).toHaveBeenCalledOnce())
  await expect(mocks.options.services.createSession({ cwd: 'D:/work/demo' })).rejects.toThrow('preset activation failed')
  expect(published).not.toHaveBeenCalled()
})
