package shedder

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The contract is protection/load-shedder.nix. The harness cuts the REAL main loop out of the
// Nix string, resolves the Nix escapes, stubs the side effects (logger, ntfy_send, systemctl,
// docker helpers, sleep) and feeds a scripted sequence of samples. The events the loop logs
// and notifies must equal the Go state machine's, tick for tick.

const nixRel = "../../../modules/protection/load-shedder.nix"

func loopText(t *testing.T, mutate func(string) string) string {
	t.Helper()
	b, err := os.ReadFile(nixRel)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	start := strings.Index(s, "      breaches_crit=0\n      breaches_page=0\n      shed_level=0")
	end := strings.Index(s[start:], "\n    '';")
	if start < 0 || end < 0 {
		t.Fatal("main loop not found in load-shedder.nix")
	}
	loop := s[start : start+end]
	if mutate != nil {
		m := mutate(loop)
		if m == loop {
			t.Fatal("mutation did not change the loop")
		}
		loop = m
	}
	// Nix string escapes: ''${ is a literal ${ ; a bare ${...} is an interpolation (stubbed).
	loop = strings.ReplaceAll(loop, "''${", "\x00{")
	loop = regexp.MustCompile(`\$\{[^}]*\}`).ReplaceAllString(loop, "1")
	loop = strings.ReplaceAll(loop, "\x00{", "${")
	loop = strings.ReplaceAll(loop, "'''", "''")
	return strings.ReplaceAll(loop, "/run/", "$TMPD/")
}

type sample struct {
	mem string
	age int
	nt  int
}

func runShell(t *testing.T, loop string, c Config, steps []sample) []string {
	t.Helper()
	dir := t.TempDir()
	var sc strings.Builder
	for _, s := range steps {
		fmt.Fprintf(&sc, "%s %d %d\n", s.mem, s.age, s.nt)
	}
	scen := filepath.Join(dir, "scen")
	os.WriteFile(scen, []byte(sc.String()), 0o644)
	prog := fmt.Sprintf(`
TMPD=%q
MEM_PSI_WARN=%d; MEM_PSI_CRIT=%d; MEM_PSI_PAGE=%d; INTERVAL=15; BACKOFF=120; NEED=%d
DOCKER_START_GRACE=%d; UNSHED_READY_WAIT=1; TIER1_SERVICES="a b"; NTFY_TOPIC=t; NTFY_BASE=b; VM=vm
STEP=0
load_step() { STEP=$((STEP+1)); l=$(sed -n "${STEP}p" %q); [ -z "$l" ] && exit 0; set -- $l; CUR_MEM=$1; CUR_AGE=$2; CUR_NT=$3; }
psi_avg10() { case "$1" in memory) printf '%%s' "$CUR_MEM";; *) echo 0;; esac; }
docker_age() { echo "$CUR_AGE"; }
ntfy_send() { echo "NTFY $2"; }
logger() { for a; do m=$a; done; echo "${m%%%%[ :]*}"; }
systemctl() { return 0; }
shed_non_tier1() { [ "$CUR_NT" = 1 ]; }
sleep() { if [ "$1" = "$INTERVAL" ]; then echo TICK; load_step; fi; }
load_step
%s
`, dir, c.Warn, c.Crit, c.Page, c.Need, c.DockerGraceSecs, scen, loop)
	out, err := exec.Command("sh", "-c", prog).CombinedOutput()
	if err != nil {
		t.Fatalf("shell harness: %v\n%s", err, out)
	}
	return strings.Fields(string(out))
}

func runGo(c Config, steps []sample) []string {
	var st State
	var out []string
	for _, s := range steps {
		for _, e := range st.Step(c, Input{MemRaw: s.mem, DockerAge: s.age, HasNonTier1: s.nt == 1}) {
			out = append(out, strings.ReplaceAll(string(e), " ", "\x01"))
		}
		out = append(out, "TICK")
	}
	// the shell prints "NTFY warn" as two fields; normalise the Go side the same way
	return strings.Fields(strings.ReplaceAll(strings.Join(out, " "), "\x01", " "))
}

