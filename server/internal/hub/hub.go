// Package hub 实现 DSH-SOLO relay 的核心：配对房间（Room）、连接泵、
// 快照缓存、环形缓冲断点续传与离线推送分流。
//
// 设计要点（对应设计文档 §3 / §5）：
//   - 电脑端 agent 与手机端 mobile 通过预共享 deviceToken 配对到同一 Room；
//   - agent 上报的 session.event 携带会话内单调递增 seqId，写入 RingBuffer 后
//     实时转发给所有在线 mobile；
//   - mobile 断线重连后发送 sync.request { lastSeqId }，relay 从 RingBuffer
//     补发差量事件（sync.catchup），中间有空洞则置 gap=true；
//   - 事件到达时若 mobile 全部离线且 pushLevel != none，则触发系统推送；
//   - cmd.dispatch 按 reqId 记录来源 mobile，rpc.response 定向回传。
package hub

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"dsh-solo/server/internal/proto"
	"dsh-solo/server/internal/push"
)

const (
	defaultRingCapacity = 1000
	defaultWriteWait    = 10 * time.Second
	defaultPongWait     = 60 * time.Second
	defaultSendBuf      = 256
	maxMessageSize      = 4 << 20 // 4MB，快照含目录树时可能较大

	defaultMaxRooms       = 256 // 房间总数上限（防垃圾 token 刷房间）
	defaultMaxConnPerIP   = 8   // 单 IP 并发连接上限
	defaultMaxGlobalConns = 512 // 全局并发连接上限
	defaultMsgRate        = 80  // 单连接每秒消息数
	defaultMsgBurst       = 160 // 单连接消息突发桶容量

	defaultUploadRate    = 1 << 20  // 单连接上传字节速率：1MB/s（令牌桶补充速率）
	defaultUploadBurst   = 4 << 20  // 上传字节突发桶容量：4MB（约一张压缩照片的瞬时额度）
	defaultMaxUploadSize = 10 << 20 // 单文件大小上限：10MB
)

// Config Hub 配置项（零值自动取默认）
type Config struct {
	PushAdapter  push.Adapter
	RingCapacity int
	WriteWait    time.Duration
	PongWait     time.Duration
	SendBuf      int
	Logger       *log.Logger

	// 连接防护（零值取默认；设为负数可关闭该项防护）
	MaxRooms       int  // 房间总数上限，超出时自动淘汰空置最久的房间
	MaxConnPerIP   int  // 单 IP 并发连接上限
	MaxGlobalConns int  // 全局并发连接上限
	MsgRate        int  // 单连接每秒消息数上限（令牌桶速率）
	MsgBurst       int  // 单连接消息突发桶容量
	TrustProxy     bool // 从 X-Forwarded-For/X-Real-IP 解析真实 IP（仅在可信反代后开启）

	// 文件上传防护（2026-10-28）：仅约束 file.offer / file.chunk，其余消息不受影响
	UploadRate    int   // 单连接上传字节速率（字节/秒），负数 = 不限速
	UploadBurst   int   // 上传字节突发桶容量（字节），负数 = 不限突发
	MaxUploadSize int64 // 单文件大小上限（字节），负数 = 不限制
}

func (c *Config) fillDefaults() {
	if c.RingCapacity <= 0 {
		c.RingCapacity = defaultRingCapacity
	}
	if c.WriteWait <= 0 {
		c.WriteWait = defaultWriteWait
	}
	if c.PongWait <= 0 {
		c.PongWait = defaultPongWait
	}
	if c.SendBuf <= 0 {
		c.SendBuf = defaultSendBuf
	}
	if c.Logger == nil {
		c.Logger = log.Default()
	}
	if c.MaxRooms == 0 {
		c.MaxRooms = defaultMaxRooms
	}
	if c.MaxConnPerIP == 0 {
		c.MaxConnPerIP = defaultMaxConnPerIP
	}
	if c.MaxGlobalConns == 0 {
		c.MaxGlobalConns = defaultMaxGlobalConns
	}
	if c.MsgRate == 0 {
		c.MsgRate = defaultMsgRate
	}
	if c.MsgBurst == 0 {
		c.MsgBurst = defaultMsgBurst
	}
	if c.UploadRate == 0 {
		c.UploadRate = defaultUploadRate
	}
	if c.UploadBurst == 0 {
		c.UploadBurst = defaultUploadBurst
	}
	if c.MaxUploadSize == 0 {
		c.MaxUploadSize = defaultMaxUploadSize
	}
}

