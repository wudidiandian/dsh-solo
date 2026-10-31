package hub

import (
	"encoding/json"
	"fmt"
	"sync"
	"time"

	"dsh-solo/server/internal/proto"
	"dsh-solo/server/internal/push"
)

// Room 一对一绑定的配对房间：一台电脑（agent）+ 若干台移动设备（mobile）。
// mu 保护全部可变状态；enqueue/send 均为非阻塞投递，持锁期间不做任何 IO 等待。
type Room struct {
	token  string
	hub    *Hub
	pusher push.Adapter

	mu       sync.Mutex
	agent    *client
	mobiles  map[*client]bool
	snapshot *proto.Envelope           // 缓存最近一次 agent.snapshot 整包
	buffers  map[string]*RingBuffer    // sessionId → 事件环形缓冲
	waiters  map[string]*client        // reqId → 发起 cmd.dispatch 的 mobile
	emptySince time.Time              // 最近一次变为空房（无 agent 且无 mobile）的时刻；非空为零值
}

// ---------------------------------------------------------------------------
// 注册 / 注销
// ---------------------------------------------------------------------------

// registerAgent agent 接入；若已有旧连接（重连/替换），踢掉旧连接。
func (r *Room) registerAgent(c *client) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if old := r.agent; old != nil && old != c {
		go old.close("replaced by new agent connection")
	}
	r.agent = c
	r.trackEmptyLocked()
}

func (r *Room) unregisterAgent(c *client) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.agent == c {
		r.agent = nil
	}
	r.trackEmptyLocked()
}

// registerMobile mobile 接入；注册后立即回吐缓存的快照，实现「秒开」。
func (r *Room) registerMobile(c *client) {
	r.mu.Lock()
	r.mobiles[c] = true
	r.trackEmptyLocked()
	snap := r.snapshot
	r.mu.Unlock()

	if snap != nil {
		if raw, err := proto.Encode(snap); err == nil {
			c.enqueue(raw)
		}
	}
}

func (r *Room) unregisterMobile(c *client) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.mobiles, c)
	for reqID, owner := range r.waiters {
		if owner == c {
			delete(r.waiters, reqID)
		}
	}
	r.trackEmptyLocked()
}

// trackEmptyLocked 维护空置时刻（调用方持 r.mu）。
func (r *Room) trackEmptyLocked() {
	if r.agent == nil && len(r.mobiles) == 0 {
		r.emptySince = time.Now()
	} else {
		r.emptySince = time.Time{}
	}
}

// emptySinceLocked 读取空置时刻（供 Hub 房间淘汰使用；锁序 Hub.mu → Room.mu）。
func (r *Room) emptySinceLocked() time.Time {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.emptySince
}

// ---------------------------------------------------------------------------
// agent 上行路由
// ---------------------------------------------------------------------------

func (r *Room) routeAgent(c *client, env *proto.Envelope, raw []byte) {
	switch env.Type {
	case proto.TypeAgentSnapshot:
		r.storeSnapshot(env, raw)
	case proto.TypeSessionEvent:
		r.storeAndBroadcast(env, raw)
	case proto.TypeSessionStream:
		// 逐字流（2026-10-28）：text-delta 等高频瞬时帧，纯直通——不进环形
		// 缓冲（避免冲刷 catchup 历史）、不触发离线推送（App 断线期间的 delta
		// 无意义，durable 的 assistant/message 会补全）。
		r.broadcastOnly(env, raw)
	case proto.TypeRPCResponse:
		r.routeRPC(env, raw)
	default:
		// agent 侧其余类型（hello.* 等）忽略
	}
}

// broadcastOnly 直播帧转发：仅投递当前在线 mobile，不进缓冲、不推送。
func (r *Room) broadcastOnly(env *proto.Envelope, raw []byte) {
	r.mu.Lock()
	mobiles := make([]*client, 0, len(r.mobiles))
	for m := range r.mobiles {
		mobiles = append(mobiles, m)
	}
	r.mu.Unlock()
	for _, m := range mobiles {
		m.enqueue(raw)
	}
}

func (r *Room) storeSnapshot(env *proto.Envelope, raw []byte) {
	r.mu.Lock()
	r.snapshot = env
	mobiles := make([]*client, 0, len(r.mobiles))
	for m := range r.mobiles {
		mobiles = append(mobiles, m)
	}
	r.mu.Unlock()

	// 快照变更主动推给所有在线 mobile：修复「agent 上报快照与 mobile 接入并发」
	// 导致 mobile 错过最新快照的竞态（收到的以最新一次为准，App 端做整包覆盖）。
	for _, m := range mobiles {
		m.enqueue(raw)
	}
	r.hub.cfg.Logger.Printf("[ROOM %s] snapshot updated (%d mobile online)", maskToken(r.token), len(mobiles))
}

