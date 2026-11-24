package tier1

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The contract is the tier1-watchdog main loop in protection/tier1-apps.nix, cut out of the Nix
// string and run under bash (it uses associative arrays) with stubbed docker/systemctl/date/
// ntfy/restart_tier1/logger/sleep.

const nixRel = "../../../modules/protection/tier1-apps.nix"

func loop(t *testing.T, mutate func(string) string) string {
	t.Helper()
	b, err := os.ReadFile(nixRel)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	start := strings.Index(s, "      declare -A restarts last_fail")
	end := strings.Index(s[start:], "\n    '';")
	if start < 0 || end < 0 {
		t.Fatal("loop not found")
	}
	l := s[start : start+end]
	if mutate != nil {
		m := mutate(l)
		if m == l {
			t.Fatal("mutation did not change the loop")
		}
		l = m
	}
	return strings.ReplaceAll(l, "''${", "${")
}

type step struct {
	running []string
	docker  bool
	now     int64
}

func shell(t *testing.T, l string, c Config, steps []step) []string {
	t.Helper()
	dir := t.TempDir()
	var sc strings.Builder
	for _, s := range steps {
		d := 0
		if s.docker {
			d = 1
		}
		r := strings.Join(s.running, ",")
		if r == "" {
			r = "-"
		}
		fmt.Fprintf(&sc, "%d %d %s\n", d, s.now, r)
	}
	scen := filepath.Join(dir, "scen")
	os.WriteFile(scen, []byte(sc.String()), 0o644)
	prog := fmt.Sprintf(`
TIER1=%q; MAX_RESTARTS=%d; CHECK_INTERVAL=30; RESET_WINDOW=%d
STEP=0
load_step() { STEP=$((STEP+1)); l=$(sed -n "${STEP}p" %q); [ -z "$l" ] && exit 0; set -- $l; CUR_DOCKER=$1; CUR_NOW=$2; CUR_RUN=$3; }
docker() { for a; do s=$a; done; case ",$CUR_RUN," in *",$s,"*) echo true;; *) echo false;; esac; }
systemctl() { [ "$CUR_DOCKER" = 1 ]; }
date() { echo "$CUR_NOW"; }
logger() { for a; do m=$a; done; echo "LOG $m"; }
ntfy() { echo "NTFY $1 $2"; }
restart_tier1() { echo "RESTART $1"; }
sleep() { echo TICK; load_step; }
load_step
%s
`, strings.Join(c.Services, " "), c.MaxRestarts, c.ResetWindow, scen, l)
	out, err := exec.Command("bash", "-c", prog).CombinedOutput()
	if err != nil {
		t.Fatalf("bash: %v\n%s", err, out)
	}
	return strings.Split(strings.TrimRight(string(out), "\n"), "\n")
}

func goRun(c Config, steps []step) []string {
	var st State
	var out []string
	for _, s := range steps {
		run := map[string]bool{}
		for _, r := range s.running {
			run[r] = true
		}
		out = append(out, st.Step(c, Input{Running: run, DockerActive: s.docker, Now: s.now})...)
		out = append(out, "TICK")
	}
	return out
}

func scenario(seed, n int) []step {
	x := uint32(seed)
	rnd := func(m int) int { x = x*1664525 + 1013904223; return int(x>>8) % m }
	all := []string{"a", "b", "c"}
	cur := step{running: all, docker: true, now: 1000}
	var out []step
	for i := 0; i < n; i++ {
		if rnd(3) == 0 {
			var r []string
			for _, s := range all {
				if rnd(3) != 0 {
					r = append(r, s)
				}
			}
			cur.running = r
		}
		if rnd(8) == 0 {
			cur.docker = rnd(3) != 0
		}
		cur.now += int64(rnd(120))
		out = append(out, cur)
	}
	return out
}

var cfgs = []Config{
	{Services: []string{"a", "b", "c"}, MaxRestarts: 3, ResetWindow: 300},
	{Services: []string{"a", "b"}, MaxRestarts: 1, ResetWindow: 60},
}

func TestTier1ParityWithShellLoop(t *testing.T) {
	l := loop(t, nil)
	total := 0
	for ci, c := range cfgs {
		for seed := 1; seed <= 6; seed++ {
			steps := scenario(seed*13+ci, 200)
			want := shell(t, l, c, steps)
			got := goRun(c, steps)
			total += len(want)
			if strings.Join(got, "\n") != strings.Join(want, "\n") {
				for i := 0; i < len(want) && i < len(got); i++ {
					if want[i] != got[i] {
						t.Fatalf("cfg %d seed %d line %d: shell %q go %q", ci, seed, i, want[i], got[i])
					}
				}
				t.Fatalf("cfg %d seed %d: length shell %d go %d", ci, seed, len(want), len(got))
			}
		}
	}
	if total < 600 {
		t.Fatalf("too quiet: %d", total)
	}
}

func TestTier1ScenariosCoverEveryBranch(t *testing.T) {
	seen := map[string]bool{}
	for ci, c := range cfgs {
		for seed := 1; seed <= 6; seed++ {
			for _, e := range goRun(c, scenario(seed*13+ci, 200)) {
				switch {
				case strings.Contains(e, "circuit reset"):
					seen["reset"] = true
				case strings.Contains(e, "CIRCUIT OPEN"):
					seen["open"] = true
				case strings.HasPrefix(e, "RESTART"):
					seen["restart"] = true
				}
			}
		}
	}
	for _, k := range []string{"reset", "open", "restart"} {
		if !seen[k] {
			t.Errorf("branch %s never exercised", k)
		}
	}
}

func TestTier1MutantsCaught(t *testing.T) {
	c := cfgs[0]
	for name, m := range map[string]func(string) string{
		"reset-window": func(s string) string {
			return strings.Replace(s, `[ "$gap" -ge "$RESET_WINDOW" ]`, `[ "$gap" -gt "$RESET_WINDOW" ]`, 1)
		},
		"max": func(s string) string {
			return strings.Replace(s, `-le "$MAX_RESTARTS" ]; then`, `-lt "$MAX_RESTARTS" ]; then`, 1)
		},
		"docker-down": func(s string) string {
			return strings.Replace(s, "continue\n            fi\n            restarts", "true\n            fi\n            restarts", 1)
		},
	} {
		caught := false
		for seed := 1; seed <= 4 && !caught; seed++ {
			steps := scenario(seed*13, 200)
			if strings.Join(shell(t, loop(t, m), c, steps), "\n") != strings.Join(goRun(c, steps), "\n") {
				caught = true
			}
		}
		if !caught {
			t.Errorf("mutant %s not caught", name)
		}
	}
}