// Hub 管理所有配对房间
type Hub struct {
	cfg       Config
	guard     *guard
	telemetry *telemetry
	mu        sync.Mutex
	rooms     map[string]*Room
}

func New(cfg Config) *Hub {
	cfg.fillDefaults()
	return &Hub{cfg: cfg, guard: newGuard(cfg.MaxGlobalConns, cfg.MaxConnPerIP), telemetry: newTelemetry(), rooms: make(map[string]*Room)}
}

// Room 按 token 取（或创建）配对房间。
// 注意：MVP 阶段房间与缓冲随进程常驻（单人自用场景内存可控）；
// relay 重启后缓冲丢失，手机端将以 gap 语义触发快照重置，agent 重连后重新上报快照。
func (h *Hub) Room(token string) *Room {
	h.mu.Lock()
	defer h.mu.Unlock()
	r, ok := h.rooms[token]
	if !ok {
		pusher := h.cfg.PushAdapter
		if pusher == nil {
			pusher = push.NewLogAdapter()
		}
		r = &Room{
			token:   token,
			hub:     h,
			pusher:  pusher,
			mobiles: make(map[*client]bool),
			buffers: make(map[string]*RingBuffer),
			waiters: make(map[string]*client),
		}
		h.rooms[token] = r
	}
	return r
}

// ---------------------------------------------------------------------------
// WebSocket 接入
// ---------------------------------------------------------------------------

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	// MVP：不做 Origin 校验（鉴权依赖 deviceToken，生产建议部署在 WSS + 反代后并收紧）
	CheckOrigin: func(*http.Request) bool { return true },
}

// HandleWS GET /ws 入口：升级连接 → 等待握手 → 按角色注册 → 启动读写泵。
func (h *Hub) HandleWS(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r, h.cfg.TrustProxy)
	if !h.guard.admit(ip) {
		h.telemetry.count(func(c *Counters) { c.ConnectionRejected++ })
		h.cfg.Logger.Printf("[GUARD] connection rejected (ip=%s, global=%d, ipConns=%d)",
			ip, h.guard.globalConns(), h.guard.ipConns(ip))
		w.WriteHeader(http.StatusTooManyRequests)
		return
	}
	handedOff := false
	defer func() {
		if !handedOff {
			h.guard.release(ip)
		}
	}()

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		h.telemetry.count(func(c *Counters) { c.UpgradeErrors++ })
		return
	}

	env, _, err := h.readHello(conn)
	if err != nil {
		h.telemetry.count(func(c *Counters) { c.HandshakeErrors++ })
		h.closeConn(conn)
		return
	}

	var (
		role  string
		token string
	)
	switch env.Type {
	case proto.TypeHelloAgent:
		var p proto.HelloAgentPayload
		if err := json.Unmarshal(env.Payload, &p); err != nil || p.DeviceToken == "" {
			h.reject(conn, "invalid hello.agent payload")
			return
		}
		role, token = proto.RoleAgent, p.DeviceToken
	case proto.TypeHelloMobile:
		var p proto.HelloMobilePayload
		if err := json.Unmarshal(env.Payload, &p); err != nil || p.DeviceToken == "" {
			h.reject(conn, "invalid hello.mobile payload")
			return
		}
		role, token = proto.RoleMobile, p.DeviceToken
	default:
		h.reject(conn, "first message must be hello.agent / hello.mobile")
		return
	}

	// 房间总数防护：新 token 需要建房时受 MaxRooms 约束（可淘汰空置最久的房间腾位）
	if !h.acquireRoom(token) {
		h.reject(conn, "relay room capacity exceeded")
		return
	}

	okEnv := proto.Envelope{Type: proto.TypeHelloOK, Payload: mustJSON(proto.HelloOKPayload{Role: role})}
	okRaw, _ := proto.Encode(&okEnv)
	if err := writeMessage(conn, okRaw, h.cfg.WriteWait); err != nil {
		h.telemetry.count(func(c *Counters) { c.WriteErrors++ })
		h.closeConn(conn)
		return
	}

	h.telemetry.sent(len(okRaw))
	c := &client{
		conn:    conn,
		send:    make(chan []byte, h.cfg.SendBuf),
		hub:     h,
		role:    role,
		token:   token,
		ip:      ip,
		limiter: newRateLimiter(h.cfg.MsgRate, h.cfg.MsgBurst),
		// 上传字节限流（仅 file.chunk 消耗；负数配置时 newRateLimiter 返回 nil = 不限流）
		uploadLimiter: newRateLimiter(h.cfg.UploadRate, h.cfg.UploadBurst),
	}

	handedOff = true
	h.telemetry.add(c)
	room := h.Room(token)
	if role == proto.RoleAgent {
		room.registerAgent(c)
	} else {
		room.registerMobile(c)
	}
	h.cfg.Logger.Printf("[WS] %s connected (token=%s..., ip=%s)", role, maskToken(token), ip)

	go c.writePump()
	go c.readPump()
}

