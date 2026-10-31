// guard.go 实现 relay 的连接防护：
//   - 令牌桶消息限流（单连接维度，防消息洪水）；
//   - 单 IP 并发连接上限（防单点滥用刷连接）；
//   - 全局并发连接上限（防连接风暴耗尽内存）。
//
// 设计约束：不引入外部依赖；所有检查为 O(1)；持锁期间不做任何 IO。
package hub

import (
	"math"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// ---------------------------------------------------------------------------
// 令牌桶限流器
// ---------------------------------------------------------------------------

// rateLimiter 令牌桶：burst 为桶容量（瞬时突发上限），rate 为每秒补充令牌数。
type rateLimiter struct {
	mu     sync.Mutex
	tokens float64
	burst  float64
	rate   float64
	last   time.Time
}

func newRateLimiter(rate, burst int) *rateLimiter {
	if rate <= 0 || burst <= 0 {
		return nil
	}
	return &rateLimiter{
		tokens: float64(burst),
		burst:  float64(burst),
		rate:   float64(rate),
		last:   time.Now(),
	}
}

// Allow 消耗一个令牌；桶空时返回 false。
func (l *rateLimiter) Allow() bool {
	return l.AllowN(1)
}

// AllowN 消耗 n 个令牌；桶内不足时返回 false（不透支）。
// 用于文件上传的字节级限流：n = 报文字节数，rate/burst 语义从"消息数"变为"字节数"。
func (l *rateLimiter) AllowN(n int64) bool {
	if n <= 0 {
		return true
	}
	now := time.Now()
	l.mu.Lock()
	defer l.mu.Unlock()
	l.tokens += now.Sub(l.last).Seconds() * l.rate
	l.last = now
	if l.tokens > l.burst {
		l.tokens = l.burst
	}
	if l.tokens < float64(n) {
		return false
	}
	l.tokens -= float64(n)
	return true
}

// ---------------------------------------------------------------------------
// 客户端真实 IP 解析
// ---------------------------------------------------------------------------

// clientIP 解析连接来源 IP。
//   - trustProxy=false（直连部署）：取 RemoteAddr，天然防 XFF 伪造；
//   - trustProxy=true（Caddy/Nginx 反代后）：优先取 X-Forwarded-For 首段 /
//     X-Real-IP。仅在可信反代之后开启，否则可被任意伪造绕过单 IP 限制。
func clientIP(r *http.Request, trustProxy bool) string {
	if trustProxy {
		for _, h := range []string{"X-Forwarded-For", "X-Real-IP"} {
			v := r.Header.Get(h)
			if v == "" {
				continue
			}
			if i := strings.IndexByte(v, ','); i >= 0 {
				v = v[:i]
			}
			v = strings.TrimSpace(v)
			if ip := net.ParseIP(v); ip != nil {
				return ip.String()
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// ---------------------------------------------------------------------------
// 连接数防护
// ---------------------------------------------------------------------------

// guard 并发连接防护：全局上限 + 单 IP 上限。
type guard struct {
	maxGlobal int
	maxPerIP  int

	mu     sync.Mutex
	global int
	perIP  map[string]int
}

func newGuard(maxGlobal, maxPerIP int) *guard {
	if maxGlobal < 0 {
		maxGlobal = math.MaxInt // 负数 = 关闭全局上限
	}
	if maxPerIP < 0 {
		maxPerIP = math.MaxInt // 负数 = 关闭单 IP 上限
	}
	if maxGlobal == 0 {
		maxGlobal = defaultMaxGlobalConns
	}
	if maxPerIP == 0 {
		maxPerIP = defaultMaxConnPerIP
	}
	return &guard{maxGlobal: maxGlobal, maxPerIP: maxPerIP, perIP: make(map[string]int)}
}

// admit 检查双上限并计数；放行后调用方必须 defer release(ip)。
func (g *guard) admit(ip string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.global >= g.maxGlobal {
		return false
	}
	if g.perIP[ip] >= g.maxPerIP {
		return false
	}
	g.global++
	g.perIP[ip]++
	return true
}

func (g *guard) release(ip string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.global > 0 {
		g.global--
	}
	if g.perIP[ip] <= 1 {
		delete(g.perIP, ip)
	} else {
		g.perIP[ip]--
	}
}

// 观测用：全局当前连接总数。
func (g *guard) globalConns() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.global
}

// 观测用：返回指定 IP 当前连接数。
func (g *guard) ipConns(ip string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.perIP[ip]
}
