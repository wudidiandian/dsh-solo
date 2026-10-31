// Typed event surface for Cordis (koishi 4 / @deepseek-ai 系)。
import { randomUUID } from 'node:crypto'
import { mkdir } from 'node:fs/promises'
import { join } from 'node:path'
import type { Context } from 'cordis'
import { AgentCore, type HarnessServices } from './core.js'
import { PairingServer } from './pairing.js'
import { resolveDeviceToken } from './token.js'
import { SoloRelayClient } from './ws-client.js'
import { listDirectorySafe, scanShallowDirectories } from './workspace.js'

import { defaultRelayUrl } from './generated-defaults.js'

export const DEFAULT_RELAY_URL = defaultRelayUrl

/** 插件配置：由 cordis.yml / 宿主配置界面注入 */
export interface Config {
  /** relay WebSocket 地址；优先使用此配置，否则使用构建时默认值 */
  relayUrl?: string
  /** 设备配对令牌；缺省则自动生成并持久化到 <workspaceRoots[0]>/.dsh-solo/device-token */
  deviceToken?: string
  /** 允许手机端访问的根目录列表（远程目录树扫描范围） */
  workspaceRoots?: string[]
}

declare module 'cordis' {
  interface Events {
    'dispose'(): void
  }
}

/** 依赖的宿主服务（cordis 注入声明，缺失的按特性探测降级） */
export const inject = ['sessions', 'llm', 'approval', 'agents', 'agentDefaultModel']

