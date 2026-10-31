import type { PushLevel } from '@dsh-solo/protocol'

/**
 * 依据会话事件类型推断推送优先级（设计文档 §4.2）：
 * - high：需要人工介入（审批请求 / Agent 提问）→ 高优响铃震动
 * - normal：任务回合结束 / 失败 → 普通系统通知
 * - none：流式过程事件，不打扰
 */
export function inferPushPriority(kind?: string): PushLevel {
  switch (kind) {
    case 'approval_request':
    case 'ask_user':
      return 'high'
    case 'turn.completed':
    case 'turn.failed':
      return 'normal'
    default:
      return 'none'
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
    case 'ask_user':
      return 'Agent 等待你的输入'
    default:
      return String(ev.kind ?? 'session event')
  }
}
