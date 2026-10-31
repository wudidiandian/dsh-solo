import { describe, expect, it, vi } from 'vitest'
import type { Envelope } from '@dsh-solo/protocol'
import { makeEnvelope } from '@dsh-solo/protocol'
import { AgentCore, type AgentSessionLike, type ApprovalRequest, type HarnessServices } from '../src/core'

// ---------------------------------------------------------------------------
// mock 设施
// ---------------------------------------------------------------------------

class MockRelay {
  sent: Envelope[] = []
  private handlers = new Map<string, Array<(env: Envelope) => void>>()

  send(env: Envelope) {
    this.sent.push(env)
  }

  on(event: 'connected' | 'command', cb: (env?: Envelope) => void) {
    const list = this.handlers.get(event) ?? []
    list.push(cb as (env: Envelope) => void)
    this.handlers.set(event, list)
  }

  emit(event: 'connected' | 'command', env?: Envelope) {
    for (const cb of this.handlers.get(event) ?? []) cb(env)
  }

  ofType(type: string) {
    return this.sent.filter((e) => e.type === type)
  }

  lastCommandResponse() {
    return this.ofType('rpc.response').at(-1)
  }
}

function makeServices() {
  const sessions = new Map<string, AgentSessionLike>()
  let created = 0
  const listeners: Array<(sessionId: string, event: { kind?: string }) => void> = []
  let approvalHandler: ((req: ApprovalRequest) => Promise<boolean>) | null = null

  const services: HarnessServices = {
    listModels: async () => [{ id: 'deepseek-v3' }],
    listSessions: async () => [...sessions.values()],
    createSession: async (opts) => {
      created++
      const s: AgentSessionLike = {
        id: `sess_new_${created}`,
        model: opts.model,
        setModel: vi.fn(async () => {
          s.model = undefined
        }),
        submitPrompt: vi.fn(async () => {}),
      }
      sessions.set(s.id, s)
      return s
    },
    getSession: async (id) => sessions.get(id) ?? null,
    onSessionEvent: (cb) => {
      listeners.push(cb)
      return () => {
        const i = listeners.indexOf(cb)
        if (i >= 0) listeners.splice(i, 1)
      }
    },
    registerApprovalHandler: (h) => {
      approvalHandler = h
    },
  }
  return {
    services,
    sessions,
    emitEvent: (sessionId: string, event: { kind?: string }) => {
      for (const cb of listeners) cb(sessionId, event)
    },
    approve: (req: ApprovalRequest) => {
      if (!approvalHandler) throw new Error('approval handler not registered')
      return approvalHandler(req)
    },
  }
}

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

