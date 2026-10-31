import { EventEmitter } from 'node:events'
import http from 'node:http'
import https from 'node:https'
import WebSocket from 'ws'
import {
  type Envelope,
  type HelloAgentPayload,
  type HelloErrorPayload,
  makeEnvelope,
} from '@dsh-solo/protocol'

export type ClientState = 'idle' | 'connecting' | 'open' | 'stopped'

export interface SoloRelayClientOptions {
  /** Relay 地址，如 ws://127.0.0.1:8787/ws 或 wss://relay.example.com/ws */
  url: string
  /** 预共享配对鉴权密钥 */
  deviceToken: string
  agentInfo?: string
  /** 心跳间隔（默认 30s） */
  heartbeatIntervalMs?: number
  /** 发出 ping 后等待 pong 的最长时间（默认 10s） */
  heartbeatTimeoutMs?: number
  /** 重连退避基数（默认 500ms，指数递增） */
  backoffBaseMs?: number
  /** 重连退避上限（默认 15s） */
  backoffMaxMs?: number
  /** 离线发送队列上限（默认 500，超出丢弃最旧） */
  maxQueue?: number
}

/**
 * SoloRelayClient：电脑端到 VPS relay 的常驻 WebSocket 客户端。
 *
 * - 连接成功即发送 hello.agent 鉴权，收到 hello.ok 后视为就绪（emit 'connected'）
 * - 断线后按指数退避自动重连（带抖动），hello.error 视为致命错误停止重连
 * - 离线期间 send() 的报文进入有界队列，重连成功后按序补发
 * - 心跳：周期 ping，超时未活动主动断开触发重连
 *
 * 事件：'connected' | 'disconnected'(reason) | 'command'(Envelope) | 'message'(Envelope) | 'error'(Error)
 */
export class SoloRelayClient extends EventEmitter {
  private readonly opts: Required<Omit<SoloRelayClientOptions, 'agentInfo'>> & { agentInfo?: string }
  private ws: WebSocket | null = null
  private state: ClientState = 'idle'
  private queue: string[] = []
  private retry = 0
  private retryTimer: NodeJS.Timeout | null = null
  private heartbeatTimer: NodeJS.Timeout | null = null
  private pongTimer: NodeJS.Timeout | null = null
  private disposed = false
  private stopped = false

  constructor(options: SoloRelayClientOptions) {
    super()
    this.opts = {
      agentInfo: options.agentInfo,
      url: options.url,
      deviceToken: options.deviceToken,
      heartbeatIntervalMs: options.heartbeatIntervalMs ?? 30_000,
      heartbeatTimeoutMs: options.heartbeatTimeoutMs ?? 10_000,
      backoffBaseMs: options.backoffBaseMs ?? 500,
      backoffMaxMs: options.backoffMaxMs ?? 15_000,
      maxQueue: options.maxQueue ?? 500,
    }
  }

  get currentState(): ClientState {
    return this.state
  }

  /** 开始运行并保持连接（幂等） */
  start(): void {
    if (this.state === 'stopped' || this.state === 'connecting' || this.state === 'open') return
    this.stopped = false
    if (!this.ws && !this.retryTimer) this.connect()
  }

  /** 停止运行：不再重连，关闭现有连接（幂等） */
  stop(): void {
    this.disposed = true
    this.stopped = true
    this.state = 'stopped'
    if (this.retryTimer) clearTimeout(this.retryTimer)
    this.stopHeartbeat()
    this.retryTimer = null
    this.queue = []
    this.ws?.close()
  }

  /** 发送信封；未连接时进入离线队列 */
  send(env: Envelope): void {
    if (this.disposed) return
    const raw = JSON.stringify(env)
    if (this.state === 'open' && this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(raw)
      return
    }
    this.queue.push(raw)
    if (this.queue.length > this.opts.maxQueue) {
      this.queue.shift() // 丢弃最旧，保住最新事件
    }
  }

  /** 当前是否已握手就绪（周期快照重报用：未连接时跳过，避免灌离线队列） */
  isConnected(): boolean {
    return this.state === 'open' && this.ws?.readyState === WebSocket.OPEN
  }

  /** 当前离线队列长度（观测用） */
  get pendingCount(): number {
    return this.queue.length
  }

  /**
   * 切换到新 token 并立即重连：hello 读取点在每次 connect() 内，
   * 因此只需更新 opts 后触发断开/重连，重连握手自然携带新 token。
   */
  reconnectWithToken(token: string): void {
    if (this.disposed) return
    this.opts.deviceToken = token
    if (this.stopped) {
      // 此前 hello.error 标记为致命停止；换 token 后重新允许连接
      this.stopped = false
      this.state = 'idle'
    }
    this.retry = 0 // 重置退避，尽快用新 token 重连
    if (this.ws) {
      this.ws.terminate() // close → onDisconnect → scheduleReconnect（新 token）
      return
    }
    if (!this.retryTimer) this.connect()
    // else 已有待执行的重连定时器，其 connect() 会读取新 token
  }

  // -------------------------------------------------------------------------

