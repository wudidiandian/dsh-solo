package hub

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"dsh-solo/server/internal/proto"
	"dsh-solo/server/internal/push"
)

// ---------------------------------------------------------------------------
// 测试工具
// ---------------------------------------------------------------------------

// recorder 记录推送调用（替代 LogAdapter 断言离线推送是否触发）
type recorder struct {
	mu   sync.Mutex
	got  []push.Notification
	seen chan push.Notification
}

func newRecorder() *recorder {
	return &recorder{seen: make(chan push.Notification, 16)}
}

func (r *recorder) Push(n push.Notification) error {
	r.mu.Lock()
	r.got = append(r.got, n)
	r.mu.Unlock()
	select {
	case r.seen <- n:
	default:
	}
	return nil
}

func (r *recorder) waitOne(t *testing.T, timeout time.Duration) push.Notification {
	t.Helper()
	select {
	case n := <-r.seen:
		return n
	case <-time.After(timeout):
		t.Fatal("timeout waiting for push notification")
		return push.Notification{}
	}
}

func startServer(t *testing.T, h *Hub) (wsURL string, close func()) {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(h.HandleWS))
	return "ws" + strings.TrimPrefix(srv.URL, "http"), srv.Close
}

func dial(t *testing.T, wsURL string) *websocket.Conn {
	t.Helper()
	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	return c
}

func send(t *testing.T, c *websocket.Conn, env *proto.Envelope) {
	t.Helper()
	raw, err := proto.Encode(env)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.WriteMessage(websocket.TextMessage, raw); err != nil {
		t.Fatalf("send: %v", err)
	}
}

func sendPayload(t *testing.T, c *websocket.Conn, typ string, payload any) {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	send(t, c, &proto.Envelope{Type: typ, Payload: b})
}

func recv(t *testing.T, c *websocket.Conn, timeout time.Duration) *proto.Envelope {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(timeout))
	_, raw, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("recv: %v", err)
	}
	env, err := proto.Decode(raw)
	if err != nil {
		t.Fatalf("recv decode: %v", err)
	}
	return env
}

func recvUntil(t *testing.T, c *websocket.Conn, timeout time.Duration, typ string) *proto.Envelope {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		remain := time.Until(deadline)
		if remain <= 0 {
			t.Fatalf("timeout waiting for %s", typ)
		}
		env := recv(t, c, remain)
		if env.Type == typ {
			return env
		}
	}
}

func waitFor(t *testing.T, timeout time.Duration, cond func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timeout waiting for %s", what)
}

// ---------------------------------------------------------------------------
// 集成测试：模拟 完整链路
// ---------------------------------------------------------------------------

