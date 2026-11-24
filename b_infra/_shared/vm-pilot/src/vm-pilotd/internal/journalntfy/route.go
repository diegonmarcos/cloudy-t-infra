// Package journalntfy is the Go port of scripts/journal-ntfy.sh: journal warnings and
// errors routed to ntfy topics by unit pattern and severity, rate limited per (unit, topic).
package journalntfy

import (
	"strings"
	"time"
)

// glob matches a shell `case` pattern made of literals and a trailing '*'.
func glob(p, s string) bool {
	if strings.HasSuffix(p, "*") {
		return strings.HasPrefix(s, p[:len(p)-1])
	}
	return p == s
}

type rule struct {
	prio  int
	topic string
	pats  []string
}

// rules are the shell route() case arms, in order (first match wins).
var rules = []rule{
	{5, "health_resources", []string{"load-shedder", "tier1-watchdog"}},
	{5, "health_mesh", []string{"wg-quick*", "wireguard*"}},
	{4, "health_containers", []string{"docker*", "containerd*"}},
	{4, "health_mesh", []string{"sshd", "dropbear", "ssh*"}},
	{4, "health_endpoints", []string{"maddy", "stalwart", "mail-puller*"}},
	{4, "health_endpoints", []string{"caddy", "introspect-proxy", "authelia"}},
	{4, "sec_audit", []string{"crowdsec", "fail2ban"}},
	{3, "health_resources", []string{"fluent-bit", "log-shipper"}},
	{2, "health_resources", []string{"health-agent", "evidence-collect*"}},
	{3, "deploy_ship", []string{"dagu*"}},
}

// Route returns the ntfy priority and topic for a unit and severity name.
func Route(unit, sev string) (int, string) {
	for _, r := range rules {
		for _, p := range r.pats {
			if glob(p, unit) {
				return r.prio, r.topic
			}
		}
	}
	switch sev {
	case "emerg", "alert", "crit":
		return 5, "health_resources"
	case "err":
		return 4, "health_resources"
	}
	return 3, "health_resources"
}

// SevName maps a journal PRIORITY (0..7) to the shell's severity words. The shell guessed
// it from substrings of the text line; the journal field is authoritative.
func SevName(priority int) string {
	switch priority {
	case 0:
		return "emerg"
	case 1:
		return "alert"
	case 2:
		return "crit"
	case 3:
		return "err"
	case 4:
		return "warning"
	}
	return "err"
}

// ExtractUnit is the shell's awk: the first whitespace field matching /[a-z].*\.service$/
// (a lowercase letter somewhere before the ".service" suffix; the regex is not anchored at
// the start), with the suffix removed; "unknown" when none.
func ExtractUnit(line string) string {
	for _, f := range strings.Fields(line) {
		if !strings.HasSuffix(f, ".service") {
			continue
		}
		stem := strings.TrimSuffix(f, ".service")
		if strings.IndexFunc(stem, func(r rune) bool { return r >= 'a' && r <= 'z' }) >= 0 {
			return stem
		}
	}
	return "unknown"
}

// SevFromLine is the shell's substring severity guess, kept for the parity test and for
// entries that carry no PRIORITY.
func SevFromLine(line string) string {
	switch {
	case strings.Contains(line, "emerg") || strings.Contains(line, "<0>"):
		return "emerg"
	case strings.Contains(line, "alert") || strings.Contains(line, "<1>"):
		return "alert"
	case strings.Contains(line, "crit") || strings.Contains(line, "<2>"):
		return "crit"
	case strings.Contains(line, " err") || strings.Contains(line, "<3>"):
		return "err"
	case strings.Contains(line, "warning") || strings.Contains(line, "<4>"):
		return "warning"
	}
	return "err"
}

// Limiter is the per (unit, topic) window of the shell's RATE_DIR files.
type Limiter struct {
	Window time.Duration
	Now    func() time.Time
	last   map[string]int64
}

func NewLimiter(window time.Duration) *Limiter {
	return &Limiter{Window: window, Now: time.Now, last: map[string]int64{}}
}

// Allow reports whether a message for (unit, topic) may go out now and records it if so.
// Whole-second arithmetic like `date +%s`: elapsed < window means suppressed.
func (l *Limiter) Allow(unit, topic string) bool {
	key := strings.ReplaceAll(unit+"_"+topic, "/", "_")
	now := l.Now().Unix()
	if last, ok := l.last[key]; ok && now-last < int64(l.Window/time.Second) {
		return false
	}
	l.last[key] = now
	return true
}
