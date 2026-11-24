package psi

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const nixRel = "../../../modules/protection/load-shedder.nix"

// The shell's psi_avg10 is cut out of load-shedder.nix and run against fixture files.
func shellFn(t *testing.T) string {
	b, err := os.ReadFile(nixRel)
	if err != nil {
		t.Fatal(err)
	}
	s := string(b)
	i := strings.Index(s, "      psi_avg10() {")
	j := strings.Index(s[i:], "\n      }\n")
	fn := s[i : i+j+len("\n      }\n")]
	return strings.ReplaceAll(fn, "/proc/pressure/", "$PSID/")
}

func TestAvg10ParityWithShell(t *testing.T) {
	fn := shellFn(t)
	dir := t.TempDir()
	fixtures := map[string]string{
		"memory": "some avg10=36.52 avg60=20.00 avg300=5.00 total=123\nfull avg10=12.34 avg60=1.00 avg300=0.50 total=9\n",
		"cpu":    "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
		"io":     "some avg10=3.10 avg60=2.00 avg300=1.00 total=5\nfull avg10=99.99 avg60=1 avg300=1 total=1\n",
		"broken": "garbage\nsome avg60=1.0\n",
		"empty":  "",
	}
	for name, body := range fixtures {
		os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644)
	}
	cases := []struct{ res, kind string }{{"memory", "some"}, {"memory", "full"}, {"cpu", "some"}, {"cpu", "full"}, {"io", "full"}, {"io", "some"},
		{"broken", "some"}, {"empty", "some"}, {"missing", "some"}}
	for _, c := range cases {
		out, err := exec.Command("sh", "-c", "PSID="+dir+"\n"+fn+"\npsi_avg10 \"$1\" \"$2\"", "sh", c.res, c.kind).Output()
		if err != nil {
			t.Fatal(err)
		}
		want := strings.TrimSpace(string(out))
		if got := Read(dir, c.res, c.kind); got != want {
			t.Errorf("%s/%s: shell %q go %q", c.res, c.kind, want, got)
		}
	}
}

func TestIntPart(t *testing.T) {
	for in, want := range map[string]int{"36.52": 36, "0": 0, "": 0, "100.00": 100, "x": 0, "7": 7} {
		if got := IntPart(in); got != want {
			t.Errorf("%q: %d want %d", in, got, want)
		}
	}
}
