// Package monitor serves a separate, authenticated, read-only relay console.
package monitor

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"dsh-solo/server/internal/hub"
)

//go:embed web/*
var assets embed.FS

const sampleInterval = 5 * time.Second
const maxHistory = 720 // one hour, bounded, process-local
const cookieName = "dsh_monitor_session"

type Point struct {
	At          time.Time `json:"at"`
	Apps        int       `json:"apps"`
	Agents      int       `json:"agents"`
	PairedRooms int       `json:"pairedRooms"`
	Connections int       `json:"connections"`
	BytesIn     uint64    `json:"bytesIn"`
	BytesOut    uint64    `json:"bytesOut"`
	MessagesIn  uint64    `json:"messagesIn"`
	MessagesOut uint64    `json:"messagesOut"`
	HeapBytes   uint64    `json:"heapBytes"`
	RSSBytes    *uint64   `json:"rssBytes"`
	ProcessCPU  *float64  `json:"processCpu"`
}
type Server struct {
	hub                *hub.Hub
	NodeName           string
	started            time.Time
	username, password [32]byte
	mu                 sync.Mutex
	history            []Point
	resources          Resources
	previous           platformReading
	previousAt         time.Time
	authMu             sync.Mutex
	sessions           map[string]time.Time
	failures           int
	failureWindow      time.Time
	static             http.Handler
}

