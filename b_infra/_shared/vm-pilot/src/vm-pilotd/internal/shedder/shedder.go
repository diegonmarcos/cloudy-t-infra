// Package shedder is the decision core of load-shedder (protection/load-shedder.nix): the
// memory-PSI state machine, without side effects. It returns the events the shell logs and
// notifies, in the shell's order, and the caller decides whether to act (live) or only to
// record (shadow). Memory PSI is the only shed trigger; cpu/io are logged, never acted on.
package shedder

import "vm-pilotd/internal/psi"

// Config holds the data-driven thresholds (consolidated protection block).
type Config struct {
	Warn, Crit, Page int // memory PSI avg10 integer thresholds
	Need             int // consecutive breaches before a shed
	DockerGraceSecs  int // pressure inside this window after docker.service started is not counted
}

// Level is the shed level: 0 normal, 1 non-tier1 shed, 2 everything stopped.
type Level int

// Input is one sample. MemRaw is the raw avg10 string (as the shell reads it).
type Input struct {
	MemRaw       string
	DockerAge    int  // seconds since docker.service entered active (huge if never)
	HasNonTier1  bool // would shed_non_tier1 find something to stop
	DockerActive bool
}

// Event names mirror the first word of the shell's logger lines, plus NTFY with the
// severity argument of ntfy_send, so the two implementations can be compared line by line.
type Event string

// State is the machine's memory between ticks.
type State struct {
	BreachesCrit, BreachesPage int
	Shed                       Level
	Warned                     bool
}

// Step advances one tick and returns the events in the order the shell emits them.
func (s *State) Step(c Config, in Input) []Event {
	var ev []Event
	mem := psi.IntPart(in.MemRaw)

	// warn band: no action, notify once per episode
	if mem >= c.Warn && mem < c.Crit && s.Shed == 0 {
		ev = append(ev, "WARN")
		if !s.Warned {
			s.Warned = true
			ev = append(ev, "NTFY warn")
		}
	}

	switch {
	case mem >= c.Crit && in.DockerAge < c.DockerGraceSecs:
		s.BreachesCrit, s.BreachesPage = 0, 0
		ev = append(ev, "GRACE")
	case mem >= c.Crit && mem < c.Page:
		s.BreachesCrit++
		s.BreachesPage = 0
		ev = append(ev, "CRIT")
	case mem >= c.Page:
		s.BreachesPage++
		s.BreachesCrit = 0
		ev = append(ev, "PAGE")
	default:
		if s.Shed > 0 {
			ev = append(ev, "RECOVERY")
			// docker active and nothing recorded as shed: the shell only notifies
			ev = append(ev, "NTFY warn")
			s.Shed = 0
		}
		s.BreachesCrit, s.BreachesPage, s.Warned = 0, 0, false
	}

	switch {
	case s.BreachesPage >= c.Need && s.Shed < 2:
		ev = append(ev, "SHED-PAGE", "NTFY page")
		s.Shed = 2
		s.BreachesPage = 0
	case s.BreachesCrit >= c.Need && s.Shed < 1:
		ev = append(ev, "SHED-CRIT")
		if in.HasNonTier1 {
			ev = append(ev, "NTFY crit")
			s.Shed = 1
		} else {
			ev = append(ev, "SHED-PAGE", "NTFY page")
			s.Shed = 2
		}
		s.BreachesCrit = 0
	}
	return ev
}