/** Cordis 插件入口：把 Harness 上下文桥接到 AgentCore */
export function apply(ctx: Context, config: Config) {
  // 默认模型兜底（2026-10-27）：宿主"默认模型"经 ctx.agentDefaultModel 管理并持久化
  // （实机核实：currentSelection() 返回 {provider, model, reasoningEffort}，重启保留）。
  // 但全新环境首次启动时为空——此时新会话回落 deepseek-official（API key 路线），
  // 未配置 key 的用户首条消息即报 MISSING_CREDENTIAL。这里检测为空时自动把
  // 账号路（deepseek-account）第一个可用模型设为默认，消灭新环境首启动的坑。
  void (async () => {
    try {
      const adm = (ctx as any).agentDefaultModel
      const llm = (ctx as any).llm
      if (!adm || typeof adm.currentSelection !== 'function' || typeof adm.saveSelection !== 'function') return
      const sel = adm.currentSelection()
      if (sel && sel.provider && sel.model) return // 已有默认（含持久化恢复），不动
      // 等模型目录就绪（账号路 /models 拉取为异步，最多等 10s）
      let first: { provider: string; model: string } | null = null
      for (let i = 0; i < 10 && !first; i++) {
        await new Promise((r) => setTimeout(r, 1000))
        try {
          const models = (await llm.listModels()) as any[]
          if (Array.isArray(models) && models.length) {
            const m = models.find((x) => x?.provider && x?.id)
            if (m) first = { provider: m.provider, model: m.id }
          }
        } catch {
          // adapter 未注册完，继续等
        }
      }
      if (!first) first = { provider: 'deepseek-account', model: 'deepseek-flash' } // 目录拉取失败时的保守兜底（官方账号路模型）
      adm.saveSelection(first)
      console.log(`[dsh-solo-agent] default model was empty; set to ${first.provider}/${first.model}`)
    } catch (err) {
      console.error('[dsh-solo-agent] default-model fallback failed:', (err as Error).message)
    }
  })()
  let core: AgentCore | null = null
  let client: SoloRelayClient | null = null
  let pairing: PairingServer | null = null

  // 'dispose' 生命周期事件由宿主（koishi/dsh）层增强，裸 cordis 类型未声明，边界处收窄
  ;(ctx as any).on('dispose', () => {
    core?.stop()
    client?.stop()
    pairing?.stop()
  })

  // 进程级兜底：WebSocket/TLS 的异步写异常偶发逃逸到 uncaughtException
  // （例：relay 证书未就绪时的 EPROTO / 半开 socket 的滞留写）。网络类错误仅记日志，
  // 避免拖垮 dsh 宿主进程；其余异常按原语义 rethrow。
  process.on('uncaughtException', (err) => {
    const code = (err as NodeJS.ErrnoException).code ?? ''
    if (
      ['EPROTO', 'ECONNRESET', 'EPIPE'].includes(code) ||
      /ssl|tls|websocket|unexpected server response|upgrade/i.test(err.message)
    ) {
      console.error('[dsh-solo-agent] swallowed network error:', err.message)
      return
    }
    throw err
  })

  // Bootstrap 是异步的：首次启动需生成并持久化设备令牌；失败仅记日志不抛出
  void bootstrap().catch((err) => {
    console.error('[dsh-solo-agent] plugin bootstrap failed:', err)
  })

  async function bootstrap(): Promise<void> {
    // 状态目录：<workspaceRoots[0] ?? cwd>/.dsh-solo（token 文件与会话历史同处）
    const stateDir = join(config.workspaceRoots?.[0] ?? process.cwd(), '.dsh-solo')
    const historyDir = join(stateDir, 'history')
    // mkdir at startup; AgentCore also mkdirs lazily before the first write.
    mkdir(historyDir, { recursive: true }).catch((err) => {
      console.error('[dsh-solo-agent] create history dir failed:', err)
    })

    // 令牌解析：显式配置 > 已持久化文件 > 自动生成并写入
    const deviceToken = await resolveDeviceToken(config.deviceToken, stateDir)
    const relayUrl = config.relayUrl ?? DEFAULT_RELAY_URL

    const relayClient = new SoloRelayClient({
      url: relayUrl,
      deviceToken,
      agentInfo: 'dsh-solo-agent',
    })
    client = relayClient
    // 必须监听 error：EventEmitter emit('error') 无监听器时会以 uncaughtException 逃逸，
    // 拖垮 dsh 宿主（relay 不可达/握手失败时必现）。连接层已有重连，这里只记日志。
    relayClient.on('error', (err) => {
      console.error('[dsh-solo-agent] relay client error:', err.message)
    })

    // Cordis 服务 → HarnessServices 适配。
    // 实机 dsh 0.2.1-rc.2 核实的宿主 API（2026-10-21，详见 PROJECT_SUMMARY §11.5）：
    // - ctx.agents（dsh-agent）：create() 同建 agent+session，驱动器为 dsh-agent-loop；
    //   prompt 经 agent.followup() 入队并唤醒，回复经 session/event 流回手机
    // - ctx.sessions（dsh-session SessionStore）：create(id?, {meta:{cwd}})、get(id)、
    //   list() 返回活 Session（header.id / header.cwd），全是同步 API
    // - 会话事件：session/event 监听参数为 (session, event)（commit() callbackArgs）
    // - ctx.authorization 是凭证注册表而非工具审批；真实审批钩子未定位（降级告警）
    // - ctx.llm.listModels 不存在；模型列表暂空，待映射 dsh-llm
    const anyCtx = ctx as any
    // 本插件创建的 agent 句柄（dispose 是能力对象，只有持有者能删除会话）
    const handles = new Map<string, any>()
    // 会话标题缓存（session/title 事件 last-wins，供快照展示）
    const titles = new Map<string, string>()

    // 模型目录（2026-10-27 实机核实）：ctx.llm.listModels 存在，但账号路目录为
    // 异步加载（/models 拉取），启动早期调用会抛 "no adapter registered"——
    // 重试 + 成功后缓存，避免每次快照都白等。
    let modelsCache: unknown[] | null = null
    const services: HarnessServices = {
    listModels: async () => {
      // 快速失败版（2026-10-28）：只试一次，失败/为空立即返回 []，不阻塞快照上报。
      // 目录就绪由 bootstrap 的轮询负责——拿到非空目录后触发 core.publishSnapshot()
      // 重报快照，App 端几秒内自动补全模型列表（修复"快照中没有模型列表"）。
      //
      // listModels 签名（2026-10-28 实机定位）：llm.listModels(provider) 需要显式
      // provider 参数，无参调用抛 "no adapter registered for provider \"undefined\""。
      // provider 取宿主默认模型的 provider，缺省回落账号路。
      if (modelsCache) return modelsCache
      const llm = anyCtx.llm
      if (typeof llm?.listModels !== 'function') return []
      const provider = anyCtx.agentDefaultModel?.currentSelection?.()?.provider ?? 'deepseek-account'
      try {
        const r = await llm.listModels(provider)
        if (Array.isArray(r) && r.length) {
          modelsCache = r
          return r
        }
      } catch {
        // 目录未就绪（账号路 /models 异步加载），由 bootstrap 轮询重试
      }
      return []
    },
    listSessions: async () => {
      let list: any[] = []
      if (typeof anyCtx.agents?.list === 'function') {
        list = anyCtx.agents
          .list()
          .map((a: any) => mapAgentSummary(a, titles, handles))
          .filter(Boolean)
      } else if (typeof anyCtx.sessions?.list === 'function') {
        list = anyCtx.sessions
          .list()
          .map((s: any) => ({
            id: s?.header?.id ?? s?.id,
            title: titles.get(s?.header?.id ?? s?.id),
            model: undefined,
            cwd: s?.header?.cwd,
            updatedAt: s?.header?.createdAt,
          }))
          .filter((e: any) => e?.id)
      }
      // 排序：从新到旧（App 会话列表 newest-first，新会话置顶）
      return list.sort((x, y) => (Number(y?.updatedAt) || 0) - (Number(x?.updatedAt) || 0))
    },
    createSession: async (opts) => {
      if (typeof anyCtx.agents?.create !== 'function') {
        throw new Error('host ctx.agents.create not available')
      }
      // dsh-agent-loop 的 createAgent 要求 sessionId 必填（同时用作 agent id，
      // 缺省会触发 "agent id undefined does not match session id" 失败），插件自行生成；
      // cwd 必须落在工作区内，否则会话持久化进 _no-cwd 桶，宿主 web UI 加载不到其历史；
      // agentOptions 必须绑定模型（宿主默认值来自 agentDefaultModel 服务），否则系统
      // 提示词组装时 {model} 变量无值，整个 turn 空跑（deployment/persona-pref 报错）
      const cwd = opts.cwd ?? config.workspaceRoots?.[0]
      const defaults = anyCtx.agentDefaultModel?.currentSelection?.()
      const model = opts.model ?? defaults?.model
      // App 端指定模型时在模型目录里反查 provider，保证 model/provider 配对
      // 正确（宿主默认选区的 provider 可能与所选模型不同源）
      let provider = defaults?.provider ?? 'deepseek'
      if (opts.model) {
        try {
          const hit = (await services.listModels() as any[]).find((x: any) => x?.id === opts.model)
          if (hit?.provider) provider = hit.provider
        } catch {
          // 目录不可用时维持默认 provider
        }
      }
      const handle = await anyCtx.agents.create({
        sessionId: `session-${randomUUID()}`,
        ...(cwd ? { meta: { cwd } } : {}),
        ...(model
          ? {
              agentOptions: {
                provider,
                model,
              },
            }
          : {}),
      })
      const session = agentToSession(handle.agent)
      handles.set(session.id, handle)
      // 快照重报：新会话立即进入 relay 缓存并广播在线 App（否则 App 重连拿到
      // 的仍是旧快照，列表"延迟几分钟"才出现新会话）
      void core?.publishSnapshot()
      return session
    },
    getSession: async (id) => {
      const agent = anyCtx.agents?.get?.(id)
      return agent ? agentToSession(agent) : null
    },
    renameSession: async (id, title) => {
      const session = anyCtx.agents?.get?.(id)?.session ?? anyCtx.sessions?.get?.(id)
      if (!session) throw new Error(`session not found: ${id}`)
      // session/title 为日志型事件（非 surface），last-wins；source 为单键 kind
      await session.append('session/title', {
        title,
        messageSeqs: [],
        source: { kind: 'user' },
      })
      titles.set(id, title)
      // 快照重报：标题变更同步进 relay 缓存
      void core?.publishSnapshot()
    },
    deleteSession: async (id) => {
      // dispose 是能力对象：仅本插件创建的会话持有句柄；web UI 创建的会话删不了
      const handle = handles.get(id)
      if (!handle) {
        throw new Error(
          `无法删除：仅支持删除手机端本次运行内创建的会话 / Cannot delete: only sessions created in this app run can be removed (${id})`,
        )
      }
      handles.delete(id)
      titles.delete(id)
      await handle.dispose()
      // 快照重报：已删会话立即从 relay 缓存移除（否则 App 重启后"死会话复活"）
      void core?.publishSnapshot()
    },
    onSessionEvent: (cb) => {
      // 监听参数为 (session, event)；在插件 ctx 注册（跨上下文投递范围待真机验证）
      if (typeof anyCtx.on === 'function') {
        return anyCtx.on('session/event', (...args: unknown[]) => {
          const normalized = normalizeSessionEventArgs(args)
          if (!normalized) return
          const [sid, ev] = normalized
          const data = ev.data as { title?: unknown } | undefined
          if (ev.kind === 'session/title' && typeof data?.title === 'string') {
            titles.set(sid, data.title)
          }
          cb(sid, ev)
        })
      }
      return () => {}
    },
    registerApprovalHandler: (handler) => {
      if (typeof anyCtx.approval?.registerHandler === 'function') {
        anyCtx.approval.registerHandler(handler)
      } else {
        console.warn(
          '[dsh-solo-agent] host approval API not found; 审批拦截未启用 / approval interception disabled (pending mapping of the real permission hook)',
        )
      }
    },
  }

    // 会话历史目录：<stateDir>/history；AgentCore 负责懒 mkdir 与落盘
    core = new AgentCore(relayClient, {
      services,
      historyDir,
      stateDir,
      workspaceRoots: config.workspaceRoots ?? [],
      deviceToken,
      relayUrl,
      rotateDeviceToken: (t) => relayClient.reconnectWithToken(t),
      buildSnapshot: async () => ({
        dirTree: await scanShallowDirectories(config.workspaceRoots ?? [], 2),
      }),
      listDir: (p) => listDirectorySafe(p, config.workspaceRoots ?? []),
    })

    // 本机配对页（127.0.0.1:8790+）：展示 relay 地址/token/二维码，支持重置
    pairing = new PairingServer({
      getToken: () => core?.getDeviceToken() ?? '',
      getRelayUrl: () => relayUrl,
      resetToken: async () => {
        if (!core) throw new Error('agent not ready')
        return core.resetDeviceToken()
      },
    })
    pairing.start()

    core.start()

    // 逐字流（2026-10-28 实机核实）：宿主 agent/assistant-stream 是进程内
    // 瞬时通道（start/chunk/end 帧，chunk.chunk.type='text-delta'），不进
    // durable 日志——durable 侧只有回合结束才 commit assistant/message，这
    // 就是 App"最后一下全出"的原因。这里把增量帧映射为 session.stream 直通
    // relay；agent-scoped dispatch 按宿主文档全局监听即可收到所有 agent。
    if (typeof anyCtx.on === 'function') {
      anyCtx.on('agent/assistant-stream', (payload: unknown) => {
        try {
          const p = payload as { agent?: { session?: { header?: { id?: string } } }; frame?: {
            type: string
            chunk?: { type: string; text?: string }
          } }
          const sid = p?.agent?.session?.header?.id
          const frame = p?.frame
          if (!sid || !core || frame?.type !== 'chunk') return
          const chunk = frame.chunk
          if (chunk?.type === 'text-delta' && typeof chunk.text === 'string' && chunk.text) {
            core.sendStreamDelta(sid, 'text-delta', chunk.text)
          } else if (chunk?.type === 'reasoning-delta' && typeof chunk.text === 'string' && chunk.text) {
            core.sendStreamDelta(sid, 'reasoning-delta', chunk.text)
          }
        } catch {
          // 流帧转发失败不影响会话主链路
        }
      })
    }
    // 先注册处理器（core.start）再发起连接；连接与重连由 SoloRelayClient.start 驱动
    relayClient.start()

    // 模型目录就绪轮询（2026-10-28）：账号路 /models 异步加载，首次快照上报时
    // 多半还没就绪（models=[]，App 显示"快照中没有模型列表"且选择器不可用）。
    // 每 3s 探测一次 listModels，拿到非空目录后立即重报快照（最多探测 60s），
    // App 端收到新快照后自动补全模型列表。
    void (async () => {
      for (let i = 0; i < 20; i++) {
        await new Promise((r) => setTimeout(r, 3000))
        try {
          const models = await services.listModels()
          if (Array.isArray(models) && models.length) {
            await core?.publishSnapshot()
            console.log(`[dsh-solo-agent] model catalog ready (${models.length} models); snapshot re-published`)
            return
        }
        console.log(`[dsh-solo-agent] catalog probe #${i}: catalog not ready yet`)
      } catch (err) {
          console.log(`[dsh-solo-agent] catalog probe #${i} failed: ${(err as Error).message}`)
        }
      }
      console.warn('[dsh-solo-agent] model catalog not ready after 60s; snapshot keeps empty models')
    })()
  }
}