var memPool = []string{"0", "0.00", "5.5", "12.5", "34.99", "35.00", "36.2", "49.9", "50", "55.5", "64.99", "65", "80.1", "100.00"}

func scenario(seed, n int) []sample {
	x := uint32(seed)
	rnd := func(m int) int { x = x*1664525 + 1013904223; return int(x>>8) % m }
	cur, age, nt := "0", 5000, 1
	var out []sample
	for i := 0; i < n; i++ {
		if rnd(10) < 3 {
			cur = memPool[rnd(len(memPool))]
		}
		if rnd(20) == 0 {
			age = []int{10, 179, 180, 5000}[rnd(4)]
		}
		if rnd(15) == 0 {
			nt = rnd(2)
		}
		out = append(out, sample{cur, age, nt})
	}
	return out
}

var configs = []Config{
	{Warn: 35, Crit: 50, Page: 65, Need: 3, DockerGraceSecs: 180},
	{Warn: 35, Crit: 50, Page: 65, Need: 1, DockerGraceSecs: 0},
	{Warn: 10, Crit: 20, Page: 40, Need: 2, DockerGraceSecs: 180},
}

func TestShedderParityWithShellLoop(t *testing.T) {
	loop := loopText(t, nil)
	total := 0
	for ci, c := range configs {
		for seed := 1; seed <= 6; seed++ {
			steps := scenario(seed*31+ci, 300)
			want := runShell(t, loop, c, steps)
			got := runGo(c, steps)
			total += len(want)
			if strings.Join(got, " ") != strings.Join(want, " ") {
				for i := 0; i < len(want) && i < len(got); i++ {
					if want[i] != got[i] {
						t.Fatalf("cfg %d seed %d: first divergence at token %d: shell %v go %v\nshell ...%v\ngo    ...%v", ci, seed, i, want[i], got[i],
							want[max(0, i-6):min(len(want), i+6)], got[max(0, i-6):min(len(got), i+6)])
					}
				}
				t.Fatalf("cfg %d seed %d: length shell %d go %d", ci, seed, len(want), len(got))
			}
		}
	}
	if total < 2000 {
		t.Fatalf("scenarios too quiet to prove anything: %d tokens", total)
	}
}

// Every event kind must actually occur in the compared streams (otherwise the parity could be
// vacuous for a branch).
func TestScenariosCoverEveryBranch(t *testing.T) {
	seen := map[string]bool{}
	for ci, c := range configs {
		for seed := 1; seed <= 6; seed++ {
			for _, e := range runGo(c, scenario(seed*31+ci, 300)) {
				seen[e] = true
			}
		}
	}
	for _, k := range []string{"WARN", "GRACE", "CRIT", "PAGE", "RECOVERY", "SHED-CRIT", "SHED-PAGE", "NTFY", "warn", "crit", "page"} {
		if !seen[k] {
			t.Errorf("event %q never produced by the scenarios", k)
		}
	}
}

// Mutations of the shell text must be seen as divergences (the harness really runs that file).
func TestShedderParityMutantsCaught(t *testing.T) {
	c := configs[0]
	for name, m := range map[string]func(string) string{
		"need-off-by-one": func(s string) string {
			return strings.Replace(s, `[ "$breaches_crit" -ge "$NEED" ]`, `[ "$breaches_crit" -gt "$NEED" ]`, 1)
		},
		"grace-ignored": func(s string) string {
			return strings.Replace(s, `-lt "$DOCKER_START_GRACE"`, `-lt 0`, 1)
		},
		"page-uses-crit-threshold": func(s string) string {
			return strings.Replace(s, `elif [ "$MEM_I" -ge "$MEM_PSI_PAGE" ]`, `elif [ "$MEM_I" -ge "$MEM_PSI_CRIT" ]`, 1)
		},
	} {
		caught := false
		for seed := 1; seed <= 4 && !caught; seed++ {
			steps := scenario(seed*31, 300)
			if strings.Join(runShell(t, loopText(t, m), c, steps), " ") != strings.Join(runGo(c, steps), " ") {
				caught = true
			}
		}
		if !caught {
			t.Errorf("mutant %s matched the Go stream on every seed: harness is not sensitive to it", name)
		}
	}
}
