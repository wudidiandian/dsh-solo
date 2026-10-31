package monitor

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"dsh-solo/server/internal/hub"
)

const testPassword = "test-only-password-123456"

func console(t *testing.T) *Server {
	t.Helper()
	s, err := New(hub.New(hub.Config{}), "admin", testPassword)
	if err != nil {
		t.Fatal(err)
	}
	return s
}
func call(s *Server, method, path, body string, cookie *http.Cookie, origin string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	if cookie != nil {
		r.AddCookie(cookie)
	}
	if origin != "" {
		r.Header.Set("Origin", origin)
	}
	w := httptest.NewRecorder()
	s.ServeHTTP(w, r)
	return w
}
func login(s *Server) *httptest.ResponseRecorder {
	return call(s, "POST", "/api/login", `{"username":"admin","password":"`+testPassword+`"}`, nil, "")
}
func TestAuthenticationExpiryLogoutAndOrigin(t *testing.T) {
	s := console(t)
	if call(s, "GET", "/api/snapshot", "", nil, "").Code != 401 {
		t.Fatal("unauthenticated data access")
	}
	if call(s, "POST", "/api/login", `{}`, nil, "https://untrusted.example").Code != 403 {
		t.Fatal("cross origin login accepted")
	}
	if call(s, "POST", "/api/login", `{"username":"admin","password":"wrong"}`, nil, "").Code != 401 {
		t.Fatal("wrong password accepted")
	}
	response := login(s)
	if response.Code != 200 {
		t.Fatal(response.Body.String())
	}
	cookie := response.Result().Cookies()[0]
	if !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode {
		t.Fatal("insecure session cookie")
	}
	data := call(s, "GET", "/api/snapshot", "", cookie, "")
	if data.Code != 200 || !strings.Contains(data.Body.String(), `"history"`) {
		t.Fatal("authenticated snapshot missing")
	}
	if strings.Contains(data.Body.String(), testPassword) || strings.Contains(data.Body.String(), cookie.Value) {
		t.Fatal("credentials in snapshot")
	}
	if call(s, "POST", "/api/logout", "", cookie, "https://untrusted.example").Code != 403 {
		t.Fatal("cross origin logout accepted")
	}
	if call(s, "POST", "/api/logout", "", cookie, "").Code != 200 {
		t.Fatal("logout failed")
	}
	if call(s, "GET", "/api/snapshot", "", cookie, "").Code != 401 {
		t.Fatal("logout did not revoke session")
	}
	second := login(s).Result().Cookies()[0]
	s.sessions[second.Value] = time.Now().Add(-time.Second)
	if call(s, "GET", "/api/snapshot", "", second, "").Code != 401 {
		t.Fatal("expired cookie accepted")
	}
}
func TestLoginThrottleAssetsAndBoundedHistory(t *testing.T) {
	s := console(t)
	for i := 0; i < 5; i++ {
		if call(s, "POST", "/api/login", `{"username":"admin","password":"wrong"}`, nil, "").Code != 401 {
			t.Fatal("unexpected throttle")
		}
	}
	if login(s).Code != 429 {
		t.Fatal("missing login throttle")
	}
	for _, path := range []string{"/", "/app.js", "/style.css"} {
		w := call(s, "GET", path, "", nil, "")
		if w.Code != 200 {
			t.Fatalf("asset %s unavailable", path)
		}
		if w.Header().Get("Content-Security-Policy") == "" || w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("missing page policy")
		}
	}
	if call(s, "GET", "/unknown", "", nil, "").Code != 404 {
		t.Fatal("unknown route accepted")
	}
	if call(s, "DELETE", "/api/snapshot", "", nil, "").Code != 405 {
		t.Fatal("write method accepted")
	}
	s.history = make([]Point, maxHistory)
	s.sample()
	if len(s.history) != maxHistory {
		t.Fatal("history grew beyond bound")
	}
	s.failures = 0
	cookie := login(s).Result().Cookies()[0]
	response := call(s, "GET", "/api/snapshot?since=9999999999999", "", cookie, "")
	var decoded struct {
		History []Point `json:"history"`
	}
	if json.Unmarshal(response.Body.Bytes(), &decoded) != nil || len(decoded.History) != 0 {
		t.Fatal("incremental sampling cursor ignored")
	}
	if _, err := New(hub.New(hub.Config{}), "admin", "short"); err == nil {
		t.Fatal("weak password accepted")
	}
}
