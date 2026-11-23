package main

// Port of ../test_bridge.py (the contract of bridge.py) plus the Go-only guarantees.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func fakeJWT(exp int64) string {
	b := func(v any) string { j, _ := json.Marshal(v); return base64.RawURLEncoding.EncodeToString(j) }
	return b(map[string]any{"alg": "RS256"}) + "." + b(map[string]any{"exp": exp}) + ".sig"
}

type seen struct {
	path string
	h    http.Header
	body string
}

func upstream(t *testing.T, log *[]seen, mu *sync.Mutex) *httptest.Server {
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		*log = append(*log, seen{r.RequestURI, r.Header.Clone(), string(b)})
		mu.Unlock()
		w.Header().Set("Content-Length", "2")
		_, _ = io.WriteString(w, "ok")
	}))
	t.Cleanup(s.Close)
	return s
}

func TestResolve(t *testing.T) {
	r := map[string]string{"a": "https://a.run.app/"}
	if aud, rest, ok := Resolve(r, "/a/x/y?q=1"); !ok || aud != "https://a.run.app" || rest != "/x/y?q=1" {
		t.Fatal(aud, rest, ok)
	}
	if aud, rest, ok := Resolve(r, "/a"); !ok || aud != "https://a.run.app" || rest != "/" {
		t.Fatal(aud, rest, ok)
	}
	for _, p := range []string{"/b/x", "/", "/a?q", ""} {
		if _, _, ok := Resolve(r, p); ok {
			t.Fatalf("%q resolved", p)
		}
	}
}

func TestCacheUntilExpiry(t *testing.T) {
	var calls []string
	now := 100.0
	tk := &Tokens{Now: func() float64 { return now }, Fetch: func(_ context.Context, aud string) (string, error) {
		calls = append(calls, aud)
		return fakeJWT(1000), nil
	}}
	ctx := context.Background()
	if tok, _ := tk.For(ctx, "u"); tok != fakeJWT(1000) {
		t.Fatal(tok)
	}
	now = 500
	tk.For(ctx, "u")
	if len(calls) != 1 {
		t.Fatal(calls)
	}
	now = 900 // inside skew -> refresh
	tk.For(ctx, "u")
	if len(calls) != 2 {
		t.Fatal(calls)
	}
	now = 100
	tk.For(ctx, "other") // per audience
	if len(calls) != 3 {
		t.Fatal(calls)
	}
}

func TestBadTokenIsNotCachedAnd502(t *testing.T) {
	tk := &Tokens{Now: func() float64 { return 1 }, Fetch: func(context.Context, string) (string, error) { return "not-a-jwt", nil }}
	h := Handler(map[string]string{"svc": "http://127.0.0.1:1"}, tk, NewUpstream(), "")
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", "/svc/x", nil))
	if w.Code != 502 || !strings.HasPrefix(w.Body.String(), `{"error": "token mint failed", "detail": `) {
		t.Fatal(w.Code, w.Body.String())
	}
}

func bridgeServer(t *testing.T, routes map[string]string, fixed string) *httptest.Server {
	tk := &Tokens{Now: func() float64 { return float64(time.Now().Unix()) },
		Fetch: func(context.Context, string) (string, error) { return fakeJWT(time.Now().Unix() + 3600), nil }}
	s := httptest.NewServer(Handler(routes, tk, NewUpstream(), fixed))
	t.Cleanup(s.Close)
	return s
}

func TestForwardHeaders(t *testing.T) {
	var log []seen
	var mu sync.Mutex
	up := upstream(t, &log, &mu)
	br := bridgeServer(t, map[string]string{"svc": up.URL}, "")
	req, _ := http.NewRequest("POST", br.URL+"/svc/v1/x", strings.NewReader("hi"))
	req.Header.Set("Authorization", "Bearer app-token")
	req.Header.Set("X-Serverless-Authorization", "evil")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if string(b) != "ok" {
		t.Fatal(string(b))
	}
	last := log[len(log)-1]
	if last.path != "/v1/x" || last.body != "hi" || last.h.Get("Authorization") != "Bearer app-token" {
		t.Fatalf("%+v", last)
	}
	if xs := last.h.Get("X-Serverless-Authorization"); !strings.HasPrefix(xs, "Bearer ey") || xs == "evil" {
		t.Fatal(xs)
	}
	r, _ := http.Get(br.URL + "/nope/x")
	if r.StatusCode != 404 {
		t.Fatal(r.StatusCode)
	}
}

