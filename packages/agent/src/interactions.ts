import { randomUUID } from 'node:crypto'

export interface Interaction {
  id: string
  sessionId: string
  type: 'approval' | 'question'
  toolName?: string
  reason?: string
  details?: string
  questions?: Array<{ id: string; question: string; header?: string; detail?: string;
    multiSelect?: boolean; options?: Array<{ label: string; description?: string }> }>
}

/** Runtime callbacks stay on the computer. Only these explicit DTOs cross E2EE. */
export class InteractionBroker {
  private pending = new Map<string, { item: Interaction; finish: (value: unknown, error?: Error) => void }>()
  private forwarded = new WeakSet<object>()
  private disposers: Array<() => void> = []
  private disposed = false
  constructor(private readonly options: { changed(): void; mobileAvailable(): boolean }) {}

  snapshot(): Interaction[] { return [...this.pending.values()].map(p => p.item) }

  install(ctx: any): void {
    const broker = this
    for (const [event, type] of [['approval/request', 'approval'], ['user-questions/request', 'question']] as const) {
      const stop = ctx.on(event, function(this: unknown, request: any, next: () => Promise<unknown>) {
        if (broker.forwarded.has(request) || broker.disposed) return next()
        const sessionId = request.agent?.sessionId ?? request.agent?.session?.id
        if (typeof sessionId !== 'string' || !sessionId || request.signal?.aborted) return next()
        if (broker.pending.size >= 256) return next()
        const lifetime = new AbortController()
        const downstream = { ...request, signal: lifetime.signal }
        broker.forwarded.add(downstream)
        const item: Interaction = { id: randomUUID(), sessionId, type }
        if (type === 'approval') {
          item.toolName = String(request.toolName ?? '')
          item.reason = String(request.reason ?? '')
          item.details = toolArguments(request)
        } else {
          if (!Array.isArray(request.questions) || !request.questions.length) return next()
          item.questions = request.questions.map((q: any) => ({
            id: String(q.id), question: String(q.question ?? ''),
            header: typeof q.header === 'string' ? q.header : undefined,
            detail: typeof q.detail === 'string' ? q.detail : undefined,
            multiSelect: q.multiSelect === true,
            options: Array.isArray(q.options) ? q.options.map((o: any) => ({
              label: String(o.label), description: typeof o.description === 'string' ? o.description : undefined,
            })) : [],
          }))
        }
        return new Promise<unknown>((resolve, reject) => {
          let settled = false
          const abort = () => finish(type === 'approval' ? 'cancelled' : undefined,
            type === 'question' ? new Error('Question cancelled') : undefined)
          const finish = (value: unknown, error?: Error) => {
            if (settled) return
            settled = true
            broker.pending.delete(item.id)
            request.signal?.removeEventListener('abort', abort)
            // Withdraw the losing desktop card or timed wait, without mutating
            // the original borrowed request or aborting the agent's turn.
            lifetime.abort()
            broker.options.changed()
            if (error) reject(error); else resolve(value)
          }
          broker.pending.set(item.id, { item, finish })
          request.signal?.addEventListener('abort', abort, { once: true })
          if (request.signal?.aborted) { abort(); return }
          broker.options.changed()
          if (type === 'question' && request.wait?.timed && request.wait?.callId &&
              broker.options.mobileAvailable() && typeof ctx.userQuestions?.attachWait === 'function') {
            void (async () => {
              for await (const _ of ctx.userQuestions.attachWait(request.agent, request.wait.callId, lifetime.signal)) {
                if (lifetime.signal.aborted) break
              }
            })().catch(() => {})
          }
          // Redispatch the same scope with a private cancellation lifetime.
          // The marked clone passes through this listener to the original UI.
          Promise.resolve().then(() => ctx.waterfall(this, event, downstream, () => {
            if (type === 'approval') return Promise.resolve('unavailable')
            return Promise.reject(new Error('No desktop question answerer'))
          })).then(value => {
            if (value === 'unavailable' && broker.options.mobileAvailable()) return
            finish(value)
          }, error => {
            if (!settled && !broker.options.mobileAvailable()) finish(undefined,
              type === 'question' ? error : undefined)
          })
        })
      }, { prepend: true })
      if (typeof stop === 'function') this.disposers.push(stop)
    }
  }

  respond(sessionId: string | undefined, id: unknown, response: any): void {
    if (typeof id !== 'string') throw new Error('Invalid request id')
    const pending = this.pending.get(id)
    if (!pending || pending.item.sessionId !== sessionId) throw new Error('Request expired or belongs to another session')
    if (pending.item.type === 'approval') {
      if (typeof response?.approved !== 'boolean') throw new Error('An explicit approval decision is required')
      pending.finish(response.approved ? 'allowed-once' : 'rejected')
      return
    }
    const questions = pending.item.questions!
    if (response?.skipped === true) { pending.finish({ answers: [] }); return }
    if (!Array.isArray(response?.answers) || response.answers.length !== questions.length) throw new Error('Answer every question')
    const seen = new Set<string>()
    const answers = response.answers.map((a: any) => {
      const q = questions.find(q => q.id === a?.id)
      if (!q || seen.has(a.id) || !Array.isArray(a.selected) || a.selected.some((v: any) => typeof v !== 'string') ||
          new Set(a.selected).size !== a.selected.length || (!q.multiSelect && a.selected.length > 1) ||
          a.selected.some((label: string) => !q.options?.some(o => o.label === label)) ||
          (a.custom !== undefined && (typeof a.custom !== 'string' || a.custom.length > 20000)) ||
          (!a.selected.length && !a.custom?.trim())) throw new Error('Invalid question answer')
      seen.add(a.id)
      return { id: q.id, selected: a.selected, ...(a.custom?.trim() ? { custom: a.custom.trim() } : {}) }
    })
    pending.finish({ answers })
  }

  dispose(): void {
    this.disposed = true
    for (const stop of this.disposers.splice(0)) stop()
    for (const { item, finish } of [...this.pending.values()]) {
      finish(item.type === 'approval' ? 'unavailable' : undefined,
        item.type === 'question' ? new Error('Plugin stopped') : undefined)
    }
  }
}

function toolArguments(req: any): string | undefined {
  try {
    const session = req.agent?.session
    if (!req.callId || typeof session?.eventAt !== 'function') return undefined
    for (let seq = session.seq - 1; seq >= Math.max(0, session.seq - 300); seq--) {
      const event = session.eventAt(seq)
      if (event?.type === 'tool/call' && (event.data?.id === req.callId || event.data?.callId === req.callId)) {
        const args = event.data.arguments
        const text = typeof args === 'string' ? args : JSON.stringify(args)
        return text && text.length > 20000
          ? text.slice(0, 20000) + '\n[详情过长，已截断；请在电脑端查看完整操作 / Truncated; inspect the full operation on desktop]'
          : text
      }
    }
  } catch { /* Presentation lookup must never prevent the actual approval. */ }
}
