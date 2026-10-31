import { mkdir, readFile, appendFile, rm, writeFile, stat } from 'node:fs/promises'
import { join } from 'node:path'
import {
  type AgentSnapshotPayload,
  type ApprovalRespondData,
  type CmdDispatchPayload,
  type Envelope,
  type FileTransferChunkData,
  type FileTransferOfferData,
  type ListDirData,
  type PromptAttachment,
  type SessionDeleteData,
  type SessionEvent,
  type SessionHistoryData,
  type SessionPromptData,
  type SessionRenameData,
  makeEnvelope,
} from '@dsh-solo/protocol'
import { inferPushPriority, summarizeEvent } from './push-level.js'
import { generateToken, writeTokenFile } from './token.js'

// ---------------------------------------------------------------------------
// Harness 侧最小接口（由 Cordis 注入的真实服务实现，测试时用 mock）
// ---------------------------------------------------------------------------

export interface ApprovalRequest {
  id: string
  sessionId?: string
  toolName: string
  summary?: string
  [key: string]: unknown
}

export interface AgentSessionLike {
  id: string
  model?: string
  setModel(modelId: string): Promise<void>
  submitPrompt(prompt: string): Promise<void>
}

export interface HarnessServices {
  listModels(): Promise<unknown[]>
  listSessions(): Promise<unknown[]>
  createSession(opts: { cwd?: string; model?: string }): Promise<AgentSessionLike>
  getSession(id: string): Promise<AgentSessionLike | null>
  /** 重命名会话（写入 session/title 事件，last-wins） */
  renameSession(id: string, title: string): Promise<void>
  /** 删除会话（dispose 持有的 agent；仅支持本插件创建的会话） */
  deleteSession(id: string): Promise<void>
  /** 订阅会话事件流，返回取消订阅函数 */
  onSessionEvent(cb: (sessionId: string, event: SessionEvent) => void): () => void
  /** 注册高危工具审批拦截器：resolve(true)=允许执行 */
  registerApprovalHandler(handler: (req: ApprovalRequest) => Promise<boolean>): void
}

export interface AgentCoreOptions {
  services: HarnessServices
  /** 手机端展开深层目录（由 workspace.ts + 白名单配置提供） */
  listDir?: (path: string) => Promise<unknown>
  /** 快照附加数据（如浅目录树扫描） */
  buildSnapshot?: () => Promise<Partial<AgentSnapshotPayload>>
  /** Directory for per-session jsonl history files; omit to keep memory-only buffering */
  historyDir?: string
  /** Relay URL surfaced to pairing surfaces (device.token.get / pairing page) */
  relayUrl?: string
  /** Resolved device token (token.ts); updated in memory by resetDeviceToken */
  deviceToken?: string
  /** State dir holding the device-token file; omit to keep resets memory-only */
  stateDir?: string
  /** 工作区白名单根目录（session.prompt 的 file 附件只允许引用这些目录内的文件） */
  workspaceRoots?: string[]
  /** Called after a token reset so the relay client reconnects with the new token */
  rotateDeviceToken?: (newToken: string) => void
}

/** Max buffered events per session (memory buffer and history reply are capped alike) */
const HISTORY_BUFFER_LIMIT = 800

/** 单文件上传上限（与 relay 默认 MaxUploadSize 对齐；relay 已先行硬校验，此处双保险） */
const MAX_UPLOAD_SIZE = 10 << 20

/** url 附件抓取上限与超时 */
const MAX_URL_FETCH_SIZE = 10 << 20
const URL_FETCH_TIMEOUT_MS = 30_000

/** 同时进行的上传传输数上限（防并发上传占满 agent 内存：4 × 10MB = 40MB 峰值） */
const MAX_CONCURRENT_TRANSFERS = 4

/** 单块传输超时：超时后丢弃整个 transfer（防半途而废的传输占内存） */
const TRANSFER_TIMEOUT_MS = 90_000

/** 一次 prompt 的附件数上限（服务端侧复核；App 端 UI 也限制） */
const MAX_ATTACHMENTS_PER_PROMPT = 3

