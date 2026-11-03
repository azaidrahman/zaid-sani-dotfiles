package refresh

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"bbprs/internal/bb"
	"bbprs/internal/store"
)

// The warm run keeps the cache of the open list warm, so that bb-prs shows
// each PR at once, also on a first visit. A LaunchAgent runs it on a timer on
// each Mac (bb-prs --warm). One refresh of the open list costs about 50
// requests to Bitbucket, because each inbox call searches many repos. So the
// warm run makes no call in these cases:
//
//   - The Mac is idle for warmIdle or more. The user works on the other Mac,
//     or not at all.
//   - A warm run had a rate limit less than warmBackoff ago.
//   - Another refresh holds the lock of the list.
//
// If the list is younger than warmFresh, the warm run does not refresh it. It
// only prefetches the PRs of the list. With the cache rule, a prefetch in
// which no PR changed makes no call.
const (
	warmIdle    = 15 * time.Minute
	warmBackoff = 30 * time.Minute
	warmFresh   = 10 * time.Minute
)

// Warm runs one warm run of the open list of the workspace. It uses no repo:
// only the inbox calls load the list. idle returns the time since the last
// key or mouse event on this Mac. If idle does not know the time, the run
// goes on. When a twg call fails with the rate limit, Warm writes the marker
// file (Paths.WarmBackoff), and the next runs make no call for warmBackoff.
// Warm returns one line that tells what it did, and why. ok is false when
// the run failed.
func Warm(ctx context.Context, env Env, idle func(context.Context) (time.Duration, bool)) (line string, ok bool) {
	now := env.now()
	if d, known := idle(ctx); known && d >= warmIdle {
		return "idle for " + bb.Age(d) + ": no calls", true
	}
	marker := env.Paths.WarmBackoff()
	if info, err := os.Stat(marker); err == nil && now.Sub(info.ModTime()) < warmBackoff {
		at := info.ModTime()
		return fmt.Sprintf("backoff after the rate limit at %s: no calls until %s",
			at.Local().Format("15:04"), at.Add(warmBackoff).Local().Format("15:04")), true
	}

	// The run refreshes the list of the workspace. When bb-prs runs in a
	// repo, it uses the list of that repo, with the same inbox calls. Thus the
	// run checks the lock and the age of each open list of the workspace.
	env.Repo, env.Dir, env.Prompt = "", "", env.WS
	path := env.Paths.ListFile(env.Prompt, "open")
	lists := env.Paths.ListFiles(env.WS, "open")
	busy := "busy: another refresh holds the lock: no calls"
	for _, l := range lists {
		if l != path && store.Held(l, staleLock) {
			return busy, true
		}
	}
	release, locked, err := store.TryLock(path, staleLock)
	if err != nil {
		return "failed: " + firstLine(err.Error()), false
	}
	if !locked {
		return busy, true
	}
	released := false
	defer func() {
		if !released {
			release()
		}
	}()

	// At the first rate limit, stop each call, and start no other call.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	var mu sync.Mutex
	limit := ""
	r := *env.Twg
	r.Failed = func(err error) {
		if !rateLimited(err) {
			return
		}
		mu.Lock()
		if limit == "" {
			limit = firstLine(err.Error())
		}
		mu.Unlock()
		cancel()
	}
	env.Twg = &r
	limited := func() (string, bool) {
		mu.Lock()
		defer mu.Unlock()
		if limit == "" {
			return "", false
		}
		_ = store.WriteAtomic(marker, []byte(now.Format(time.RFC3339)+"\n"))
		return "failed: rate limit, no calls for " + bb.Age(warmBackoff) + ": " + limit, true
	}

	// The newest open list of the workspace. Its modification time is the
	// time of its last refresh, also of a refresh that failed.
	newest, at := "", time.Time{}
	for _, l := range lists {
		if info, err := os.Stat(l); err == nil && info.ModTime().After(at) {
			newest, at = l, info.ModTime()
		}
	}
	var prs []bb.PR
	var what string
	if newest != "" && now.Sub(at) < warmFresh {
		c, err := store.LoadList(newest)
		if err != nil {
			return "failed: " + firstLine(err.Error()), false
		}
		prs = c.PRs
		what = fmt.Sprintf("fresh list (%s old): %s", bb.Age(now.Sub(at)), count(len(prs), "PR"))
	} else {
		var errs []string
		if prs, errs, err = save(ctx, env, "open", path); err != nil {
			return "failed: " + firstLine(err.Error()), false
		}
		if text, ok := limited(); ok {
			return text, false
		}
		if len(errs) > 0 {
			return "failed: " + firstLine(errs[0]), false
		}
		what = "refreshed the open list: " + count(len(prs), "PR")
	}
	release()
	released = true

	env.Paths.PruneOldPreviews(previewKeep)
	n := Prefetch(ctx, env, prs, 4)
	if text, ok := limited(); ok {
		return what + ", " + text, false
	}
	return what + ", prefetched " + count(n, "view"), true
}

// count returns "1 <noun>" or "<n> <noun>s".
func count(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return fmt.Sprintf("%d %ss", n, noun)
}

// firstLine returns the first line of s, without spaces at the ends.
func firstLine(s string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(s), "\n")
	return strings.TrimSpace(line)
}
