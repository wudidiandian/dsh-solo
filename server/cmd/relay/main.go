// dsh-solo-relay：VPS 极轻中转服务（设计文档 §5）。
//
// 端点：
//   GET /ws       —— agent / mobile WebSocket 接入（首报文 hello.* 鉴权配对）
//   GET /healthz  —— 健康检查
//
// 部署：
//   开发:   go run ./cmd/relay
//   生产:   配合 Caddy/Nginx 做 WSS 反代；或直接 -tls-cert/-tls-key
package main

import (
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"dsh-solo/server/internal/hub"
	"dsh-solo/server/internal/push"
)

func main() {
	var (
		addr         = flag.String("addr", ":8787", "HTTP 监听地址（Caddy 反代部署时建议 127.0.0.1:8787）")
		tlsCert      = flag.String("tls-cert", "", "TLS 证书路径（留空则以纯 WS 运行，仅限本机开发）")
		tlsKey       = flag.String("tls-key", "", "TLS 私钥路径")
		barkURL      = flag.String("bark-url", "", "Bark 推送地址，如 https://api.day.app/<key>（留空用日志推送）")
		ringCapacity = flag.Int("ring-capacity", 1000, "每会话事件环形缓冲容量")

		maxRooms       = flag.Int("max-rooms", 256, "房间总数上限（防垃圾 token 刷房间；负数不限）")
		maxConnPerIP   = flag.Int("max-conn-per-ip", 8, "单 IP 并发连接上限（负数不限）")
		maxGlobalConns = flag.Int("max-global-conns", 512, "全局并发连接上限（负数不限）")
		msgRate        = flag.Int("msg-rate", 80, "单连接每秒消息数上限（令牌桶速率；负数不限流）")
		msgBurst       = flag.Int("msg-burst", 160, "单连接消息突发桶容量")
		trustProxy     = flag.Bool("trust-proxy", false, "从 X-Forwarded-For/X-Real-IP 解析真实 IP（仅在可信反代后开启）")

		uploadRate  = flag.Int("upload-rate", 1<<20, "单连接上传字节速率（字节/秒，默认 1MB/s；负数不限）")
		uploadBurst = flag.Int("upload-burst", 4<<20, "上传字节突发桶容量（默认 4MB；负数不限）")
		maxUpload   = flag.Int64("max-upload", 10<<20, "单文件上传大小上限（字节，默认 10MB；负数不限）")
	)
	flag.Parse()

	logger := log.New(os.Stdout, "[relay] ", log.LstdFlags|log.Lmicroseconds)

	var pusher push.Adapter
	if *barkURL != "" {
		pusher = push.NewBarkAdapter(*barkURL)
		logger.Printf("push channel: bark -> %s", *barkURL)
	} else {
		pusher = push.NewLogAdapter()
		logger.Printf("push channel: log (bark-url 未配置)")
	}

	h := hub.New(hub.Config{
		PushAdapter:    pusher,
		RingCapacity:   *ringCapacity,
		Logger:         logger,
		MaxRooms:       *maxRooms,
		MaxConnPerIP:   *maxConnPerIP,
		MaxGlobalConns: *maxGlobalConns,
		MsgRate:        *msgRate,
		MsgBurst:       *msgBurst,
		TrustProxy:     *trustProxy,
		UploadRate:     *uploadRate,
		UploadBurst:    *uploadBurst,
		MaxUploadSize:  *maxUpload,
	})

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", h.HandleWS)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	srv := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
		<-sig
		logger.Printf("shutting down...")
		_ = srv.Close()
	}()

	logger.Printf("dsh-solo-relay listening on %s (ws=%v)", *addr, *tlsCert == "")
	logger.Printf("guard: max-rooms=%d max-conn-per-ip=%d max-global-conns=%d msg-rate=%d/s burst=%d trust-proxy=%v",
		*maxRooms, *maxConnPerIP, *maxGlobalConns, *msgRate, *msgBurst, *trustProxy)
	logger.Printf("upload: rate=%d B/s burst=%d B max-file=%d B", *uploadRate, *uploadBurst, *maxUpload)
	var err error
	if *tlsCert != "" && *tlsKey != "" {
		err = srv.ListenAndServeTLS(*tlsCert, *tlsKey)
	} else {
		err = srv.ListenAndServe()
	}
	if err != nil && err != http.ErrServerClosed {
		logger.Fatalf("server error: %v", err)
	}
}