/** 周期快照兜底重报间隔：覆盖不经本插件的会话变更（电脑端直接操作） */
const SNAPSHOT_REFRESH_MS = 60_000

/** Session id → safe file name (strip path separators and other unsafe chars) */
function historyFileName(sessionId: string): string {
  return `${sessionId.replace(/[^a-zA-Z0-9._-]/g, '_')}.jsonl`
}

/** 与 SoloRelayClient 结构兼容的最小客户端接口（便于单测注入 mock） */
export interface RelayLike {
  send(env: Envelope): void
  on(event: 'connected', cb: () => void): unknown
  on(event: 'command', cb: (env: Envelope) => void): unknown
  /** 连接就绪探测（可选）：周期快照重报在未连接时跳过，避免灌离线队列 */
  isConnected?(): boolean
}

/**
 * AgentCore：插件核心逻辑（与 Cordis 解耦，可独立单测）。
 *
 * 职责（设计文档 §4）：
 * 1. 连接建立后上报 HostSnapshot（模型 + 会话 + 目录树）
 * 2. 会话事件流打上会话内单调递增 seqId 推给 relay
 * 3. 拦截高危工具审批，挂起等待手机端决定
 * 4. 处理手机端远程指令：发消息 / 审批响应 / 展开目录
 */
export class AgentCore {
  private seq = 0
  private readonly pendingApprovals = new Map<string, (approved: boolean) => void>()
  private readonly unsubscribes: Array<() => void> = []
  private started = false
  /** 周期快照兜底定时器（start 创建，stop 清理） */
  private snapshotTimer: ReturnType<typeof setInterval> | null = null
  /** Per-session event buffer for history replay (capped at HISTORY_BUFFER_LIMIT) */
  private readonly historyBuffers = new Map<string, SessionEvent[]>()
  /** Per-session promise chain serializing jsonl appends (keeps on-disk order) */
  private readonly historyWriteChains = new Map<string, Promise<void>>()
  /** Lazily-created mkdir promise for historyDir (reset on failure so writes can retry) */
  private historyDirReady?: Promise<void>
  /** Current device token (starts from opts, replaced on reset) */
  private currentToken: string

  /** 进行中的文件上传（transferId → 状态）；内存组装，收齐后一次性落盘 */
  private readonly transfers = new Map<
    string,
    {
      name: string
      size: number
      mime?: string
      chunks: number
      received: Map<number, Buffer>
      timer: ReturnType<typeof setTimeout>
    }
  >()

  constructor(
    private readonly client: RelayLike,
    private readonly opts: AgentCoreOptions,
  ) {
    this.currentToken = opts.deviceToken ?? ''
  }

  start(): void {
    if (this.started) return
    this.started = true

    this.client.on('connected', () => {
      void this.publishSnapshot()
    })
    this.client.on('command', (env) => {
      void this.handleCommand(env)
    })
    this.unsubscribes.push(
      this.opts.services.onSessionEvent((sessionId, event) => this.forwardEvent(sessionId, event)),
    )
    this.opts.services.registerApprovalHandler((req) => this.interceptApproval(req))
    // 周期快照兜底（2026-10-28）：会话在电脑端直接创建/删除/重命名时不会经过
    // 本插件的 services 路径，App 端重连会拿到 relay 缓存的陈旧快照。每 60s
    // 重报一次（未连接时跳过，避免灌离线队列；重连时 connected 回调也会发最新）。
    this.snapshotTimer = setInterval(() => {
      if (this.client.isConnected?.()) void this.publishSnapshot()
    }, SNAPSHOT_REFRESH_MS)
  }

  stop(): void {
    if (this.snapshotTimer) {
      clearInterval(this.snapshotTimer)
      this.snapshotTimer = null
    }
    for (const unsub of this.unsubscribes.splice(0)) {
      try {
        unsub()
      } catch {
        /* 忽略取消订阅异常 */
      }
    }
    // 未决审批一律拒绝，避免 Harness 侧永久挂起
    for (const resolve of this.pendingApprovals.values()) resolve(false)
    this.pendingApprovals.clear()
    // 丢弃未完成的文件上传，释放内存与定时器
    this.dropAllTransfers()
    this.started = false
  }

