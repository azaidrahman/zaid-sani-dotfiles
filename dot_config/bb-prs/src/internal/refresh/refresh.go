// Package refresh loads the lists of PRs in the background. It also makes the
// preview files, and it starts the detached child process that does this work.
package refresh

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"sync"
	"syscall"
	"time"

	"bbprs/internal/bb"
	"bbprs/internal/gitops"
	"bbprs/internal/store"
	"bbprs/internal/twg"
)

const (
	autoMaxAge = 3 * time.Minute
	staleLock  = 2 * time.Minute
	lockWait   = 120 * time.Second
	lockPoll   = 100 * time.Millisecond
	// previewKeep is the age at which a preview file goes away. Pinned files
	// of a PR that does not change stay for a week, so that the prefetch does
	// not load them again each day.
	previewKeep  = 7 * 24 * time.Hour
	rateLimitTip = " (Bitbucket rate limit: wait some minutes, then r)"
)

// Env holds what each function of this package needs.
type Env struct {
	Paths store.Paths
	// Repo is "<workspace>/<repo>" of the current directory. Dir is the root
	// of that checkout. Both are empty outside a Bitbucket repo.
	Repo, WS, Dir string
	// Prompt names the list file. It is Repo, or WS if Repo is empty.
	Prompt string
	Twg    *twg.Runner
	// Now gives the current time. If it is nil, Run uses time.Now.
	Now func() time.Time
}

func (e Env) now() time.Time {
	if e.Now != nil {
		return e.Now()
	}
	return time.Now()
}

// Call is one twg call that loads a source of a list.
type Call struct {
	// Name tells the source: query, reviewer, author, merged, or declined.
	Name string
	// What is the text for an error message.
	What string
	// Args are the arguments of twg. They do not hold "-o json".
	Args []string
}

// Calls returns the twg calls that load the list "open" or "closed". Run
// makes exactly these calls. Without a repo, the calls for the repo are not in
// the result.
func Calls(list, repo, ws string) []Call {
	var calls []Call
	query := func(name, what, state string, n string) {
		args := []string{"bitbucket", "pull-requests", "query", "--repo", repo}
		if state != "" {
			args = append(args, "--state", state)
		}
		calls = append(calls, Call{Name: name, What: what + " of " + repo, Args: append(args, "-n", n)})
	}
	inbox := func(name, what string, extra ...string) {
		args := append([]string{"bitbucket", "inbox", "--workspace", ws}, extra...)
		calls = append(calls, Call{Name: name, What: what, Args: args})
	}
	if list == "closed" {
		if repo != "" {
			query("merged", "merged PRs", "MERGED", "25")
			query("declined", "declined PRs", "DECLINED", "15")
		}
		inbox("author", "your merged PRs", "--role", "author", "--state", "MERGED", "-n", "15")
		return calls
	}
	if repo != "" {
		query("query", "open PRs", "", "50")
	}
	inbox("reviewer", "review inbox", "-n", "50")
	inbox("author", "your open PRs", "--role", "author", "-n", "50")
	return calls
}

// Run refreshes one list and saves it. It is the background refresh.
//
// If auto is true and the list file is new enough, Run does nothing. If
// another refresh holds the lock, Run waits until the lock goes away, and then
// returns. A source that fails does not fail Run. Its message goes to the
// Errors of the list file. Then the old PRs stay, if there are any.
func Run(ctx context.Context, env Env, list string, auto bool) error {
	path := env.Paths.ListFile(env.Prompt, list)
	if auto && store.Fresh(path, autoMaxAge) {
		return nil
	}
	release, ok, err := store.TryLock(path, staleLock)
	if err != nil {
		return err
	}
	if !ok {
		waitForLock(ctx, path)
		return nil
	}
	released := false
	defer func() {
		if !released {
			release()
		}
	}()

	prs, errs, err := save(ctx, env, list, path)
	if err != nil {
		return err
	}
	release()
	released = true

	env.Paths.PruneOldPreviews(previewKeep)
	// Only the open list gets previews in advance. The closed list is long,
	// and you look at few of its PRs.
	if list == "open" && len(errs) == 0 {
		Prefetch(ctx, env, prs, 4)
	}
	return nil
}