/** 把宿主 Agent 映射成 AgentCore 需要的会话句柄 */
let setModelUnsupportedWarned = false

function agentToSession(agent: any): import('./core.js').AgentSessionLike {
  const id = agent?.session?.header?.id ?? agent?.id
  if (!id) throw new Error('host agent has no session id')
  return {
    id,
    model: agent?.options?.model,
    async setModel(modelId: string): Promise<void> {
      // 尽力而为（2026-10-28）：宿主暂无已知的 per-session 模型切换 API。
      // 新会话路径（createSession 的 agentOptions）已支持任意模型；已有会话
      // 找不到宿主切换入口时不抛错——否则 App 对已有会话选模型会让整条
      // prompt 失败。仅提示一次“该会话保持原模型”。
      if (typeof agent?.setModel === 'function') {
        await agent.setModel(modelId)
        return
      }
      if (!setModelUnsupportedWarned) {
        setModelUnsupportedWarned = true
        console.warn(
          '[dsh-solo-agent] host per-session setModel not available; App 模型选择仅对新建会话生效',
        )
      }
    },
    async submitPrompt(prompt: string): Promise<void> {
      // followup 入队普通下一轮并唤醒驱动器。inbox 消息按原样提交为 user/message，
      // 必须携带完整 UserMessage 字段（缺 role 会导致模型请求 400：messages[i] missing field "role"）
      agent.followup({
        id: randomUUID(),
        role: 'user',
        content: [{ type: 'text', text: prompt }],
        source: { kind: 'user' },
      })
    },
  }
}

