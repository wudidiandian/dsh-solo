// Package proto 定义 DSH-SOLO 统一 JSON 报文信封。
// 字段与 packages/protocol/src/index.ts 及 src/schema.json 保持逐字段一致（三端契约）。
package proto

import "encoding/json"

const (
	// Version 协议版本
	Version = 1
)

// 报文类型（与 TS 端 MessageType 一致）
const (
	TypeHelloAgent    = "hello.agent"
	TypeHelloMobile   = "hello.mobile"
	TypeHelloOK       = "hello.ok"
	TypeHelloError    = "hello.error"
	TypeAgentSnapshot = "agent.snapshot"
	TypeSessionEvent  = "session.event"
	TypeSessionStream = "session.stream"
	TypeSyncRequest   = "sync.request"
	TypeSyncCatchup   = "sync.catchup"
	TypeCmdDispatch   = "cmd.dispatch"
	TypeRPCResponse   = "rpc.response"
)

// 推送优先级
const (
	PushNone   = "none"
	PushNormal = "normal"
	PushHigh   = "high"
)

// 连接角色
const (
	RoleAgent  = "agent"
	RoleMobile = "mobile"
)

// Envelope 统一 JSON 报文信封。
type Envelope struct {
	V           int             `json:"v"`
	Type        string          `json:"type"`
	ReqID       string          `json:"reqId,omitempty"`
	SessionID   string          `json:"sessionId,omitempty"`
	SeqID       int64           `json:"seqId,omitempty"`
	PushLevel   string          `json:"pushLevel,omitempty"`
	PushSummary string          `json:"pushSummary,omitempty"`
	TS          int64           `json:"ts,omitempty"`
	Payload     json.RawMessage `json:"payload,omitempty"`
}

// Decode 解析原始报文并校验协议版本（v=0 视为兼容放行，v>Version 拒绝）。
func Decode(data []byte) (*Envelope, error) {
	var e Envelope
	if err := json.Unmarshal(data, &e); err != nil {
		return nil, err
	}
	if e.V > Version {
		return nil, ErrVersionUnsupported
	}
	return &e, nil
}

// Encode 序列化信封并填充默认协议版本与时间戳。
func Encode(e *Envelope) ([]byte, error) {
	if e.V == 0 {
		e.V = Version
	}
	if e.TS == 0 {
		e.TS = timeNowUnixMilli()
	}
	return json.Marshal(e)
}

// ---------------------------------------------------------------------------
// 握手负载
// ---------------------------------------------------------------------------

type HelloAgentPayload struct {
	DeviceToken string `json:"deviceToken"`
	AgentInfo   string `json:"agentInfo,omitempty"`
}

type HelloMobilePayload struct {
	DeviceToken string `json:"deviceToken"`
	DeviceInfo  string `json:"deviceInfo,omitempty"`
}

type HelloOKPayload struct {
	Role string `json:"role"`
}

type HelloErrorPayload struct {
	Reason string `json:"reason"`
}

// ---------------------------------------------------------------------------
// 断点续传负载
// ---------------------------------------------------------------------------

type SyncRequestPayload struct {
	SessionID string `json:"sessionId"`
	LastSeqID int64  `json:"lastSeqId"`
}

type SyncCatchupPayload struct {
	SessionID string      `json:"sessionId"`
	FromSeqID int64       `json:"fromSeqId"`
	ToSeqID   int64       `json:"toSeqId"`
	Gap       bool        `json:"gap"`
	Events    []*Envelope `json:"events"`
}

// ---------------------------------------------------------------------------
// 远程指令负载
// ---------------------------------------------------------------------------

type CmdDispatchPayload struct {
	Action string          `json:"action"`
	Data   json.RawMessage `json:"data"`
}

type RPCResponsePayload struct {
	OK     bool            `json:"ok"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
}
