import type { HostCapabilities } from '@dsh-solo/protocol'

/**
 * 宿主（DSH/Cordis）API 适配层：index.ts 之外唯一允许触碰宿主形状的地方。
 *
 * 宿主接口未公开稳定契约（多为实机探测所得），这里集中做三件事：
 * 1. 以命名 getter 暴露宿主服务，宿主改名/迁移时只改本文件；
 * 2. 探测能力表（capabilities）随快照上报，App 据此动态启用/降级 UI；
 * 3. 探测宿主版本（探测不到则缺省，不猜测）。
 *
 * 兼容矩阵（已实机核实的宿主形状）：
 * - dsh 0.2.1-rc.2：agents.create/get/list、sessions.get/list、sessionQuery.readSession、
 *   llm.listModels(provider)、agentDefaultModel.currentSelection/saveSelection、
 *   agentPresets.resolve/mount、workspaceRegistry、connection.fetch.register、
 *   waterfall('approval/request' | 'user-questions/request')、
 *   事件 session/event、agent/status、agent/assistant-stream。
 *   无 per-session setModel、无通用会话删除 API（delete 能力为 own-only）。
 */
export class HostAdapter {
  /** per-session 模型切换：初始按保守值 false，见到活 agent 后动态修正 */
  private setModelAvailable = false
  /** 回合中断（agent.cancel）：同样随活 agent 探测 */
  private interruptAvailable = false

  constructor(private readonly ctx: any) {}

  /** 原始 Cordis 上下文（仅用于需要整体 ctx 的宿主入口，如 InteractionBroker.install） */
  get context(): any {
    return this.ctx
  }

  get agents(): any {
    return this.ctx?.agents
  }

  get sessions(): any {
    return this.ctx?.sessions
  }

  get llm(): any {
    return this.ctx?.llm
  }

  get agentDefaultModel(): any {
    return this.ctx?.agentDefaultModel
  }

  get agentPresets(): any {
    return this.ctx?.agentPresets
  }

  get workspaceRegistry(): any {
    return this.ctx?.workspaceRegistry
  }

  get sessionQuery(): any {
    return this.ctx?.sessionQuery
  }

  get connection(): any {
    return this.ctx?.connection
  }

  on(event: string, listener: (...args: unknown[]) => void): () => void {
    if (typeof this.ctx?.on === 'function') {
      return this.ctx.on(event, listener)
    }
    return () => {}
  }

  /** 宿主版本：按已知形状依次探测，均无则缺省 */
  get hostVersion(): string | undefined {
    const candidates = [this.ctx?.version, this.ctx?.app?.version, this.ctx?.root?.app?.version]
    for (const v of candidates) {
      if (typeof v === 'string' && v) return v
    }
    return undefined
  }

  /**
   * 记录活 agent 是否提供 per-session setModel；返回能力是否发生变化
   * （变化时调用方应重报快照，让 App 及时点亮/降级模型切换 UI）。
   */
  noteSetModel(available: boolean): boolean {
    if (this.setModelAvailable === available) return false
    this.setModelAvailable = available
    return true
  }

  /** 记录活 agent 是否提供 cancel（回合中断）；返回能力是否变化 */
  noteInterrupt(available: boolean): boolean {
    if (this.interruptAvailable === available) return false
    this.interruptAvailable = available
    return true
  }

  /** 探测活 agent 的动态能力（setModel / cancel），任一变化返回 true */
  noteAgentCapabilities(agent: any): boolean {
    const a = this.noteSetModel(typeof agent?.setModel === 'function')
    const b = this.noteInterrupt(typeof agent?.cancel === 'function')
    return a || b
  }

  /**
   * 聚合所有 provider 路由的模型目录（桌面端选择器即跨 provider 聚合）。
   * 仅拉默认 provider 会漏掉自定义/API-key 路线的模型。按 id 去重（先注册优先），
   * 缺失 provider 字段时补所属路由；单个 provider 目录未就绪不影响其余。
   */
  async listAllModels(fallbackProvider: string): Promise<unknown[]> {
    const llm = this.llm
    if (typeof llm?.listModels !== 'function') return []
    let providers: string[] = []
    if (typeof llm.listProviders === 'function') {
      try {
        providers = (llm.listProviders() ?? [])
          .map((p: any) => p?.id)
          .filter((id: any) => typeof id === 'string' && id)
      } catch {
        providers = []
      }
    }
    if (!providers.length) providers = [fallbackProvider]
    const merged: any[] = []
    const seen = new Set<string>()
    for (const provider of providers) {
      try {
        const rows = await llm.listModels(provider)
        if (!Array.isArray(rows)) continue
        for (const m of rows) {
          const id = (m as any)?.id
          if (typeof id !== 'string' || !id || seen.has(id)) continue
          seen.add(id)
          merged.push({ ...(m as object), provider: (m as any)?.provider ?? provider })
        }
      } catch {
        // 该 provider 适配器未就绪或目录拉取失败：跳过
      }
    }
    return merged
  }

  capabilities(): HostCapabilities {
    const genericDelete =
      typeof this.sessions?.delete === 'function' || typeof this.agents?.delete === 'function'
    return {
      'session.create': typeof this.agents?.create === 'function',
      'session.setModel': this.setModelAvailable,
      'session.interrupt': this.interruptAvailable,
      'session.delete': genericDelete ? 'all' : 'own-only',
      'session.rename': typeof this.sessions?.get === 'function' || typeof this.agents?.get === 'function',
      'session.history': typeof this.sessionQuery?.readSession === 'function',
      interactions: typeof this.ctx?.waterfall === 'function',
      models: typeof this.llm?.listModels === 'function',
      projects: this.workspaceRegistry != null,
      fileUpload: true,
    }
  }
}