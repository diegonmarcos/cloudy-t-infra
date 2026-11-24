// Package dockerapi is an in-process Docker Engine client over the unix socket. The shell
// daemons used curl (a fork per call) because the docker CLI is forbidden in the watchdog:
// it spawns plugin metadata subprocesses that inherit RT priority and can starve the VM.
package dockerapi

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

type Client struct {
	hc *http.Client
}

func New(socket string) *Client {
	return &Client{hc: &http.Client{Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", socket)
		},
		DisableKeepAlives: true,
	}}}
}

func (c *Client) do(ctx context.Context, method, path string, timeout time.Duration) (int, []byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, "http://docker"+path, nil)
	if err != nil {
		return 0, nil, err
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	return resp.StatusCode, b, err
}

// Ping is `curl -sf --max-time 5 /_ping`.
func (c *Client) Ping(ctx context.Context) bool {
	st, _, err := c.do(ctx, "GET", "/_ping", 5*time.Second)
	return err == nil && st >= 200 && st < 300
}

type container struct {
	Names  []string `json:"Names"`
	State  string   `json:"State"`
	Status string   `json:"Status"`
}

// List returns container names (without the leading '/') for a filters JSON string
// ("" for none), `all` including stopped ones.
func (c *Client) List(ctx context.Context, all bool, filters string) ([]string, error) {
	p := "/containers/json?"
	if all {
		p += "all=true&"
	}
	if filters != "" {
		p += "filters=" + urlEscape(filters)
	}
	st, b, err := c.do(ctx, "GET", strings.TrimSuffix(p, "&"), 5*time.Second)
	if err != nil || st != 200 {
		return nil, err
	}
	var cs []container
	if err := json.Unmarshal(b, &cs); err != nil {
		return nil, err
	}
	var out []string
	for _, x := range cs {
		if len(x.Names) > 0 {
			out = append(out, strings.TrimPrefix(x.Names[0], "/"))
		}
	}
	return out, nil
}

// Restart is POST /containers/<name>/restart?t=10 (15 s cap, as the shell).
func (c *Client) Restart(ctx context.Context, name string) error {
	_, _, err := c.do(ctx, "POST", "/containers/"+name+"/restart?t=10", 15*time.Second)
	return err
}

// Post issues a prune-style POST with a 30 s cap.
func (c *Client) Post(ctx context.Context, path string) error {
	_, _, err := c.do(ctx, "POST", path, 30*time.Second)
	return err
}

func urlEscape(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		ch := s[i]
		if ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-' || ch == '_' || ch == '.' {
			b.WriteByte(ch)
		} else {
			b.WriteString("%" + strings.ToUpper(string("0123456789abcdef"[ch>>4])+string("0123456789abcdef"[ch&15])))
		}
	}
	return b.String()
}