  private connect(): void {
    if (this.stopped) return
    this.state = 'connecting'
    // 预检：先用 http(s).request 探测目标可达性与 TLS 握手。
    // 原因：ws 库在 TLS 握手失败（如证书未就绪时的 alert）存在滞留写竞态，
    // EPROTO 可能以 uncaughtException 逃逸拖垮宿主；https.request 的错误走事件回调不逃逸。
    this.precheck(this.opts.url, (ok) => {
      if (!ok) {
        this.onDisconnect('precheck failed')
        return
      }
      if (this.stopped || this.ws) return
      // handshakeTimeout：TLS/网络卡死时强制失败并清理，避免半开连接的滞留写逃逸成未捕获异常
      const ws = new WebSocket(this.opts.url, { handshakeTimeout: 10_000 })
      this.ws = ws

      ws.on('open', () => {
        if (this.stopped || this.ws !== ws) { ws.close(); return }
        const hello = makeEnvelope<HelloAgentPayload>('hello.agent', {
          deviceToken: this.opts.deviceToken,
          agentInfo: this.opts.agentInfo,
        })
        ws.send(JSON.stringify(hello))
      })
      ws.on('message', (data, isBinary) => {
        if (isBinary || this.stopped || this.ws !== ws) return
        this.onMessage(data.toString())
      })
      ws.on('pong', () => {
        if (this.ws !== ws) return
        if (this.pongTimer) clearTimeout(this.pongTimer)
        this.pongTimer = null
      })
      ws.on('error', (err) => {
        this.emit('error', err)
        // 握手/协议错误后立即销毁 socket：丢弃滞留写队列，防 EPROTO 类异常逃逸拖垮宿主
        try {
          ws.terminate()
        } catch {
          /* 已销毁则忽略 */
        }
      })
      ws.on('close', () => {
        if (this.ws === ws) this.onDisconnect('connection closed')
      })
    })
  }

  /** TLS/HTTP 可达性预检：收到任意 HTTP 响应即视为可达（ws 升级端点对 GET 返回 426 也算通） */
  private precheck(rawUrl: string, cb: (ok: boolean) => void): void {
    let u: URL
    try {
      u = new URL(rawUrl)
    } catch {
      cb(true) // 非法 URL 交给 ws 库自己报错
      return
    }
    const mod = u.protocol === 'wss:' ? https : u.protocol === 'ws:' ? http : null
    if (!mod) {
      cb(true)
      return
    }
    let settled = false
    const done = (ok: boolean) => {
      if (settled) return
      settled = true
      cb(ok)
    }
    const req = mod.request(
      {
        hostname: u.hostname,
        port: u.port || (u.protocol === 'wss:' ? 443 : 80),
        path: u.pathname,
        method: 'GET',
        timeout: 5_000,
      },
      (res) => {
        res.resume()
        done(true)
      },
    )
    req.on('timeout', () => {
      req.destroy()
      done(false)
    })
    req.on('error', () => done(false))
    req.end()
  }

  private onMessage(raw: string): void {
    if (this.stopped) return
    let env: Envelope
    try {
      env = JSON.parse(raw) as Envelope
    } catch {
      return
    }

    switch (env.type) {
      case 'hello.ok':
        this.state = 'open'
        this.retry = 0
        this.startHeartbeat()
        this.flushQueue()
        this.emit('connected')
        break
      case 'hello.error': {
        // 鉴权失败是致命错误：重连也不会通过，停止重试避免打爆 relay
        const reason = (env.payload as HelloErrorPayload | undefined)?.reason ?? 'unauthorized'
        this.stopped = true
        this.state = 'stopped'
        this.emit('error', new Error(`relay rejected handshake: ${reason}`))
        this.ws?.close()
        break
      }
      case 'cmd.dispatch':
        this.emit('command', env)
        break
      default:
        this.emit('message', env)
    }
  }

  private startHeartbeat(): void {
    this.stopHeartbeat()
    this.heartbeatTimer = setInterval(() => {
      if (this.pongTimer || this.ws?.readyState !== WebSocket.OPEN) return
      // Start the deadline after sending a ping, not after the previous message.
      // Otherwise the default 30s interval always exceeds the 10s idle threshold.
      const ws = this.ws
      this.pongTimer = setTimeout(() => ws.terminate(), this.opts.heartbeatTimeoutMs)
      ws.ping()
    }, this.opts.heartbeatIntervalMs)
  }

  private stopHeartbeat(): void {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer)
    if (this.pongTimer) clearTimeout(this.pongTimer)
    this.heartbeatTimer = null
    this.pongTimer = null
  }

  private onDisconnect(reason: string): void {
    this.stopHeartbeat()
    const wasOpen = this.state === 'open'
    this.ws = null
    if (this.stopped) return // 主动 stop / 鉴权失败：不进入 idle、不再重连
    this.state = 'idle'
    if (wasOpen) this.emit('disconnected', reason)
    this.scheduleReconnect()
  }

  private scheduleReconnect(): void {
    if (this.stopped) return
    const base = this.opts.backoffBaseMs
    const cap = this.opts.backoffMaxMs
    const delay = Math.min(base * 2 ** this.retry, cap) * (0.5 + Math.random())
    this.retry++
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null
      this.connect()
    }, delay)
  }

  private flushQueue(): void {
    if (!this.queue.length || !this.ws) return
    const pending = this.queue.splice(0)
    for (const raw of pending) {
      if (this.ws.readyState === WebSocket.OPEN) this.ws.send(raw)
    }
  }
}
