// Package runner wires the pure decision cores to the host: samplers (procfs, docker socket,
// statfs), the shadow recorder and the journal-ntfy loop. In shadow mode nothing here acts:
// every decision is written to the log with the SHADOW tag and compared where the old
// daemon leaves a trace.
package runner

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"vm-pilotd/internal/dockerapi"
	"vm-pilotd/internal/journalntfy"
	"vm-pilotd/internal/petter"
	"vm-pilotd/internal/psi"
	"vm-pilotd/internal/sdnotify"
	"vm-pilotd/internal/shedder"
	"vm-pilotd/internal/tier1"
)

// Config is /etc/vm-pilotd.json, rendered by the Nix module from the same consolidated
// protection block the shell units read.
type Config struct {
	VM         string   `json:"vm"`
	Shadow     bool     `json:"shadow"`
	Components []string `json:"components"` // journal-ntfy, shedder, petter
	Shedder    struct {
		Warn, Crit, Page, Need, IntervalSecs, DockerGraceSecs int
		Tier1                                                 []string
	} `json:"shedder"`
	Petter struct {
		DockerFailThreshold, LowMemPruneMB, DiskWarn, DiskHigh, DiskEmerg int
		JournalFloorDays                                                  string
	} `json:"petter"`
	JournalNtfy struct {
		WGBase, PublicBase string
		RateSeconds        int
		ShellRateDir       string
	} `json:"journal_ntfy"`
	Tier1 struct {
		Services                               []string
		MaxRestarts, ResetWindow, IntervalSecs int
	} `json:"tier1"`
	DockerSock string `json:"docker_sock"`
	Procfs     string `json:"procfs"`
}

func Load(path string) (Config, error) {
	var c Config
	b, err := os.ReadFile(path)
	if err != nil {
		return c, err
	}
	if err := json.Unmarshal(b, &c); err != nil {
		return c, err
	}
	if c.DockerSock == "" {
		c.DockerSock = "/var/run/docker.sock"
	}
	if c.Procfs == "" {
		c.Procfs = "/proc"
	}
	if c.Shedder.IntervalSecs == 0 {
		c.Shedder.IntervalSecs = 15
	}
	return c, nil
}

type Logger func(format string, a ...any)

// DockerAge is seconds since dockerd started (pid file + /proc/<pid>/stat starttime); the shell
// asks systemd for ActiveEnterTimestamp, which needs a fork. 999999 when unknown.
func DockerAge(procfs, pidFile string) int {
	pb, err := os.ReadFile(pidFile)
	if err != nil {
		return 999999
	}
	pid := strings.TrimSpace(string(pb))
	sb, err := os.ReadFile(procfs + "/" + pid + "/stat")
	if err != nil {
		return 999999
	}
	s := string(sb)
	rp := strings.LastIndexByte(s, ')')
	if rp < 0 {
		return 999999
	}
	f := strings.Fields(s[rp+2:])
	if len(f) < 20 { // starttime is field 22 overall = index 19 after the comm field
		return 999999
	}
	start, err := strconv.ParseInt(f[19], 10, 64)
	if err != nil {
		return 999999
	}
	ub, err := os.ReadFile(procfs + "/uptime")
	if err != nil {
		return 999999
	}
	up, err := strconv.ParseFloat(strings.Fields(string(ub))[0], 64)
	if err != nil {
		return 999999
	}
	return int(up - float64(start)/100.0)
}

// MemAvailMB is MemAvailable from meminfo in MB (9999 when unreadable, like the shell).
func MemAvailMB(procfs string) int {
	b, err := os.ReadFile(procfs + "/meminfo")
	if err != nil {
		return 9999
	}
	for _, l := range strings.Split(string(b), "\n") {
		if strings.HasPrefix(l, "MemAvailable:") {
			f := strings.Fields(l)
			if len(f) >= 2 {
				kb, _ := strconv.Atoi(f[1])
				return kb / 1024
			}
		}
	}
	return 9999
}

// DiskPct is the used percentage of / the way df -P reports it (rounded up).
func DiskPct(path string) int {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil || st.Blocks == 0 {
		return 0
	}
	used := st.Blocks - st.Bfree
	avail := st.Bavail
	return int((used*100 + (used + avail) - 1) / (used + avail))
}