  /** 当前待审批数量（观测用） */
  get pendingApprovalCount(): number {
    return this.pendingApprovals.size
  }

  /** 下一个将分配的 seqId（观测/测试用） */
  get nextSeq(): number {
    return this.seq + 1
  }

  /** 当前设备令牌（配对页 / device.token.get 用） */
  getDeviceToken(): string {
    return this.currentToken
  }

  /** 重置设备令牌：重新生成、持久化、并触发 relay 客户端换 token 重连 */
  async resetDeviceToken(): Promise<string> {
    const token = generateToken()
    this.currentToken = token
    if (this.opts.stateDir) {
      try {
        await writeTokenFile(this.opts.stateDir, token)
      } catch (err) {
        console.error('[dsh-solo-agent] persist device token failed:', err)
      }
    }
    this.opts.rotateDeviceToken?.(token)
    return token
  }

  // -------------------------------------------------------------------------

  /**
   * 构建并上报 HostSnapshot。连接建立时自动调用；也可在模型目录等异步资源
   * 就绪后由外部（index.ts bootstrap）再次调用，把补全后的快照重推给 App。
   */
  async publishSnapshot(): Promise<void> {
    try {
      const [models, sessions, extra] = await Promise.all([
        this.opts.services.listModels().catch(() => []),
        this.opts.services.listSessions().catch(() => []),
        this.opts.buildSnapshot?.().catch(() => ({})) ?? Promise.resolve({}),
      ])
      this.client.send(
        makeEnvelope('agent.snapshot', {
          models,
          sessions,
          ...extra,
          timestamp: Date.now(),
        } satisfies AgentSnapshotPayload),
      )
    } catch (err) {
      console.error('[dsh-solo-agent] publish snapshot failed:', err)
    }
  }

  /**
   * 逐字流帧下发（2026-10-28）：宿主 agent/assistant-stream 的 text-delta /
   * reasoning-delta 直通转发。瞬时帧——仅在已连接时发送（断线期间的 delta
   * 无意义，durable 的 assistant/message 会在回合结束时补全），不入离线队列。
   */
  sendStreamDelta(sessionId: string, kind: 'text-delta' | 'reasoning-delta' | 'end', text?: string): void {
    if (!this.client.isConnected?.()) return
    this.client.send(
      makeEnvelope('session.stream', { kind, text }, { sessionId }),
    )
  }

  private forwardEvent(sessionId: string, event: SessionEvent): void {
    this.seq++
    const seqId = this.seq
    this.recordHistory(sessionId, event, seqId)
    const pushLevel = inferPushPriority(event.kind)
    this.client.send(
      makeEnvelope('session.event', event, {
        sessionId,
        seqId,
        pushLevel,
        pushSummary: pushLevel === 'none' ? undefined : summarizeEvent(event),
      }),
    )
  }

  /** Record an event into the per-session memory buffer and append it to the disk jsonl */
  private recordHistory(sessionId: string, event: SessionEvent, seqId: number): void {
    // Embed seqId so the App can dedupe / merge history against live events
    const stored: SessionEvent = { ...event, seqId }
    let buf = this.historyBuffers.get(sessionId)
    if (!buf) {
      buf = []
      this.historyBuffers.set(sessionId, buf)
    }
    buf.push(stored)
    if (buf.length > HISTORY_BUFFER_LIMIT) {
      buf.splice(0, buf.length - HISTORY_BUFFER_LIMIT)
    }

    const dir = this.opts.historyDir
    if (!dir) return
    const file = join(dir, historyFileName(sessionId))
    const prev = this.historyWriteChains.get(sessionId) ?? Promise.resolve()
    // Fire-and-forget: never block forwardEvent, failures only logged
    const next = prev
      .then(async () => {
        await this.ensureHistoryDir()
        await appendFile(file, `${JSON.stringify(stored)}\n`, 'utf8')
      })
      .catch((err) => {
        console.error('[dsh-solo-agent] persist session history failed:', err)
      })
    this.historyWriteChains.set(sessionId, next)
  }

