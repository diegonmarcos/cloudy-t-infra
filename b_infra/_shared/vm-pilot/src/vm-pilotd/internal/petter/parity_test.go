package petter

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The contract is protection/watchdog-petter.sh. The harness runs the REAL script with its
// loop sleeps replaced by a scenario stepper, /proc/meminfo and the log path redirected into a
// temp dir, and fake curl/df/systemctl/find/rm/journalctl on PATH that record every action and
// notification. The recorded stream must equal the Go engine's, tick for tick.

const scriptRel = "../../../modules/protection/watchdog-petter.sh"

type step struct {
	ping       bool
	restarting []string
	unhealthy  []string
	mem, disk  int
}

func names(v []string) string {
	if len(v) == 0 {
		return "-"
	}
	return strings.Join(v, ",")
}

func patched(t *testing.T, mutate func(string) string) string {
	t.Helper()
	b, err := os.ReadFile(scriptRel)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	repl := []struct{ from, to string }{
		{"LOG=/var/log/watchdog-petter.log", "LOG=$TMPD/wd.log"},
		{"  sync 2>/dev/null\n  sleep 5\n}", "  :\n}"},
		{"    sleep 5\n    continue", "    tick_sleep\n    continue"},
		{"  sleep 5\ndone", "  tick_sleep\ndone"},
	}
	for _, r := range repl {
		if strings.Count(s, r.from) != 1 {
			t.Fatalf("expected exactly one %q in the script", r.from)
		}
		s = strings.Replace(s, r.from, r.to, 1)
	}
	s = strings.ReplaceAll(s, "/proc/meminfo", "$TMPD/meminfo")
	if mutate != nil {
		m := mutate(s)
		if m == s {
			t.Fatal("mutation did not change the script")
		}
		s = m
	}
	return s
}

const fakeCurl = `#!/bin/sh
sock=0; method=GET; url=""; title=""; prio=""
while [ $# -gt 0 ]; do
  case "$1" in
    --unix-socket) sock=1; shift ;;
    -X) method="$2"; shift ;;
    -H) case "$2" in Title:*) title="${2#Title: }";; Priority:*) prio="${2#Priority: }";; esac; shift ;;
    http*) url="$1" ;;
  esac
  shift
done
if [ "$sock" = 1 ]; then
  path="${url#http://localhost}"
  case "$method $path" in
    "GET /_ping") [ "$(cat "$TMPD/ping")" = 1 ] && exit 0 || exit 22 ;;
    "GET /containers/json?all=true&filters="*restarting*) n=$(cat "$TMPD/restarting") ;;
    "GET /containers/json?filters="*unhealthy*) n=$(cat "$TMPD/unhealthy") ;;
    "GET "*) echo '[]'; exit 0 ;;
    "POST /containers/prune"*) echo "ACT prune-containers" >> "$TMPD/ev" ;;
    "POST /images/prune?filters="*) echo "ACT prune-images-dangling" >> "$TMPD/ev" ;;
    "POST /images/prune"*) echo "ACT prune-images" >> "$TMPD/ev" ;;
    "POST /build/prune"*) echo "ACT prune-build" >> "$TMPD/ev" ;;
    "POST /containers/"*"/restart"*) c="${path#/containers/}"; echo "ACT restart ${c%%/*}" >> "$TMPD/ev" ;;
  esac
  case "$method $path" in
    "GET "*) [ "$n" = "-" ] && echo '[]' || { printf '['; first=1; for c in $(echo "$n" | tr , ' '); do [ $first = 1 ] || printf ','; first=0; printf '{"Names":["/%s"]}' "$c"; done; echo ']'; } ;;
  esac
  exit 0
fi
t="${title#\[*\] }"
echo "NTFY $prio $t" >> "$TMPD/ev"
exit 0
`

