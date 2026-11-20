import type { PushLevel } from '@dsh-solo/protocol'

/**
 * 依据会话事件推断推送优先级（设计文档 §4.2）：
 * - high：需要人工介入（审批请求 / Agent 提问）→ 高优响铃震动
 * - normal：任务回合结束 / 失败 / 用户停止 → 普通系统通知
 * - none：流式过程事件，不打扰
 *
 * 兼容宿主原始 kind（turn/end、approval/asked）与插件归一化 kind
 * （turn.completed、turn.failed、approval_request、ask_user）。
 */
export function inferPushPriority(ev: { kind?: string; [k: string]: unknown }): PushLevel {
  switch (ev.kind) {
    case 'approval_request':
    case 'ask_user':
    case 'approval/asked':
      return 'high'
    case 'turn.completed':
    case 'turn.failed':
    case 'turn/end':
      return 'normal'
    default:
      return 'none'
  }
}

/** 宿主 turn/end 的 reason 结构：{ kind, reason?: { kind }, error? } */
function turnReason(ev: { [k: string]: unknown }): { kind: string; cause?: string } {
  const data = ev.data as { reason?: unknown } | undefined
  const r = data?.reason as { kind?: unknown; reason?: { kind?: unknown } } | undefined
  return {
    kind: typeof r?.kind === 'string' ? r.kind : '',
    cause: typeof r?.reason?.kind === 'string' ? r.reason.kind : undefined,
  }
}

/** 生成推送摘要（展示在系统通知栏） */
export function summarizeEvent(ev: { kind?: string; summary?: string; [k: string]: unknown }): string {
  if (ev.summary) return ev.summary
  switch (ev.kind) {
    case 'turn.completed':
      return '任务已完成'
    case 'turn.failed':
      return '任务执行失败'
    case 'turn/end': {
      const { kind, cause } = turnReason(ev)
      if (kind === 'completed') return '任务已完成'
      if (kind === 'aborted') return cause === 'user' ? '任务已停止' : '任务已中止'
      return '任务执行失败'
    }
    case 'ask_user':
      return 'Agent 等待你的输入'
    case 'approval/asked': {
      const tool = (ev.data as { toolName?: unknown } | undefined)?.toolName
      return `⚠️ 待审批: [${typeof tool === 'string' ? tool : ''}]`.trim()
    }
    default:
      return String(ev.kind ?? 'session event')
  }
}