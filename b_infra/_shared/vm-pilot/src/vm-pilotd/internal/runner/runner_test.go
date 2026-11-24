package runner

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadAndDefaults(t *testing.T) {
	p := filepath.Join(t.TempDir(), "c.json")
	os.WriteFile(p, []byte(`{"vm":"oci-apps","shadow":true,"components":["journal-ntfy","shedder","petter","tier1"],
	 "shedder":{"Warn":35,"Crit":50,"Page":65,"Need":3,"DockerGraceSecs":180,"Tier1":["caddy"]},
	 "tier1":{"Services":["caddy"],"MaxRestarts":3,"ResetWindow":300}}`), 0o644)
	c, err := Load(p)
	if err != nil {
		t.Fatal(err)
	}
	if c.VM != "oci-apps" || !c.Shadow || len(c.Components) != 4 || c.Shedder.Crit != 50 || c.Shedder.IntervalSecs != 15 ||
		c.DockerSock != "/var/run/docker.sock" || c.Procfs != "/proc" || c.Tier1.MaxRestarts != 3 || c.Shedder.Tier1[0] != "caddy" {
		t.Fatalf("%+v", c)
	}
	if _, err := Load(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("missing config must error")
	}
}

func TestProcfsSamplers(t *testing.T) {
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, "meminfo"), []byte("MemTotal: 1000000 kB\nMemAvailable:  204800 kB\n"), 0o644)
	if got := MemAvailMB(d); got != 200 {
		t.Fatalf("MemAvailable: %d", got)
	}
	if got := MemAvailMB(filepath.Join(d, "nope")); got != 9999 {
		t.Fatalf("missing meminfo must read as 9999, got %d", got)
	}
	// dockerd started 100 s after boot, uptime now 160.5 s -> age 60 s (starttime is in clock ticks)
	os.MkdirAll(filepath.Join(d, "4242"), 0o755)
	stat := "4242 (dockerd) S 1 4242 4242 0 -1 4194560 100 0 0 0 5 5 0 0 20 0 10 0 10000 1000000 100 18446744073709551615"
	os.WriteFile(filepath.Join(d, "4242", "stat"), []byte(stat), 0o644)
	os.WriteFile(filepath.Join(d, "uptime"), []byte("160.50 300.00\n"), 0o644)
	pid := filepath.Join(d, "docker.pid")
	os.WriteFile(pid, []byte("4242\n"), 0o644)
	if got := DockerAge(d, pid); got != 60 {
		t.Fatalf("DockerAge=%d want 60", got)
	}
	if got := DockerAge(d, filepath.Join(d, "none")); got != 999999 {
		t.Fatalf("unknown age must be huge, got %d", got)
	}
	if p := DiskPct("/"); p < 0 || p > 100 {
		t.Fatalf("DiskPct=%d", p)
	}
}
