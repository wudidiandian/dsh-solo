import { spawn, spawnSync, type ChildProcess } from 'node:child_process'
import { promises as fs } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { WebSocket } from 'ws'
import type { Envelope } from '@dsh-solo/protocol'
import { makeEnvelope } from '@dsh-solo/protocol'
import { AgentCore, type AgentSessionLike, type ApprovalRequest, type HarnessServices } from '../src/core'
import { SoloRelayClient } from '../src/ws-client'

// ---------------------------------------------------------------------------
// 定位 / 构建 Go relay
// ---------------------------------------------------------------------------

const here = path.dirname(fileURLToPath(import.meta.url))
const serverDir = path.resolve(here, '../../../server')
const relayBin = path.join(serverDir, 'bin', 'relay-e2e.exe')
const RELAY_URL = 'ws://127.0.0.1:18999/ws'

function locateGo(): string | null {
  if (process.env.GO_BIN) return process.env.GO_BIN
  const sdkGo = path.resolve(here, '../../../.sdk/go/bin/go.exe')
  const candidates = process.platform === 'win32'
    ? [sdkGo, 'C:\\Program Files\\Go\\bin\\go.exe']
    : ['/usr/local/go/bin/go']
  for (const c of [...candidates, 'go']) {
    try {
      const r = spawnSync(c, ['version'], { encoding: 'utf8' })
      if (r.status === 0) return c
    } catch {
      /* try next */
    }
  }
  return null
}

const goBin = locateGo()

// ---------------------------------------------------------------------------
// mock Harness 服务（模拟 DeepSeek Harness 注入的 ctx.sessions/llm/approval）
// ---------------------------------------------------------------------------

function makeMockServices() {
  const listeners: Array<(sessionId: string, event: { kind?: string }) => void> = []
  let approvalHandler: ((req: ApprovalRequest) => Promise<boolean>) | null = null
  const services: HarnessServices = {
    listModels: async () => [{ id: 'deepseek-v3' }, { id: 'deepseek-r1' }],
    listSessions: async () => [],
    createSession: async () => {
      throw new Error('not used in e2e')
    },
    getSession: async () => null,
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
    emit: (sid: string, ev: { kind?: string }) => listeners.forEach((cb) => cb(sid, ev)),
    approve: (req: ApprovalRequest) => {
      if (!approvalHandler) throw new Error('no approval handler')
      return approvalHandler(req)
    },
  }
}

// ---------------------------------------------------------------------------
// mock 手机端（裸 WS 客户端，模拟 App 行为）
// ---------------------------------------------------------------------------

class MobileMock {
  private ws!: WebSocket
  received: Envelope[] = []

  async connect(): Promise<void> {
    this.ws = new WebSocket(RELAY_URL)
    this.ws.on('message', (data) => {
      this.received.push(JSON.parse(data.toString()) as Envelope)
    })
    await new Promise<void>((resolve, reject) => {
      this.ws.once('open', () => {
        this.ws.send(JSON.stringify(makeEnvelope('hello.mobile', { deviceToken: 'e2e-tok' })))
        resolve()
      })
      this.ws.once('error', reject)
    })
  }

  send(env: Envelope) {
    this.ws.send(JSON.stringify(env))
  }

  waitForType(type: string, timeoutMs = 5000): Promise<Envelope> {
    const existing = this.received.find((e) => e.type === type)
    if (existing) return Promise.resolve(existing)
    return new Promise((resolve, reject) => {
      const start = Date.now()
      const timer = setInterval(() => {
        const env = this.received.find((e) => e.type === type)
        if (env) {
          clearInterval(timer)
          resolve(env)
        } else if (Date.now() - start > timeoutMs) {
          clearInterval(timer)
          reject(new Error(`timeout waiting for ${type}; got: ${this.received.map((e) => e.type).join(',')}`))
        }
      }, 20)
    })
  }

