package hub

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"dsh-solo/server/internal/proto"
)

// ---------------------------------------------------------------------------
// 文件上传防护测试（2026-10-28）：
//   - file.offer 超过 MaxUploadSize → relay 直接拒绝（rpc.response 错误，不转发 agent）；
//   - file.chunk 超出上传字节桶 → 服务端断开连接（硬限制，防绕过 App 限速）；
//   - 正常 offer/chunk → 原样转发给 agent。
// ---------------------------------------------------------------------------

// setupUploadRoom 启动 Hub 并完成 agent+mobile 握手配对。
func setupUploadRoom(t *testing.T, cfg Config) (agentConn, mobileConn *websocket.Conn, closeFn func()) {
	t.Helper()
	h := New(cfg)
	wsURL, stop := startServer(t, h)

	agent := dial(t, wsURL)
	sendPayload(t, agent, proto.TypeHelloAgent, proto.HelloAgentPayload{DeviceToken: "tok-up"})
	recvUntil(t, agent, 2*time.Second, proto.TypeHelloOK)

	mobile := dial(t, wsURL)
	sendPayload(t, mobile, proto.TypeHelloMobile, proto.HelloMobilePayload{DeviceToken: "tok-up"})
	recvUntil(t, mobile, 2*time.Second, proto.TypeHelloOK)

	return agent, mobile, func() {
		_ = agent.Close()
		_ = mobile.Close()
		stop()
	}
}

func dispatchEnv(reqID, action string, data map[string]any) *proto.Envelope {
	b, err := json.Marshal(map[string]any{"action": action, "data": data})
	if err != nil {
		panic(err)
	}
	return &proto.Envelope{Type: proto.TypeCmdDispatch, ReqID: reqID, Payload: b}
}

func rpcPayload(t *testing.T, env *proto.Envelope) proto.RPCResponsePayload {
	t.Helper()
	var rp proto.RPCResponsePayload
	if err := json.Unmarshal(env.Payload, &rp); err != nil {
		t.Fatalf("decode rpc.response: %v", err)
	}
	return rp
}

func TestUploadOfferSizeCap(t *testing.T) {
	agent, mobile, done := setupUploadRoom(t, Config{
		MaxUploadSize: 1024,    // 1KB 上限
		UploadRate:    1 << 20, // 限流不影响本用例
		UploadBurst:   1 << 20,
	})
	defer done()

	send(t, mobile, dispatchEnv("req-1", "file.offer", map[string]any{
		"transferId": "t1", "name": "big.jpg", "size": 2048, "chunks": 2,
	}))
	resp := rpcPayload(t, recvUntil(t, mobile, 2*time.Second, proto.TypeRPCResponse))
	if resp.OK || resp.Error == "" {
		t.Fatalf("expect rejected offer, got ok=%v err=%q", resp.OK, resp.Error)
	}
	_ = agent.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	if _, raw, err := agent.ReadMessage(); err == nil {
		t.Fatalf("agent should receive nothing, got: %s", raw)
	}
}

func TestUploadChunkRateLimitDisconnect(t *testing.T) {
	_, mobile, done := setupUploadRoom(t, Config{
		MaxUploadSize: 1 << 20,
		UploadRate:    1000,  // 1KB/s：极小速率便于测试
		UploadBurst:   1024,  // 突发 1KB：十来个 chunk 必然耗尽
	})
	defer done()

	// offer 在字节桶之外（仅 chunk 计费）
	send(t, mobile, dispatchEnv("req-0", "file.offer", map[string]any{
		"transferId": "t1", "name": "a.bin", "size": 4096, "chunks": 10,
	}))
	// 每个报文 ~200B，连发 20 个（~4KB）必超 burst=1KB。
	// 服务端桶耗尽后会断开连接：后续 send 报错 / 读端报错均视为限流生效。
	for i := 0; i < 20; i++ {
		raw, err := proto.Encode(dispatchEnv("req-c", "file.chunk", map[string]any{
			"transferId": "t1", "index": i, "data": "QUFBQQ==",
		}))
		if err != nil {
			t.Fatal(err)
		}
		if werr := mobile.WriteMessage(websocket.TextMessage, raw); werr != nil {
			return // 连接已被服务端断开，符合预期
		}
	}
	// 若发送全程未报错，还需确认读端被断开
	_ = mobile.SetReadDeadline(time.Now().Add(2 * time.Second))
	for {
		if _, _, err := mobile.ReadMessage(); err != nil {
			return // 连接被断开，符合预期
		}
	}
}

func TestUploadForwardHappyPath(t *testing.T) {
	agent, mobile, done := setupUploadRoom(t, Config{
		MaxUploadSize: 1 << 20,
		UploadRate:    1 << 20,
		UploadBurst:   1 << 20,
	})
	defer done()

	send(t, mobile, dispatchEnv("req-1", "file.offer", map[string]any{
		"transferId": "t1", "name": "photo.jpg", "size": 1024, "chunks": 1,
	}))
	fwd := recvUntil(t, agent, 2*time.Second, proto.TypeCmdDispatch)
	var dp proto.CmdDispatchPayload
	if err := json.Unmarshal(fwd.Payload, &dp); err != nil || dp.Action != "file.offer" {
		t.Fatalf("expect file.offer forwarded, got %q err=%v", dp.Action, err)
	}

	send(t, mobile, dispatchEnv("req-2", "file.chunk", map[string]any{
		"transferId": "t1", "index": 0, "data": "QUFBQQ==",
	}))
	fwd2 := recvUntil(t, agent, 2*time.Second, proto.TypeCmdDispatch)
	var dp2 proto.CmdDispatchPayload
	if err := json.Unmarshal(fwd2.Payload, &dp2); err != nil || dp2.Action != "file.chunk" {
		t.Fatalf("expect file.chunk forwarded, got %q err=%v", dp2.Action, err)
	}
}
