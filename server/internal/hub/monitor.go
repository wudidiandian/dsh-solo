package hub

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

// Monitoring never exports tokens, raw IPs, session identifiers or payloads.
type Counters struct {
	Connections        uint64 `json:"connections"`
	PeakConnections    uint64 `json:"peakConnections"`
	MessagesIn         uint64 `json:"messagesIn"`
	MessagesOut        uint64 `json:"messagesOut"`
	BytesIn            uint64 `json:"bytesIn"`
	BytesOut           uint64 `json:"bytesOut"`
	UploadBytesIn      uint64 `json:"uploadBytesIn"`
	ConnectionRejected uint64 `json:"connectionRejected"`
	HandshakeErrors    uint64 `json:"handshakeErrors"`
	UpgradeErrors      uint64 `json:"upgradeErrors"`
	InvalidMessages    uint64 `json:"invalidMessages"`
	ReadErrors         uint64 `json:"readErrors"`
	WriteErrors        uint64 `json:"writeErrors"`
	MessageLimited     uint64 `json:"messageLimited"`
	UploadLimited      uint64 `json:"uploadLimited"`
	UploadRejected     uint64 `json:"uploadRejected"`
	SlowConsumers      uint64 `json:"slowConsumers"`
	PushErrors         uint64 `json:"pushErrors"`
}

type telemetry struct {
	mu      sync.Mutex
	clients map[uint64]*client
	key     [32]byte
	next    atomic.Uint64
	totals  Counters
}

func newTelemetry() *telemetry {
	t := &telemetry{clients: make(map[uint64]*client)}
	if _, err := rand.Read(t.key[:]); err != nil {
		panic("monitoring identity randomness unavailable")
	}
	return t
}

func (t *telemetry) count(update func(*Counters)) { t.mu.Lock(); update(&t.totals); t.mu.Unlock() }
func (t *telemetry) received(n int) {
	t.count(func(c *Counters) { c.MessagesIn++; c.BytesIn += uint64(n) })
}
func (t *telemetry) sent(n int) {
	t.count(func(c *Counters) { c.MessagesOut++; c.BytesOut += uint64(n) })
}
func (t *telemetry) add(c *client) {
	c.monitorID = t.next.Add(1)
	c.connectedAt = time.Now()
	c.lastActivity.Store(c.connectedAt.UnixMilli())
	t.mu.Lock()
	t.clients[c.monitorID] = c
	t.totals.Connections++
	if uint64(len(t.clients)) > t.totals.PeakConnections {
		t.totals.PeakConnections = uint64(len(t.clients))
	}
	t.mu.Unlock()
}
func (t *telemetry) remove(c *client) { t.mu.Lock(); delete(t.clients, c.monitorID); t.mu.Unlock() }
func (t *telemetry) roomID(token string) string {
	h := hmac.New(sha256.New, t.key[:])
	_, _ = h.Write([]byte(token))
	return hex.EncodeToString(h.Sum(nil)[:8])
}
func maskedIP(text string) string {
	ip := net.ParseIP(text)
	if ip == nil {
		return "unknown"
	}
	if v4 := ip.To4(); v4 != nil {
		return fmt.Sprintf("%d.%d.%d.x", v4[0], v4[1], v4[2])
	}
	return ip.Mask(net.CIDRMask(48, 128)).String() + "/48"
}

type ConnectionView struct {
	ID           string    `json:"id"`
	RoomID       string    `json:"roomId"`
	Role         string    `json:"role"`
	Peer         string    `json:"peer"`
	ConnectedAt  time.Time `json:"connectedAt"`
	LastActivity time.Time `json:"lastActivity"`
	QueueDepth   int       `json:"queueDepth"`
}
type MonitorSnapshot struct {
	OnlineApps          int              `json:"onlineApps"`
	OnlineAgents        int              `json:"onlineAgents"`
	ActiveRooms         int              `json:"activeRooms"`
	PairedRooms         int              `json:"pairedRooms"`
	TotalRooms          int              `json:"totalRooms"`
	ReservedConnections int              `json:"reservedConnections"`
	MaxConnections      int              `json:"maxConnections"`
	MaxRooms            int              `json:"maxRooms"`
	MaxPerIP            int              `json:"maxPerIp"`
	Counters            Counters         `json:"counters"`
	Connections         []ConnectionView `json:"connections,omitempty"`
}

// MonitorSnapshot is observational only. Lock ordering never goes from telemetry to Hub/Room.
func (h *Hub) MonitorSnapshot(includeConnections bool) MonitorSnapshot {
	s := MonitorSnapshot{MaxConnections: h.cfg.MaxGlobalConns, MaxRooms: h.cfg.MaxRooms, MaxPerIP: h.cfg.MaxConnPerIP, ReservedConnections: h.guard.globalConns()}
	h.mu.Lock()
	s.TotalRooms = len(h.rooms)
	h.mu.Unlock()
	t := h.telemetry
	t.mu.Lock()
	s.Counters = t.totals
	clients := make([]*client, 0, len(t.clients))
	for _, c := range t.clients {
		clients = append(clients, c)
	}
	t.mu.Unlock()
	rooms := make(map[string]uint8)
	for _, c := range clients {
		bit := uint8(1)
		if c.role == "agent" {
			s.OnlineAgents++
			bit = 2
		} else {
			s.OnlineApps++
		}
		rooms[c.token] |= bit
		if includeConnections {
			s.Connections = append(s.Connections, ConnectionView{ID: fmt.Sprintf("c-%06d", c.monitorID), RoomID: t.roomID(c.token), Role: c.role, Peer: maskedIP(c.ip), ConnectedAt: c.connectedAt, LastActivity: time.UnixMilli(c.lastActivity.Load()).UTC(), QueueDepth: len(c.send)})
		}
	}
	s.ActiveRooms = len(rooms)
	for _, bits := range rooms {
		if bits == 3 {
			s.PairedRooms++
		}
	}
	sort.Slice(s.Connections, func(i, j int) bool { return s.Connections[i].ID < s.Connections[j].ID })
	return s
}
