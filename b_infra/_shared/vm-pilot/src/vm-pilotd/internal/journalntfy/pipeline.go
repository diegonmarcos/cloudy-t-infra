package journalntfy

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// Entry is the part of `journalctl -o json` the pipeline needs.
type Entry struct {
	Unit     string
	Ident    string
	Priority int
	Message  string
	TS       time.Time
	PID      string
}

type rawEntry struct {
	Unit     string          `json:"_SYSTEMD_UNIT"`
	Ident    string          `json:"SYSLOG_IDENTIFIER"`
	Priority string          `json:"PRIORITY"`
	Message  json.RawMessage `json:"MESSAGE"`
	RealTS   string          `json:"__REALTIME_TIMESTAMP"`
	PID      string          `json:"_PID"`
}

// ParseEntry decodes one JSON line. MESSAGE may be a string or, for binary data, a byte array.
func ParseEntry(line []byte) (Entry, error) {
	var r rawEntry
	if err := json.Unmarshal(line, &r); err != nil {
		return Entry{}, err
	}
	e := Entry{Unit: r.Unit, Ident: r.Ident, PID: r.PID, Priority: 6}
	if p, err := strconv.Atoi(r.Priority); err == nil {
		e.Priority = p
	}
	var s string
	if json.Unmarshal(r.Message, &s) == nil {
		e.Message = s
	} else {
		var b []byte
		if json.Unmarshal(r.Message, &b) == nil {
			e.Message = string(b)
		} else {
			var arr []int
			if json.Unmarshal(r.Message, &arr) == nil {
				bs := make([]byte, len(arr))
				for i, v := range arr {
					bs[i] = byte(v)
				}
				e.Message = string(bs)
			}
		}
	}
	if us, err := strconv.ParseInt(r.RealTS, 10, 64); err == nil {
		e.TS = time.UnixMicro(us)
	}
	return e, nil
}

// Line renders the entry like `journalctl -o short-precise --no-hostname`.
func (e Entry) Line() string {
	id := e.Ident
	if id == "" {
		id = strings.TrimSuffix(e.Unit, ".service")
	}
	pid := ""
	if e.PID != "" {
		pid = "[" + e.PID + "]"
	}
	return fmt.Sprintf("%s %s%s: %s", e.TS.Format("Jan 02 15:04:05.000000"), id, pid, e.Message)
}

// UnitName is the unit the shell would have derived: the entry's own unit when journald
// supplied one (authoritative), else the awk scan of the rendered line.
func (e Entry) UnitName() string {
	if u := strings.TrimSuffix(e.Unit, ".service"); u != "" {
		return u
	}
	return ExtractUnit(e.Line())
}

// Decision is one message that would be (or was) published.
type Decision struct {
	Unit, Sev, Topic string
	Prio             int
	Title, Body      string
}

// Pipeline turns entries into rate-limited decisions.
type Pipeline struct {
	VM      string
	Limiter *Limiter
}

// Handle returns the decision for the entry, ok=false when rate limited.
func (p *Pipeline) Handle(e Entry) (Decision, bool) {
	unit := e.UnitName()
	sev := SevName(e.Priority)
	prio, topic := Route(unit, sev)
	if !p.Limiter.Allow(unit, topic) {
		return Decision{}, false
	}
	return Decision{Unit: unit, Sev: sev, Topic: topic, Prio: prio,
		Title: fmt.Sprintf("[%s] %s (%s)", p.VM, unit, sev), Body: e.Line()}, true
}

// Poster publishes to ntfy: WG-direct base first, public edge second, 5 s each (as the shell).
type Poster struct {
	WGBase, PublicBase, VM string
	Client                 *http.Client
}

func (p *Poster) Post(ctx context.Context, d Decision) error {
	var last error
	for _, base := range []string{p.WGBase, p.PublicBase} {
		if base == "" {
			continue
		}
		cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
		req, _ := http.NewRequestWithContext(cctx, "POST", base+"/"+d.Topic, strings.NewReader(d.Body))
		req.Header.Set("Title", d.Title)
		req.Header.Set("Priority", strconv.Itoa(d.Prio))
		req.Header.Set("Tags", "journal,"+p.VM)
		resp, err := p.Client.Do(req)
		cancel()
		if err == nil {
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				return nil
			}
			err = fmt.Errorf("%s: HTTP %d", base, resp.StatusCode)
		}
		last = err
	}
	return last
}

// Follow runs ONE long-lived `journalctl -p warning -f -o json` child and sends every entry
// on out until ctx ends. The shell forked a pipeline with awk/cut/date/curl per line.
func Follow(ctx context.Context, bin string, out chan<- Entry, logf func(string, ...any)) error {
	cmd := exec.CommandContext(ctx, bin, "-p", "warning", "-f", "-n", "0", "--no-hostname", "-o", "json")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 1<<20), 8<<20)
	for sc.Scan() {
		e, err := ParseEntry(sc.Bytes())
		if err != nil {
			logf("journal-ntfy: skip unparsable entry: %v", err)
			continue
		}
		select {
		case out <- e:
		case <-ctx.Done():
		}
	}
	return cmd.Wait()
}
