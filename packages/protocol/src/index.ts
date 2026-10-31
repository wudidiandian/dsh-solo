/**
 * DSH-SOLO 统一报文协议 (Envelope Protocol) v1
 *
 * 所有通过 WebSocket 传输的消息均遵循统一的 JSON 信封结构。
 * 本包是三端（agent / relay / app）的协议单一事实源：
 * - TS 端（agent 插件）直接引用本包类型
 * - Go 端（relay）在 server/internal/proto 中保持字段级一致（见 schema.json）
 * - Flutter 端（app）依据 schema.json 生成模型
 */

/** 协议版本号 */
export const PROTOCOL_VERSION = 1

/** 推送优先级：none 不推送 / normal 普通系统通知 / high 高优带响铃震动 */
export type PushLevel = 'none' | 'normal' | 'high'

/** 全部报文类型 */
export type MessageType =
  // 握手与鉴权
  | 'hello.agent' // agent → relay
  | 'hello.mobile' // mobile → relay
  | 'hello.ok' // relay → 任意端（握手成功确认）
  | 'hello.error' // relay → 任意端（鉴权失败，之后服务端会主动断开）
  // 业务报文
  | 'agent.snapshot' // agent → relay 缓存，relay → mobile 秒开
  | 'session.event' // agent → relay → mobile（带 seqId，进入环形缓冲）
  | 'session.stream' // agent → relay → mobile（逐字流：不带 seqId，不入缓冲，断线即丢）
  | 'sync.request' // mobile → relay：断线重连后请求补发差量事件
  | 'sync.catchup' // relay → mobile：补发 [fromSeqId+1, toSeqId] 区间事件
  // 远程指令（mobile → relay → agent）
  | 'cmd.dispatch'
  // 指令执行结果（agent → relay → mobile，按 reqId 路由）
  | 'rpc.response'

/** 统一 JSON 报文信封 */
export interface Envelope<P = unknown> {
  /** 协议版本，固定为 1 */
  v: number
  /** 报文类型 */
  type: MessageType
  /** RPC 关联 ID（cmd.dispatch / rpc.response 成对出现） */
  reqId?: string
  /** 所属会话 ID */
  sessionId?: string
  /** 会话内严格单调递增的序列号（session.event 必填） */
  seqId?: number
  /** 推送优先级 */
  pushLevel?: PushLevel
  /** 推送摘要（手机离线时展示在系统通知里） */
  pushSummary?: string
  /** 毫秒时间戳 */
  ts?: number
  /** 业务负载 */
  payload?: P
}

// ---------------------------------------------------------------------------
// 握手负载
// ---------------------------------------------------------------------------

export interface HelloAgentPayload {
  deviceToken: string
  agentInfo?: string
}

export interface HelloMobilePayload {
  deviceToken: string
  deviceInfo?: string
}

export interface HelloOkPayload {
  role: 'agent' | 'mobile'
}

export interface HelloErrorPayload {
  reason: string
}

// ---------------------------------------------------------------------------
// 快照负载
// ---------------------------------------------------------------------------

/** 电脑端环境快照：手机秒开的数据源（目录树 + 模型列表 + 活跃会话） */
export interface AgentSnapshotPayload {
  models?: unknown[]
  sessions?: unknown[]
  dirTree?: DirTreeNode[]
  timestamp: number
}

/** 浅目录树节点（默认展开 2 层） */
export interface DirTreeNode {
  name: string
  path: string
  type: 'dir' | 'file'
  children?: DirTreeNode[]
}

// ---------------------------------------------------------------------------
// 断点续传负载
// ---------------------------------------------------------------------------

export interface SyncRequestPayload {
  sessionId: string
  /** 本地已收到的最后一个 seqId，relay 补发其之后的事件 */
  lastSeqId: number
}

export interface SyncCatchupPayload {
  sessionId: string
  fromSeqId: number
  toSeqId: number
  /** true 表示本地落后太多、中间有事件已被环形缓冲淘汰，App 应以快照/全量重置为准 */
  gap: boolean
  events: Envelope[]
}

// ---------------------------------------------------------------------------
// 远程指令负载
// ---------------------------------------------------------------------------

export type CommandAction =
  | 'project.list'
  | 'session.prompt'
  | 'approval.respond'
  | 'fs.list_dir'
  | 'session.rename'
  | 'session.delete'
  | 'session.history'
  | 'device.token.get'
  | 'device.token.reset'
  // 文件传输（2026-10-28）：手机 → 电脑上传。relay 仅做字节限流与大小校验，
  // 不落盘不缓存；agent 内存组装后写入 uploads 目录。
  | 'file.offer'
  | 'file.chunk'