func TestPortModePrefixesService(t *testing.T) {
	var log []seen
	var mu sync.Mutex
	up := upstream(t, &log, &mu)
	br := bridgeServer(t, map[string]string{"svc": up.URL}, "svc")
	r, err := http.Get(br.URL + "/v2/check?x=1")
	if err != nil || r.StatusCode != 200 {
		t.Fatal(err, r)
	}
	if log[len(log)-1].path != "/v2/check?x=1" {
		t.Fatal(log[len(log)-1].path)
	}
	h, _ := http.Get(br.URL + "/_health")
	if h.StatusCode != 200 {
		t.Fatal(h.StatusCode)
	}
}

func TestStampedJSONIsTolerated(t *testing.T) {
	d := t.TempDir()
	_ = os.WriteFile(filepath.Join(d, "r.json"), []byte(`{"_generated":{"w":"x"},"description":"d","svc":"http://127.0.0.1:1"}`), 0o600)
	_ = os.WriteFile(filepath.Join(d, "p.json"), []byte(`{"_generated":{"w":"x"},"description":"d","18999":"svc"}`), 0o600)
	routes, err := loadRoutes(filepath.Join(d, "r.json"))
	if err != nil || len(routes) != 1 || routes["svc"] == "" {
		t.Fatal(routes, err)
	}
	ports, err := loadPorts(filepath.Join(d, "p.json"), routes)
	if err != nil || len(ports) != 1 || ports["18999"] != "svc" {
		t.Fatal(ports, err)
	}
	_ = os.WriteFile(filepath.Join(d, "bad.json"), []byte(`{"18999":"ghost"}`), 0o600)
	if _, err := loadPorts(filepath.Join(d, "bad.json"), routes); err == nil || !strings.Contains(err.Error(), "unknown service ghost") {
		t.Fatal(err)
	}
	if p, err := loadPorts(filepath.Join(d, "absent.json"), routes); err != nil || len(p) != 0 {
		t.Fatal(p, err)
	}
}

// Go-only: concurrent first requests for one audience make one metadata call.
func TestConcurrentMintsShareOneCall(t *testing.T) {
	var n atomic.Int64
	tk := &Tokens{Now: func() float64 { return 1 }, Fetch: func(context.Context, string) (string, error) {
		n.Add(1)
		time.Sleep(100 * time.Millisecond)
		return fakeJWT(10000), nil
	}}
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = tk.For(context.Background(), "aud") }()
	}
	wg.Wait()
	if n.Load() != 1 {
		t.Fatalf("metadata calls %d", n.Load())
	}
}

func TestMetadataRequestShape(t *testing.T) {
	var got *http.Request
	meta := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Clone(context.Background())
		_, _ = io.WriteString(w, fakeJWT(time.Now().Unix()+3600)+"\n")
	}))
	defer meta.Close()
	tk := NewTokens(meta.URL + "/identity")
	tok, err := tk.For(context.Background(), "https://svc-x.a.run.app")
	if err != nil || strings.HasSuffix(tok, "\n") {
		t.Fatal(err, tok)
	}
	if got.Header.Get("Metadata-Flavor") != "Google" || got.URL.RawQuery != "audience=https%3A%2F%2Fsvc-x.a.run.app&format=full" {
		t.Fatal(got.Header, got.URL.RawQuery)
	}
}

func TestRedirectsFollowLikeUrllib(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/r302":
			http.Redirect(w, r, "/final", 302)
		case "/r307":
			http.Redirect(w, r, "/final", 307)
		default:
			fmt.Fprintf(w, "final %s", r.Method)
		}
	}))
	defer up.Close()
	br := bridgeServer(t, map[string]string{"svc": up.URL}, "")
	cl := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	cases := []struct{ method, path, want string }{
		{"GET", "/svc/r302", "200 final GET"},
		{"GET", "/svc/r307", "200 final GET"},
		{"POST", "/svc/r302", "200 final GET"},
		{"POST", "/svc/r307", "307 "},
		{"PUT", "/svc/r302", "302 "},
	}
	for _, c := range cases {
		req, _ := http.NewRequest(c.method, br.URL+c.path, strings.NewReader("b"))
		r, err := cl.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(r.Body)
		r.Body.Close()
		got := fmt.Sprintf("%d %s", r.StatusCode, b)
		if !strings.HasPrefix(got, c.want) {
			t.Errorf("%s %s: %q, want %q", c.method, c.path, got, c.want)
		}
	}
}