func New(h *hub.Hub, username, password string) (*Server, error) {
	if strings.TrimSpace(username) == "" || len(password) < 16 {
		return nil, errors.New("monitor username is required and password must be at least 16 bytes")
	}
	web, err := fs.Sub(assets, "web")
	if err != nil {
		return nil, err
	}
	s := &Server{hub: h, started: time.Now().UTC(), username: sha256.Sum256([]byte(username)), password: sha256.Sum256([]byte(password)), sessions: make(map[string]time.Time), static: http.FileServer(http.FS(web))}
	s.sample()
	return s, nil
}
func (s *Server) Run(ctx context.Context) {
	ticker := time.NewTicker(sampleInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.sample()
		}
	}
}
func (s *Server) sample() {
	reading := readResources()
	stats := s.hub.MonitorSnapshot(false)
	now := time.Now().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.previousAt.IsZero() {
		elapsed := now.Sub(s.previousAt).Seconds()
		if reading.cpuAvailable && s.previous.cpuAvailable && elapsed > 0 {
			v := (reading.cpuSeconds - s.previous.cpuSeconds) / elapsed * 100
			if v >= 0 {
				reading.resources.ProcessCPUPercent = &v
			}
		}
		if reading.cpuTotal > s.previous.cpuTotal && reading.cpuIdle >= s.previous.cpuIdle {
			v := 100 * (1 - float64(reading.cpuIdle-s.previous.cpuIdle)/float64(reading.cpuTotal-s.previous.cpuTotal))
			if v >= 0 && v <= 100 {
				reading.resources.SystemCPUPercent = &v
			}
		}
	}
	s.resources = reading.resources
	s.previous = reading
	s.previousAt = now
	point := Point{At: now, Apps: stats.OnlineApps, Agents: stats.OnlineAgents, PairedRooms: stats.PairedRooms, Connections: stats.ReservedConnections, BytesIn: stats.Counters.BytesIn, BytesOut: stats.Counters.BytesOut, MessagesIn: stats.Counters.MessagesIn, MessagesOut: stats.Counters.MessagesOut, HeapBytes: reading.resources.HeapBytes, RSSBytes: reading.resources.RSSBytes, ProcessCPU: reading.resources.ProcessCPUPercent}
	if len(s.history) >= maxHistory {
		copy(s.history, s.history[1:])
		s.history = s.history[:maxHistory-1]
	}
	s.history = append(s.history, point)
}
func jsonReply(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
func sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	parsed, err := url.Parse(origin)
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	return err == nil && parsed.Scheme == scheme && parsed.Host == r.Host && parsed.Path == "" && parsed.RawQuery == "" && parsed.Fragment == ""
}
func (s *Server) authenticated(r *http.Request) bool {
	cookie, err := r.Cookie(cookieName)
	if err != nil {
		return false
	}
	s.authMu.Lock()
	defer s.authMu.Unlock()
	expiry, ok := s.sessions[cookie.Value]
	if ok && !time.Now().Before(expiry) {
		delete(s.sessions, cookie.Value)
		return false
	}
	return ok
}
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
	switch r.URL.Path {
	case "/api/login":
		s.login(w, r)
	case "/api/logout":
		if r.Method != http.MethodPost {
			w.WriteHeader(405)
			return
		}
		if !sameOrigin(r) {
			w.WriteHeader(403)
			return
		}
		if cookie, err := r.Cookie(cookieName); err == nil {
			s.authMu.Lock()
			delete(s.sessions, cookie.Value)
			s.authMu.Unlock()
		}
		http.SetCookie(w, &http.Cookie{Name: cookieName, Value: "", Path: "/", MaxAge: -1, HttpOnly: true, SameSite: http.SameSiteStrictMode, Secure: r.TLS != nil})
		jsonReply(w, 200, map[string]bool{"ok": true})
	case "/api/snapshot":
		if r.Method != http.MethodGet {
			w.WriteHeader(405)
			return
		}
		if !s.authenticated(r) {
			jsonReply(w, 401, map[string]string{"error": "请先登录"})
			return
		}
		since, _ := strconv.ParseInt(r.URL.Query().Get("since"), 10, 64)
		s.mu.Lock()
		resources := s.resources
		history := make([]Point, 0, len(s.history))
		for _, p := range s.history {
			if p.At.UnixMilli() > since {
				history = append(history, p)
			}
		}
		s.mu.Unlock()
		jsonReply(w, 200, struct {
			NodeName      string              `json:"nodeName"`
			Now           time.Time           `json:"now"`
			StartedAt     time.Time           `json:"startedAt"`
			SampleSeconds int                 `json:"sampleSeconds"`
			Stats         hub.MonitorSnapshot `json:"stats"`
			Resources     Resources           `json:"resources"`
			History       []Point             `json:"history"`
		}{s.NodeName, time.Now().UTC(), s.started, 5, s.hub.MonitorSnapshot(true), resources, history})
	default:
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.WriteHeader(405)
			return
		}
		if r.URL.Path != "/" && r.URL.Path != "/app.js" && r.URL.Path != "/style.css" {
			http.NotFound(w, r)
			return
		}
		s.static.ServeHTTP(w, r)
	}
}
func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(405)
		return
	}
	if !sameOrigin(r) {
		w.WriteHeader(403)
		return
	}
	now := time.Now()
	s.authMu.Lock()
	if now.Sub(s.failureWindow) >= time.Minute {
		s.failureWindow = now
		s.failures = 0
	}
	if s.failures >= 5 {
		s.authMu.Unlock()
		w.Header().Set("Retry-After", "60")
		jsonReply(w, 429, map[string]string{"error": "尝试过于频繁，请稍后重试"})
		return
	}
	s.failures++
	s.authMu.Unlock()
	var input struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	if decoder.Decode(&input) != nil {
		jsonReply(w, 400, map[string]string{"error": "无效请求"})
		return
	}
	u, p := sha256.Sum256([]byte(input.Username)), sha256.Sum256([]byte(input.Password))
	if subtle.ConstantTimeCompare(u[:], s.username[:])&subtle.ConstantTimeCompare(p[:], s.password[:]) != 1 {
		jsonReply(w, 401, map[string]string{"error": "用户名或密码错误"})
		return
	}
	var random [32]byte
	if _, err := rand.Read(random[:]); err != nil {
		jsonReply(w, 500, map[string]string{"error": "无法创建登录会话"})
		return
	}
	token := hex.EncodeToString(random[:])
	expiry := now.Add(8 * time.Hour)
	s.authMu.Lock()
	for id, until := range s.sessions {
		if !now.Before(until) {
			delete(s.sessions, id)
		}
	}
	if len(s.sessions) >= 128 {
		s.authMu.Unlock()
		jsonReply(w, 503, map[string]string{"error": "登录会话已达上限"})
		return
	}
	s.sessions[token] = expiry
	s.authMu.Unlock()
	http.SetCookie(w, &http.Cookie{Name: cookieName, Value: token, Path: "/", Expires: expiry, MaxAge: 8 * 3600, HttpOnly: true, SameSite: http.SameSiteStrictMode, Secure: r.TLS != nil})
	jsonReply(w, 200, map[string]bool{"ok": true})
}
