package refresh

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"bbprs/internal/bb"
)

// The cache rule. The preview files hold two kinds of data:
//
//   - Pinned data changes only when the PR changes. The name of its file holds
//     the update time of the PR, so a file of the same update is good at any
//     age. The diffstat, the commits, and the diff are pinned. Each view of a
//     closed PR is pinned.
//   - Live data changes also when the PR does not change: the merge checks
//     (the checks part of the details bundle), and the activity of an open PR.
//     A copy of live data is fresh for LiveFor.
//   - The PR itself (the pr part of the details bundle) is between the two.
//     Bitbucket does not change the update time of the PR for each change of
//     the PR. Thus an update of the details also gets the PR when its pr part
//     is older than PRPartFor.
//
// Live and Expired hold this rule. Cached, Fetch, and the UI use them.

// LiveFor is the time that a copy of live data stays fresh.
const LiveFor = time.Minute

// PRPartFor is the time that the pr part of a details bundle stays good.
const PRPartFor = 15 * time.Minute

// State tells how good the copy of a view on the disk is.
type State int

const (
	// Missing means that there is no copy of the view of the PR.
	Missing State = iota
	// Fresh means that the copy needs no update.
	Fresh
	// Stale means that the copy can show, but it needs an update: it is live
	// data older than LiveFor, or it is of an older update of the PR.
	Stale
)

// Live is true when the view of pr can change without an update of the PR.
func Live(pr bb.PR, view string) bool {
	return pr.IsOpen() && (view == "details" || view == "activity")
}

// Expired is true when a copy of the view of pr for the same update, saved at
// saved, needs an update at the time now.
func Expired(pr bb.PR, view string, saved, now time.Time) bool {
	return Live(pr, view) && now.Sub(saved) >= LiveFor
}

// Cached reads the copy of one view of pr from the disk. It does not call
// twg. A file of the same update is fresh, or stale if it holds expired live
// data. Saved is the modification time of that file. If there is no such
// file, the newest file of an older update of the PR is stale. Else the state
// is Missing.
func Cached(env Env, pr bb.PR, view string) (raw []byte, state State, saved time.Time) {
	path := env.Paths.PreviewFile(pr.Repo, pr.ID, pr.UpdatedRaw, view)
	if info, err := os.Stat(path); err == nil {
		if data, err := os.ReadFile(path); err == nil {
			if Expired(pr, view, info.ModTime(), env.now()) {
				return data, Stale, info.ModTime()
			}
			return data, Fresh, info.ModTime()
		}
	}
	if data, ok := env.Paths.FindPreview(pr.Repo, pr.ID, view); ok {
		return data, Stale, time.Time{}
	}
	return nil, Missing, time.Time{}
}

// LoadView returns the data of one view of a PR for a reader that does not
// use live data. The AI review uses it: it needs the description and the
// diff, not the merge checks. A copy of the same update on the disk serves at
// any age, so no failed update can fail the reader. If there is no such
// copy, LoadView loads the view with Fetch. A bundle with failed parts is
// good for the reader, as the merge checks are.
func LoadView(ctx context.Context, env Env, pr bb.PR, view string) ([]byte, error) {
	if data, err := os.ReadFile(env.Paths.PreviewFile(pr.Repo, pr.ID, pr.UpdatedRaw, view)); err == nil {
		return data, nil
	}
	raw, err := Fetch(ctx, env, pr, view)
	if partial := (*PartialError)(nil); errors.As(err, &partial) {
		return raw, nil
	}
	return raw, err
}

// Fetch loads one view of pr with twg, and saves it: details, activity,
// commits, or diff. If twg fails, Fetch returns the error and does not change
// the file. Thus a failed update never replaces a good copy. If an action
// dropped the previews of the PR after the start of Fetch (store.DropPreviews),
// the data can be from before the action, so Fetch does not save it.
//
// The details file holds {"pr":…,"checks":…,"diffstat":…,"pr_at":…}. If a
// bundle of the same update is on the disk, Fetch updates its live parts (see
// fetchDetails). Else Fetch loads the whole bundle (see fetchBundle). If parts
// of a whole bundle fail, Fetch returns the bundle and a *PartialError. The
// diff file holds the text of the diff of all the files of the PR, not JSON.
func Fetch(ctx context.Context, env Env, pr bb.PR, view string) ([]byte, error) {
	start := time.Now()
	path := env.Paths.PreviewFile(pr.Repo, pr.ID, pr.UpdatedRaw, view)
	id := strconv.Itoa(pr.ID)
	var raw []byte
	var err error
	var failed []string
	switch view {
	case "details":
		raw, failed, err = fetchDetails(ctx, env, pr, path)
	case "activity", "commits":
		raw, err = env.Twg.JSON(ctx, "bitbucket", "pull-requests", view, id, "--repo", pr.Repo, "-n", "100")
	case "diff":
		raw, err = env.Twg.Text(ctx, "bitbucket", "pull-requests", "diff", id, "--repo", pr.Repo)
	default:
		err = fmt.Errorf("unknown view %q", view)
	}
	switch {
	case err != nil:
		return nil, err
	case len(failed) > 0:
		return raw, &PartialError{Parts: failed}
	case !env.Paths.DroppedAt(pr.Repo, pr.ID).Before(start):
		return raw, nil // an action dropped the previews during the fetch
	}
	if err := writeFile(path, raw); err != nil {
		return nil, err
	}
	return raw, nil
}