// storeAndBroadcast 事件入环形缓冲 → 实时转发全部在线 mobile →
// 若 mobile 全部离线且 pushLevel != none，则触发系统推送。
func (r *Room) storeAndBroadcast(env *proto.Envelope, raw []byte) {
	// 1. 入缓冲（无 seqId 的事件不占缓冲，仅透传）
	if env.SeqID > 0 {
		r.mu.Lock()
		buf := r.buffers[env.SessionID]
		if buf == nil {
			buf = NewRingBuffer(r.hub.cfg.RingCapacity)
			r.buffers[env.SessionID] = buf
		}
		buf.Push(*env)
		r.mu.Unlock()
	}

	// 2. 实时转发
	r.mu.Lock()
	mobiles := make([]*client, 0, len(r.mobiles))
	for m := range r.mobiles {
		mobiles = append(mobiles, m)
	}
	r.mu.Unlock()
	for _, m := range mobiles {
		m.enqueue(raw)
	}

	// 3. 离线推送分流：仅当无任何在线 mobile 且需要推送时
	if len(mobiles) == 0 && env.PushLevel != "" && env.PushLevel != proto.PushNone {
		notif := push.Notification{
			Level:    env.PushLevel,
			Title:    pushTitle(env.PushLevel),
			Body:     env.PushSummary,
			DeepLink: deepLink(env.SessionID, env.PushLevel),
		}
		// 异步推送，失败仅记日志，不影响主链路
		go func() {
			if err := r.pusher.Push(notif); err != nil {
				r.hub.cfg.Logger.Printf("[PUSH] failed: %v", err)
			}
		}()
	}
}

func pushTitle(level string) string {
	if level == proto.PushHigh {
		return "⚠️ 待审批"
	}
	return "DSH-SOLO"
}

func deepLink(sessionID, level string) string {
	action := "open"
	if level == proto.PushHigh {
		action = "approve"
	}
	if sessionID == "" {
		return "dshsolo://"
	}
	return "dshsolo://session/" + sessionID + "?action=" + action
}

// routeRPC 将 agent 的执行结果按 reqId 定向回传给发起 mobile；
// 找不到来源（如 mobile 已重连）则广播兜底。
func (r *Room) routeRPC(env *proto.Envelope, raw []byte) {
	r.mu.Lock()
	var target *client
	if env.ReqID != "" {
		target = r.waiters[env.ReqID]
		delete(r.waiters, env.ReqID)
	}
	var mobiles []*client
	for m := range r.mobiles {
		mobiles = append(mobiles, m)
	}
	r.mu.Unlock()

	if target != nil {
		target.enqueue(raw)
		return
	}
	for _, m := range mobiles {
		m.enqueue(raw)
	}
}

// ---------------------------------------------------------------------------
// mobile 上行路由
// ---------------------------------------------------------------------------

func (r *Room) routeMobile(c *client, env *proto.Envelope, raw []byte) {
	switch env.Type {
	case proto.TypeSyncRequest:
		var p proto.SyncRequestPayload
		if err := json.Unmarshal(env.Payload, &p); err != nil {
			return
		}
		r.catchup(c, env.SessionID, p)
	case proto.TypeCmdDispatch:
		r.forwardCommand(c, env, raw)
	default:
		// 安全边界：mobile 不得伪造 snapshot / session.event / rpc.response
	}
}

// catchup 补发 (lastSeqId, …] 的差量事件；存在被淘汰空洞时 gap=true。
func (r *Room) catchup(c *client, sessionID string, p proto.SyncRequestPayload) {
	if sessionID == "" {
		sessionID = p.SessionID
	}

	r.mu.Lock()
	buf := r.buffers[sessionID]
	var events []proto.Envelope
	var latest int64
	var gap bool
	if buf != nil {
		events, _, gap = buf.ReplayAfter(p.LastSeqID)
		latest = buf.LatestSeq()
	}
	r.mu.Unlock()

	from := p.LastSeqID + 1
	to := p.LastSeqID
	if len(events) > 0 {
		from = events[0].SeqID
		to = events[len(events)-1].SeqID
	} else if buf != nil && latest > p.LastSeqID {
		// 理论不可达，防御性处理
		gap = true
	}

	catchupEnv := proto.Envelope{
		Type:      proto.TypeSyncCatchup,
		SessionID: sessionID,
		Payload: mustJSON(proto.SyncCatchupPayload{
			SessionID: sessionID,
			FromSeqID: from,
			ToSeqID:   to,
			Gap:       gap,
			Events:    envelopePointers(events),
		}),
	}
	if raw, err := proto.Encode(&catchupEnv); err == nil {
		c.enqueue(raw)
	}
}

