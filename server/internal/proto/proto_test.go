package proto

import (
	"encoding/json"
	"testing"
)

// TestEnvelopeFieldNames 校验 JSON 字段名与 TS 端协议（camelCase）一致，
// 这是三端契约的关键锚点。
func TestEnvelopeFieldNames(t *testing.T) {
	e := &Envelope{
		Type:        TypeSessionEvent,
		ReqID:       "req-1",
		SessionID:   "sess-1",
		SeqID:       42,
		PushLevel:   PushHigh,
		PushSummary: "待审批 bash",
		TS:          1776691200000,
		Payload:     json.RawMessage(`{"kind":"approval_request"}`),
	}
	raw, err := json.Marshal(e)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"v", "type", "reqId", "sessionId", "seqId", "pushLevel", "pushSummary", "ts", "payload"} {
		if _, ok := m[key]; !ok {
			t.Fatalf("missing json field %q in %s", key, raw)
		}
	}
}

func TestEncodeDecodeRoundTrip(t *testing.T) {
	e := &Envelope{
		Type:      TypeSyncRequest,
		SessionID: "s1",
		Payload:   mustMarshal(SyncRequestPayload{SessionID: "s1", LastSeqID: 100}),
	}
	raw, err := Encode(e)
	if err != nil {
		t.Fatal(err)
	}
	if e.V != Version || e.TS == 0 {
		t.Fatalf("Encode should fill defaults, got v=%d ts=%d", e.V, e.TS)
	}

	decoded, err := Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	var p SyncRequestPayload
	if err := json.Unmarshal(decoded.Payload, &p); err != nil {
		t.Fatal(err)
	}
	if p.SessionID != "s1" || p.LastSeqID != 100 {
		t.Fatalf("payload mismatch: %+v", p)
	}
}

func TestDecodeRejectsHigherVersion(t *testing.T) {
	raw := []byte(`{"v":999,"type":"session.event"}`)
	if _, err := Decode(raw); err != ErrVersionUnsupported {
		t.Fatalf("want ErrVersionUnsupported, got %v", err)
	}
}

func TestPayloadStructsJSONTags(t *testing.T) {
	// SyncCatchupPayload 字段名对齐 TS 端
	b, _ := json.Marshal(SyncCatchupPayload{SessionID: "s", FromSeqID: 1, ToSeqID: 2, Gap: true, Events: nil})
	want := `{"sessionId":"s","fromSeqId":1,"toSeqId":2,"gap":true,"events":null}`
	if string(b) != want {
		t.Fatalf("got %s want %s", b, want)
	}
}

func mustMarshal(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}
