package journalntfy

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The contract is the shell script itself: these tests EXECUTE scripts/journal-ntfy.sh (or
// functions cut out of it) and compare against the Go port. A mutation of the shell text
// must make the comparison fail, which proves the harness really reads that file.

const scriptRel = "../../../modules/scripts/journal-ntfy.sh"

func script(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile(scriptRel)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func between(t *testing.T, s, from, to string) string {
	t.Helper()
	i := strings.Index(s, from)
	if i < 0 {
		t.Fatalf("marker %q not found", from)
	}
	j := strings.Index(s[i:], to)
	if j < 0 {
		t.Fatalf("end marker %q not found", to)
	}
	return s[i : i+j+len(to)]
}

func sh(t *testing.T, prog string, args ...string) string {
	t.Helper()
	out, err := exec.Command("sh", append([]string{"-c", prog, "sh"}, args...)...).Output()
	if err != nil {
		t.Fatalf("sh: %v\n%s", err, prog)
	}
	return strings.TrimRight(string(out), "\n")
}

var units = []string{"load-shedder", "tier1-watchdog", "wg-quick@wg0", "wireguard-x", "wireguard", "docker", "docker-compose", "containerd",
	"sshd", "dropbear", "ssh-agent", "ssh", "maddy", "stalwart", "mail-puller-gmail", "mail-pull", "caddy", "caddy-l4", "introspect-proxy",
	"authelia", "crowdsec", "fail2ban", "fluent-bit", "log-shipper", "health-agent", "evidence-collector", "evidence-collect", "dagu",
	"dagu-worker", "unknown", "random-unit", "systemd-logind", "x"}
var sevs = []string{"emerg", "alert", "crit", "err", "warning"}

func routeFn(s string) string { return between2(s, "route() {\n", "\n}\n") }

func between2(s, from, to string) string {
	i := strings.Index(s, from)
	j := strings.Index(s[i:], to)
	return s[i : i+j+len(to)]
}

func shellRouteMismatches(t *testing.T, scriptText string) int {
	fn := routeFn(scriptText)
	bad := 0
	for _, u := range units {
		for _, sv := range sevs {
			got := sh(t, fn+`route "$1" "$2"`, u, sv)
			p, topic := Route(u, sv)
			if want := fmt.Sprintf("%d %s", p, topic); got != want {
				bad++
				if bad < 5 {
					t.Logf("route(%q,%q): shell %q go %q", u, sv, got, want)
				}
			}
		}
	}
	return bad
}

func TestRouteParity(t *testing.T) {
	if n := shellRouteMismatches(t, script(t)); n != 0 {
		t.Fatalf("%d route mismatches vs the shell", n)
	}
}

func TestRouteParityMutantCaught(t *testing.T) {
	s := script(t)
	for name, mut := range map[string]string{
		"prio":    strings.Replace(s, `echo "4 health_containers"`, `echo "3 health_containers"`, 1),
		"topic":   strings.Replace(s, `echo "4 sec_audit"`, `echo "4 sec_audit2"`, 1),
		"pattern": strings.Replace(s, `wg-quick*|wireguard*)`, `wg-quick*)`, 1),
		"default": strings.Replace(s, `err)              echo "4 health_resources"`, `err)              echo "3 health_resources"`, 1),
	} {
		if mut == s {
			t.Fatalf("mutation %s did not change the script", name)
		}
		if shellRouteMismatches(t, mut) == 0 {
			t.Errorf("mutation %s survived", name)
		}
	}
}

var lines = []string{
	"Nov 24 12:00:00.000001 systemd[1]: Failed unit caddy.service err happened",
	"Nov 24 12:00:00.000001 systemd[1]: unit sshd.service crit now",
	"Nov 24 12:00:00.000001 kernel: nothing here at all",
	"Nov 24 12:00:00.000001 x[1]: Foo.service err",
	"Nov 24 12:00:00.000001 x[1]: a wg-quick@wg0.service warning dropped",
	"Nov 24 12:00:00.000001 x[1]: 9bad.service err",
	"Nov 24 12:00:00.000001 x[1]: first a.service then b.service emerg",
	"Nov 24 12:00:00.000001 x[1]: caddy.service: with colon err",
	"Nov 24 12:00:00.000001 x[1]: <3> something .service",
	"Nov 24 12:00:00.000001 x[1]: alert from docker.service",
	"Nov 24 12:00:00.000001 x[1]: <4> m.service",
	"Nov 24 12:00:00.000001 x[1]: plain text only",
}

func TestUnitAndSeverityExtractionParity(t *testing.T) {
	s := script(t)
	awk := between(t, s, "  unit=$(printf", "}')")
	sevBlock := between(t, s, `  sev="err"`, "  esac")
	for _, l := range lines {
		gotUnit := sh(t, `line="$1"; `+awk+`; [ -z "$unit" ] && unit=unknown; printf '%s' "$unit"`, l)
		if want := ExtractUnit(l); gotUnit != want {
			t.Errorf("unit of %q: shell %q go %q", l, gotUnit, want)
		}
		gotSev := sh(t, `line="$1"; `+sevBlock+`; printf '%s' "$sev"`, l)
		if want := SevFromLine(l); gotSev != want {
			t.Errorf("sev of %q: shell %q go %q", l, gotSev, want)
		}
	}
}

type ev struct {
	unit string
	prio int
}

func lineFor(e ev) string {
	word := SevName(e.prio)
	if e.unit == "unknown" {
		return "Nov 24 12:00:00.000000 systemd[1]: some unit " + word + " happened"
	}
	return "Nov 24 12:00:00.000000 systemd[1]: Unit " + e.unit + ".service " + word + " happened"
}

// End to end: the real script runs with a fake journalctl (cats a fixture) and a fake curl
// (records the request); the Go pipeline gets the same events. Same messages, same order.
func TestEndToEndAgainstShellScript(t *testing.T) {
	events := []ev{
		{"caddy", 3}, {"caddy", 3}, {"caddy", 4}, {"sshd", 2}, {"foo", 4}, {"foo", 3}, {"foo2", 3},
		{"unknown", 4}, {"unknown", 3}, {"docker", 3}, {"load-shedder", 0}, {"wg-quick@wg0", 4},
		{"crowdsec", 3}, {"dagu", 4}, {"health-agent", 3}, {"health-agent", 4}, {"mail-puller-x", 2}, {"x-y", 1},
	}
	dir := t.TempDir()
	fix := filepath.Join(dir, "fixture")
	var sb strings.Builder
	for _, e := range events {
		sb.WriteString(lineFor(e) + "\n")
	}
	os.WriteFile(fix, []byte(sb.String()), 0o644)
	bin := filepath.Join(dir, "bin")
	os.Mkdir(bin, 0o755)
	os.WriteFile(filepath.Join(bin, "journalctl"), []byte("#!/bin/sh\ncat \""+fix+"\"\n"), 0o755)
	rec := filepath.Join(dir, "curl.log")
	os.WriteFile(filepath.Join(bin, "curl"), []byte(`#!/bin/sh
url=""; title=""; prio=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) case "$2" in Title:*) title="${2#Title: }";; Priority:*) prio="${2#Priority: }";; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
printf '%s|%s|%s\n' "${url##*/}" "$prio" "$title" >> "`+rec+`"
`), 0o755)
	script := strings.Replace(script(t), `RATE_DIR="/tmp/journal-ntfy-rate"`, `RATE_DIR="`+filepath.Join(dir, "rate")+`"`, 1)
	if !strings.Contains(script, dir) {
		t.Fatal("RATE_DIR override failed")
	}
	sp := filepath.Join(dir, "j.sh")
	os.WriteFile(sp, []byte(script), 0o755)
	cmd := exec.Command("sh", sp)
	cmd.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"), "RATE_SECONDS=300", "NTFY_WG_BASE=http://wg.test", "NTFY_BASE=http://pub.test")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("script: %v %s", err, out)
	}
	b, _ := os.ReadFile(rec)
	var want []string
	vm := strings.TrimSpace(sh(t, `hostname -s 2>/dev/null || echo unknown`))
	p := &Pipeline{VM: vm, Limiter: NewLimiter(300 * time.Second)}
	now := time.Unix(1_800_000_000, 0)
	p.Limiter.Now = func() time.Time { return now }
	for _, e := range events {
		unit := e.unit
		entry := Entry{Unit: unit + ".service", Priority: e.prio, Message: "x", PID: "1", TS: now}
		if unit == "unknown" {
			entry.Unit = ""
			entry.Ident = "systemd"
			entry.Message = "some unit " + SevName(e.prio) + " happened"
		}
		if d, ok := p.Handle(entry); ok {
			want = append(want, fmt.Sprintf("%s|%d|%s", d.Topic, d.Prio, d.Title))
		}
	}
	got := strings.Split(strings.TrimSpace(string(b)), "\n")
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("shell published:\n%s\ngo would publish:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	if len(want) < 8 || len(want) >= len(events) {
		t.Fatalf("fixture must exercise both rate-limited and published events: %d of %d", len(want), len(events))
	}
}

func TestLimiterWindow(t *testing.T) {
	now := time.Unix(1000, 0)
	l := NewLimiter(300 * time.Second)
	l.Now = func() time.Time { return now }
	if !l.Allow("a", "t") || l.Allow("a", "t") {
		t.Fatal("second call inside the window must be suppressed")
	}
	if !l.Allow("a", "other") || !l.Allow("b", "t") {
		t.Fatal("different key must pass")
	}
	now = now.Add(299 * time.Second)
	if l.Allow("a", "t") {
		t.Fatal("299 s is still inside the window")
	}
	now = now.Add(1 * time.Second)
	if !l.Allow("a", "t") {
		t.Fatal("300 s reopens the window")
	}
}

func TestParseEntry(t *testing.T) {
	e, err := ParseEntry([]byte(`{"_SYSTEMD_UNIT":"caddy.service","PRIORITY":"3","MESSAGE":"boom","__REALTIME_TIMESTAMP":"1700000000000000","_PID":"42","SYSLOG_IDENTIFIER":"caddy"}`))
	if err != nil || e.UnitName() != "caddy" || e.Priority != 3 || e.Message != "boom" || e.PID != "42" {
		t.Fatalf("%+v %v", e, err)
	}
	b, _ := ParseEntry([]byte(`{"PRIORITY":"4","MESSAGE":[104,105]}`))
	if b.Message != "hi" || b.UnitName() != "unknown" {
		t.Fatalf("binary message: %+v", b)
	}
	if _, err := ParseEntry([]byte(`{nope`)); err == nil {
		t.Fatal("garbage must error")
	}
}