  /** mkdir -p the history dir once (recursive mkdir is idempotent; retried after failure) */
  private ensureHistoryDir(): Promise<void> {
    const dir = this.opts.historyDir
    if (!dir) return Promise.resolve()
    this.historyDirReady ??= mkdir(dir, { recursive: true }).then(
      () => undefined,
      (err) => {
        this.historyDirReady = undefined
        throw err
      },
    )
    return this.historyDirReady
  }

  /** Parse a history jsonl file into events, skipping corrupted lines */
  private async readHistoryFile(sessionId: string): Promise<SessionEvent[] | null> {
    const dir = this.opts.historyDir
    if (!dir) return null
    const file = join(dir, historyFileName(sessionId))
    let raw: string
    try {
      raw = await readFile(file, 'utf8')
    } catch (err) {
      // Missing file = session without persisted history; other errors are logged
      if ((err as NodeJS.ErrnoException)?.code !== 'ENOENT') {
        console.error('[dsh-solo-agent] read session history failed:', err)
      }
      return null
    }
    const events: SessionEvent[] = []
    for (const line of raw.split('\n')) {
      const trimmed = line.trim()
      if (!trimmed) continue
      try {
        const parsed: unknown = JSON.parse(trimmed)
        if (parsed && typeof parsed === 'object') events.push(parsed as SessionEvent)
      } catch {
        // Skip corrupted lines (e.g. half-written lines from an interrupted append)
      }
    }
    return events
  }

  /**
   * Load session history.
   * - Without sinceSeqId: memory buffer first, else read disk jsonl and backfill the buffer.
   * - With sinceSeqId: read disk jsonl first (survives memory-buffer eviction gaps) and
   *   filter to seqId > sinceSeqId; fall back to the memory buffer when no file exists.
   */
  private async loadHistory(sessionId: string, sinceSeqId?: number): Promise<SessionEvent[]> {
    if (typeof sinceSeqId === 'number') {
      const disk = await this.readHistoryFile(sessionId)
      const source = disk ?? this.historyBuffers.get(sessionId) ?? []
      return source.filter((e) => {
        const seq = typeof e.seqId === 'number' ? e.seqId : 0
        return seq > sinceSeqId
      })
    }
    const buffered = this.historyBuffers.get(sessionId)
    if (buffered && buffered.length > 0) return [...buffered]
    const disk = await this.readHistoryFile(sessionId)
    if (disk == null) return []
    const trimmedEvents =
      disk.length > HISTORY_BUFFER_LIMIT ? disk.slice(disk.length - HISTORY_BUFFER_LIMIT) : disk
    this.historyBuffers.set(sessionId, trimmedEvents)
    return trimmedEvents
  }

  /** Drop the in-memory buffer and delete the on-disk jsonl for a session */
  private clearHistory(sessionId: string): void {
    this.historyBuffers.delete(sessionId)
    const dir = this.opts.historyDir
    if (!dir) return
    const file = join(dir, historyFileName(sessionId))
    const prev = this.historyWriteChains.get(sessionId) ?? Promise.resolve()
    // Serialize the rm after any queued appends so a pending write cannot resurrect the file
    const next = prev
      .then(() => rm(file, { force: true }))
      .catch((err) => {
        console.error('[dsh-solo-agent] remove session history failed:', err)
      })
    this.historyWriteChains.set(sessionId, next)
  }

  private interceptApproval(req: ApprovalRequest): Promise<boolean> {
    this.seq++
    this.client.send(
      makeEnvelope('session.event', { kind: 'approval_request', approvalId: req.id, ...req }, {
        sessionId: req.sessionId,
        seqId: this.seq,
        pushLevel: 'high',
        pushSummary: `⚠️ 待审批: [${req.toolName}] ${req.summary ?? ''}`.trim(),
      }),
    )
    return new Promise<boolean>((resolve) => {
      this.pendingApprovals.set(req.id, resolve)
    })
  }

