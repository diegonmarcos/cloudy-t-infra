// Package petter is the decision core of watchdog-petter.sh: docker liveness, crash-loop and
// unhealthy container restarts, low-memory prune and the tiered disk-pressure response. It
// emits the actions and notifications in the shell's order and performs none of them; the
// caller acts (live) or records (shadow). The kernel watchdog itself stays disabled
// (WD_ENABLED=0 in the shell) and is not part of this port.
package petter

import (
	"fmt"
	"strings"
)

// Config mirrors the env knobs injected by watchdog.nix.
type Config struct {
	DockerFailThreshold           int
	LowMemPruneMB                 int
	DiskWarn, DiskHigh, DiskEmerg int
	JournalFloorDays              string // "" = undeclared: no vacuum
}

// Input is one 5 s sample.
type Input struct {
	PingOK     bool
	Restarting []string // containers in status=restarting
	Unhealthy  []string // containers with health=unhealthy
	MemAvailMB int
	DiskPct    int
}

// State carries the counters between ticks.
type State struct {
	DockerFail int
	Cycle      int
	track      []string // restart tracker: one entry per restart done this window
}

func (s *State) count(c string) int {
	n := 0
	for _, t := range s.track {
		if t == c {
			n++
		}
	}
	return n
}

// Event strings are the comparison vocabulary shared with the shell harness:
// "NTFY <prio> <title>" and "ACT <what>".
func ntfy(p int, title string) string { return fmt.Sprintf("NTFY %d %s", p, title) }

// Step advances one iteration of the shell's main loop.
func (s *State) Step(c Config, in Input) []string {
	var ev []string
	if !in.PingOK {
		s.DockerFail++
		if s.DockerFail >= c.DockerFailThreshold {
			ev = append(ev, ntfy(4, "Docker restart"), "ACT docker-restart")
			s.DockerFail = 0
		}
		return ev
	}
	s.DockerFail = 0

	for _, ctr := range in.Restarting {
		if s.count(ctr) < 2 {
			ev = append(ev, ntfy(3, "Container restart"), "ACT restart "+ctr)
			s.track = append(s.track, ctr)
		}
	}
	for _, ctr := range in.Unhealthy {
		if s.count(ctr) < 1 {
			ev = append(ev, ntfy(3, "Container unhealthy"), "ACT restart "+ctr)
			s.track = append(s.track, ctr)
		}
	}

	if in.MemAvailMB < c.LowMemPruneMB {
		ev = append(ev, ntfy(4, "Low memory"), "ACT prune-containers", "ACT prune-images")
	}

	if in.DiskPct >= c.DiskWarn {
		ev = append(ev, "ACT truncate-logs")
	}
	switch {
	case in.DiskPct >= c.DiskEmerg:
		ev = append(ev, ntfy(5, "DISK EMERG"), "ACT ballast", "ACT prune-containers", "ACT prune-images-dangling", "ACT prune-build")
		if c.JournalFloorDays != "" {
			ev = append(ev, "ACT vacuum "+c.JournalFloorDays)
		}
	case in.DiskPct >= c.DiskHigh:
		ev = append(ev, ntfy(4, "Disk high"), "ACT prune-containers", "ACT prune-images", "ACT prune-build")
	case in.DiskPct >= c.DiskWarn:
		ev = append(ev, ntfy(3, "Disk warn"), "ACT prune-containers", "ACT prune-images-dangling")
	}

	s.Cycle++
	if s.Cycle >= 10 {
		s.track = nil
		s.Cycle = 0
	}
	return ev
}

// Describe is a log helper.
func Describe(ev []string) string { return strings.Join(ev, "; ") }
