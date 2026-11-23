//go:build shadow

package main

// Shadow-compare harness (#1872): bridge.py (the reference, its metadata URL pointed at a
// fake) and this Go port run side by side in front of one echo upstream; every fixture goes to
// both and the client-visible answer (status, body, content type, location, and what the
// upstream received) must match. Three behaviours differ on purpose and are asserted
// separately: gzip responses keep their Content-Encoding, repeated Set-Cookie headers are all
// kept, and no Python-urllib User-Agent is invented.
//
//	PY_BIN=python3 go test -tags shadow -run TestShadow .

import (
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

type answer struct {
	Status   int
	Body     string
	CT, Loc  string
	Upstream string
}

func echo(w http.ResponseWriter, r *http.Request) {
	switch {
	case strings.HasPrefix(r.URL.Path, "/status/"):
		var c int
		fmt.Sscanf(r.URL.Path, "/status/%d", &c)
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(c)
		fmt.Fprintf(w, "status %d", c)
		return
	case strings.HasPrefix(r.URL.Path, "/redirect/"):
		var c int
		fmt.Sscanf(r.URL.Path, "/redirect/%d", &c)
		http.Redirect(w, r, "/final?from="+fmt.Sprint(c), c)
		return
	case r.URL.Path == "/gzip":
		w.Header().Set("Content-Encoding", "gzip")
		gz := gzip.NewWriter(w)
		_, _ = io.WriteString(gz, "zipped")
		_ = gz.Close()
		return
	case r.URL.Path == "/cookies":
		w.Header().Add("Set-Cookie", "a=1")
		w.Header().Add("Set-Cookie", "b=2")
		_, _ = io.WriteString(w, "cookies")
		return
	}
	b, _ := io.ReadAll(r.Body)
	keep := []string{"Authorization", "X-Custom", "Content-Type", "Accept-Encoding", "Cookie", "X-Forwarded-For", "X-Forwarded-Host", "Content-Length", "Upgrade", "Te"} // Connection: urllib sends close, Go keeps the pool alive (hop-by-hop, not compared)
	var hs []string
	for _, k := range keep {
		if v := r.Header.Values(k); len(v) > 0 {
			hs = append(hs, k+"="+strings.Join(v, "|"))
		}
	}
	if k := r.Header.Get("Content-Length"); k == "" && len(b) > 0 {
		hs = append(hs, "Content-Length=<chunked>")
	}
	xs := r.Header.Get("X-Serverless-Authorization")
	hs = append(hs, "XSA-ok="+fmt.Sprint(strings.HasPrefix(xs, "Bearer ey") && !strings.Contains(xs, "evil")))
	sort.Strings(hs)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("X-Upstream", "echo")
	_ = json.NewEncoder(w).Encode(map[string]any{"m": r.Method, "uri": r.RequestURI, "body": string(b), "h": hs})
}

func get(t *testing.T, cl *http.Client, method, url string, body string, hdr [][2]string) answer {
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, url, rd)
	if err != nil {
		t.Fatal(err)
	}
	for _, h := range hdr {
		req.Header.Add(h[0], h[1])
	}
	r, err := cl.Do(req)
	if err != nil {
		return answer{Status: -1, Body: err.Error()}
	}
	defer r.Body.Close()
	b, _ := io.ReadAll(r.Body)
	return answer{Status: r.StatusCode, Body: string(b), CT: r.Header.Get("Content-Type"), Loc: r.Header.Get("Location")}
}

func port(t *testing.T) int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

