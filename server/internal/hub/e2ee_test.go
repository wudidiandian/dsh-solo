package hub

import (
	"dsh-solo/server/internal/proto"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestDefaultRateAllowsFastEncryptedAgentStream(t *testing.T) {
	h := New(Config{})
	url, stop := startServer(t, h)
	defer stop()
	agent := dial(t, url)
	defer agent.Close()
	sendPayload(t, agent, proto.TypeHelloAgent, map[string]any{"deviceToken": "fast-room", "e2ee": 1})
	recv(t, agent, time.Second)
	mobile := dial(t, url)
	defer mobile.Close()
	id := "00112233445566778899aabbccddeeff"
	sendPayload(t, mobile, proto.TypeHelloMobile, map[string]any{"deviceToken": "fast-room", "e2ee": 1, "secureId": id})
	recv(t, mobile, time.Second)
	// Opaque data for an absent recipient still consumes the sender's frame
	// quota, without making this a receiver queue/backpressure test.
	for i := 0; i < 4000; i++ {
		send(t, agent, &proto.Envelope{Type: proto.TypeSecureData, PeerID: "absent", Payload: mustJSON(map[string]any{"ciphertext": "opaque"})})
	}
	send(t, agent, &proto.Envelope{Type: proto.TypeSecureData, PeerID: id, Payload: mustJSON(map[string]any{"ciphertext": "final"})})
	got := recv(t, mobile, 3*time.Second)
	if got.Type != proto.TypeSecureData || !strings.Contains(string(got.Payload), "final") {
		t.Fatal("fast small-frame stream was interrupted before its final frame")
	}
}

func TestEncryptedMobileByteLimitSurvivesHigherMessageQuota(t *testing.T) {
	h := New(Config{UploadRate: 1024, UploadBurst: 1024})
	url, stop := startServer(t, h)
	defer stop()
	mobile := dial(t, url)
	defer mobile.Close()
	id := "00112233445566778899aabbccddeeff"
	sendPayload(t, mobile, proto.TypeHelloMobile, map[string]any{"deviceToken": "byte-room", "e2ee": 1, "secureId": id})
	recv(t, mobile, time.Second)
	// One message is well below the frame-count quota, but exceeds the byte
	// bucket. No plaintext file metadata is needed to enforce this limit.
	send(t, mobile, &proto.Envelope{Type: proto.TypeSecureData, PeerID: id, Payload: mustJSON(map[string]any{"ciphertext": strings.Repeat("x", 2048)})})
	_ = mobile.SetReadDeadline(time.Now().Add(time.Second))
	if _, _, err := mobile.ReadMessage(); err == nil || strings.Contains(err.Error(), "timeout") {
		t.Fatalf("expected immediate byte-limit disconnect, got %v", err)
	}
}

func TestSecureRelayOpaqueRoutingAndNoContentCache(t *testing.T) {
	h := New(Config{})
	url, stop := startServer(t, h)
	defer stop()
	agent := dial(t, url)
	defer agent.Close()
	sendPayload(t, agent, proto.TypeHelloAgent, map[string]any{"deviceToken": "secure-room", "e2ee": 1})
	ack := recv(t, agent, time.Second)
	var accepted map[string]any
	if err := json.Unmarshal(ack.Payload, &accepted); err != nil || accepted["e2ee"] != float64(1) {
		t.Fatal("missing encryption capability")
	}
	mobile := dial(t, url)
	defer mobile.Close()
	id := "00112233445566778899aabbccddeeff"
	sendPayload(t, mobile, proto.TypeHelloMobile, map[string]any{"deviceToken": "secure-room", "e2ee": 1, "secureId": id})
	recv(t, mobile, time.Second)
	// A connection cannot impersonate another opaque routing ID.
	send(t, mobile, &proto.Envelope{Type: proto.TypeSecureHello, PeerID: "ffffffffffffffffffffffffffffffff", Payload: mustJSON(map[string]any{"proof": "forged"})})
	send(t, mobile, &proto.Envelope{Type: proto.TypeSecureHello, PeerID: id, Payload: mustJSON(map[string]any{"publicKey": "opaque-public-key", "proof": "opaque-proof"})})
	routed := recv(t, agent, time.Second)
	if routed.PeerID != id {
		t.Fatal("routed forged peer ID")
	}
	// Relay does not decrypt or interpret encrypted contents.
	send(t, agent, &proto.Envelope{Type: proto.TypeSecureData, PeerID: id, Payload: mustJSON(map[string]any{"counter": 1, "ciphertext": "opaque-ciphertext"})})
	response := recv(t, mobile, time.Second)
	if response.Type != proto.TypeSecureData || response.PeerID != id {
		t.Fatal("secure response routing failed")
	}
	room := h.Room("secure-room")
	room.mu.Lock()
	if room.snapshot != nil || len(room.buffers) != 0 || len(room.waiters) != 0 {
		t.Error("encrypted rooms must not build plaintext snapshots, history or RPC indexes")
	}
	room.mu.Unlock()
}

func TestSecureMobileRequiresConnectionID(t *testing.T) {
	h := New(Config{})
	url, stop := startServer(t, h)
	defer stop()
	mobile := dial(t, url)
	defer mobile.Close()
	sendPayload(t, mobile, proto.TypeHelloMobile, map[string]any{"deviceToken": "secure-room", "e2ee": 1})
	if recv(t, mobile, time.Second).Type != proto.TypeHelloError {
		t.Fatal("missing secure ID accepted")
	}
}

func TestLegacyClientRejectedByDefault(t *testing.T) {
	h := New(Config{})
	url, stop := startServer(t, h)
	defer stop()
	c := dial(t, url)
	defer c.Close()
	sendPayload(t, c, proto.TypeHelloMobile, map[string]any{"deviceToken": "legacy-room"})
	if recv(t, c, time.Second).Type != proto.TypeHelloError {
		t.Fatal("plaintext client accepted without explicit opt-in")
	}
}
