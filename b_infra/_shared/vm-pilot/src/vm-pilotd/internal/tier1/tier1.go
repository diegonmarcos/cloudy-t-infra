// Package tier1 is the decision core of tier1-watchdog (protection/tier1-apps.nix): restart a
// stopped tier-1 container, with a per-service circuit breaker (MaxRestarts consecutive
// restarts, then page and stop trying until ResetWindow seconds have passed since the last
// failure). No side effects: it returns the log lines, restarts and notifications in the
// shell's order. The compose-aware restart procedure itself (restart_tier1) is performed by
// the caller and is deliberately not part of this port's shadow stage.
package tier1

import "fmt"

type Config struct {
	Services    []string
	MaxRestarts int
	ResetWindow int // seconds
}

type Input struct {
	Running      map[string]bool
	DockerActive bool
	Now          int64
}

type State struct {
	restarts map[string]int
	lastFail map[string]int64
}

// Step runs one pass over the services.
func (s *State) Step(c Config, in Input) []string {
	if s.restarts == nil {
		s.restarts, s.lastFail = map[string]int{}, map[string]int64{}
	}
	var ev []string
	for _, svc := range c.Services {
		if s.restarts[svc] >= c.MaxRestarts {
			if in.Now-s.lastFail[svc] >= int64(c.ResetWindow) {
				s.restarts[svc] = 0
				ev = append(ev, fmt.Sprintf("LOG [%s] circuit reset after %ds clean window", svc, c.ResetWindow))
			} else {
				continue
			}
		}
		if in.Running[svc] {
			s.restarts[svc] = 0
			continue
		}
		if !in.DockerActive {
			continue
		}
		s.restarts[svc]++
		s.lastFail[svc] = in.Now
		ev = append(ev, fmt.Sprintf("LOG [%s] not running — restart attempt %d/%d", svc, s.restarts[svc], c.MaxRestarts))
		if s.restarts[svc] <= c.MaxRestarts {
			ev = append(ev, "RESTART "+svc, fmt.Sprintf("NTFY 4 Tier-1 restart: %s", svc))
		}
		if s.restarts[svc] >= c.MaxRestarts {
			ev = append(ev, fmt.Sprintf("LOG [%s] CIRCUIT OPEN — %d restarts exhausted; paging", svc, c.MaxRestarts),
				fmt.Sprintf("NTFY 5 Tier-1 CIRCUIT OPEN: %s", svc))
		}
	}
	return ev
}