func shellRun(t *testing.T, script string, c Config, steps []step) []string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	os.Mkdir(bin, 0o755)
	w := func(name, body string) { os.WriteFile(filepath.Join(bin, name), []byte(body), 0o755) }
	w("curl", fakeCurl)
	w("df", "#!/bin/sh\nprintf 'Filesystem 1K-blocks Used Available Use%% Mounted\\n/dev/x 100 %s 10 %s%% /\\n' \"$(cat \"$TMPD/disk\")\" \"$(cat \"$TMPD/disk\")\"\n")
	w("systemctl", "#!/bin/sh\n[ \"$1\" = restart ] && [ \"$2\" = docker ] && echo 'ACT docker-restart' >> \"$TMPD/ev\"\nexit 0\n")
	w("find", "#!/bin/sh\ncase \"$*\" in *-json.log*) echo 'ACT truncate-logs' >> \"$TMPD/ev\";; esac\nexit 0\n")
	w("rm", "#!/bin/sh\ncase \"$*\" in *ballast.bin*) echo 'ACT ballast' >> \"$TMPD/ev\";; esac\nexit 0\n")
	w("journalctl", "#!/bin/sh\nfor a; do case \"$a\" in --vacuum-time=*) d=\"${a#--vacuum-time=}\"; echo \"ACT vacuum ${d%d}\" >> \"$TMPD/ev\";; esac; done\nexit 0\n")
	for _, n := range []string{"ps", "swapon", "sync", "sleep"} {
		w(n, "#!/bin/sh\nexit 0\n")
	}
	var sc strings.Builder
	for _, s := range steps {
		p := 0
		if s.ping {
			p = 1
		}
		fmt.Fprintf(&sc, "%d %s %s %d %d\n", p, names(s.restarting), names(s.unhealthy), s.mem, s.disk)
	}
	scen := filepath.Join(dir, "scen")
	os.WriteFile(scen, []byte(sc.String()), 0o644)
	prologue := fmt.Sprintf(`#!/bin/sh
TMPD=%q; export TMPD
PATH=%q:$PATH
DOCKER_FAIL_THRESHOLD=%d; LOW_MEM_PRUNE_MB=%d; DISK_WARN=%d; DISK_HIGH=%d; DISK_EMERG=%d
%s
STEP=0
load_step() { STEP=$((STEP+1)); l=$(sed -n "${STEP}p" %q); [ -z "$l" ] && exit 0; set -- $l
  echo "$1" > "$TMPD/ping"; echo "$2" > "$TMPD/restarting"; echo "$3" > "$TMPD/unhealthy"; echo "$5" > "$TMPD/disk"
  printf 'MemTotal: 1000000 kB\nMemAvailable: %%d kB\nBuffers: 1 kB\nCached: 1 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n' $(( $4 * 1024 )) > "$TMPD/meminfo"; }
tick_sleep() { echo TICK >> "$TMPD/ev"; load_step; }
load_step
`, dir, bin, c.DockerFailThreshold, c.LowMemPruneMB, c.DiskWarn, c.DiskHigh, c.DiskEmerg,
		map[bool]string{true: "JOURNAL_FLOOR_DAYS=" + c.JournalFloorDays + "; export JOURNAL_FLOOR_DAYS", false: ""}[c.JournalFloorDays != ""], scen)
	body := strings.TrimPrefix(script, "#!/bin/sh\n")
	sp := filepath.Join(dir, "petter.sh")
	os.WriteFile(sp, []byte(prologue+body), 0o755)
	if out, err := exec.Command("sh", sp).CombinedOutput(); err != nil {
		t.Fatalf("petter harness: %v\n%s", err, tail(string(out)))
	}
	b, _ := os.ReadFile(filepath.Join(dir, "ev"))
	return strings.Split(strings.TrimSpace(string(b)), "\n")
}

func tail(s string) string {
	if len(s) > 2000 {
		return s[len(s)-2000:]
	}
	return s
}

func goRun(c Config, steps []step) []string {
	var st State
	var out []string
	for _, s := range steps {
		out = append(out, st.Step(c, Input{PingOK: s.ping, Restarting: s.restarting, Unhealthy: s.unhealthy, MemAvailMB: s.mem, DiskPct: s.disk})...)
		out = append(out, "TICK")
	}
	return out
}

