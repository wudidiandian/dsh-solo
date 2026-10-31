package hub

import (
	"sync"

	"dsh-solo/server/internal/proto"
)

// RingBuffer 每会话事件环形缓冲区：
// 保留最近 capacity 条带 seqId 的事件，支持手机断线重连后的毫秒级 catch-up 补发。
// 非并发安全，由 Room 持锁访问（ReplayAfter 内部自带读锁，可独立使用）。
type RingBuffer struct {
	mu     sync.RWMutex
	cap    int
	events []proto.Envelope
}

func NewRingBuffer(capacity int) *RingBuffer {
	if capacity <= 0 {
		capacity = 1000
	}
	return &RingBuffer{cap: capacity}
}

// Push 追加事件；超出容量时淘汰最旧事件。
func (r *RingBuffer) Push(ev proto.Envelope) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.events = append(r.events, ev)
	if len(r.events) > r.cap {
		// 淘汰最旧的 (len-cap) 条；容量内切片拷贝代价可接受（cap 默认 1000）
		r.events = append([]proto.Envelope(nil), r.events[len(r.events)-r.cap:]...)
	}
}

// ReplayAfter 返回 seqId > lastSeq 的全部保留事件。
// oldest 为当前保留的最小 seqId（空缓冲返回 0）；
// gap=true 表示客户端的 lastSeq+1 已早于最旧保留事件，中间存在无法补发的空洞，
// 客户端应以快照/全量重置为准。
func (r *RingBuffer) ReplayAfter(lastSeq int64) (events []proto.Envelope, oldest int64, gap bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if len(r.events) == 0 {
		return nil, 0, false
	}
	oldest = r.events[0].SeqID
	gap = lastSeq+1 < oldest
	for i := range r.events {
		if r.events[i].SeqID > lastSeq {
			events = append(events, r.events[i])
		}
	}
	return events, oldest, gap
}

// LatestSeq 当前缓冲中最大的 seqId（空缓冲返回 0）。
func (r *RingBuffer) LatestSeq() int64 {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if len(r.events) == 0 {
		return 0
	}
	return r.events[len(r.events)-1].SeqID
}

// Len 当前保留的事件数。
func (r *RingBuffer) Len() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.events)
}