// prefetchViews are the views that Prefetch makes for each PR.
var prefetchViews = []string{"details", "commits", "diff", "activity"}

// Prefetch makes each view of each PR that has no file for the update of the
// PR. A file of any age is good: Prefetch does not update live data. The UI
// does that when the user opens the PR. Thus a refresh in which no PR changed
// makes no call. Prefetch makes at most workers views at the same time. It
// ignores a failure: the UI shows it when the user opens the PR. A bundle
// with a failed part is not saved, so the next refresh loads it again. When
// ctx ends, no new view starts. Prefetch returns the number of views that it
// started.
func Prefetch(ctx context.Context, env Env, prs []bb.PR, workers int) int {
	if workers < 1 {
		workers = 1
	}
	slots := make(chan struct{}, workers)
	var wg sync.WaitGroup
	started := 0
	defer wg.Wait()
	for _, pr := range prs {
		for _, view := range prefetchViews {
			if _, err := os.Stat(env.Paths.PreviewFile(pr.Repo, pr.ID, pr.UpdatedRaw, view)); err == nil {
				continue
			}
			select {
			case slots <- struct{}{}:
			case <-ctx.Done():
				return started
			}
			// A view that ended can end ctx before it frees its slot.
			if ctx.Err() != nil {
				return started
			}
			started++
			wg.Add(1)
			go func() {
				defer wg.Done()
				defer func() { <-slots }()
				_, _ = Fetch(ctx, env, pr, view)
			}()
		}
	}
	return started
}

// SourceRepo returns the full name of the repo of the source branch of pr.
// The source repo of a PR never changes. Thus SourceRepo first reads a details
// preview of the PR, of any update and of any age. If there is none, or if
// it does not tell the repo, SourceRepo gets the PR from twg one time.
func SourceRepo(ctx context.Context, env Env, pr bb.PR) (string, error) {
	if data, ok := env.Paths.FindPreview(pr.Repo, pr.ID, "details"); ok {
		var bundle struct {
			PR json.RawMessage `json:"pr"`
		}
		if json.Unmarshal(data, &bundle) == nil {
			if src, err := bb.SourceRepo(bundle.PR); err == nil {
				return src, nil
			}
		}
	}
	get, err := env.Twg.JSON(ctx, "bitbucket", "pull-requests", "get", strconv.Itoa(pr.ID), "--repo", pr.Repo)
	if err != nil {
		return "", err
	}
	return bb.SourceRepo(get)
}

// PartialError tells that a details bundle has failed parts. Fetch returns
// the bundle with the error. Each failed part is [], and the bundle is not
// saved.
type PartialError struct {
	Parts []string
}

func (e *PartialError) Error() string {
	return "these parts of the details did not load: " + strings.Join(e.Parts, ", ")
}

// bundle is the content of a details file. PRAt is the time of the load of
// the pr part.
type bundle struct {
	PR       json.RawMessage `json:"pr"`
	Checks   json.RawMessage `json:"checks"`
	Diffstat json.RawMessage `json:"diffstat"`
	PRAt     time.Time       `json:"pr_at"`
}

// KeepParts returns the bundle raw with the parts from the bundle old: each
// part in parts that old has. The UI uses it when parts of a new bundle
// failed, so that its copy keeps the good parts. If raw or old is not a
// bundle, KeepParts returns raw.
func KeepParts(raw, old []byte, parts []string) []byte {
	var b, o bundle
	if json.Unmarshal(raw, &b) != nil || json.Unmarshal(old, &o) != nil {
		return raw
	}
	for _, p := range parts {
		switch {
		case p == "mergeability" && len(o.Checks) > 0:
			b.Checks = o.Checks
		case p == "diffstat" && len(o.Diffstat) > 0:
			b.Diffstat = o.Diffstat
		}
	}
	out, err := json.Marshal(b)
	if err != nil {
		return raw
	}
	return out
}