  private async handleCommand(env: Envelope): Promise<void> {
    const payload = env.payload as CmdDispatchPayload | undefined
    if (!payload || typeof payload.action !== 'string') return
    const respond = (ok: boolean, result?: unknown, error?: string) => {
      if (env.reqId) {
        this.client.send(makeEnvelope('rpc.response', { ok, result, error }, { reqId: env.reqId }))
      }
    }

    try {
      switch (payload.action) {
        case 'session.prompt': {
          const data = payload.data as SessionPromptData
          let session = data.sessionId
            ? await this.opts.services.getSession(data.sessionId)
            : null
          if (!session) {
            session = await this.opts.services.createSession({ cwd: data.cwd, model: data.modelId })
          }
          if (data.modelId && session.model !== data.modelId) {
            await session.setModel(data.modelId)
          }
          // 附件解析（upload/file 校验路径、url 抓取落盘），失败整体报错
          const attachNote = await this.resolveAttachments(data.attachments)
          await session.submitPrompt(attachNote ? `${data.prompt}\n\n${attachNote}` : data.prompt)
          respond(true, { sessionId: session.id })
          break
        }
        case 'file.offer': {
          const data = payload.data as FileTransferOfferData
          respond(true, this.admitTransfer(data))
          break
        }
        case 'file.chunk': {
          const data = payload.data as FileTransferChunkData
          const done = await this.receiveChunk(data)
          respond(true, done)
          break
        }
        case 'approval.respond': {
          const data = payload.data as ApprovalRespondData
          const resolve = this.pendingApprovals.get(data.approvalId)
          if (!resolve) throw new Error(`unknown approvalId: ${data.approvalId}`)
          this.pendingApprovals.delete(data.approvalId)
          resolve(data.approved)
          respond(true)
          break
        }
        case 'fs.list_dir': {
          const data = payload.data as ListDirData
          if (!this.opts.listDir) throw new Error('listDir not configured')
          respond(true, await this.opts.listDir(data.path))
          break
        }
        case 'session.rename': {
          const data = payload.data as SessionRenameData
          await this.opts.services.renameSession(data.sessionId, data.title)
          respond(true, { sessionId: data.sessionId, title: data.title })
          break
        }
        case 'session.delete': {
          const data = payload.data as SessionDeleteData
          await this.opts.services.deleteSession(data.sessionId)
          this.clearHistory(data.sessionId)
          respond(true, { sessionId: data.sessionId })
          break
        }
        case 'session.history': {
          const data = payload.data as SessionHistoryData
          const events = await this.loadHistory(data.sessionId, data.sinceSeqId)
          respond(true, { events })
          break
        }
        case 'device.token.get':
          respond(true, { token: this.getDeviceToken(), relayUrl: this.opts.relayUrl ?? '' })
          break
        case 'device.token.reset': {
          const token = await this.resetDeviceToken()
          respond(true, { token })
          break
        }
        default:
          respond(false, undefined, `unknown action: ${String((payload as { action: string }).action)}`)
      }
    } catch (err) {
      respond(false, undefined, err instanceof Error ? err.message : String(err))
    }
  }

  // -------------------------------------------------------------------------
  // 文件上传（file.offer / file.chunk）与 prompt 附件
  // -------------------------------------------------------------------------

  /** uploads 落盘目录：<stateDir>/uploads（未配置 stateDir 时不支持上传） */
  private uploadsDir(): string | null {
    return this.opts.stateDir ? join(this.opts.stateDir, 'uploads') : null
  }

  /** 文件名安全化：剥离路径分隔符与不可见字符，避免落盘穿越 */
  private static safeFileName(name: string): string {
    const base = (name.split(/[\\/]/).pop() ?? 'file').replace(/[^a-zA-Z0-9._\-\u4e00-\u9fa5]/g, '_')
    return base.length ? base.slice(0, 120) : 'file'
  }

