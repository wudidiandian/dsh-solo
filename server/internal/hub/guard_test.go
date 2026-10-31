// guard_test.go 验证连接防护：令牌桶限流、单 IP/全局连接上限、
// 房间总数上限与空房淘汰、真实 IP 解析。
package hub

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"dsh-solo/server/internal/proto"
)

// ---------------------------------------------------------------------------
// 令牌桶限流器
// ---------------------------------------------------------------------------

func TestRateLimiterBurst(t *testing.T) {
	l := newRateLimiter(100, 5) // 5 个突发令牌，每秒补 100
	if l == nil {
		t.Fatal("limiter should not be nil")
	}
	for i := 0; i < 5; i++ {
		if !l.Allow() {
			t.Fatalf("burst token %d should be allowed", i+1)
		}
	}
	if l.Allow() {
		t.Fatal("6th message must be rate limited (burst exhausted)")
	}
}

func TestRateLimiterRefill(t *testing.T) {
	l := newRateLimiter(200, 2)
	if !l.Allow() || !l.Allow() {
		t.Fatal("initial burst should be allowed")
	}
	if l.Allow() {
		t.Fatal("burst exhausted")
	}
	// 200/s → 25ms 补 5 个令牌
	time.Sleep(30 * time.Millisecond)
	if !l.Allow() {
		t.Fatal("token should refill after 30ms at 200/s")
	}
}

func TestRateLimiterDisabled(t *testing.T) {
	if newRateLimiter(-1, -1) != nil {
		t.Fatal("negative rate/burst = disabled limiter (nil)")
	}
}

// ---------------------------------------------------------------------------
// 连接数防护
// ---------------------------------------------------------------------------

func TestGuardPerIPLimit(t *testing.T) {
	g := newGuard(100, 2)
	if !g.admit("1.1.1.1") || !g.admit("1.1.1.1") {
		t.Fatal("first two connections from same IP should pass")
	}
	if g.admit("1.1.1.1") {
		t.Fatal("third connection from same IP must be rejected")
	}
	if !g.admit("2.2.2.2") {
		t.Fatal("different IP should not be affected")
	}
	g.release("1.1.1.1")
	if !g.admit("1.1.1.1") {
		t.Fatal("after release, connection should pass again")
	}
}

func TestGuardGlobalLimit(t *testing.T) {
	g := newGuard(1, 100)
	if !g.admit("1.1.1.1") {
		t.Fatal("first connection should pass")
	}
	if g.admit("2.2.2.2") {
		t.Fatal("global limit must reject")
	}
	g.release("1.1.1.1")
	if !g.admit("2.2.2.2") {
		t.Fatal("after release, global slot freed")
	}
}

func TestGuardDisabledByNegative(t *testing.T) {
	g := newGuard(-1, -1)
	for i := 0; i < 100; i++ {
		if !g.admit("1.1.1.1") {
			t.Fatalf("disabled guard must admit all (iteration %d)", i+1)
		}
		defer g.release("1.1.1.1")
	}
}

func TestClientIPParsing(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/ws", nil)
	r.RemoteAddr = "9.9.9.9:12345"

	if got := clientIP(r, false); got != "9.9.9.9" {
		t.Fatalf("direct mode: want 9.9.9.9, got %s", got)
	}

	// trustProxy=true 且有 XFF → 取首段
	r.Header.Set("X-Forwarded-For", "1.2.3.4, 10.0.0.1")
	if got := clientIP(r, true); got != "1.2.3.4" {
		t.Fatalf("trustProxy: want 1.2.3.4, got %s", got)
	}

	// trustProxy=true 但 XFF 非法 IP → 回退 RemoteAddr
	r.Header.Set("X-Forwarded-For", "not-an-ip")
	if got := clientIP(r, true); got != "9.9.9.9" {
		t.Fatalf("invalid XFF fallback: want 9.9.9.9, got %s", got)
	}

	// trustProxy=false 时伪造 XFF 无效
	r.Header.Set("X-Forwarded-For", "6.6.6.6")
	if got := clientIP(r, false); got != "9.9.9.9" {
		t.Fatalf("forged XFF must be ignored: got %s", got)
	}
}

