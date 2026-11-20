import { describe, expect, it } from 'vitest'
import { inferPushPriority, summarizeEvent } from '../src/push-level'

describe('inferPushPriority（宿主原始 kind 兼容）', () => {
  it('回合结束/失败/停止均为 normal，审批与提问为 high，流式事件 none', () => {
    expect(inferPushPriority({ kind: 'turn/end', data: { reason: { kind: 'completed' } } })).toBe('normal')
    expect(inferPushPriority({ kind: 'turn/end', data: { reason: { kind: 'aborted', reason: { kind: 'user' } } } })).toBe('normal')
    expect(inferPushPriority({ kind: 'turn/end', data: { reason: { kind: 'error' } } })).toBe('normal')
    expect(inferPushPriority({ kind: 'approval/asked', data: { toolName: 'bash' } })).toBe('high')
    expect(inferPushPriority({ kind: 'approval_request' })).toBe('high')
    expect(inferPushPriority({ kind: 'ask_user' })).toBe('high')
    expect(inferPushPriority({ kind: 'turn.completed' })).toBe('normal')
    expect(inferPushPriority({ kind: 'turn.failed' })).toBe('normal')
    expect(inferPushPriority({ kind: 'text.delta' })).toBe('none')
    expect(inferPushPriority({ kind: 'tool/call' })).toBe('none')
    expect(inferPushPriority({})).toBe('none')
  })
})

describe('summarizeEvent', () => {
  it('用户主动停止显示"任务已停止"，非用户中止显示"任务已中止"', () => {
    expect(summarizeEvent({ kind: 'turn/end', data: { reason: { kind: 'aborted', reason: { kind: 'user' } } } })).toBe('任务已停止')
    expect(summarizeEvent({ kind: 'turn/end', data: { reason: { kind: 'aborted', reason: { kind: 'hook', reason: 'x' } } } })).toBe('任务已中止')
    expect(summarizeEvent({ kind: 'turn/end', data: { reason: { kind: 'completed' } } })).toBe('任务已完成')
    expect(summarizeEvent({ kind: 'turn/end', data: { reason: { kind: 'error', error: { message: 'boom' } } } })).toBe('任务执行失败')
  })

  it('审批摘要带工具名；归一化 kind 与显式 summary 保持原行为', () => {
    expect(summarizeEvent({ kind: 'approval/asked', data: { toolName: 'bash' } })).toBe('⚠️ 待审批: [bash]')
    expect(summarizeEvent({ kind: 'turn.completed' })).toBe('任务已完成')
    expect(summarizeEvent({ kind: 'turn.failed' })).toBe('任务执行失败')
    expect(summarizeEvent({ kind: 'x', summary: '自定义' })).toBe('自定义')
  })
})