  /**
   * file.offer 入口校验：大小/并发数上限（relay 已做服务端硬限制，这里双保险）。
   * 通过则注册传输并启动超时计时，返回回执给 App。
   */
  private admitTransfer(data: FileTransferOfferData): { transferId: string; received: number; chunks: number } {
    const dir = this.uploadsDir()
    if (!dir) throw new Error('uploads not supported (stateDir not configured)')
    if (!data.transferId || typeof data.transferId !== 'string') throw new Error('transferId required')
    if (!data.name || typeof data.size !== 'number' || data.size <= 0) {
      throw new Error('invalid file offer')
    }
    if (data.size > MAX_UPLOAD_SIZE) {
      throw new Error(`file too large: ${data.size} > ${MAX_UPLOAD_SIZE} bytes`)
    }
    if (!Number.isInteger(data.chunks) || data.chunks <= 0 || data.chunks > 4096) {
      throw new Error(`invalid chunk count: ${data.chunks}`)
    }
    if (this.transfers.size >= MAX_CONCURRENT_TRANSFERS) {
      throw new Error(`too many concurrent uploads (${MAX_CONCURRENT_TRANSFERS})`)
    }
    // 同 transferId 重复 offer：先清理旧状态再重开
    const existing = this.transfers.get(data.transferId)
    if (existing) {
      clearTimeout(existing.timer)
      this.transfers.delete(data.transferId)
    }
    const timer = setTimeout(() => this.dropTransfer(data.transferId), TRANSFER_TIMEOUT_MS)
    this.transfers.set(data.transferId, {
      name: data.name,
      size: data.size,
      mime: data.mime,
      chunks: data.chunks,
      received: new Map(),
      timer,
    })
    return { transferId: data.transferId, received: 0, chunks: data.chunks }
  }

  /**
   * 接收单块：存入内存缓冲；收齐后一次性写盘并返回落盘路径。
   * 返回值作为 rpc.response result 回给 App（App 据此推进进度/完成）。
   */
  private async receiveChunk(data: FileTransferChunkData): Promise<Record<string, unknown>> {
    const t = this.transfers.get(data.transferId)
    if (!t) throw new Error(`unknown or expired transfer: ${data.transferId}`)
    if (!Number.isInteger(data.index) || data.index < 0 || data.index >= t.chunks) {
      throw new Error(`chunk index out of range: ${data.index}/${t.chunks}`)
    }
    if (t.received.has(data.index)) {
      return { transferId: data.transferId, index: data.index, duplicated: true }
    }
    const buf = Buffer.from(data.data ?? '', 'base64')
    t.received.set(data.index, buf)
    let total = 0
    for (const b of t.received.values()) total += b.length
    if (total > t.size + 64 * 1024) {
      this.dropTransfer(data.transferId)
      throw new Error('received bytes exceed declared size')
    }

    if (t.received.size < t.chunks) {
      return { transferId: data.transferId, index: data.index, received: t.received.size, chunks: t.chunks }
    }

    // 收齐：按序拼接 → 写盘 → 清理
    const parts: Buffer[] = []
    for (let i = 0; i < t.chunks; i++) parts.push(t.received.get(i) ?? Buffer.alloc(0))
    const file = Buffer.concat(parts)
    if (file.length > MAX_UPLOAD_SIZE) {
      this.dropTransfer(data.transferId)
      throw new Error(`assembled file too large: ${file.length}`)
    }
    const dir = this.uploadsDir()!
    await mkdir(dir, { recursive: true })
    const stamped = `${Date.now().toString(36)}-${AgentCore.safeFileName(t.name)}`
    const path = join(dir, stamped)
    await writeFile(path, file)
    this.dropTransfer(data.transferId)
    return { transferId: data.transferId, done: true, path, size: file.length, name: t.name }
  }

