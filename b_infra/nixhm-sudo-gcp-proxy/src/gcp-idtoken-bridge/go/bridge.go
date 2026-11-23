// gcp-idtoken-bridge (#1686, Go port #1872): forwards /<service>/<path> to a Cloud Run service
// with a Google ID token.
//
// Same contract as bridge.py: the token comes from the VM metadata server (no key on disk), per
// target audience, cached until SKEW seconds before its exp, and is sent as
// X-Serverless-Authorization so the app's own Authorization header passes through untouched.
// Only services listed in the routes file are reachable (no open proxy). Same listen address,
// routes, per-port listeners, hop-header filtering, redirect following (urllib rules), error
// bodies and timeouts (metadata 5 s, upstream 300 s).
//
// Built on httputil.ReverseProxy (streaming, one goroutine per request) with a direct call to
// the metadata identity endpoint, which is what google.golang.org/api/idtoken does on GCE;
// stdlib only, so the home-manager build needs no vendored modules.
package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"time"
)

const (
	defaultMeta = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity"
	skew        = 120
)

// hop is bridge.py's HOP set: never forwarded in either direction.
var hop = map[string]bool{
	"connection": true, "keep-alive": true, "proxy-authenticate": true, "proxy-authorization": true,
	"te": true, "trailers": true, "transfer-encoding": true, "upgrade": true, "host": true,
	"content-length": true, "x-serverless-authorization": true,
}

// quote is urllib.parse.quote(s, safe=""): everything but A-Za-z0-9_.-~ percent-encoded.
func quote(s string) string {
	var sb strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '.' || c == '-' || c == '~' {
			sb.WriteByte(c)
		} else {
			fmt.Fprintf(&sb, "%%%02X", c)
		}
	}
	return sb.String()
}

// jwtExp is bridge.py's jwt_exp: int(payload["exp"]) of an unverified JWT.
func jwtExp(tok string) (int64, error) {
	parts := strings.Split(tok, ".")
	if len(parts) < 2 {
		return 0, errors.New("list index out of range")
	}
	p := strings.TrimRight(parts[1], "=")
	b, err := base64.RawURLEncoding.DecodeString(p)
	if err != nil {
		return 0, err
	}
	var claims map[string]json.RawMessage
	if err := json.Unmarshal(b, &claims); err != nil {
		return 0, err
	}
	raw, ok := claims["exp"]
	if !ok {
		return 0, errors.New("'exp'")
	}
	var f float64
	if err := json.Unmarshal(raw, &f); err != nil {
		var s string
		if json.Unmarshal(raw, &s) != nil {
			return 0, err
		}
		var n int64
		if _, err := fmt.Sscan(strings.TrimSpace(s), &n); err != nil {
			return 0, err
		}
		return n, nil
	}
	return int64(f), nil
}

type cached struct {
	tok string
	exp int64
}

// Tokens mints and caches ID tokens per audience. Concurrent misses for one audience share
// one metadata call.
type Tokens struct {
	Meta  string
	HTTP  *http.Client
	Now   func() float64
	Fetch func(ctx context.Context, aud string) (string, error) // nil = metadata server

	mu       sync.Mutex
	cache    map[string]cached
	inflight map[string]*call
}

type call struct {
	done chan struct{}
	tok  string
	err  error
}

// NewTokens returns a token source on the metadata server.
func NewTokens(meta string) *Tokens {
	return &Tokens{Meta: meta, HTTP: &http.Client{Timeout: 5 * time.Second},
		Now: func() float64 { return float64(time.Now().UnixNano()) / 1e9 }}
}

func (t *Tokens) fetchMeta(ctx context.Context, aud string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, t.Meta+"?audience="+quote(aud)+"&format=full", nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Metadata-Flavor", "Google")
	resp, err := t.HTTP.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	if err != nil {
		return "", err
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return "", fmt.Errorf("HTTP Error %d: %s", resp.StatusCode, http.StatusText(resp.StatusCode))
	}
	return strings.TrimSpace(string(b)), nil
}

// For is token_for(aud).
func (t *Tokens) For(ctx context.Context, aud string) (string, error) {
	t.mu.Lock()
	if t.cache == nil {
		t.cache, t.inflight = map[string]cached{}, map[string]*call{}
	}
	if c, ok := t.cache[aud]; ok && float64(c.exp-skew) > t.Now() {
		t.mu.Unlock()
		return c.tok, nil
	}
	if c, ok := t.inflight[aud]; ok {
		t.mu.Unlock()
		<-c.done
		return c.tok, c.err
	}
	c := &call{done: make(chan struct{})}
	t.inflight[aud] = c
	t.mu.Unlock()

	fetch := t.Fetch
	if fetch == nil {
		fetch = t.fetchMeta
	}
	tok, err := fetch(context.WithoutCancel(ctx), aud)
	var exp int64
	if err == nil {
		exp, err = jwtExp(tok)
	}
	t.mu.Lock()
	if err == nil {
		t.cache[aud] = cached{tok, exp}
	}
	delete(t.inflight, aud)
	t.mu.Unlock()
	c.tok, c.err = tok, err
	close(c.done)
	return tok, err
}

