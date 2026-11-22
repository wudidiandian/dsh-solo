import { describe, expect, it } from 'vitest'
import { HostAdapter } from '../src/host-adapter'

/** 已实机核实的宿主形状（dsh 0.2.1-rc.2，见 host-adapter.ts 兼容矩阵） */
function fullCtx(): any {
  return {
    version: '0.2.1-rc.2',
    agents: { create: () => {}, get: () => null, list: () => [] },
    sessions: { get: () => null, list: () => [] },
    llm: { listModels: async () => [] },
    sessionQuery: { readSession: async () => ({ events: [] }) },
    workspaceRegistry: {},
    waterfall: () => {},
    on: () => () => {},
  }
}

describe('HostAdapter.capabilities', () => {
  it('完整宿主：能力全开，delete 为 own-only，setModel 初始保守 false', () => {
    const host = new HostAdapter(fullCtx())
    expect(host.capabilities()).toEqual({
      'session.create': true,
      'session.setModel': false,
      'session.interrupt': false,
      'session.delete': 'own-only',
      'session.rename': true,
      'session.history': true,
      interactions: true,
      models: true,
      projects: true,
      fileUpload: true,
    })
  })

  it('空宿主：全部降级为 false，不抛错', () => {
    const host = new HostAdapter({})
    const caps = host.capabilities()
    expect(caps['session.create']).toBe(false)
    expect(caps['session.rename']).toBe(false)
    expect(caps['session.history']).toBe(false)
    expect(caps.interactions).toBe(false)
    expect(caps.models).toBe(false)
    expect(caps.projects).toBe(false)
    expect(caps['session.delete']).toBe('own-only')
    expect(caps.fileUpload).toBe(true)
  })

  it('宿主提供通用删除 API 时 delete 升级为 all', () => {
    const ctx = fullCtx()
    ctx.sessions.delete = () => {}
    expect(new HostAdapter(ctx).capabilities()['session.delete']).toBe('all')
    const ctx2 = fullCtx()
    ctx2.agents.delete = () => {}
    expect(new HostAdapter(ctx2).capabilities()['session.delete']).toBe('all')
  })

  it('noteSetModel 仅在能力变化时返回 true（触发快照重报）', () => {
    const host = new HostAdapter(fullCtx())
    expect(host.noteSetModel(false)).toBe(false) // 与初始值相同
    expect(host.noteSetModel(true)).toBe(true)
    expect(host.capabilities()['session.setModel']).toBe(true)
    expect(host.noteSetModel(true)).toBe(false) // 重复探测不重报
    expect(host.noteSetModel(false)).toBe(true)
    expect(host.capabilities()['session.setModel']).toBe(false)
  })
})

describe('HostAdapter.listAllModels（跨 provider 聚合）', () => {
  it('聚合所有 provider 目录、按 id 去重、补 provider 字段', async () => {
    const host = new HostAdapter({
      llm: {
        listProviders: () => [{ id: 'deepseek-account', name: '账号' }, { id: 'custom-key', name: '自定义' }],
        listModels: async (p: string) => {
          if (p === 'deepseek-account') return [{ id: 'deepseek-flash' }, { id: 'shared-model' }]
          if (p === 'custom-key') return [{ id: 'qwen4-max' }, { id: 'shared-model', provider: 'other' }]
          return []
        },
      },
    })
    const models = await host.listAllModels('deepseek-account') as any[]
    expect(models.map(m => m.id)).toEqual(['deepseek-flash', 'shared-model', 'qwen4-max'])
    expect(models.find(m => m.id === 'qwen4-max').provider).toBe('custom-key')
    expect(models.find(m => m.id === 'deepseek-flash').provider).toBe('deepseek-account')
    // 先注册 provider 优先：shared-model 保留 account 归属
    expect(models.find(m => m.id === 'shared-model').provider).toBe('deepseek-account')
  })

  it('单个 provider 失败不影响其余；无 listProviders 时回落默认 provider', async () => {
    const host = new HostAdapter({
      llm: {
        listProviders: () => [{ id: 'broken' }, { id: 'ok' }],
        listModels: async (p: string) => {
          if (p === 'broken') throw new Error('no adapter registered')
          return [{ id: 'm1' }]
        },
      },
    })
    expect((await host.listAllModels('x') as any[]).map(m => m.id)).toEqual(['m1'])
    const legacy = new HostAdapter({
      llm: { listModels: async (p: string) => (p === 'fallback' ? [{ id: 'm2' }] : []) },
    })
    expect((await legacy.listAllModels('fallback') as any[]).map(m => m.id)).toEqual(['m2'])
  })

  it('llm 缺失或目录全空返回空数组', async () => {
    expect(await new HostAdapter({}).listAllModels('x')).toEqual([])
    const empty = new HostAdapter({ llm: { listProviders: () => [{ id: 'a' }], listModels: async () => [] } })
    expect(await empty.listAllModels('x')).toEqual([])
  })
})

describe('HostAdapter.hostVersion', () => {
  it('按已知形状探测版本', () => {
    expect(new HostAdapter(fullCtx()).hostVersion).toBe('0.2.1-rc.2')
    expect(new HostAdapter({ app: { version: '9.9.9' } }).hostVersion).toBe('9.9.9')
    expect(new HostAdapter({ root: { app: { version: '1.2.3' } } }).hostVersion).toBe('1.2.3')
  })

  it('探测不到或非字符串时缺省，不猜测', () => {
    expect(new HostAdapter({}).hostVersion).toBeUndefined()
    expect(new HostAdapter({ version: 42 }).hostVersion).toBeUndefined()
    expect(new HostAdapter(null).hostVersion).toBeUndefined()
  })
})

describe('HostAdapter.on', () => {
  it('宿主无 on 时返回可用的取消函数（降级不抛错）', () => {
    const host = new HostAdapter({})
    const dispose = host.on('session/event', () => {})
    expect(typeof dispose).toBe('function')
    expect(() => dispose()).not.toThrow()
  })

  it('宿主有 on 时透传注册', () => {
    const calls: string[] = []
    const host = new HostAdapter({ on: (ev: string) => { calls.push(ev); return () => {} } })
    host.on('agent/status', () => {})
    expect(calls).toEqual(['agent/status'])
  })
})