// fetchDetails loads the details bundle of pr. If the file path holds a
// bundle, its diffstat is pinned. Then fetchDetails gets the checks, and also
// the PR if the pr part is older than PRPartFor. The calls run at the same
// time, and a failure is an error. Else fetchDetails loads the whole bundle
// with fetchBundle. failed names the parts of the bundle that failed.
func fetchDetails(ctx context.Context, env Env, pr bb.PR, path string) (raw []byte, failed []string, err error) {
	var old bundle
	data, rerr := os.ReadFile(path)
	if rerr != nil || json.Unmarshal(data, &old) != nil || len(old.PR) == 0 {
		return fetchBundle(ctx, env, pr)
	}
	now := env.now()
	var get, checks json.RawMessage
	var getErr, checksErr error
	var calls []func()
	if pr.IsOpen() {
		calls = append(calls, func() { checks, checksErr = partJSON(ctx, env, pr, "mergeability") })
	}
	if now.Sub(old.PRAt) >= PRPartFor {
		calls = append(calls, func() { get, getErr = partJSON(ctx, env, pr, "get") })
	}
	parallel(calls...)
	if err := errors.Join(checksErr, getErr); err != nil {
		return nil, nil, err
	}
	if checks != nil {
		old.Checks = checks
	}
	if get != nil {
		old.PR, old.PRAt = get, now
	}
	raw, err = json.Marshal(old)
	return raw, nil, err
}

// fetchBundle loads the whole details bundle. The calls get, mergeability,
// and diffstat start at the same time. If get fails, the bundle fails, and
// the other two calls stop. A failed other part is [] and does not fail the
// bundle. Then failed names the part, and the twg runner records the line
// "✗ <part>: <message>" in the command log. A closed PR gets no mergeability
// call: the UI shows no merge state for it. Its checks are [].
func fetchBundle(ctx context.Context, env Env, pr bb.PR) (raw []byte, failed []string, err error) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	get, diffstat, checks := json.RawMessage(nil), json.RawMessage(nil), json.RawMessage("[]")
	var getErr, checksErr, diffstatErr error
	calls := []func(){
		func() {
			if get, getErr = partJSON(ctx, env, pr, "get"); getErr != nil {
				cancel()
			}
		},
		func() { diffstat, diffstatErr = partJSON(ctx, env, pr, "diffstat") },
	}
	if pr.IsOpen() {
		calls = append(calls, func() { checks, checksErr = partJSON(ctx, env, pr, "mergeability") })
	}
	parallel(calls...)
	if getErr != nil {
		return nil, nil, getErr
	}
	part := func(sub string, b json.RawMessage, err error) json.RawMessage {
		if err == nil {
			return b
		}
		if env.Twg.Record != nil {
			env.Twg.Record("✗ " + sub + ": " + err.Error())
		}
		failed = append(failed, sub)
		return json.RawMessage("[]")
	}
	checks = part("mergeability", checks, checksErr)
	diffstat = part("diffstat", diffstat, diffstatErr)
	raw, err = json.Marshal(bundle{get, checks, diffstat, env.now()})
	return raw, failed, err
}

// partJSON runs one call of the details bundle and checks its JSON.
func partJSON(ctx context.Context, env Env, pr bb.PR, sub string) (json.RawMessage, error) {
	id := strconv.Itoa(pr.ID)
	b, err := env.Twg.JSON(ctx, "bitbucket", "pull-requests", sub, id, "--repo", pr.Repo)
	switch {
	case err != nil:
		return nil, err
	case !json.Valid(b) && sub == "get":
		return nil, fmt.Errorf("bad JSON from twg for PR %s", id)
	case !json.Valid(b):
		return nil, errors.New("bad JSON from twg")
	}
	return b, nil
}

// parallel runs each function in its own goroutine, and waits for all of
// them. If a function panics, parallel panics in the goroutine of the caller,
// so that a recover of the caller catches it.
func parallel(fns ...func()) {
	var wg sync.WaitGroup
	var mu sync.Mutex
	var caught any
	for _, fn := range fns {
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() {
				if r := recover(); r != nil {
					mu.Lock()
					caught = r
					mu.Unlock()
				}
			}()
			fn()
		}()
	}
	wg.Wait()
	if caught != nil {
		panic(caught)
	}
}

// writeFile writes a temporary file in the directory of path, and then
// renames it. A reader never sees a partial file.
func writeFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	_, err = tmp.Write(data)
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), path)
	}
	if err != nil {
		_ = os.Remove(tmp.Name())
	}
	return err
}
