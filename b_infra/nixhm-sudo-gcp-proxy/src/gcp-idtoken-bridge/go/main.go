package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode"
)

func env(k, def string) string {
	if v, ok := os.LookupEnv(k); ok {
		return v
	}
	return def
}

// loadRoutes keeps only "<name>": "http(s)://..." pairs whose name does not start with "_"
// (the build stamps _generated/description meta keys into the JSON).
func loadRoutes(path string) (map[string]string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var raw map[string]any
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, err
	}
	out := map[string]string{}
	for k, v := range raw {
		s, ok := v.(string)
		if ok && (strings.HasPrefix(s, "http://") || strings.HasPrefix(s, "https://")) && !strings.HasPrefix(k, "_") {
			out[k] = s
		}
	}
	return out, nil
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if !unicode.IsDigit(r) {
			return false
		}
	}
	return true
}

// loadPorts reads ports.json ({"<port>": "<service>"}); only digit keys with a string value
// are listeners, and every one must name a known route.
func loadPorts(path string, routes map[string]string) (map[string]string, error) {
	out := map[string]string{}
	if path == "" {
		return out, nil
	}
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	var raw map[string]any
	if err := json.Unmarshal(b, &raw); err != nil {
		return nil, err
	}
	for p, v := range raw {
		svc, ok := v.(string)
		if !isDigits(p) || !ok {
			continue
		}
		if _, known := routes[svc]; !known {
			return nil, fmt.Errorf("ports.json names unknown service %s", svc)
		}
		out[p] = svc
	}
	return out, nil
}

func serve(addr string, h http.Handler) error {
	srv := &http.Server{Addr: addr, Handler: h, ReadHeaderTimeout: 30 * time.Second, IdleTimeout: 120 * time.Second}
	return srv.ListenAndServe()
}

func main() {
	if len(os.Args) == 3 && os.Args[1] == "-healthcheck" {
		r, err := (&http.Client{Timeout: 5 * time.Second}).Get(os.Args[2])
		if err != nil || r.StatusCode != 200 {
			os.Exit(1)
		}
		os.Exit(0)
	}
	routes, err := loadRoutes(env("BRIDGE_ROUTES", "/etc/gcp-idtoken-bridge/routes.json"))
	if err != nil {
		log.Fatal(err)
	}
	addr := env("BRIDGE_LISTEN", "10.0.0.1")
	port := env("BRIDGE_PORT", "9120")
	ports, err := loadPorts(env("BRIDGE_PORTS", ""), routes)
	if err != nil {
		log.Fatal(err)
	}
	tokens := NewTokens(env("BRIDGE_METADATA_URL", defaultMeta))
	up := NewUpstream()
	errc := make(chan error, len(ports)+1)
	for p, svc := range ports {
		go func(p, svc string) { errc <- serve(addr+":"+p, Handler(routes, tokens, up, svc)) }(p, svc)
	}
	go func() { errc <- serve(addr+":"+port, Handler(routes, tokens, up, "")) }()
	log.Printf("gcp-idtoken-bridge: %d routes, router %s:%s, %d service listeners", len(routes), addr, port, len(ports))
	log.Fatal(<-errc)
}