  close() {
    this.ws.close()
    this.received = []
  }
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

// ---------------------------------------------------------------------------
// E2E
// ---------------------------------------------------------------------------

describe.skipIf(!goBin)('agent ↔ relay 跨语言端到端', () => {
  let proc: ChildProcess | null = null
  let client: SoloRelayClient
  let mock: ReturnType<typeof makeMockServices>
  let workspace: string

  beforeAll(async () => {
    // 1. 构建 relay（注意：vitest worker 在 Windows 下 spawnSync 传 cwd 会 ENOENT，
    //    因此用 go build -C 指定目录，而不是 cwd 选项）
    const build = spawnSync(goBin!, ['build', '-C', serverDir, '-o', relayBin, './cmd/relay'], {
      encoding: 'utf8',
      env: { ...process.env, GOPROXY: 'https://goproxy.cn,direct' },
    })
    if (build.status !== 0) {
      throw new Error(`relay build failed: ${build.stderr || build.stdout || build.error}`)
    }

    // 2. 启动 relay
    proc = spawn(relayBin, ['-addr', '127.0.0.1:18999'], { stdio: ['ignore', 'pipe', 'pipe'] })
    proc.stderr?.on('data', (d) => process.stderr.write(`[relay] ${d}`))

    // 3. 等 /healthz 就绪
    const deadline = Date.now() + 10_000
    while (Date.now() < deadline) {
      try {
        const res = await fetch('http://127.0.0.1:18999/healthz')
        if (res.ok) break
      } catch {
        /* not ready */
      }
      await sleep(100)
    }

    // 4. 准备真实工作区目录（fs.list_dir 用）
    workspace = await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-e2e-'))
    await fs.mkdir(path.join(workspace, 'proj'))
    await fs.writeFile(path.join(workspace, 'proj', 'main.go'), 'package main')

    // 5. 启动 agent（真实 SoloRelayClient + AgentCore）
    mock = makeMockServices()
    const core = new AgentCore(client = new SoloRelayClient({
      url: RELAY_URL,
      deviceToken: 'e2e-tok',
      backoffBaseMs: 100,
    }), {
      services: mock.services,
      listDir: (p) => fs.readdir(p, { withFileTypes: true }).then((es) =>
        es.map((e) => ({ name: e.name, path: path.join(p, e.name), type: e.isDirectory() ? 'dir' : 'file' })),
      ),
      buildSnapshot: async () => ({ dirTree: [{ name: 'workspace', path: workspace, type: 'dir' }] }),
    })
    core.start()
    client.start()
  }, 30_000)

  afterAll(async () => {
    client?.stop()
    proc?.kill()
    if (workspace) await fs.rm(workspace, { recursive: true, force: true })
    await fs.rm(path.join(serverDir, 'bin'), { recursive: true, force: true }).catch(() => {})
  })

  it('1. agent 连接后，手机秒开拿到快照', async () => {
    // 等待 agent connected（快照已在连接后上报）
    await sleep(500)
    const mobile = new MobileMock()
    await mobile.connect()

    const snap = await mobile.waitForType('agent.snapshot')
    const payload = snap.payload as { models: Array<{ id: string }>; dirTree: unknown[] }
    expect(payload.models.map((m) => m.id)).toContain('deepseek-v3')
    expect(payload.dirTree).toHaveLength(1)
    mobile.close()
  })

  it('2. 事件实时转发 + 手机离线重连后 seq_id 断点续传', async () => {
    const mobile = new MobileMock()
    await mobile.connect()
    await mobile.waitForType('agent.snapshot')

    // agent 产出 seq 1..2（手机在线 → 实时收到）
    mock.emit('sess-1', { kind: 'text.delta' })
    mock.emit('sess-1', { kind: 'text.delta' })
    await mobile.waitForType('session.event')
    await sleep(100)
    const live = mobile.received.filter((e) => e.type === 'session.event')
    expect(live.map((e) => e.seqId)).toEqual([1, 2])

    // 手机离线，agent 继续产出 seq3（普通）+ seq4（审批，挂起中）
    mobile.close()
    await sleep(200) // 等 relay 感知离线
    mock.emit('sess-1', { kind: 'turn.completed' })
    const approvalPromise = mock.approve({ id: 'ap-e2e', sessionId: 'sess-1', toolName: 'bash', summary: 'git push' })
    await sleep(300)

    // 手机重连 → sync.request 补发 seq 3..4
    const mobile2 = new MobileMock()
    await mobile2.connect()
    await mobile2.waitForType('agent.snapshot')
    mobile2.send(makeEnvelope('sync.request', { sessionId: 'sess-1', lastSeqId: 2 }))

    const catchup = await mobile2.waitForType('sync.catchup')
    const cp = catchup.payload as { gap: boolean; events: Envelope[] }
    expect(cp.gap).toBe(false)
    expect(cp.events.map((e) => e.seqId)).toEqual([3, 4])
    expect((cp.events[1].payload as { kind: string }).kind).toBe('approval_request')

    // 手机端点击「允许」→ 审批 resolve，rpc 定向回传
    mobile2.send(
      makeEnvelope('cmd.dispatch', { action: 'approval.respond', data: { approvalId: 'ap-e2e', approved: true } }, { reqId: 'req-ap' }),
    )
    await expect(approvalPromise).resolves.toBe(true)
    const rpc = await mobile2.waitForType('rpc.response')
    expect((rpc.payload as { ok: boolean }).ok).toBe(true)
    mobile2.close()
  })

  it('3. fs.list_dir 远程读目录 → rpc 回传真实文件系统结果', async () => {
    const mobile = new MobileMock()
    await mobile.connect()
    await mobile.waitForType('agent.snapshot')

    mobile.send(
      makeEnvelope('cmd.dispatch', { action: 'fs.list_dir', data: { path: path.join(workspace, 'proj') } }, { reqId: 'req-ls' }),
    )
    const rpc = await mobile.waitForType('rpc.response')
    expect(rpc.reqId).toBe('req-ls')
    const payload = rpc.payload as { ok: boolean; result: Array<{ name: string; type: string }> }
    expect(payload.ok).toBe(true)
    expect(payload.result).toMatchObject([{ name: 'main.go', type: 'file' }])
    mobile.close()
  })
})