// acquireRoom 确认 token 对应房间可创建：
//   - 房间已存在 → 放行；
//   - 未达 MaxRooms 上限（或上限为负=不限）→ 放行；
//   - 已达上限 → 淘汰空置最久的空闲房间腾位，腾不出则拒绝。
//
// 注意锁序：Hub.mu → Room.mu（全工程无反向获取，无死锁风险）。
func (h *Hub) acquireRoom(token string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.rooms[token]; ok {
		return true
	}
	if h.cfg.MaxRooms < 0 || len(h.rooms) < h.cfg.MaxRooms {
		return true
	}
	var (
		victim *Room
		oldest time.Time
	)
	for tok, r := range h.rooms {
		if tok == token {
			continue
		}
		es := r.emptySinceLocked()
		if es.IsZero() {
			continue
		}
		if victim == nil || es.Before(oldest) {
			victim, oldest = r, es
		}
	}
	if victim == nil {
		return false
	}
	delete(h.rooms, victim.token)
	h.cfg.Logger.Printf("[GUARD] evicted idle room (token=%s..., idle since %s, room limit %d)",
		maskToken(victim.token), oldest.Format("15:04:05"), h.cfg.MaxRooms)
	return true
}

// readHello 读取首条握手报文（复用 readPump 的尺寸/超时约束）
func (h *Hub) readHello(conn *websocket.Conn) (*proto.Envelope, []byte, error) {
	_ = conn.SetReadDeadline(time.Now().Add(h.cfg.PongWait))
	conn.SetReadLimit(maxMessageSize)
	_, raw, err := conn.ReadMessage()
	if err != nil {
		return nil, nil, err
	}
	h.telemetry.received(len(raw))
	env, err := proto.Decode(raw)
	if err != nil {
		return nil, nil, err
	}
	return env, raw, nil
}

func (h *Hub) reject(conn *websocket.Conn, reason string) {
	h.telemetry.count(func(c *Counters) { c.HandshakeErrors++ })
	env := proto.Envelope{Type: proto.TypeHelloError, Payload: mustJSON(proto.HelloErrorPayload{Reason: reason})}
	if raw, err := proto.Encode(&env); err == nil {
		if err := writeMessage(conn, raw, h.cfg.WriteWait); err == nil {
			h.telemetry.sent(len(raw))
		} else {
			h.telemetry.count(func(c *Counters) { c.WriteErrors++ })
		}
	}
	h.cfg.Logger.Printf("[WS] handshake rejected: %s", reason)
	h.closeConn(conn)
}

func (h *Hub) closeConn(conn *websocket.Conn) {
	_ = conn.SetReadDeadline(time.Now())
	_ = conn.Close()
}

// ---------------------------------------------------------------------------
// client：单条 WS 连接与读写泵
// ---------------------------------------------------------------------------

type client struct {
	conn         *websocket.Conn
	send         chan []byte
	hub          *Hub
	role         string
	token        string
	ip           string
	monitorID    uint64
	connectedAt  time.Time
	lastActivity atomic.Int64

	limiter *rateLimiter // 单连接消息限流（nil = 不限流）

	// 上传字节限流（nil = 不限流）：仅 file.chunk 按报文字节数消耗令牌，
	// 保护 VPS 带宽——App 端每块都等 rpc ack 再发下一块，与服务端桶速率天然对齐
	uploadLimiter *rateLimiter

	mu     sync.Mutex
	closed bool
}

