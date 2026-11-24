// vm-pilotd: one static host daemon replacing the shell daemons of vm-pilot (ticket #1876):
// journal-ntfy, load shedder, watchdog-petter. Shadow mode (the default) records decisions
// next to the running shell units and acts on nothing.
//
//	vm-pilotd -config /etc/vm-pilotd.json
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"vm-pilotd/internal/journalntfy"
	"vm-pilotd/internal/runner"
)

func main() {
	cfgPath := flag.String("config", "/etc/vm-pilotd.json", "config file")
	flag.Parse()
	c, err := runner.Load(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		os.Exit(2)
	}
	lg := log.New(os.Stdout, "vm-pilotd ", 0)
	logf := func(f string, a ...any) { lg.Printf(f, a...) }
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if !c.Shadow {
		logf("live mode requested: only journal-ntfy has a live path; shedder and petter stay shadow until their switch-over")
	}
	wd := runner.Watchdog(ctx)
	var wg sync.WaitGroup
	run := func(f func()) { wg.Add(1); go func() { defer wg.Done(); f() }() }
	for _, comp := range c.Components {
		switch comp {
		case "journal-ntfy":
			var poster *journalntfy.Poster
			if !c.Shadow {
				poster = &journalntfy.Poster{WGBase: c.JournalNtfy.WGBase, PublicBase: c.JournalNtfy.PublicBase, VM: c.VM, Client: &http.Client{}}
			}
			run(func() { runner.RunJournalNtfy(ctx, c, logf, poster) })
		case "shedder":
			cc := c
			cc.Shadow = true
			run(func() { runner.RunShedder(ctx, cc, logf, wd) })
		case "petter":
			cc := c
			cc.Shadow = true
			run(func() { runner.RunPetter(ctx, cc, logf, wd) })
		default:
			logf("unknown component %q ignored", comp)
		}
	}
	runner.Ready(c.VM)
	logf("started vm=%s shadow=%v components=%v", c.VM, c.Shadow, c.Components)
	// keep the systemd watchdog fed even when every component is between ticks
	t := time.NewTicker(10 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			wg.Wait()
			return
		case <-t.C:
			wd()
		}
	}
}
