package browser

import (
	"syscall"
	"time"
)

// accessTime returns the access time in the stat data of a file.
func accessTime(st *syscall.Stat_t) time.Time { return time.Unix(st.Atimespec.Unix()) }
