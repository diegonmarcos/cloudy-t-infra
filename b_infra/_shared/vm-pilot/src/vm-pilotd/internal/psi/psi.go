// Package psi reads kernel Pressure Stall Information (/proc/pressure/*).
package psi

import (
	"os"
	"strconv"
	"strings"
)

// Avg10 returns the avg10 value of the line starting with kind ("some" or "full") in the
// content of a /proc/pressure file; ok=false when the line or field is absent. Same
// extraction as the shell awk: split on "avg10=", take the first word after it.
func Avg10(content, kind string) (float64, string, bool) {
	for _, line := range strings.Split(content, "\n") {
		if !strings.HasPrefix(line, kind) {
			continue
		}
		i := strings.Index(line, "avg10=")
		if i < 0 {
			return 0, "", true // awk prints an empty field for the first matching line and exits
		}
		f := strings.Fields(line[i+len("avg10="):])
		if len(f) == 0 {
			return 0, "", true
		}
		v, err := strconv.ParseFloat(f[0], 64)
		if err != nil {
			return 0, f[0], true
		}
		return v, f[0], true
	}
	return 0, "", false
}

// IntPart is the shell's ${V%%.*} with an empty result becoming 0.
func IntPart(raw string) int {
	if i := strings.IndexByte(raw, '.'); i >= 0 {
		raw = raw[:i]
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0
	}
	return n
}

// Read reads /proc/pressure/<res> (or dir/<res>) and returns the raw avg10 string, "0" when
// unavailable, exactly as the shell's psi_avg10 does.
func Read(dir, res, kind string) string {
	b, err := os.ReadFile(dir + "/" + res)
	if err != nil {
		return "0"
	}
	_, raw, ok := Avg10(string(b), kind)
	if !ok {
		return ""
	}
	return raw
}
