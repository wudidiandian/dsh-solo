import { afterAll, afterEach, describe, expect, it, vi } from 'vitest'
import { WebSocketServer, type WebSocket as WSType } from 'ws'
import type { Envelope } from '@dsh-solo/protocol'
import { makeEnvelope } from '@dsh-solo/protocol'
import { SoloRelayClient } from '../src/ws-client'

// ---------------------------------------------------------------------------
// mock relay 服务器
// ---------------------------------------------------------------------------

interface MockRelay {
  url: string
  serverConns: WSType[]
  received: Envelope[]
  broadcast: (env: Envelope) => void
  closeConn: (index: number) => void
  close: () => Promise<void>
}

let wss: WebSocketServer | null = null

afterAll(async () => {
  if (wss) await new Promise<void>((resolve) => wss!.close(() => resolve()))
})

afterEach(async () => {
  if (wss) {
    await new Promise<void>((resolve) => wss!.close(() => resolve()))
    wss = null
  }
})

function startMockRelay(opts?: {
  rejectHello?: boolean
  onEnvelope?: (env: Envelope, conn: WSType) => void
}): MockRelay {
  wss = new WebSocketServer({ port: 0 })
  const serverConns: WSType[] = []
  const received: Envelope[] = []

  wss.on('connection', (conn) => {
    serverConns.push(conn)
    conn.on('message', (data) => {
      const env = JSON.parse(data.toString()) as Envelope
      received.push(env)
      if (env.type === 'hello.agent') {
        const resp = opts?.rejectHello
          ? makeEnvelope('hello.error', { reason: 'bad token' })
          : makeEnvelope('hello.ok', { role: 'agent' })
        conn.send(JSON.stringify(resp))
        return
      }
      opts?.onEnvelope?.(env, conn)
    })
  })

  const relay = {
    url: '',
    serverConns,
    received,
    broadcast(env: Envelope) {
      for (const c of serverConns) c.send(JSON.stringify(env))
    },
    closeConn(index: number) {
      serverConns[index]?.close()
    },
    async close() {
      await new Promise<void>((resolve) => wss!.close(() => resolve()))
    },
  } as MockRelay

  return relay
}

function listenMock(relay: MockRelay): Promise<string> {
  return new Promise((resolve, reject) => {
    wss!.once('error', reject)
    wss!.on('listening', () => {
      const addr = wss!.address() as { port: number }
      relay.url = `ws://127.0.0.1:${addr.port}`
      resolve(relay.url)
    })
  })
}

function waitFor<T>(check: () => T | null | undefined | false, timeout = 3000): Promise<T> {
  return new Promise((resolve, reject) => {
    const start = Date.now()
    const timer = setInterval(() => {
      const v = check()
      if (v) {
        clearInterval(timer)
        resolve(v)
      } else if (Date.now() - start > timeout) {
        clearInterval(timer)
        reject(new Error('timeout'))
      }
    }, 10)
  })
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

// ---------------------------------------------------------------------------
// 用例
// ---------------------------------------------------------------------------

describe('SoloRelayClient', () => {
  it('握手成功后进入 open 并发出 connected', async () => {
    const relay = startMockRelay()
    const url = await listenMock(relay)

    const client = new SoloRelayClient({ url, deviceToken: 'tok', backoffBaseMs: 10 })
    const connected = vi.fn()
    client.on('connected', connected)
    client.start()

    await waitFor(() => connected.mock.calls.length > 0)
    expect(client.currentState).toBe('open')
    expect(relay.received[0].type).toBe('hello.agent')

    client.stop()
  })

  it('离线期间 send 进入队列，连接成功后按序补发', async () => {
    const relay = startMockRelay()
    const url = await listenMock(relay)

    const client = new SoloRelayClient({ url, deviceToken: 'tok', backoffBaseMs: 10 })
    // 先发两条（未连接 → 入队）
    client.send(makeEnvelope('agent.snapshot', { timestamp: 1 }))
    client.send(makeEnvelope('session.event', {}, { seqId: 1 }))
    expect(client.pendingCount).toBe(2)

    client.start()
    await waitFor(() => relay.received.length >= 3)

    expect(relay.received.map((e) => e.type)).toEqual([
      'hello.agent',
      'agent.snapshot',
      'session.event',
    ])
    client.stop()
  })

  it('断线后自动重连（指数退避）', async () => {
    const relay = startMockRelay()
    const url = await listenMock(relay)

    const client = new SoloRelayClient({
      url,
      deviceToken: 'tok',
      backoffBaseMs: 10,
      backoffMaxMs: 50,
      heartbeatIntervalMs: 60_000,
    })
    const disconnected = vi.fn()
    client.on('disconnected', disconnected)
    client.start()

    await waitFor(() => relay.serverConns.length >= 1)
    relay.closeConn(0) // 服务端踢掉第一条连接

    await waitFor(() => relay.serverConns.length >= 2, 5000)
    expect(disconnected).toHaveBeenCalled()
    // 重连后应重新握手
    expect(relay.received.filter((e) => e.type === 'hello.agent').length).toBeGreaterThanOrEqual(2)
    client.stop()
  })

  it('收到 cmd.dispatch 时发出 command 事件', async () => {
    const relay = startMockRelay()
    const url = await listenMock(relay)

    const client = new SoloRelayClient({ url, deviceToken: 'tok', backoffBaseMs: 10 })
    const commands: Envelope[] = []
    client.on('command', (env: Envelope) => commands.push(env))
    client.start()
    await waitFor(() => client.currentState === 'open')

    relay.broadcast(makeEnvelope('cmd.dispatch', { action: 'fs.list_dir', data: { path: '~' } }, { reqId: 'r1' }))
    await waitFor(() => commands.length > 0)
    expect(commands[0].reqId).toBe('r1')
    client.stop()
  })

  it('hello.error 视为致命错误：发出 error 并停止重连', async () => {
    const relay = startMockRelay({ rejectHello: true })
    const url = await listenMock(relay)

    const errors: Error[] = []
    const client = new SoloRelayClient({ url, deviceToken: 'bad', backoffBaseMs: 10 })
    client.on('error', (e: Error) => errors.push(e))
    client.start()

    await waitFor(() => errors.length > 0)
    expect(errors[0].message).toContain('bad token')
    expect(client.currentState).toBe('stopped')

    await sleep(100)
    // 不应有第二次握手尝试
    expect(relay.received.filter((e) => e.type === 'hello.agent').length).toBe(1)
  })

  it('初始状态为 idle 且可观测', () => {
    const client = new SoloRelayClient({ url: 'ws://127.0.0.1:1', deviceToken: 't' })
    expect(client.currentState).toBe('idle')
  })
})