/** 活代理 → 快照会话条目 */
function mapAgentSummary(a: any, titles: Map<string, string>, handles: Map<string, any>) {
  const id = a?.session?.header?.id ?? a?.id
  if (!id) return null
  return {
    id,
    title: titles.get(id),
    model: a?.options?.model,
    cwd: a?.session?.header?.cwd,
    updatedAt: a?.session?.header?.createdAt,
    // deleteSession 的能力对象只在本插件手里：标记 App 端可否删除（驱动 UI 区分来源）
    deletable: handles.has(id),
  }
}

/**
 * session/event 监听参数归一化：commit() 广播 (session, event)，
 * 部分路径可能给 (sessionId, event)，两种形状都兼容。
 * 返回 [sessionId, {kind, ...}]，识别失败返回 null。
 */
function normalizeSessionEventArgs(args: unknown[]): [string, Record<string, unknown>] | null {
  let sessionId: string | null = null
  let event: any = null
  for (const a of args) {
    if (typeof a === 'string') {
      sessionId = a
    } else if (a && typeof a === 'object') {
      const o = a as any
      if (event === null && typeof o.type === 'string') event = o
      else if (sessionId === null && typeof o.header?.id === 'string') sessionId = o.header.id
    }
  }
  if (!sessionId || !event) return null
  return [sessionId, { kind: event.type, data: event.data, seq: event.seq }]
}