func scenario(seed, n int) []step {
	x := uint32(seed)
	rnd := func(m int) int { x = x*1664525 + 1013904223; return int(x>>8) % m }
	pool := []string{"a", "b", "c"}
	pick := func() []string {
		var v []string
		for _, p := range pool {
			if rnd(3) == 0 {
				v = append(v, p)
			}
		}
		return v
	}
	cur := step{ping: true, mem: 9999, disk: 10}
	var out []step
	for i := 0; i < n; i++ {
		if rnd(4) == 0 {
			cur.ping = rnd(5) != 0
		}
		if rnd(4) == 0 {
			cur.restarting = pick()
		}
		if rnd(4) == 0 {
			cur.unhealthy = pick()
		}
		if rnd(5) == 0 {
			cur.mem = []int{9999, 500, 51, 50, 49, 10}[rnd(6)]
		}
		if rnd(5) == 0 {
			cur.disk = []int{10, 79, 80, 84, 85, 89, 90, 99}[rnd(8)]
		}
		out = append(out, cur)
	}
	return out
}

var configs = []Config{
	{DockerFailThreshold: 3, LowMemPruneMB: 50, DiskWarn: 80, DiskHigh: 85, DiskEmerg: 90},
	{DockerFailThreshold: 2, LowMemPruneMB: 50, DiskWarn: 80, DiskHigh: 85, DiskEmerg: 90, JournalFloorDays: "7"},
}

func TestPetterParityWithShellScript(t *testing.T) {
	script := patched(t, nil)
	total := 0
	for ci, c := range configs {
		for seed := 1; seed <= 3; seed++ {
			steps := scenario(seed*17+ci, 120)
			want := shellRun(t, script, c, steps)
			got := goRun(c, steps)
			total += len(want)
			if strings.Join(got, "\n") != strings.Join(want, "\n") {
				for i := 0; i < len(want) && i < len(got); i++ {
					if want[i] != got[i] {
						t.Fatalf("cfg %d seed %d: first divergence at line %d: shell %q go %q\nshell ...%q\ngo    ...%q", ci, seed, i, want[i], got[i],
							want[max(0, i-5):min(len(want), i+5)], got[max(0, i-5):min(len(got), i+5)])
					}
				}
				t.Fatalf("cfg %d seed %d: length shell %d go %d", ci, seed, len(want), len(got))
			}
		}
	}
	if total < 400 {
		t.Fatalf("scenarios too quiet: %d lines", total)
	}
}

func TestScenariosCoverEveryAction(t *testing.T) {
	seen := map[string]bool{}
	for ci, c := range configs {
		for seed := 1; seed <= 3; seed++ {
			for _, e := range goRun(c, scenario(seed*17+ci, 120)) {
				seen[e] = true
			}
		}
	}
	for _, k := range []string{"NTFY 4 Docker restart", "ACT docker-restart", "NTFY 3 Container restart", "NTFY 3 Container unhealthy", "ACT restart a",
		"NTFY 4 Low memory", "ACT truncate-logs", "NTFY 5 DISK EMERG", "ACT ballast", "ACT prune-build", "ACT vacuum 7", "NTFY 4 Disk high", "NTFY 3 Disk warn",
		"ACT prune-images-dangling", "ACT prune-images", "ACT prune-containers"} {
		if !seen[k] {
			t.Errorf("%q never produced", k)
		}
	}
}

func TestPetterParityMutantsCaught(t *testing.T) {
	c := configs[0]
	for name, m := range map[string]func(string) string{
		"unhealthy-limit": func(s string) string { return strings.Replace(s, `[ "$PREV" -lt 1 ]`, `[ "$PREV" -lt 2 ]`, 1) },
		"disk-tier": func(s string) string {
			return strings.Replace(s, `[ "$DISK_PCT" -ge "$DISK_HIGH" ]`, `[ "$DISK_PCT" -gt "$DISK_HIGH" ]`, 1)
		},
		"low-mem": func(s string) string {
			return strings.Replace(s, `-lt "$LOW_MEM_PRUNE_MB"`, `-le "$LOW_MEM_PRUNE_MB"`, 1)
		},
	} {
		caught := false
		for seed := 1; seed <= 3 && !caught; seed++ {
			steps := scenario(seed*17, 120)
			if strings.Join(shellRun(t, patched(t, m), c, steps), "\n") != strings.Join(goRun(c, steps), "\n") {
				caught = true
			}
		}
		if !caught {
			t.Errorf("mutant %s produced the same stream on every seed: harness is not sensitive to it", name)
		}
	}
}