func TestRelayEndToEnd(t *testing.T) {
	rec := newRecorder()
	h := New(Config{PushAdapter: rec, PongWait: 2 * time.Second})
	wsURL, stop := startServer(t, h)
	defer stop()

	const tok = "tok1"
	const sess = "sess_1"
	room := h.Room(tok)

	// --- 1. agent 握手 ---
	agent := dial(t, wsURL)
	defer agent.Close()
	sendPayload(t, agent, proto.TypeHelloAgent, proto.HelloAgentPayload{DeviceToken: tok, AgentInfo: "test-pc"})
	env := recv(t, agent, 2*time.Second)
	if env.Type != proto.TypeHelloOK {
		t.Fatalf("want hello.ok, got %s", env.Type)
	}

	// --- 2. agent 上报快照（等待 relay 落缓存，保证与 mobile 接入的时序确定性） ---
	sendPayload(t, agent, proto.TypeAgentSnapshot, map[string]any{
		"models": []string{"deepseek-v3"}, "timestamp": 1776691200000,
	})
	waitFor(t, 2*time.Second, func() bool { return room.Snapshot() != nil }, "snapshot cached")

	// --- 3. agent 持续产出事件 seq 1..3（手机未连接） ---
	for i := int64(1); i <= 3; i++ {
		send(t, agent, &proto.Envelope{Type: proto.TypeSessionEvent, SessionID: sess, SeqID: i, PushLevel: proto.PushNone, Payload: json.RawMessage(`{"kind":"text.delta"}`)})
	}
	waitFor(t, 2*time.Second, func() bool {
		buf := room.Buffer(sess)
		return buf != nil && buf.LatestSeq() == 3
	}, "events 1..3 buffered")

	// --- 4. mobile 握手 → 自动收到缓存快照（秒开） ---
	mobile := dial(t, wsURL)
	defer mobile.Close()
	sendPayload(t, mobile, proto.TypeHelloMobile, proto.HelloMobilePayload{DeviceToken: tok, DeviceInfo: "phone"})
	env = recv(t, mobile, 2*time.Second)
	if env.Type != proto.TypeHelloOK {
		t.Fatalf("want hello.ok, got %s", env.Type)
	}
	env = recvUntil(t, mobile, 2*time.Second, proto.TypeAgentSnapshot)
	if env.Payload == nil || !strings.Contains(string(env.Payload), "deepseek-v3") {
		t.Fatalf("snapshot payload mismatch: %s", env.Payload)
	}

	// --- 5. 实时转发：agent 发 seq4，mobile 应实时收到 ---
	send(t, agent, &proto.Envelope{Type: proto.TypeSessionEvent, SessionID: sess, SeqID: 4, PushLevel: proto.PushNone})
	env = recvUntil(t, mobile, 2*time.Second, proto.TypeSessionEvent)
	if env.SeqID != 4 {
		t.Fatalf("live event seq = %d, want 4", env.SeqID)
	}

	// --- 6. 手机离线 → 高优事件触发推送 ---
	_ = mobile.Close()
	waitFor(t, 2*time.Second, func() bool { return room.MobileCount() == 0 }, "mobile offline")

	send(t, agent, &proto.Envelope{
		Type: proto.TypeSessionEvent, SessionID: sess, SeqID: 5,
		PushLevel: proto.PushHigh, PushSummary: "待审批: bash rm -rf",
	})
	n := rec.waitOne(t, 3*time.Second)
	if n.Level != proto.PushHigh || !strings.Contains(n.Body, "bash") {
		t.Fatalf("push mismatch: %+v", n)
	}
	if !strings.HasPrefix(n.DeepLink, "dshsolo://session/") {
		t.Fatalf("deeplink mismatch: %s", n.DeepLink)
	}

	// --- 7. 手机重连 → sync.request 补发 seq 4..5，无空洞 ---
	mobile2 := dial(t, wsURL)
	defer mobile2.Close()
	sendPayload(t, mobile2, proto.TypeHelloMobile, proto.HelloMobilePayload{DeviceToken: tok})
	recv(t, mobile2, 2*time.Second)                                              // hello.ok
	recvUntil(t, mobile2, 2*time.Second, proto.TypeAgentSnapshot)                // 秒开快照
	sendPayload(t, mobile2, proto.TypeSyncRequest, proto.SyncRequestPayload{SessionID: sess, LastSeqID: 3})

	env = recvUntil(t, mobile2, 2*time.Second, proto.TypeSyncCatchup)
	var cp proto.SyncCatchupPayload
	if err := json.Unmarshal(env.Payload, &cp); err != nil {
		t.Fatal(err)
	}
	if cp.Gap {
		t.Fatal("gap should be false (seq3..5 all retained)")
	}
	if len(cp.Events) != 2 || cp.Events[0].SeqID != 4 || cp.Events[1].SeqID != 5 {
		t.Fatalf("catchup events mismatch: %+v", cp.Events)
	}

	// --- 8. cmd.dispatch → agent，rpc.response 按 reqId 定向回传 ---
	b, _ := json.Marshal(map[string]any{
		"action": "fs.list_dir", "data": map[string]any{"path": "~/Projects"},
	})
	send(t, mobile2, &proto.Envelope{Type: proto.TypeCmdDispatch, ReqID: "req-1", Payload: b})
	cmdEnv := recvUntil(t, agent, 2*time.Second, proto.TypeCmdDispatch)
	if cmdEnv.ReqID != "req-1" {
		t.Fatalf("cmd.dispatch reqId = %q, want req-1", cmdEnv.ReqID)
	}
	reqID := cmdEnv.ReqID

	send(t, agent, &proto.Envelope{
		Type: proto.TypeRPCResponse, ReqID: reqID,
		Payload: json.RawMessage(`{"ok":true,"result":["a","b"]}`),
	})
	env = recvUntil(t, mobile2, 2*time.Second, proto.TypeRPCResponse)
	var rpc proto.RPCResponsePayload
	if err := json.Unmarshal(env.Payload, &rpc); err != nil {
		t.Fatal(err)
	}
	if !rpc.OK {
		t.Fatalf("rpc should succeed: %+v", rpc)
	}

	// --- 9. agent 离线 → mobile 命令立即收到 agent offline 错误 ---
	_ = agent.Close()
	waitFor(t, 2*time.Second, func() bool { return !room.HasAgent() }, "agent offline")

	var respErr *proto.Envelope
	for i := 0; i < 20; i++ {
		sendPayload(t, mobile2, proto.TypeCmdDispatch, map[string]any{
			"action": "session.prompt", "data": map[string]any{"prompt": "hi"},
		})
		env := recvUntil(t, mobile2, 2*time.Second, proto.TypeRPCResponse)
		var rpc proto.RPCResponsePayload
		_ = json.Unmarshal(env.Payload, &rpc)
		if !rpc.OK {
			respErr = env
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if respErr == nil {
		t.Fatal("expected agent offline error response")
	}
}

// TestCatchupGap 手机落后过多（事件已被环形缓冲淘汰）时必须置 gap=true。
func TestCatchupGap(t *testing.T) {
	h := New(Config{RingCapacity: 3, PongWait: 2 * time.Second})
	wsURL, stop := startServer(t, h)
	defer stop()

	const tok = "tok-gap"
	agent := dial(t, wsURL)
	defer agent.Close()
	sendPayload(t, agent, proto.TypeHelloAgent, proto.HelloAgentPayload{DeviceToken: tok})
	recv(t, agent, 2*time.Second)

	for i := int64(1); i <= 6; i++ {
		send(t, agent, &proto.Envelope{Type: proto.TypeSessionEvent, SessionID: "s", SeqID: i})
	}
	waitFor(t, 2*time.Second, func() bool {
		buf := h.Room(tok).Buffer("s")
		return buf != nil && buf.LatestSeq() == 6
	}, "events 1..6 buffered")

	mobile := dial(t, wsURL)
	defer mobile.Close()
	sendPayload(t, mobile, proto.TypeHelloMobile, proto.HelloMobilePayload{DeviceToken: tok})
	recv(t, mobile, 2*time.Second) // hello.ok（本场景无快照，不会收到 agent.snapshot）

	sendPayload(t, mobile, proto.TypeSyncRequest, proto.SyncRequestPayload{SessionID: "s", LastSeqID: 0})
	env := recvUntil(t, mobile, 2*time.Second, proto.TypeSyncCatchup)
	var cp proto.SyncCatchupPayload
	if err := json.Unmarshal(env.Payload, &cp); err != nil {
		t.Fatal(err)
	}
	if !cp.Gap {
		t.Fatal("gap must be true when events were evicted")
	}
	if len(cp.Events) != 3 || cp.Events[0].SeqID != 4 || cp.Events[2].SeqID != 6 {
		t.Fatalf("retained events mismatch: %+v", cp.Events)
	}
}

// TestHandshakeValidation 握手必须校验 token 与首报文类型。
func TestHandshakeValidation(t *testing.T) {
	h := New(Config{})
	wsURL, stop := startServer(t, h)
	defer stop()

	// 首报文不是 hello → hello.error
	c := dial(t, wsURL)
	defer c.Close()
	sendPayload(t, c, proto.TypeSessionEvent, map[string]any{})
	env := recv(t, c, 2*time.Second)
	if env.Type != proto.TypeHelloError {
		t.Fatalf("want hello.error, got %s", env.Type)
	}

	// 缺 token → hello.error
	c2 := dial(t, wsURL)
	defer c2.Close()
	sendPayload(t, c2, proto.TypeHelloMobile, proto.HelloMobilePayload{})
	env = recv(t, c2, 2*time.Second)
	if env.Type != proto.TypeHelloError {
		t.Fatalf("want hello.error for empty token, got %s", env.Type)
	}
}
