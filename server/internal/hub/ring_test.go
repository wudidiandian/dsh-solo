package hub

import (
	"sync"
	"testing"

	"dsh-solo/server/internal/proto"
)

func env(seq int64) proto.Envelope {
	return proto.Envelope{Type: proto.TypeSessionEvent, SessionID: "s1", SeqID: seq, TS: seq}
}

func TestRingBufferEviction(t *testing.T) {
	r := NewRingBuffer(3)
	for i := int64(1); i <= 5; i++ {
		r.Push(env(i))
	}
	if r.Len() != 3 {
		t.Fatalf("len = %d, want 3 (capacity)", r.Len())
	}
	if got := r.LatestSeq(); got != 5 {
		t.Fatalf("latest = %d, want 5", got)
	}
	// 保留的是最新的 3,4,5
	events, oldest, gap := r.ReplayAfter(2)
	if oldest != 3 {
		t.Fatalf("oldest = %d, want 3", oldest)
	}
	if gap {
		t.Fatal("gap should be false: lastSeq(2)+1 == oldest(3)")
	}
	if len(events) != 3 || events[0].SeqID != 3 || events[2].SeqID != 5 {
		t.Fatalf("replay mismatch: %+v", seqs(events))
	}
}

func TestRingBufferReplay(t *testing.T) {
	r := NewRingBuffer(3)
	for i := int64(1); i <= 5; i++ {
		r.Push(env(i))
	}
	// 保留 3,4,5
	events, oldest, gap := r.ReplayAfter(2)
	if len(events) != 3 || events[0].SeqID != 3 || events[2].SeqID != 5 {
		t.Fatalf("replay mismatch: %+v", seqs(events))
	}
	if oldest != 3 || gap {
		t.Fatalf("oldest=%d gap=%v, want 3/false", oldest, gap)
	}

	// lastSeq=0：最早保留的 3 已大于 lastSeq+1=1 → 有空洞
	events, oldest, gap = r.ReplayAfter(0)
	if !gap || oldest != 3 {
		t.Fatalf("gap=%v oldest=%d, want true/3", gap, oldest)
	}
	if len(events) != 3 {
		t.Fatalf("should replay all retained, got %d", len(events))
	}

	// lastSeq=5：无新事件
	events, _, gap = r.ReplayAfter(5)
	if len(events) != 0 || gap {
		t.Fatalf("want empty & no gap, got %d events gap=%v", len(events), gap)
	}
}

func TestRingBufferEmpty(t *testing.T) {
	r := NewRingBuffer(10)
	if r.Len() != 0 || r.LatestSeq() != 0 {
		t.Fatal("fresh buffer should be empty")
	}
	events, oldest, gap := r.ReplayAfter(100)
	if events != nil || oldest != 0 || gap {
		t.Fatalf("replay on empty buffer: %+v oldest=%d gap=%v", events, oldest, gap)
	}
}

func TestRingBufferConcurrent(t *testing.T) {
	r := NewRingBuffer(64)
	var wg sync.WaitGroup
	for w := 0; w < 4; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				r.Push(env(int64(w*1000 + i)))
				r.ReplayAfter(int64(i))
			}
		}(w)
	}
	wg.Wait()
	if r.Len() != 64 {
		t.Fatalf("len = %d, want 64", r.Len())
	}
}

func seqs(events []proto.Envelope) []int64 {
	out := make([]int64, 0, len(events))
	for _, e := range events {
		out = append(out, e.SeqID)
	}
	return out
}