// RunShedder ticks the shedder core. Shadow only: it records what it would do.
func RunShedder(ctx context.Context, c Config, log Logger, wd func()) {
	d := dockerapi.New(c.DockerSock)
	cfg := shedder.Config{Warn: c.Shedder.Warn, Crit: c.Shedder.Crit, Page: c.Shedder.Page, Need: c.Shedder.Need, DockerGraceSecs: c.Shedder.DockerGraceSecs}
	var st shedder.State
	tier1 := map[string]bool{}
	for _, t := range c.Shedder.Tier1 {
		tier1[t] = true
	}
	t := time.NewTicker(time.Duration(c.Shedder.IntervalSecs) * time.Second)
	defer t.Stop()
	for {
		raw := psi.Read(c.Procfs+"/pressure", "memory", "some")
		in := shedder.Input{MemRaw: raw, DockerAge: DockerAge(c.Procfs, "/var/run/docker.pid"), DockerActive: d.Ping(ctx)}
		if len(tier1) > 0 {
			names, _ := d.List(ctx, false, "")
			for _, n := range names {
				if !tier1[n] {
					in.HasNonTier1 = true
				}
			}
		}
		if ev := st.Step(cfg, in); len(ev) > 0 {
			log("SHADOW shedder mem=%s age=%d level=%d: %v", raw, in.DockerAge, st.Shed, ev)
		}
		wd()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// RunPetter ticks the petter core every 5 s. Shadow only.
func RunPetter(ctx context.Context, c Config, log Logger, wd func()) {
	d := dockerapi.New(c.DockerSock)
	cfg := petter.Config{DockerFailThreshold: c.Petter.DockerFailThreshold, LowMemPruneMB: c.Petter.LowMemPruneMB,
		DiskWarn: c.Petter.DiskWarn, DiskHigh: c.Petter.DiskHigh, DiskEmerg: c.Petter.DiskEmerg, JournalFloorDays: c.Petter.JournalFloorDays}
	var st petter.State
	t := time.NewTicker(5 * time.Second)
	defer t.Stop()
	for {
		in := petter.Input{PingOK: d.Ping(ctx), MemAvailMB: MemAvailMB(c.Procfs), DiskPct: DiskPct("/")}
		if in.PingOK {
			in.Restarting, _ = d.List(ctx, true, `{"status":["restarting"]}`)
			in.Unhealthy, _ = d.List(ctx, false, `{"health":["unhealthy"]}`)
		}
		if ev := st.Step(cfg, in); len(ev) > 0 {
			log("SHADOW petter ping=%v mem=%dMB disk=%d%%: %s", in.PingOK, in.MemAvailMB, in.DiskPct, petter.Describe(ev))
		}
		wd()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// RunJournalNtfy follows the journal and, in shadow mode, logs each decision and whether the
// shell publisher left a rate-limit file for the same (unit, topic) key. Live mode posts.
func RunJournalNtfy(ctx context.Context, c Config, log Logger, poster *journalntfy.Poster) {
	rate := time.Duration(c.JournalNtfy.RateSeconds) * time.Second
	if rate == 0 {
		rate = 300 * time.Second
	}
	p := &journalntfy.Pipeline{VM: c.VM, Limiter: journalntfy.NewLimiter(rate)}
	ch := make(chan journalntfy.Entry, 256)
	go func() {
		for ctx.Err() == nil {
			if err := journalntfy.Follow(ctx, "journalctl", ch, log); err != nil && ctx.Err() == nil {
				log("journal-ntfy: journalctl ended: %v (retry in 5s)", err)
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
			}
		}
	}()
	var shadowN, shellSeen int
	for {
		select {
		case <-ctx.Done():
			return
		case e := <-ch:
			d, ok := p.Handle(e)
			if !ok {
				continue
			}
			if c.Shadow || poster == nil {
				shadowN++
				seen := ""
				if dir := c.JournalNtfy.ShellRateDir; dir != "" {
					key := strings.ReplaceAll(d.Unit+"_"+d.Topic, "/", "_")
					if st, err := os.Stat(dir + "/" + key); err == nil && time.Since(st.ModTime()) < 10*time.Minute {
						seen = " shell=same-key"
						shellSeen++
					} else {
						seen = " shell=none"
					}
				}
				log("SHADOW journal-ntfy would-post topic=%s prio=%d title=%q%s (decisions=%d shell-agrees=%d)", d.Topic, d.Prio, d.Title, seen, shadowN, shellSeen)
				continue
			}
			if err := poster.Post(ctx, d); err != nil {
				log("journal-ntfy: post failed: %v", err)
			}
		}
	}
}

// Watchdog keeps systemd's WatchdogSec fed at half the interval.
func Watchdog(ctx context.Context) func() {
	iv := sdnotify.WatchdogInterval()
	last := time.Time{}
	var mu sync.Mutex
	return func() {
		mu.Lock()
		defer mu.Unlock()
		if iv > 0 && time.Since(last) >= iv {
			sdnotify.Send("WATCHDOG=1")
			last = time.Now()
		}
	}
}

func Ready(vm string) { sdnotify.Send(fmt.Sprintf("READY=1\nSTATUS=vm-pilotd %s", vm)) }

// RunTier1 ticks the tier-1 watchdog core. Shadow only: restarts are recorded, never performed.
func RunTier1(ctx context.Context, c Config, log Logger, wd func()) {
	d := dockerapi.New(c.DockerSock)
	iv := c.Tier1.IntervalSecs
	if iv == 0 {
		iv = 30
	}
	cfg := tier1.Config{Services: c.Tier1.Services, MaxRestarts: c.Tier1.MaxRestarts, ResetWindow: c.Tier1.ResetWindow}
	var st tier1.State
	t := time.NewTicker(time.Duration(iv) * time.Second)
	defer t.Stop()
	for {
		in := tier1.Input{Running: map[string]bool{}, DockerActive: d.Ping(ctx), Now: time.Now().Unix()}
		for _, s := range cfg.Services {
			in.Running[s] = in.DockerActive && d.Running(ctx, s)
		}
		if ev := st.Step(cfg, in); len(ev) > 0 {
			log("SHADOW tier1 docker=%v: %s", in.DockerActive, strings.Join(ev, "; "))
		}
		wd()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
