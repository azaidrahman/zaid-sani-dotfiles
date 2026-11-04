package refresh

import (
	"context"
	"fmt"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	"bbprs/internal/bb"
	"bbprs/internal/store"
)

// The warm run keeps the cache of the open lists warm, so that bb-prs shows
// the list and each PR at once, also on a first visit. A LaunchAgent runs it
// every 9 minutes on each Mac (bb-prs --warm). The screen marks the list
// that it opens (Paths.MarkUsed). The warm run refreshes each open list of
// the workspace that the screen used on this Mac, and no other list. One
// refresh costs about 50 requests to Bitbucket, because each inbox call
// searches many repos. So the warm run makes no call in these cases:
//
//   - The screen used no list of the workspace on this Mac in the last
//     warmUsed.
//   - The user is idle on this Mac for warmIdle or more: no key, mouse, or
//     terminal input. The user works on the other Mac, or not at all.
//   - A warm run had a rate limit less than warmBackoff ago.
//   - Another refresh holds the lock of a list of the workspace.
//
// If each list is younger than warmFresh, the warm run does not refresh the
// lists. It only prefetches their PRs. With the cache rule, a prefetch in
// which no PR changed makes no call.
const (
	warmUsed    = 8 * time.Hour
	warmIdle    = 15 * time.Minute
	warmBackoff = 30 * time.Minute
	warmFresh   = 5 * time.Minute
)

// Warm runs one warm run of the open lists of the workspace. It uses no
// checkout, so it runs no git fetch. idle returns the time since the last
// input of the user on this Mac. If idle does not know the time, the run
// goes on. When a twg call fails with the rate limit, Warm writes the marker
// file (Paths.WarmBackoff), and the next runs make no call for warmBackoff.
// Warm returns one line that tells what it did, and why. ok is false when
// the run failed.
func Warm(ctx context.Context, env Env, idle func(context.Context) (time.Duration, bool)) (line string, ok bool) {
	now := env.now()
	targets := usedLists(env, now)
	if len(targets) == 0 {
		return "not used here in " + bb.Age(warmUsed) + ": no calls", true
	}
	if d, known := idle(ctx); known && d >= warmIdle {
		return "idle for " + bb.Age(d) + ": no calls", true
	}
	marker := env.Paths.WarmBackoff()
	if info, err := os.Stat(marker); err == nil && now.Sub(info.ModTime()) < warmBackoff {
		at := info.ModTime()
		return fmt.Sprintf("backoff after the rate limit at %s: no calls until %s",
			at.Local().Format("15:04"), at.Add(warmBackoff).Local().Format("15:04")), true
	}

	// The inbox calls load the PRs of each open list of the workspace. Thus
	// the refresh of another list makes the same calls, and the run waits
	// for the next time.
	env.Repo, env.Dir = "", ""
	paths := make([]string, len(targets))
	for i, prompt := range targets {
		paths[i] = env.Paths.ListFile(prompt, "open")
	}
	busy := "busy: another refresh holds the lock: no calls"
	for _, l := range env.Paths.ListFiles(env.WS, "open") {
		if !slices.Contains(paths, l) && store.Held(l, staleLock) {
			return busy, true
		}
	}
	var releases []func()
	release := func() {
		for _, r := range releases {
			r()
		}
		releases = nil
	}
	defer release()
	for _, path := range paths {
		r, locked, err := store.TryLock(path, staleLock)
		if err != nil {
			return "failed: " + firstLine(err.Error()), false
		}
		if !locked {
			return busy, true
		}
		releases = append(releases, r)
	}

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

	lists := count(len(targets), "list") + " (" + strings.Join(targets, ", ") + ")"
	var prs []bb.PR
	var what, failed string
	if age, young := oldest(paths, now); young {
		for _, path := range paths {
			c, err := store.LoadList(path)
			if err != nil {
				return "failed: " + firstLine(err.Error()), false
			}
			prs = append(prs, c.PRs...)
		}
		prs = union(prs)
		what = fmt.Sprintf("fresh %s, %s old: %s", lists, bb.Age(age), count(len(prs), "PR"))
	} else {
		var errs []string
		var err error
		if prs, errs, err = saveAll(ctx, env, targets, paths); err != nil {
			return "failed: " + firstLine(err.Error()), false
		}
		if text, ok := limited(); ok {
			return text, false
		}
		// A list that fails, for example the list of a repo that is gone,
		// must not stop the prefetch of the PRs of the other lists.
		if len(errs) > 0 {
			failed = ", failed: " + firstLine(errs[0])
		}
		what = "refreshed " + lists + ": " + count(len(prs), "PR")
	}
	release()

	env.Paths.PruneOldPreviews(previewKeep)
	n := Prefetch(ctx, env, prs, 4)
	if text, ok := limited(); ok {
		return what + ", " + text, false
	}
	return what + ", prefetched " + count(n, "view") + failed, failed == ""
}

