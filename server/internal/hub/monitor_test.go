package hub

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"dsh-solo/server/internal/proto"
	"github.com/gorilla/websocket"
)

func waitMonitor(t *testing.T, h *Hub, predicate func(MonitorSnapshot) bool) MonitorSnapshot {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		s := h.MonitorSnapshot(true)
		if predicate(s) {
			return s
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("monitor condition not reached")
	return MonitorSnapshot{}
}
func TestMonitorConnectionLifetimePrivacyAndTraffic(t *testing.T) {
	h := New(Config{MaxGlobalConns: 2, MaxConnPerIP: 2, PongWait: 2 * time.Second})
	address, stop := startServer(t, h)
	defer stop()
	token := "monitor-private-token-never-exported"
	agent := dial(t, address)
	defer agent.Close()
	sendPayload(t, agent, proto.TypeHelloAgent, proto.HelloAgentPayload{DeviceToken: token})
	recv(t, agent, time.Second)
	mobile := dial(t, address)
	defer mobile.Close()
	sendPayload(t, mobile, proto.TypeHelloMobile, proto.HelloMobilePayload{DeviceToken: token})
	recv(t, mobile, time.Second)
	s := waitMonitor(t, h, func(s MonitorSnapshot) bool {
		return s.OnlineApps == 1 && s.OnlineAgents == 1 && s.ReservedConnections == 2
	})
	if s.PairedRooms != 1 || s.ActiveRooms != 1 || s.Counters.PeakConnections != 2 {
		t.Fatalf("incorrect stats: %+v", s)
	}
	data, _ := json.Marshal(s)
	for _, private := range []string{token, "127.0.0.1"} {
		if strings.Contains(string(data), private) {
			t.Fatal("monitor leaked private identifier")
		}
	}
	if s.Connections[0].RoomID != s.Connections[1].RoomID || s.Connections[0].ID == s.Connections[1].ID {
		t.Fatal("room/connection identifiers incorrect")
	}
	extra, response, err := websocket.DefaultDialer.Dial(address, nil)
	if extra != nil {
		extra.Close()
	}
	if err == nil || response.StatusCode != http.StatusTooManyRequests {
		t.Fatal("live WS connections must retain guard reservations")
	}
	if h.MonitorSnapshot(false).Counters.ConnectionRejected != 1 {
		t.Fatal("rejection not counted")
	}
	payload := proto.Envelope{V: 1, Type: proto.TypeAgentSnapshot, Payload: json.RawMessage(`{"models":[],"sessions":[],"dirTree":[]}`)}
	send(t, agent, &payload)
	if recv(t, mobile, time.Second).Type != proto.TypeAgentSnapshot {
		t.Fatal("snapshot forwarding failed")
	}
	s = waitMonitor(t, h, func(s MonitorSnapshot) bool { return s.Counters.MessagesIn >= 3 && s.Counters.MessagesOut >= 3 })
	if s.Counters.BytesIn == 0 || s.Counters.BytesOut == 0 {
		t.Fatal("traffic missing")
	}
	_ = mobile.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
	mobile.Close()
	waitMonitor(t, h, func(s MonitorSnapshot) bool { return s.OnlineApps == 0 && s.ReservedConnections == 1 })
	replacement := dial(t, address)
	defer replacement.Close()
	sendPayload(t, replacement, proto.TypeHelloMobile, proto.HelloMobilePayload{DeviceToken: token})
	recv(t, replacement, time.Second)
	waitMonitor(t, h, func(s MonitorSnapshot) bool { return s.OnlineApps == 1 && s.ReservedConnections == 2 })
}
func TestMonitorInvalidFramesAndMaskedIPv6(t *testing.T) {
	h := New(Config{})
	address, stop := startServer(t, h)
	defer stop()
	conn := dial(t, address)
	defer conn.Close()
	sendPayload(t, conn, proto.TypeHelloMobile, proto.HelloMobilePayload{DeviceToken: "fixture"})
	recv(t, conn, time.Second)
	if err := conn.WriteMessage(websocket.TextMessage, []byte("not JSON")); err != nil {
		t.Fatal(err)
	}
	waitMonitor(t, h, func(s MonitorSnapshot) bool { return s.Counters.InvalidMessages == 1 })
	if maskedIP("2001:db8:1234:5678:abcd::1") != "2001:db8:1234::/48" {
		t.Fatal("IPv6 mask incorrect")
	}
	if h.telemetry.roomID("fixture") == New(Config{}).telemetry.roomID("fixture") {
		t.Fatal("room identities should rotate on process restart")
	}
}