  /** 丢弃单个传输（超时/异常路径） */
  private dropTransfer(transferId: string): void {
    const t = this.transfers.get(transferId)
    if (!t) return
    clearTimeout(t.timer)
    this.transfers.delete(transferId)
  }

  private dropAllTransfers(): void {
    for (const id of [...this.transfers.keys()]) this.dropTransfer(id)
  }

  /**
   * 解析 prompt 附件为注入 prompt 的文本块。
   * - upload：路径必须落在 uploads 目录内（防任意读）；
   * - file：路径必须落在 workspaceRoots 内；
   * - url：agent 电脑侧抓取（≤10MB / 30s），落盘到 uploads 后引用。
   */
  private async resolveAttachments(atts?: PromptAttachment[]): Promise<string> {
    if (!atts?.length) return ''
    if (atts.length > MAX_ATTACHMENTS_PER_PROMPT) {
      throw new Error(`too many attachments: ${atts.length} > ${MAX_ATTACHMENTS_PER_PROMPT}`)
    }
    const dir = this.uploadsDir()
    const lines: string[] = ['[附件]（以下文件已就绪，可用工具读取）']
    for (const att of atts) {
      const name = (att.name ?? 'file').slice(0, 120)
      if (att.kind === 'upload' || att.kind === 'file') {
        const path = att.path ?? ''
        if (!path) throw new Error(`attachment ${name}: path required`)
        const allowed =
          att.kind === 'upload'
            ? AgentCore.pathUnder(path, this.uploadsDir() ?? '\0none')
            : (this.opts.workspaceRoots ?? []).some((root) => AgentCore.pathUnder(path, root))
        if (!allowed) throw new Error(`attachment path not allowed: ${path}`)
        await stat(path) // 不存在即抛错
        lines.push(`- ${name} → ${path}`)
        continue
      }
      if (att.kind === 'url') {
        const url = att.url ?? ''
        if (!/^https?:\/\//i.test(url)) throw new Error(`attachment ${name}: invalid url`)
        const fetched = await this.fetchToUploads(url, name)
        lines.push(`- ${name}（已从 ${url} 下载）→ ${fetched}`)
        continue
      }
      throw new Error(`unknown attachment kind: ${String((att as { kind?: string }).kind)}`)
    }
    return lines.join('\n')
  }

  /** 路径是否位于 root 之下（规范化 + 大小写不敏感，Windows 友好） */
  private static pathUnder(path: string, root: string): boolean {
    const norm = (p: string) => p.replace(/\//g, '\\').replace(/[\\/]+$/, '').toLowerCase()
    const p = norm(path)
    const r = norm(root)
    return p === r || p.startsWith(r + '\\')
  }

  /** 抓取 URL 内容到 uploads 目录（限制大小与超时），返回落盘路径 */
  private async fetchToUploads(url: string, name: string): Promise<string> {
    const dir = this.uploadsDir()
    if (!dir) throw new Error('uploads not supported (stateDir not configured)')
    const ctrl = new AbortController()
    const timer = setTimeout(() => ctrl.abort(), URL_FETCH_TIMEOUT_MS)
    try {
      const res = await fetch(url, { signal: ctrl.signal, redirect: 'follow' })
      if (!res.ok) throw new Error(`fetch ${url}: HTTP ${res.status}`)
      const reader = res.body?.getReader()
      if (!reader) throw new Error(`fetch ${url}: empty body`)
      const chunks: Buffer[] = []
      let total = 0
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        total += value.byteLength
        if (total > MAX_URL_FETCH_SIZE) throw new Error(`url content exceeds ${MAX_URL_FETCH_SIZE} bytes`)
        chunks.push(Buffer.from(value))
      }
      await mkdir(dir, { recursive: true })
      const ext = url.match(/\.(html?|md|txt|pdf|docx?)(?=$|[?#])/i)?.[0] ?? ''
      const path = join(dir, `${Date.now().toString(36)}-${AgentCore.safeFileName(name)}${ext}`)
      await writeFile(path, Buffer.concat(chunks))
      return path
    } finally {
      clearTimeout(timer)
    }
  }
}