// usedLists returns the prompts of the open lists of the workspace that the
// screen used on this Mac in the last warmUsed, sorted. A prompt is the
// workspace, or a repo of the workspace.
func usedLists(env Env, now time.Time) []string {
	var out []string
	for _, p := range env.Paths.UsedSince(now.Add(-warmUsed)) {
		if p == env.WS || strings.HasPrefix(p, env.WS+"/") {
			out = append(out, p)
		}
	}
	return out
}

// oldest returns the age of the oldest list file of paths. The modification
// time of a list file is the time of its last refresh, also of a refresh that
// failed. young is false if a file is missing, or if a file is warmFresh old
// or older.
func oldest(paths []string, now time.Time) (age time.Duration, young bool) {
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil {
			return 0, false
		}
		age = max(age, now.Sub(info.ModTime()))
	}
	return age, age < warmFresh
}

// saveAll refreshes the open list of each prompt at the same time, and saves
// it in its file of paths. A memo runs each distinct twg call one time, so
// the lists share the inbox calls. saveAll returns the PRs of all the lists,
// each PR one time, and the error lines of all the lists.
func saveAll(ctx context.Context, env Env, prompts, paths []string) ([]bb.PR, []string, error) {
	call := newMemo(env.Twg.JSON).call
	type result struct {
		prs  []bb.PR
		errs []string
		err  error
	}
	results := make([]result, len(prompts))
	var wg sync.WaitGroup
	for i, prompt := range prompts {
		wg.Add(1)
		go func() {
			defer wg.Done()
			e := env
			e.Prompt = prompt
			if prompt != env.WS {
				e.Repo = prompt
			}
			r := &results[i]
			r.prs, r.errs, r.err = save(ctx, e, call, "open", paths[i])
		}()
	}
	wg.Wait()
	var prs []bb.PR
	var errs []string
	for _, r := range results {
		if r.err != nil {
			return nil, nil, r.err
		}
		prs = append(prs, r.prs...)
		errs = append(errs, r.errs...)
	}
	return union(prs), errs, nil
}

// memo runs each distinct call one time. A call with the same arguments
// waits for the first call and gets its result, also when the two calls
// start at the same time.
type memo struct {
	run   callFunc
	mu    sync.Mutex
	calls map[string]*memoCall
}

// memoCall is the result of one distinct call of a memo.
type memoCall struct {
	once sync.Once
	out  []byte
	err  error
}

func newMemo(run callFunc) *memo { return &memo{run: run, calls: map[string]*memoCall{}} }

// call is a callFunc. The key of a call is its arguments.
func (m *memo) call(ctx context.Context, args ...string) ([]byte, error) {
	key := strings.Join(args, "\x00")
	m.mu.Lock()
	c, ok := m.calls[key]
	if !ok {
		c = &memoCall{}
		m.calls[key] = c
	}
	m.mu.Unlock()
	c.once.Do(func() { c.out, c.err = m.run(ctx, args...) })
	return c.out, c.err
}

// union returns the first copy of each PR of prs, in the order of prs.
func union(prs []bb.PR) []bb.PR {
	seen := map[string]bool{}
	var out []bb.PR
	for _, p := range prs {
		if !seen[p.Key()] {
			seen[p.Key()] = true
			out = append(out, p)
		}
	}
	return out
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