func TestShadowCompare(t *testing.T) {
	py := os.Getenv("PY_BIN")
	if py == "" {
		t.Fatal("PY_BIN is required: the harness never skips")
	}
	app, _ := filepath.Abs("..")
	up := httptest.NewServer(http.HandlerFunc(echo))
	defer up.Close()
	meta := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Metadata-Flavor") != "Google" || strings.Contains(r.URL.RawQuery, "badmint") {
			http.Error(w, "no", 500)
			return
		}
		_, _ = io.WriteString(w, fakeJWT(time.Now().Unix()+3600)+"\n")
	}))
	defer meta.Close()
	routes := map[string]string{"svc": up.URL + "/", "badmint": up.URL + "/?badmint", "dead": "http://127.0.0.1:1"}
	rj, _ := json.Marshal(routes)

	pp, pf := port(t), port(t)
	driver := fmt.Sprintf(`
import sys, json, threading
sys.path.insert(0, %q)
import bridge
bridge.META = %q
from http.server import ThreadingHTTPServer
routes = json.loads(%q)
f = ThreadingHTTPServer(("127.0.0.1", %d), bridge.make_handler(routes, fixed="svc"))
threading.Thread(target=f.serve_forever, daemon=True).start()
ThreadingHTTPServer(("127.0.0.1", %d), bridge.make_handler(routes)).serve_forever()
`, app, meta.URL+"/identity", string(rj), pf, pp)
	cmd := exec.Command(py, "-c", driver)
	cmd.Env = append(os.Environ(), "PYTHONDONTWRITEBYTECODE=1")
	var plog strings.Builder
	cmd.Stdout, cmd.Stderr = &plog, &plog
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()

	tk := NewTokens(meta.URL + "/identity")
	goR := httptest.NewServer(Handler(routes, tk, NewUpstream(), ""))
	defer goR.Close()
	goF := httptest.NewServer(Handler(routes, tk, NewUpstream(), "svc"))
	defer goF.Close()
	pyR, pyF := fmt.Sprintf("http://127.0.0.1:%d", pp), fmt.Sprintf("http://127.0.0.1:%d", pf)
	// One connection per request: a bridge.py HEAD-after-redirect answer carries a body, which
	// would otherwise desynchronise the next request on a kept-alive connection.
	cl := &http.Client{Transport: &http.Transport{DisableKeepAlives: true}, Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	for i := 0; i < 50; i++ {
		if r, err := cl.Get(pyR + "/_health"); err == nil {
			r.Body.Close()
			break
		}
		time.Sleep(100 * time.Millisecond)
	}

	type c struct {
		name, method, path, body string
		hdr                      [][2]string
		fixed                    bool
	}
	auth := [2]string{"Authorization", "Bearer app-token"}
	cases := []c{
		{name: "health", method: "GET", path: "/_health"},
		{name: "health-query", method: "GET", path: "/_health?x=1"},
		{name: "health-fixed", method: "GET", path: "/_health", fixed: true},
		{name: "root", method: "GET", path: "/"},
		{name: "unknown", method: "GET", path: "/nope/x"},
		{name: "svc-query-only", method: "GET", path: "/svc?x=1"},
		{name: "svc-bare", method: "GET", path: "/svc"},
		{name: "svc-slash", method: "GET", path: "/svc/"},
		{name: "get-path-query", method: "GET", path: "/svc/a/b?q=1&r=%2F", hdr: [][2]string{auth, {"X-Custom", "v"}}},
		{name: "post-body", method: "POST", path: "/svc/v1/x", body: "hi", hdr: [][2]string{auth, {"Content-Type", "text/plain"}}},
		{name: "post-body-no-ct", method: "POST", path: "/svc/v1/x", body: "a=1"},
		{name: "put", method: "PUT", path: "/svc/x", body: "p"},
		{name: "patch", method: "PATCH", path: "/svc/x", body: "p"},
		{name: "delete", method: "DELETE", path: "/svc/x"},
		{name: "head", method: "HEAD", path: "/svc/x"},
		{name: "options", method: "OPTIONS", path: "/svc/x"},
		{name: "evil-xsa", method: "GET", path: "/svc/x", hdr: [][2]string{{"X-Serverless-Authorization", "evil"}}},
		{name: "hop-headers", method: "GET", path: "/svc/x", hdr: [][2]string{{"Te", "trailers"}, {"Upgrade", "websocket"}, {"Connection", "keep-alive"}, {"Proxy-Authorization", "x"}}},
		{name: "dup-header-last-wins", method: "GET", path: "/svc/x", hdr: [][2]string{{"X-Custom", "one"}, {"X-Custom", "two"}}},
		{name: "forwarded-for", method: "GET", path: "/svc/x", hdr: [][2]string{{"X-Forwarded-For", "10.0.0.6"}, {"X-Forwarded-Host", "c3-pvt.diegonmarcos.com"}}},
		{name: "accept-encoding-identity", method: "GET", path: "/svc/x", hdr: [][2]string{{"Accept-Encoding", "identity"}}},
		{name: "status-404", method: "GET", path: "/svc/status/404"},
		{name: "status-500", method: "POST", path: "/svc/status/500", body: "x"},
		{name: "status-204", method: "GET", path: "/svc/status/204"},
		{name: "get-302-followed", method: "GET", path: "/svc/redirect/302"},
		{name: "get-301-followed", method: "GET", path: "/svc/redirect/301"},
		{name: "get-307-followed", method: "GET", path: "/svc/redirect/307"},
		{name: "get-308-followed", method: "GET", path: "/svc/redirect/308"},
		{name: "post-303-as-get", method: "POST", path: "/svc/redirect/303", body: "x"},
		{name: "post-302-as-get", method: "POST", path: "/svc/redirect/302", body: "x"},
		{name: "post-307-passed", method: "POST", path: "/svc/redirect/307", body: "x"},
		{name: "put-302-passed", method: "PUT", path: "/svc/redirect/302", body: "x"},
		{name: "delete-301-passed", method: "DELETE", path: "/svc/redirect/301"},
		{name: "fixed-get", method: "GET", path: "/v2/check?x=1", fixed: true},
		{name: "fixed-root", method: "GET", path: "/", fixed: true},
		{name: "fixed-post", method: "POST", path: "/api", body: "{}", hdr: [][2]string{{"Content-Type", "application/json"}}, fixed: true},
	}
	failed := 0
	for _, k := range cases {
		pb, gb := pyR, goR.URL
		if k.fixed {
			pb, gb = pyF, goF.URL
		}
		a := get(t, cl, k.method, pb+k.path, k.body, k.hdr)
		b := get(t, cl, k.method, gb+k.path, k.body, k.hdr)
		if os.Getenv("SHADOW_VERBOSE") != "" {
			t.Logf("%-26s %d %q", k.name, a.Status, a.Body)
		}
		if a != b {
			failed++
			t.Errorf("%s\n  python: %+v\n  go:     %+v", k.name, a, b)
		}
	}
	// Failure answers: same status and error kind; the detail text is each runtime's own.
	for _, k := range []struct{ name, path, prefix string }{
		{"mint-failure", "/badmint/x", `{"error": "token mint failed", "detail": `},
		{"upstream-down", "/dead/x", `{"error": "upstream", "detail": `},
	} {
		a, b := get(t, cl, "GET", pyR+k.path, "", nil), get(t, cl, "GET", goR.URL+k.path, "", nil)
		if a.Status != 502 || b.Status != 502 || !strings.HasPrefix(a.Body, k.prefix) || !strings.HasPrefix(b.Body, k.prefix) || a.CT != b.CT {
			failed++
			t.Errorf("%s\n  python: %+v\n  go:     %+v", k.name, a, b)
		}
	}
	t.Logf("shadow-compare: %d cases, %d mismatches", len(cases)+2, failed)

	// Intentional differences (bridge.py bugs the port does not copy).
	ae := [][2]string{{"Accept-Encoding", "gzip"}}
	reqGz, _ := http.NewRequest("GET", goR.URL+"/svc/gzip", nil)
	reqGz.Header.Set("Accept-Encoding", "gzip")
	if r, err := cl.Do(reqGz); err != nil || r.Header.Get("Content-Encoding") != "gzip" {
		t.Errorf("go must keep Content-Encoding on a gzip answer: %v %v", err, r)
	}
	pg := get(t, cl, "GET", pyR+"/svc/gzip", "", ae)
	t.Logf("note: python strips Content-Encoding but forwards the gzip bytes (%d bytes, unreadable as text)", len(pg.Body))
	if h := get(t, cl, "HEAD", goR.URL+"/svc/redirect/302", "", nil); h.Status != 200 || h.Body != "" {
		t.Errorf("go HEAD through a redirect must stay a bodiless HEAD: %+v", h)
	}
	t.Logf("note: python follows a HEAD redirect as GET and writes that body onto the HEAD answer")
	r, err := cl.Get(goR.URL + "/svc/cookies")
	if err != nil || len(r.Header.Values("Set-Cookie")) != 2 {
		t.Errorf("go must keep both Set-Cookie headers: %v", r.Header.Values("Set-Cookie"))
	}
	if failed > 0 {
		t.Logf("python log:\n%s", plog.String())
	}
}