// Resolve is bridge.py's resolve: "/svc/rest?q" -> (audience, "/rest?q"), on the raw request
// target (query included, so "/svc?q" is not a service).
func Resolve(routes map[string]string, path string) (string, string, bool) {
	parts := strings.SplitN(path, "/", 3)
	if len(parts) < 2 || parts[1] == "" {
		return "", "", false
	}
	aud, ok := routes[parts[1]]
	if !ok {
		return "", "", false
	}
	rest := "/"
	if len(parts) > 2 {
		rest = "/" + parts[2]
	}
	return strings.TrimRight(aud, "/"), rest, true
}

func jsonReply(w http.ResponseWriter, code int, body string) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", fmt.Sprint(len(body)))
	w.WriteHeader(code)
	_, _ = io.WriteString(w, body)
}

// pyDumps is json.dumps({"error": e, "detail": d}) with Python's separators.
func pyDumps(e, d string) string {
	eb, _ := json.Marshal(e)
	db, _ := json.Marshal(d)
	return `{"error": ` + string(eb) + `, "detail": ` + string(db) + `}`
}

func trunc200(s string) string {
	r := []rune(s)
	if len(r) > 200 {
		r = r[:200]
	}
	return string(r)
}

type ctxKey struct{}

type target struct {
	url   *url.URL
	token string
}

// urllibRedirects follows redirects only where urllib's HTTPRedirectHandler does: any of
// 301/302/303/307/308 for GET/HEAD, 301/302/303 for POST (re-sent as GET); everything else is
// handed back to the caller as is.
func urllibRedirects(req *http.Request, via []*http.Request) error {
	if len(via) >= 10 {
		return http.ErrUseLastResponse
	}
	// urllib rebuilds the redirected request without its content headers.
	req.Header.Del("Content-Type")
	req.Header.Del("Content-Length")
	m := via[0].Method
	code := req.Response.StatusCode
	switch {
	case (m == http.MethodGet || m == http.MethodHead) && (code == 301 || code == 302 || code == 303 || code == 307 || code == 308):
		return nil
	case m == http.MethodPost && (code == 301 || code == 302 || code == 303):
		return nil
	}
	return http.ErrUseLastResponse
}

type clientTransport struct{ c *http.Client }

// RoundTrip hands the proxied request to an http.Client so redirects are followed; the
// client refuses a request that still carries the server-side RequestURI.
func (t clientTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.RequestURI = ""
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		// urllib re-sends a followed GET/HEAD without its body; let the client do the same.
		r.GetBody = func() (io.ReadCloser, error) { return http.NoBody, nil }
	}
	return t.c.Do(r)
}

// NewUpstream is the forwarding client: 300 s like urlopen(timeout=300), urllib redirect rules.
func NewUpstream() http.RoundTripper {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = (&net.Dialer{Timeout: 300 * time.Second, KeepAlive: 30 * time.Second}).DialContext
	tr.ResponseHeaderTimeout = 300 * time.Second
	tr.MaxIdleConnsPerHost = 4
	return clientTransport{&http.Client{Transport: tr, CheckRedirect: urllibRedirects}}
}

// Handler serves the router (fixed == "") or one service at the listener root (port mode).
func Handler(routes map[string]string, tokens *Tokens, upstream http.RoundTripper, fixed string) http.Handler {
	rp := &httputil.ReverseProxy{
		Transport: upstream,
		Rewrite: func(pr *httputil.ProxyRequest) {
			t := pr.In.Context().Value(ctxKey{}).(target)
			pr.Out.URL = t.url
			pr.Out.Host = ""
			// bridge.py: {k: v for k, v in self.headers.items() if k.lower() not in HOP}
			// (one value per name, the last one), then the minted token.
			h := http.Header{}
			for k, vs := range pr.In.Header {
				if hop[strings.ToLower(k)] || len(vs) == 0 {
					continue
				}
				h[k] = []string{vs[len(vs)-1]}
			}
			h.Set("X-Serverless-Authorization", "Bearer "+t.token)
			if h.Get("Accept-Encoding") == "" {
				h.Set("Accept-Encoding", "identity") // what http.client sends by default
			}
			if pr.Out.ContentLength != 0 && h.Get("Content-Type") == "" {
				h.Set("Content-Type", "application/x-www-form-urlencoded") // urllib's default for a body
			}
			if h.Get("User-Agent") == "" {
				h["User-Agent"] = []string{""} // no Go default User-Agent
			}
			pr.Out.Header = h
		},
		ModifyResponse: func(r *http.Response) error {
			for k := range r.Header {
				if hop[strings.ToLower(k)] && strings.ToLower(k) != "content-length" {
					delete(r.Header, k)
				}
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			jsonReply(w, 502, pyDumps("upstream", trunc200(err.Error())))
		},
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.RequestURI == "/_health" {
			jsonReply(w, 200, `{"ok":true}`)
			return
		}
		path := r.RequestURI
		if fixed != "" {
			path = "/" + fixed + r.RequestURI
		}
		aud, rest, ok := Resolve(routes, path)
		if !ok {
			jsonReply(w, 404, `{"error":"unknown service"}`)
			return
		}
		tok, err := tokens.For(r.Context(), aud)
		if err != nil {
			jsonReply(w, 502, pyDumps("token mint failed", trunc200(err.Error())))
			return
		}
		u, err := url.Parse(aud + rest)
		if err != nil {
			jsonReply(w, 502, pyDumps("upstream", trunc200(err.Error())))
			return
		}
		r.Header.Del("Upgrade") // bridge.py never upgrades (Upgrade is a HOP header)
		ctx := context.WithValue(r.Context(), ctxKey{}, target{u, tok})
		rp.ServeHTTP(w, r.WithContext(ctx))
	})
}