describe('AgentCore', () => {
  it('connected 后上报 HostSnapshot（模型+会话+目录树）', async () => {
    const relay = new MockRelay()
    const { services } = makeServices()
    const core = new AgentCore(relay, {
      services,
      buildSnapshot: async () => ({ dirTree: [{ name: 'proj', path: '/p', type: 'dir' }] }),
    })
    core.start()
    relay.emit('connected')
    // 等待异步快照
    await vi.waitFor(() => expect(relay.ofType('agent.snapshot').length).toBe(1))

    const snap = relay.ofType('agent.snapshot')[0]
    const payload = snap.payload as { models: unknown[]; sessions: unknown[]; dirTree: unknown[]; timestamp: number }
    expect(payload.models).toEqual([{ id: 'deepseek-v3' }])
    expect(payload.dirTree).toHaveLength(1)
    expect(payload.timestamp).toBeGreaterThan(0)
  })

  it('会话事件流转为带 seqId 的信封，pushLevel 按类型推断', () => {
    const relay = new MockRelay()
    const { services, emitEvent } = makeServices()
    const core = new AgentCore(relay, { services })
    core.start()

    emitEvent('s1', { kind: 'text.delta', text: 'he' })
    emitEvent('s1', { kind: 'text.delta', text: 'llo' })
    emitEvent('s1', { kind: 'turn.completed' })

    const events = relay.ofType('session.event')
    expect(events).toHaveLength(3)
    expect(events[0].seqId).toBe(1)
    expect(events[0].pushLevel).toBe('none')
    expect(events[1].seqId).toBe(2)
    expect(events[2].seqId).toBe(3)
    expect(events[2].pushLevel).toBe('normal')
    expect(events[2].pushSummary).toBe('任务已完成')
  })

  it('审批拦截：high 推送 + 挂起等待，手机端 respond 后 resolve', async () => {
    const relay = new MockRelay()
    const { services, approve } = makeServices()
    const core = new AgentCore(relay, { services })
    core.start()

    const pending = approve({ id: 'ap-1', sessionId: 's1', toolName: 'bash', summary: 'rm -rf' })

    const approvalEvents = relay.ofType('session.event')
    expect(approvalEvents).toHaveLength(1)
    expect(approvalEvents[0].pushLevel).toBe('high')
    expect(approvalEvents[0].pushSummary).toContain('bash')
    expect((approvalEvents[0].payload as { approvalId: string }).approvalId).toBe('ap-1')
    expect(core.pendingApprovalCount).toBe(1)

    // 手机端点击允许
    relay.emit(
      'command',
      makeEnvelope('cmd.dispatch', { action: 'approval.respond', data: { approvalId: 'ap-1', approved: true } }, { reqId: 'r1' }),
    )
    await expect(pending).resolves.toBe(true)
    expect(core.pendingApprovalCount).toBe(0)
    expect(relay.lastCommandResponse()?.reqId).toBe('r1')
    expect((relay.lastCommandResponse()?.payload as { ok: boolean }).ok).toBe(true)
  })

  it('stop 时未决审批一律拒绝', async () => {
    const relay = new MockRelay()
    const { services, approve } = makeServices()
    const core = new AgentCore(relay, { services })
    core.start()

    const pending = approve({ id: 'ap-2', toolName: 'git push' })
    core.stop()
    await expect(pending).resolves.toBe(false)
  })

  it('session.prompt：缺省新建会话 + 切模型 + 提交 prompt，回传 rpc.ok', async () => {
    const relay = new MockRelay()
    const { services } = makeServices()
    const core = new AgentCore(relay, { services })
    core.start()

    relay.emit(
      'command',
      makeEnvelope(
        'cmd.dispatch',
        { action: 'session.prompt', data: { cwd: '~/proj', modelId: 'm2', prompt: '帮我重构' } },
        { reqId: 'r2' },
      ),
    )
    await vi.waitFor(() => expect(relay.ofType('rpc.response').length).toBe(1))

    const resp = relay.lastCommandResponse()!
    expect(resp.reqId).toBe('r2')
    const payload = resp.payload as { ok: boolean; result: { sessionId: string } }
    expect(payload.ok).toBe(true)
    expect(payload.result.sessionId).toBe('sess_new_1')
  })

  it('session.prompt：未知 sessionId 返回 rpc 错误', async () => {
    const relay = new MockRelay()
    const { services } = makeServices()
    // 预置一个已有会话，使 getSession('nope') 返回 null 走 create 分支之外的场景：
    // 这里直接构造 getSession 永远 null 且 create 抛错的服务
    const broken: HarnessServices = {
      ...services,
      createSession: async () => {
        throw new Error('create failed')
      },
    }
    const core = new AgentCore(relay, { services: broken })
    core.start()

    relay.emit(
      'command',
      makeEnvelope('cmd.dispatch', { action: 'session.prompt', data: { prompt: 'x' } }, { reqId: 'r3' }),
    )
    await vi.waitFor(() => expect(relay.ofType('rpc.response').length).toBe(1))
    const payload = relay.lastCommandResponse()!.payload as { ok: boolean; error: string }
    expect(payload.ok).toBe(false)
    expect(payload.error).toContain('create failed')
  })

  it('fs.list_dir 走注入的沙盒实现并回传结果', async () => {
    const relay = new MockRelay()
    const { services } = makeServices()
    const core = new AgentCore(relay, {
      services,
      listDir: async () => [{ name: 'a', path: '/x/a', type: 'dir' }],
    })
    core.start()

    relay.emit(
      'command',
      makeEnvelope('cmd.dispatch', { action: 'fs.list_dir', data: { path: '~/x' } }, { reqId: 'r4' }),
    )
    await vi.waitFor(() => expect(relay.ofType('rpc.response').length).toBe(1))
    const payload = relay.lastCommandResponse()!.payload as { ok: boolean; result: unknown[] }
    expect(payload.ok).toBe(true)
    expect(payload.result[0]).toMatchObject({ name: 'a' })
  })

  it('未知 action 返回错误响应', async () => {
    const relay = new MockRelay()
    const { services } = makeServices()
    const core = new AgentCore(relay, { services })
    core.start()

    relay.emit(
      'command',
      makeEnvelope('cmd.dispatch', { action: 'hack.system', data: {} }, { reqId: 'r5' }),
    )
    await vi.waitFor(() => expect(relay.ofType('rpc.response').length).toBe(1))
    const payload = relay.lastCommandResponse()!.payload as { ok: boolean; error: string }
    expect(payload.ok).toBe(false)
    expect(payload.error).toContain('unknown action')
  })

  it('stop 取消会话事件订阅', () => {
    const relay = new MockRelay()
    const { services, emitEvent } = makeServices()
    const core = new AgentCore(relay, { services })
    core.start()
    core.stop()
    emitEvent('s1', { kind: 'text.delta' })
    expect(relay.ofType('session.event')).toHaveLength(0)
  })

  it('session.history：全量返回内存缓冲，sinceSeqId 走磁盘增量过滤', async () => {
    const { mkdtemp, rm } = await import('node:fs/promises')
    const { tmpdir } = await import('node:os')
    const { join } = await import('node:path')
    const dir = await mkdtemp(join(tmpdir(), 'dsh-hist-'))
    try {
      const relay = new MockRelay()
      const { services, emitEvent } = makeServices()
      const core = new AgentCore(relay, { services, historyDir: dir })
      core.start()

      emitEvent('s1', { kind: 'text.delta', text: 'a' })
      emitEvent('s1', { kind: 'text.delta', text: 'b' })
      emitEvent('s1', { kind: 'turn.completed' })

      const ask = async (reqId: string, data: Record<string, unknown>) => {
        relay.emit('command', makeEnvelope('cmd.dispatch', { action: 'session.history', data }, { reqId }))
        await vi.waitFor(() => expect(relay.ofType('rpc.response').some((e) => e.reqId === reqId)).toBe(true))
        return relay.ofType('rpc.response').find((e) => e.reqId === reqId)!.payload as {
          ok: boolean
          result?: { events: Array<{ kind?: string; seqId?: number }> }
        }
      }

      // 全量（内存缓冲命中，事件内嵌 seqId）
      const full = await ask('h1', { sessionId: 's1' })
      expect(full.ok).toBe(true)
      expect(full.result?.events).toHaveLength(3)
      expect(full.result?.events.map((e) => e.seqId)).toEqual([1, 2, 3])

      // 等落盘 promise 链完成，验证磁盘文件已写入
      await vi.waitFor(async () => {
        const raw = await import('node:fs/promises').then((fs) => fs.readFile(join(dir, 's1.jsonl'), 'utf8'))
        expect(raw.trim().split('\n')).toHaveLength(3)
      })

      // 增量：清空内存缓冲模拟淘汰，只能靠磁盘 jsonl 过滤
      const clear = (core as unknown as { historyBuffers: Map<string, unknown[]> }).historyBuffers
      clear.delete('s1')
      const inc = await ask('h2', { sessionId: 's1', sinceSeqId: 2 })
      expect(inc.ok).toBe(true)
      expect(inc.result?.events.map((e) => e.seqId)).toEqual([3])
      expect(inc.result?.events[0]?.kind).toBe('turn.completed')
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })

  it('session.history：磁盘文件不存在时回退内存缓冲过滤', async () => {
    const { mkdtemp, rm } = await import('node:fs/promises')
    const { tmpdir } = await import('node:os')
    const { join } = await import('node:path')
    const dir = await mkdtemp(join(tmpdir(), 'dsh-hist-'))
    try {
      const relay = new MockRelay()
      const { services, emitEvent } = makeServices()
      const core = new AgentCore(relay, { services, historyDir: dir })
      core.start()

      emitEvent('s2', { kind: 'text.delta', text: 'x' })
      emitEvent('s2', { kind: 'turn.completed' })

      relay.emit(
        'command',
        makeEnvelope(
          'cmd.dispatch',
          { action: 'session.history', data: { sessionId: 's2', sinceSeqId: 1 } },
          { reqId: 'h3' },
        ),
      )
      await vi.waitFor(() => expect(relay.ofType('rpc.response').some((e) => e.reqId === 'h3')).toBe(true))
      const payload = relay.ofType('rpc.response').find((e) => e.reqId === 'h3')!.payload as {
        ok: boolean
        result?: { events: Array<{ seqId?: number }> }
      }
      expect(payload.ok).toBe(true)
      expect(payload.result?.events.map((e) => e.seqId)).toEqual([2])
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })

  // -------------------------------------------------------------------------
  // 文件上传与附件（2026-10-28）
  // -------------------------------------------------------------------------

  it('file.offer/file.chunk：分块收齐落盘并回传路径，超限/未知传输被拒', async () => {
    const { mkdtemp, readFile, rm } = await import('node:fs/promises')
    const { tmpdir } = await import('node:os')
    const { join } = await import('node:path')
    const stateDir = await mkdtemp(join(tmpdir(), 'dsh-up-'))
    try {
      const relay = new MockRelay()
      const { services } = makeServices()
      const core = new AgentCore(relay, { services, stateDir })
      core.start()

      const dispatch = (action: string, data: unknown, reqId: string) =>
        relay.emit('command', makeEnvelope('cmd.dispatch', { action, data }, { reqId }))
      const respOf = async (reqId: string) => {
        await vi.waitFor(() =>
          expect(relay.ofType('rpc.response').some((e) => e.reqId === reqId)).toBe(true),
        )
        return relay.ofType('rpc.response').find((e) => e.reqId === reqId)!.payload as {
          ok: boolean
          result?: Record<string, unknown>
          error?: string
        }
      }

      // 超限 offer：agent 双保险拒绝
      dispatch('file.offer', { transferId: 't0', name: 'big.bin', size: (10 << 20) + 1, chunks: 1 }, 'o-big')
      expect((await respOf('o-big')).ok).toBe(false)
      expect((await respOf('o-big')).error).toContain('too large')

      // 正常传输：2 块收齐 → 落盘 → 最后一块回 done+path
      dispatch('file.offer', { transferId: 't1', name: 'photo 测试.jpg', size: 5, chunks: 2 }, 'o1')
      const offerResp = await respOf('o1')
      expect(offerResp.ok).toBe(true)
      dispatch('file.chunk', { transferId: 't1', index: 1, data: Buffer.from('AAAAA').toString('base64') }, 'c1')
      const c1 = await respOf('c1')
      expect(c1.ok).toBe(true)
      expect(c1.result).toMatchObject({ received: 1 })
      dispatch('file.chunk', { transferId: 't1', index: 0, data: Buffer.from('BBBB').toString('base64') }, 'c2')
      const c2 = await respOf('c2')
      expect(c2.ok).toBe(true)
      expect(c2.result?.done).toBe(true)
      expect(c2.result?.path).toBeTruthy()
      // 乱序分块也能按序拼回原始内容（index1=AAAAA, index0=BBBB → BBBBAAAAA）
      const disk = await readFile(c2.result!.path as string)
      expect(disk.toString()).toBe('BBBBAAAAA')

      // 未知 transfer 的 chunk：拒绝
      dispatch('file.chunk', { transferId: 'ghost', index: 0, data: '' }, 'u1')
      expect((await respOf('u1')).ok).toBe(false)
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('session.prompt 附件：upload/file 白名单校验、url 抓取，非法路径被拒', async () => {
    const { mkdtemp, rm, writeFile } = await import('node:fs/promises')
    const { tmpdir } = await import('node:os')
    const { join } = await import('node:path')
    const stateDir = await mkdtemp(join(tmpdir(), 'dsh-att-'))
    const root = await mkdtemp(join(tmpdir(), 'dsh-ws-'))
    try {
      await writeFile(join(root, 'doc.md'), 'hello doc')
      const relay = new MockRelay()
      const { services, sessions } = makeServices()
      const core = new AgentCore(relay, {
        services,
        stateDir,
        workspaceRoots: [root],
      })
      core.start()

      const dispatch = (action: string, data: unknown, reqId: string) =>
        relay.emit('command', makeEnvelope('cmd.dispatch', { action, data }, { reqId }))
      const respOf = async (reqId: string) => {
        await vi.waitFor(() =>
          expect(relay.ofType('rpc.response').some((e) => e.reqId === reqId)).toBe(true),
        )
        return relay.ofType('rpc.response').find((e) => e.reqId === reqId)!.payload as {
          ok: boolean
          result?: Record<string, unknown>
          error?: string
        }
      }

      // 先上传一个文件得到 uploads 内路径
      dispatch('file.offer', { transferId: 'u1', name: 'shot.jpg', size: 4, chunks: 1 }, 'uo')
      await respOf('uo')
      dispatch('file.chunk', {
        transferId: 'u1', index: 0, data: Buffer.from('IMG!').toString('base64'),
      }, 'uc')
      const done = await respOf('uc')
      const uploadPath = done.result!.path as string

      // prompt 携带 upload + file 附件：注入 [附件] 文本块（含路径），会话正常创建
      dispatch(
        'session.prompt',
        {
          prompt: '看这两个文件',
          attachments: [
            { kind: 'upload', name: 'shot.jpg', path: uploadPath },
            { kind: 'file', name: 'doc.md', path: join(root, 'doc.md') },
          ],
        },
        'p1',
      )
      const p1 = await respOf('p1')
      expect(p1.ok).toBe(true)
      const session = sessions.get((p1.result as { sessionId: string }).sessionId)!
      const promptArg = (session.submitPrompt as ReturnType<typeof vi.fn>).mock.calls[0][0] as string
      expect(promptArg).toContain('看这两个文件')
      expect(promptArg).toContain('[附件]')
      expect(promptArg).toContain(uploadPath)
      expect(promptArg).toContain('doc.md')

      // upload 附件路径白名单：指向 uploads 之外 → 整体报错
      dispatch(
        'session.prompt',
        { prompt: 'evil', attachments: [{ kind: 'upload', name: 'x', path: join(root, 'doc.md') }] },
        'p2',
      )
      expect((await respOf('p2')).ok).toBe(false)

      // file 附件超出 workspaceRoots → 拒绝
      dispatch(
        'session.prompt',
        { prompt: 'out', attachments: [{ kind: 'file', name: 'y', path: 'C:\\Windows\\system32\\evil.dll' }] },
        'p3',
      )
      expect((await respOf('p3')).ok).toBe(false)

      // url 附件：非法协议直接拒
      dispatch(
        'session.prompt',
        { prompt: 'url', attachments: [{ kind: 'url', name: 'z', url: 'file:///etc/passwd' }] },
        'p4',
      )
      expect((await respOf('p4')).ok).toBe(false)
      expect((await respOf('p4')).error).toContain('invalid url')
    } finally {
      await rm(stateDir, { recursive: true, force: true })
      await rm(root, { recursive: true, force: true })
    }
  })
})


describe('snapshot and shutdown regressions', () => {
  it('keeps the last snapshot on read failure, but publishes a genuine empty list', async () => {
    const relay = new MockRelay()
    const { services } = makeServices()
    const list = vi.spyOn(services, 'listSessions')
      .mockResolvedValueOnce([{ id: 'existing' }])
      .mockRejectedValueOnce(new Error('inactive context'))
      .mockResolvedValueOnce([])
    const log = vi.spyOn(console, 'error').mockImplementation(() => {})
    const core = new AgentCore(relay, { services })
    try {
      await core.publishSnapshot()
      await core.publishSnapshot()
      expect(relay.ofType('agent.snapshot')).toHaveLength(1)
      expect(relay.ofType('agent.snapshot')[0].payload).toMatchObject({ sessions: [{ id: 'existing' }] })
      await core.publishSnapshot()
      expect(relay.ofType('agent.snapshot')).toHaveLength(2)
      expect(relay.ofType('agent.snapshot')[1].payload).toMatchObject({ sessions: [] })
    } finally { core.stop(); list.mockRestore(); log.mockRestore() }
  })

  it('discards an older snapshot that finishes after a newer one', async () => {
    const relay = new MockRelay()
    const { services } = makeServices()
    let finish!: (sessions: unknown[]) => void
    services.listSessions = vi.fn()
      .mockImplementationOnce(() => new Promise(resolve => { finish = resolve }))
      .mockResolvedValueOnce([{ id: 'new' }])
    const core = new AgentCore(relay, { services })
    const old = core.publishSnapshot()
    await core.publishSnapshot()
    finish([{ id: 'old' }])
    await old
    expect(relay.ofType('agent.snapshot')).toHaveLength(1)
    expect(relay.ofType('agent.snapshot')[0].payload).toMatchObject({ sessions: [{ id: 'new' }] })
    core.stop()
  })

  it('does not publish pending snapshots or handle commands after stop', async () => {
    const relay = new MockRelay()
    const { services } = makeServices()
    let finish!: (sessions: unknown[]) => void
    services.listSessions = () => new Promise(resolve => { finish = resolve })
    const create = vi.spyOn(services, 'createSession')
    const core = new AgentCore(relay, { services })
    core.start()
    const pending = core.publishSnapshot()
    core.stop()
    finish([])
    await pending
    relay.emit('connected')
    relay.emit('command', makeEnvelope('cmd.dispatch', { action: 'session.prompt', data: { prompt: 'test' } }, { reqId: 'late' }))
    await Promise.resolve()
    expect(create).not.toHaveBeenCalled()
    expect(relay.sent).toHaveLength(0)
  })

  it('does not submit a pending prompt after its owning context is stopped', async () => {
    const relay = new MockRelay()
    const { services } = makeServices()
    let finish!: (session: AgentSessionLike) => void
    services.getSession = () => new Promise(resolve => { finish = resolve })
    const submitPrompt = vi.fn()
    const core = new AgentCore(relay, { services })
    core.start()
    relay.emit('command', makeEnvelope('cmd.dispatch', { action: 'session.prompt', data: { sessionId: 's1', prompt: 'test' } }, { reqId: 'pending' }))
    core.stop()
    finish({ id: 's1', submitPrompt, setModel: vi.fn() })
    await Promise.resolve()
    expect(submitPrompt).not.toHaveBeenCalled()
    expect(relay.sent).toHaveLength(0)
  })
})


it('routes project selection to new sessions and refuses moving an existing session', async () => {
  const relay = new MockRelay()
  const { services } = makeServices()
  services.listProjects = async () => [{ id: 'demo', title: 'Demo' }]
  const create = vi.spyOn(services, 'createSession')
  const core = new AgentCore(relay, { services })
  core.start()
  try {
    relay.emit('command', makeEnvelope('cmd.dispatch', { action: 'project.list', data: {} }, { reqId: 'list' }))
    await vi.waitFor(() => expect(relay.lastCommandResponse()?.reqId).toBe('list'))
    expect(relay.lastCommandResponse()?.payload).toMatchObject({ ok: true, result: [{ id: 'demo', title: 'Demo' }] })
    relay.emit('command', makeEnvelope('cmd.dispatch', { action: 'session.prompt', data: { projectId: 'demo', prompt: 'hello' } }, { reqId: 'new' }))
    await vi.waitFor(() => expect(relay.lastCommandResponse()?.reqId).toBe('new'))
    expect(create).toHaveBeenCalledWith(expect.objectContaining({ projectId: 'demo' }))
    relay.emit('command', makeEnvelope('cmd.dispatch', { action: 'session.prompt', data: { projectId: 'demo', sessionId: 'existing', prompt: 'hello' } }, { reqId: 'move' }))
    await vi.waitFor(() => expect(relay.lastCommandResponse()?.reqId).toBe('move'))
    expect(relay.lastCommandResponse()?.payload).toMatchObject({ ok: false })
    expect(create).toHaveBeenCalledTimes(1)
  } finally { core.stop() }
})