// ---------------------------------------------------------------------------
// 房间总数上限与空房淘汰（端到端）
// ---------------------------------------------------------------------------

// TestRoomCapacityReject：房间满且无空房可淘汰时，新 token 握手必须被拒。
func TestRoomCapacityReject(t *testing.T) {
	h := New(Config{MaxRooms: 2, MaxConnPerIP: -1, PongWait: 2 * time.Second})
	wsURL, stop := startServer(t, h)
	defer stop()

	agent1 := dial(t, wsURL)
	defer agent1.Close()
	sendPayload(t, agent1, proto.TypeHelloAgent, proto.HelloAgentPayload{DeviceToken: "tok1"})
	recv(t, agent1, 2*time.Second)

	agent2 := dial(t, wsURL)
	defer agent2.Close()
	sendPayload(t, agent2, proto.TypeHelloAgent, proto.HelloAgentPayload{DeviceToken: "tok2"})
	recv(t, agent2, 2*time.Second)

	// 第 3 个 token：房间满，且 tok1/tok2 都在线（无空房）→ hello.error
	c3 := dial(t, wsURL)
	defer c3.Close()
	sendPayload(t, c3, proto.TypeHelloAgent, proto.HelloAgentPayload{DeviceToken: "tok3"})
	env := recv(t, c3, 2*time.Second)
	if env.Type != proto.TypeHelloError {
		t.Fatalf("want hello.error, got %s", env.Type)
	}
	if payload := env.Payload; payload == nil || !strings.Contains(string(payload), "room capacity") {
		t.Fatalf("unexpected reject reason: %s", env.Payload)
	}

	// 同 token 重连不受上限影响（房间已存在）
	agent1b := dial(t, wsURL)
	defer agent1b.Close()
	sendPayload(t, agent1b, proto.TypeHelloAgent, proto.HelloAgentPayload{DeviceToken: "tok1"})
	if env := recv(t, agent1b, 2*time.Second); env.Type != proto.TypeHelloOK {
		t.Fatalf("existing token must pass: got %s", env.Type)
	}
}

// TestRoomCapacityEvictIdle：房间满时，新 token 连接应淘汰空置最久的空闲房间。
func TestRoomCapacityEvictIdle(t *testing.T) {
	h := New(Config{MaxRooms: 2, MaxConnPerIP: -1, PongWait: 2 * time.Second})
	wsURL, stop := startServer(t, h)
	defer stop()

	agent1 := dial(t, wsURL)
	sendPayload(t, agent1, proto.TypeHelloAgent, proto.HelloAgentPayload{DeviceToken: "tok1"})
	recv(t, agent1, 2*time.Second)

	agent2 := dial(t, wsURL)
	defer agent2.Close()
	sendPayload(t, agent2, proto.TypeHelloAgent, proto.HelloAgentPayload{DeviceToken: "tok2"})
	recv(t, agent2, 2*time.Second)

	// tok1 断开 → 房间空闲（emptySince 记录）→ 被淘汰腾位
	_ = agent1.Close()
	waitFor(t, 2*time.Second, func() bool { return !h.Room("tok1").HasAgent() }, "tok1 idle")

	agent3 := dial(t, wsURL)
	defer agent3.Close()
	sendPayload(t, agent3, proto.TypeHelloAgent, proto.HelloAgentPayload{DeviceToken: "tok3"})
	if env := recv(t, agent3, 2*time.Second); env.Type != proto.TypeHelloOK {
		t.Fatalf("tok3 should be admitted after evicting idle tok1, got %s", env.Type)
	}

	// 被淘汰的 tok1 房间已删除（重连将以 gap 语义重建，符合设计）
	h.mu.Lock()
	_, exists := h.rooms["tok1"]
	h.mu.Unlock()
	if exists {
		t.Fatal("evicted room should be removed from hub")
	}
}