func envelopePointers(events []proto.Envelope) []*proto.Envelope {
	if len(events) == 0 {
		return nil
	}
	out := make([]*proto.Envelope, len(events))
	for i := range events {
		out[i] = &events[i]
	}
	return out
}

// forwardCommand 将 mobile 指令转发给 agent；agent 离线时即时回错误 rpc.response。
// 文件上传防护（2026-10-28，服务端硬限制，不信任客户端）：
//   - file.offer：单文件大小超 MaxUploadSize 直接拒绝（不转发）；
//   - file.chunk：按报文字节数消耗单连接上传令牌桶，超速断开连接
//     （正常 App 每块等 ack 再发下一块，速率与服务端桶对齐，不会触发）。
func (r *Room) forwardCommand(c *client, env *proto.Envelope, raw []byte) {
	if !r.admitUpload(c, env, raw) {
		return
	}

	r.mu.Lock()
	agent := r.agent
	if agent != nil && env.ReqID != "" {
		r.waiters[env.ReqID] = c
	}
	r.mu.Unlock()

	if agent == nil {
		errEnv := proto.Envelope{
			V:     proto.Version,
			Type:  proto.TypeRPCResponse,
			ReqID: env.ReqID,
			TS:    nowMilli(),
			Payload: mustJSON(proto.RPCResponsePayload{
				OK:    false,
				Error: "agent offline",
			}),
		}
		if errRaw, err := proto.Encode(&errEnv); err == nil {
			c.enqueue(errRaw)
		}
		return
	}
	agent.enqueue(raw)
}

// admitUpload 文件上传前置校验；返回 false 表示已拦截（要么已回错误响应，要么已断开）。
func (r *Room) admitUpload(c *client, env *proto.Envelope, raw []byte) bool {
	if env.Type != proto.TypeCmdDispatch {
		return true
	}
	var probe struct {
		Action string `json:"action"`
		Data   struct {
			Size   int64  `json:"size"`
			Name   string `json:"name"`
			Chunks int    `json:"chunks"`
		} `json:"data"`
	}
	if err := json.Unmarshal(env.Payload, &probe); err != nil {
		return true // 非 JSON/坏负载交由 agent 侧报错
	}

	switch probe.Action {
	case "file.offer":
		maxUp := r.hub.cfg.MaxUploadSize
		if maxUp < 0 {
			return true // 负数 = 关闭大小限制
		}
		if probe.Data.Size <= 0 || probe.Data.Size > maxUp {
			r.replyError(c, env, fmt.Sprintf("file size %d exceeds limit %d bytes", probe.Data.Size, maxUp))
			r.hub.cfg.Logger.Printf("[GUARD] upload rejected: %q size=%d limit=%d (token=%s...)",
				probe.Data.Name, probe.Data.Size, maxUp, maskToken(c.token))
			return false
		}
	case "file.chunk":
		if c.uploadLimiter != nil && !c.uploadLimiter.AllowN(int64(len(raw))) {
			// 字节桶耗尽：直接断开。正常客户端按 ack 节奏发送不会触达；
			// 被破解的客户端绕过 App 限速时在此被硬性拦截。
			c.close("upload bandwidth exceeded")
			return false
		}
	}
	return true
}

// replyError 以 rpc.response 形式回错误给发起 mobile（reqId 缺省则静默）。
func (r *Room) replyError(c *client, env *proto.Envelope, msg string) {
	if env.ReqID == "" {
		return
	}
	errEnv := proto.Envelope{
		V:     proto.Version,
		Type:  proto.TypeRPCResponse,
		ReqID: env.ReqID,
		TS:    nowMilli(),
		Payload: mustJSON(proto.RPCResponsePayload{
			OK:    false,
			Error: msg,
		}),
	}
	if raw, err := proto.Encode(&errEnv); err == nil {
		c.enqueue(raw)
	}
}

// Snapshot 供测试与观测读取当前快照。
func (r *Room) Snapshot() *proto.Envelope {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.snapshot
}

// Buffer 供测试访问会话环形缓冲。
func (r *Room) Buffer(sessionID string) *RingBuffer {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.buffers[sessionID]
}

// MobileCount 当前在线 mobile 数（观测/测试用）。
func (r *Room) MobileCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.mobiles)
}

// HasAgent agent 是否在线（观测/测试用）。
func (r *Room) HasAgent() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.agent != nil
}