// enqueue 非阻塞投递；慢消费者（发送缓冲满）直接断开，避免拖垮 Room 广播路径。
// 与 close 互斥，保证不会向已关闭的 channel 发送（否则 panic）。
func (c *client) enqueue(data []byte) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	select {
	case c.send <- data:
		c.mu.Unlock()
	default:
		c.mu.Unlock()
		go c.close("slow consumer")
	}
}

func (c *client) close(reason string) {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return
	}
	c.closed = true
	close(c.send)
	c.mu.Unlock()
	if reason == "slow consumer" {
		c.hub.telemetry.count(func(v *Counters) { v.SlowConsumers++ })
	}
	c.hub.telemetry.remove(c)
	c.hub.guard.release(c.ip)
	c.hub.cfg.Logger.Printf("[WS] %s disconnected (token=%s...): %s", c.role, maskToken(c.token), reason)
	_ = c.conn.Close()
}

// readPump 读泵：解析报文并路由；读错误（含对端关闭/心跳超时）即退出。
func (c *client) readPump() {
	defer func() {
		room := c.hub.Room(c.token)
		if c.role == proto.RoleAgent {
			room.unregisterAgent(c)
		} else {
			room.unregisterMobile(c)
		}
		c.close("read exit")
	}()
	pongWait := c.hub.cfg.PongWait
	_ = c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		c.lastActivity.Store(time.Now().UnixMilli())
		return c.conn.SetReadDeadline(time.Now().Add(pongWait))
	})
	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			c.mu.Lock()
			closed := c.closed
			c.mu.Unlock()
			if !closed && !websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) {
				c.hub.telemetry.count(func(v *Counters) { v.ReadErrors++ })
			}
			return
		}
		c.lastActivity.Store(time.Now().UnixMilli())
		c.hub.telemetry.received(len(raw))
		// 任意有效报文都视作存活信号
		_ = c.conn.SetReadDeadline(time.Now().Add(pongWait))
		// 消息限流：超速直接断开（防单连接消息洪水拖垮广播路径）
		if c.limiter != nil && !c.limiter.Allow() {
			c.hub.telemetry.count(func(v *Counters) { v.MessageLimited++ })
			c.close("rate limited")
			return
		}
		env, err := proto.Decode(raw)
		if err != nil {
			c.hub.telemetry.count(func(v *Counters) { v.InvalidMessages++ })
			c.hub.cfg.Logger.Printf("[WS] bad envelope from %s: %v", c.role, err)
			continue
		}
		room := c.hub.Room(c.token)
		if c.role == proto.RoleAgent {
			room.routeAgent(c, env, raw)
		} else {
			room.routeMobile(c, env, raw)
		}
	}
}

// writePump 写泵：串行化发送；周期性 Ping 保活。
func (c *client) writePump() {
	ticker := time.NewTicker(c.hub.cfg.PongWait * 9 / 10)
	defer func() {
		ticker.Stop()
		_ = c.conn.Close()
	}()
	for {
		select {
		case data, ok := <-c.send:
			if err := c.conn.SetWriteDeadline(time.Now().Add(c.hub.cfg.WriteWait)); err != nil {
				return
			}
			if !ok {
				_ = c.conn.WriteMessage(websocket.CloseMessage, []byte{})
				return
			}
			if err := writeFrame(c.conn, data); err != nil {
				c.hub.telemetry.count(func(v *Counters) { v.WriteErrors++ })
				return
			}
			c.hub.telemetry.sent(len(data))
		case <-ticker.C:
			if err := c.conn.SetWriteDeadline(time.Now().Add(c.hub.cfg.WriteWait)); err != nil {
				return
			}
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

func writeMessage(conn *websocket.Conn, data []byte, writeWait time.Duration) error {
	_ = conn.SetWriteDeadline(time.Now().Add(writeWait))
	return conn.WriteMessage(websocket.TextMessage, data)
}

func writeFrame(conn *websocket.Conn, data []byte) error {
	w, err := conn.NextWriter(websocket.TextMessage)
	if err != nil {
		return err
	}
	if _, err := w.Write(data); err != nil {
		return err
	}
	return w.Close()
}

func mustJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		return json.RawMessage(`{}`)
	}
	return b
}

func maskToken(tok string) string {
	if len(tok) <= 4 {
		return "***"
	}
	return tok[:4]
}
