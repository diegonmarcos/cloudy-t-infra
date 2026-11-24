// Package sdnotify speaks the minimal systemd notify protocol (READY, WATCHDOG, STATUS).
package sdnotify

import (
	"net"
	"os"
	"strconv"
	"time"
)

// Send writes state to $NOTIFY_SOCKET; it is a no-op (false) outside systemd.
func Send(state string) bool {
	path := os.Getenv("NOTIFY_SOCKET")
	if path == "" {
		return false
	}
	if path[0] == '@' {
		path = "\x00" + path[1:]
	}
	c, err := net.DialUnix("unixgram", nil, &net.UnixAddr{Name: path, Net: "unixgram"})
	if err != nil {
		return false
	}
	defer c.Close()
	_, err = c.Write([]byte(state))
	return err == nil
}

// WatchdogInterval is half of WATCHDOG_USEC (systemd's recommendation); 0 when no watchdog.
func WatchdogInterval() time.Duration {
	us, err := strconv.ParseInt(os.Getenv("WATCHDOG_USEC"), 10, 64)
	if err != nil || us <= 0 {
		return 0
	}
	return time.Duration(us) * time.Microsecond / 2
}
