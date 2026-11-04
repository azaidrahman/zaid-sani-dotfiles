//go:build !darwin

package browser

import (
	"syscall"
	"time"
)

// accessTime returns the zero time. bb-prs runs on macOS only. On another
// system, TTYIdle does not know the time, and this file keeps the build
// working.
func accessTime(*syscall.Stat_t) time.Time { return time.Time{} }