// save loads the list and saves it in the file path. The caller holds the
// lock of the file. It returns the PRs that it loaded, and one error line for
// each source that failed. If a source fails and the file has PRs, the file
// keeps the old PRs.
func save(ctx context.Context, env Env, list, path string) ([]bb.PR, []string, error) {
	prs, errs := load(ctx, env, list)

	old, _ := store.LoadList(path)
	next := store.ListCache{PRs: prs, Errors: errs, Saved: env.now()}
	if len(errs) > 0 && len(old.PRs) > 0 {
		// Keep the old PRs, and keep Saved as the age of that data. An old
		// file without Saved gives its time from the modification time.
		saved := old.Saved
		if saved.IsZero() {
			if info, err := os.Stat(path); err == nil {
				saved = info.ModTime()
			}
		}
		next.PRs = old.PRs
		next.Saved = saved
		if !saved.IsZero() {
			next.Errors = append(errs, "showing the list from "+saved.Local().Format("15:04"))
		}
	}
	if err := store.SaveList(path, next); err != nil {
		return nil, nil, err
	}
	return prs, errs, nil
}

// waitForLock waits until the lock of the list goes away. It stops after 120
// seconds, or when ctx ends.
func waitForLock(ctx context.Context, path string) {
	deadline := time.NewTimer(lockWait)
	defer deadline.Stop()
	tick := time.NewTicker(lockPoll)
	defer tick.Stop()
	for store.Locked(path) {
		select {
		case <-tick.C:
		case <-deadline.C:
			return
		case <-ctx.Done():
			return
		}
	}
}

// load runs the calls of the list at the same time. For the open list in a
// checkout, it also runs git fetch. It returns the merged PRs and one error
// line for each failed source.
func load(ctx context.Context, env Env, list string) ([]bb.PR, []string) {
	calls := Calls(list, env.Repo, env.WS)
	out := make([][]byte, len(calls))
	fails := make([]error, len(calls))
	var wg sync.WaitGroup
	for i, c := range calls {
		wg.Add(1)
		go func() {
			defer wg.Done()
			out[i], fails[i] = env.Twg.JSON(ctx, c.Args...)
		}()
	}
	// Only the open list shows behind counts, so only the open list fetches.
	if list == "open" && env.Dir != "" {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// A failed fetch only makes the behind counts old.
			_ = gitops.Git{Dir: env.Dir}.Fetch(ctx)
		}()
	}
	wg.Wait()

	var errs []string
	src := map[string][]byte{}
	for i, c := range calls {
		if fails[i] != nil {
			errs = append(errs, errorLine(c.What, fails[i]))
			continue
		}
		src[c.Name] = out[i]
	}
	var prs []bb.PR
	var err error
	if list == "closed" {
		prs, err = bb.MergeClosed(src["merged"], src["declined"], src["author"])
	} else {
		prs, err = bb.MergeOpen(src["query"], src["reviewer"], src["author"], env.Repo)
	}
	if err != nil {
		errs = append(errs, errorLine("PR list", err))
	}
	return prs, errs
}

// errorLine makes the text of an error of one source.
func errorLine(what string, err error) string {
	line := "could not load the " + what + ": " + err.Error()
	if rateLimited(err) {
		line += rateLimitTip
	}
	return line
}

// rateLimitRe finds the HTTP status 429 as a whole word, so that a PR number
// such as #1429 or a hash does not match.
var rateLimitRe = regexp.MustCompile(`\b429\b`)

// rateLimited is true when err is the rate limit of Bitbucket: the HTTP
// status 429 in the message of twg.
func rateLimited(err error) bool {
	return err != nil && rateLimitRe.MatchString(err.Error())
}

// Spawn starts "self args..." in dir as a detached process. The process has
// its own session, and its input and output go to /dev/null. It lives on when
// the terminal of the caller closes.
func Spawn(self, dir string, args ...string) error {
	cmd := exec.Command(self, args...)
	cmd.Dir = dir
	// With nil input and output, exec uses /dev/null.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start %s: %w", self, err)
	}
	// Wait for the exit in the background, so that the child does not stay
	// as a zombie while the screen runs.
	go cmd.Wait()
	return nil
}
