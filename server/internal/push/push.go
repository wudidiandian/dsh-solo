// Package push 抽象离线推送通道：手机端不在线时，由 relay 调用系统推送。
// MVP 阶段内置 Log（打点）与 Bark（iOS 自托管通知）两个实现；
// 鸿蒙端接入华为 Push Kit、iOS 接入 APNs 时在此追加 Adapter 即可。
package push

import (
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Notification 一条待推送通知
type Notification struct {
	Level    string // normal | high
	Title    string
	Body     string
	DeepLink string // 如 dshsolo://session/sess_xxx?action=approve
}

// Adapter 推送通道接口
type Adapter interface {
	Push(n Notification) error
}

// ---------------------------------------------------------------------------
// LogAdapter：默认实现，仅记录日志（本地开发与测试用）
// ---------------------------------------------------------------------------

type LogAdapter struct {
	Logger *log.Logger
}

func NewLogAdapter() *LogAdapter {
	return &LogAdapter{Logger: log.Default()}
}

func (l *LogAdapter) Push(n Notification) error {
	l.Logger.Printf("[PUSH] level=%s title=%q body=%q link=%s", n.Level, n.Title, n.Body, n.DeepLink)
	return nil
}

// ---------------------------------------------------------------------------
// BarkAdapter：iOS Bark 通道（GET {base}/{title}/{body}）
// ---------------------------------------------------------------------------

type BarkAdapter struct {
	// BaseURL 形如 https://api.day.app/<deviceKey>
	BaseURL string
	Group   string
	Client  *http.Client
}

func NewBarkAdapter(baseURL string) *BarkAdapter {
	return &BarkAdapter{BaseURL: strings.TrimRight(baseURL, "/"), Group: "dsh-solo", Client: &http.Client{Timeout: 10 * time.Second}}
}

func (b *BarkAdapter) Push(n Notification) error {
	if b.BaseURL == "" {
		return fmt.Errorf("bark: empty base url")
	}
	u := fmt.Sprintf("%s/%s/%s",
		b.BaseURL,
		url.PathEscape(n.Title),
		url.PathEscape(n.Body),
	)
	q := url.Values{}
	if b.Group != "" {
		q.Set("group", b.Group)
	}
	if n.Level == "high" {
		q.Set("level", "timeSensitive")
	}
	if n.DeepLink != "" {
		q.Set("url", n.DeepLink)
	}
	full := u + "?" + q.Encode()
	resp, err := b.Client.Get(full)
	if err != nil {
		return fmt.Errorf("bark: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 {
		return fmt.Errorf("bark: http %d", resp.StatusCode)
	}
	return nil
}