/** prompt 附件引用（session.prompt 携带；upload/file 指向电脑磁盘路径，url 由 agent 抓取） */
export interface PromptAttachment {
  /** upload=手机上传已落盘 / file=电脑已有文件 / url=在线文档链接 */
  kind: 'upload' | 'file' | 'url'
  /** 展示名（含扩展名） */
  name: string
  /** kind=upload/file 时必填：电脑上的绝对路径 */
  path?: string
  /** kind=url 时必填 */
  url?: string
  size?: number
  mime?: string
}

export interface ProjectEntry {
  id: string
  title: string
}

export interface SessionPromptData {
  /** Existing desktop workspace selected for a new session. */
  projectId?: string
  /** 缺省则新建会话 */
  sessionId?: string
  cwd?: string
  modelId?: string
  prompt: string
  /** 附件列表（agent 解析后以文本引用形式注入 prompt） */
  attachments?: PromptAttachment[]
}

/** file.offer：宣告一次上传（手机 → agent），校验通过后开始逐块发送 */
export interface FileTransferOfferData {
  transferId: string
  name: string
  size: number
  mime?: string
  /** 总块数（App 按 CHUNK_SIZE 计算；agent 按此数量收齐后组装） */
  chunks: number
}

/** file.chunk：单块数据（base64），每块都回 rpc.response（App 收到 ack 再发下一块 = 内置节奏控制） */
export interface FileTransferChunkData {
  transferId: string
  index: number
  /** base64 编码的块数据 */
  data: string
}

export interface ApprovalRespondData {
  approvalId: string
  approved: boolean
}

export interface ListDirData {
  path: string
}

export interface SessionRenameData {
  sessionId: string
  title: string
}

export interface SessionDeleteData {
  sessionId: string
}

export interface SessionHistoryData {
  sessionId: string
  /** Only return events with seqId greater than this (incremental sync); omit for full history */
  sinceSeqId?: number
}

export interface CmdDispatchPayload<A extends CommandAction = CommandAction> {
  action: A
  data: A extends 'session.prompt'
    ? SessionPromptData
    : A extends 'approval.respond'
      ? ApprovalRespondData
      : A extends 'fs.list_dir'
        ? ListDirData
        : A extends 'session.rename'
          ? SessionRenameData
          : A extends 'session.delete'
            ? SessionDeleteData
            : A extends 'session.history'
              ? SessionHistoryData
              : A extends 'device.token.get' | 'device.token.reset'
                ? Record<string, never>
                : A extends 'file.offer'
                  ? FileTransferOfferData
                  : A extends 'file.chunk'
                    ? FileTransferChunkData
                    : unknown
}

export interface RpcResponsePayload {
  ok: boolean
  result?: unknown
  error?: string
}

// ---------------------------------------------------------------------------
// 会话事件（agent 上报的 Harness 事件流）
// ---------------------------------------------------------------------------

export type SessionEventKind =
  | 'text.delta'
  | 'thought.delta'
  | 'tool.started'
  | 'tool.completed'
  | 'approval_request'
  | 'ask_user'
  | 'turn.completed'
  | 'turn.failed'

export interface SessionEvent {
  kind?: SessionEventKind | string
  [key: string]: unknown
}

// ---------------------------------------------------------------------------
// 逐字流（agent → relay 直通 → mobile；不持久，断线即丢）
// ---------------------------------------------------------------------------

/** 逐字流帧负载：宿主 agent/assistant-stream 的 text-delta 透传 */
export interface SessionStreamPayload {
  /** 流帧种类：正文增量 / 思考增量 / 本轮流结束 */
  kind: 'text-delta' | 'reasoning-delta' | 'end'
  /** 增量文本（end 帧为空） */
  text?: string
}

// ---------------------------------------------------------------------------
// 构造工具
// ---------------------------------------------------------------------------

let seqCounter = 0

/** 生成 RPC 关联 ID（优先使用 crypto.randomUUID） */
export function newId(): string {
  const g = globalThis as { crypto?: { randomUUID?: () => string } }
  if (g.crypto?.randomUUID) return g.crypto.randomUUID()
  return `id-${Date.now().toString(36)}-${(++seqCounter).toString(36)}-${Math.random().toString(36).slice(2, 8)}`
}

/** 构造一个符合协议的信封 */
export function makeEnvelope<P>(type: MessageType, payload?: P, extra?: Partial<Envelope<P>>): Envelope<P> {
  return { v: PROTOCOL_VERSION, type, ts: Date.now(), payload, ...extra }
}
