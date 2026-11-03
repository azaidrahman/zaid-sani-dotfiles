package refresh

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"bbprs/internal/bb"
)

const (
	openPreviewTTL   = 15 * time.Minute
	closedPreviewTTL = 1440 * time.Minute
)

// ttl is the time that a preview of the PR stays valid. A closed PR does not
// change, so its preview stays valid for longer.
func ttl(pr bb.PR) time.Duration {
	if pr.IsOpen() {
		return openPreviewTTL
	}
	return closedPreviewTTL
}

// previewFresh is true when the file exists and is younger than maxAge.
func previewFresh(path string, maxAge time.Duration) bool {
	info, err := os.Stat(path)
	return err == nil && time.Since(info.ModTime()) < maxAge
}

// Prefetch makes the details previews that are not fresh. It makes at most
// workers previews at the same time. It ignores a failure: the UI shows it
// when the user opens the PR. A bundle with a failed part is not saved, so
// the UI loads it again.
func Prefetch(ctx context.Context, env Env, prs []bb.PR, workers int) {
	if workers < 1 {
		workers = 1
	}
	slots := make(chan struct{}, workers)
	var wg sync.WaitGroup
	for _, pr := range prs {
		if previewFresh(env.Paths.PreviewFile(pr.Repo, pr.ID, pr.UpdatedRaw, "details"), ttl(pr)) {
			continue
		}
		slots <- struct{}{}
		wg.Add(1)
		go func() {
			defer wg.Done()
			defer func() { <-slots }()
			_, _ = LoadView(ctx, env, pr, "details")
		}()
	}
	wg.Wait()
}

// LoadView returns the data of one view of a PR: details, activity, commits,
// or diff. It reads the file from the cache if the file is fresh. Otherwise it
// loads the view with twg and saves it.
//
// The details file holds {"pr":…,"checks":…,"diffstat":…}. If the mergeability
// call or the diffstat call fails, that part is []. Then LoadView returns the
// bundle but does not save it, so the next load calls twg again. The diff
// file holds the text of the diff of all the files of the PR, not JSON.
func LoadView(ctx context.Context, env Env, pr bb.PR, view string) ([]byte, error) {
	path := env.Paths.PreviewFile(pr.Repo, pr.ID, pr.UpdatedRaw, view)
	if previewFresh(path, ttl(pr)) {
		if data, err := os.ReadFile(path); err == nil {
			return data, nil
		}
	}
	var raw []byte
	var err error
	save := true
	switch view {
	case "details":
		raw, save, err = loadDetails(ctx, env, pr)
	case "activity", "commits":
		raw, err = env.Twg.JSON(ctx, "bitbucket", "pull-requests", view, strconv.Itoa(pr.ID),
			"--repo", pr.Repo, "-n", "100")
	case "diff":
		raw, err = env.Twg.Text(ctx, "bitbucket", "pull-requests", "diff", strconv.Itoa(pr.ID), "--repo", pr.Repo)
	default:
		err = fmt.Errorf("unknown view %q", view)
	}
	if err != nil {
		return nil, err
	}
	if !save {
		return raw, nil
	}
	if err := writeFile(path, raw); err != nil {
		return nil, err
	}
	return raw, nil
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

// loadDetails loads the details bundle. A failed part is [] and does not
// fail the bundle. Then complete is false, and the twg runner records the
// line "✗ <part>: <message>" in the command log.
func loadDetails(ctx context.Context, env Env, pr bb.PR) (raw []byte, complete bool, err error) {
	id := strconv.Itoa(pr.ID)
	get, err := env.Twg.JSON(ctx, "bitbucket", "pull-requests", "get", id, "--repo", pr.Repo)
	if err != nil {
		return nil, false, err
	}
	if !json.Valid(get) {
		return nil, false, fmt.Errorf("bad JSON from twg for PR %s", id)
	}
	part := func(sub string) (json.RawMessage, bool) {
		b, err := env.Twg.JSON(ctx, "bitbucket", "pull-requests", sub, id, "--repo", pr.Repo)
		if err == nil && !json.Valid(b) {
			err = errors.New("bad JSON from twg")
		}
		if err != nil {
			if env.Twg.Record != nil {
				env.Twg.Record("✗ " + sub + ": " + err.Error())
			}
			return json.RawMessage("[]"), false
		}
		return b, true
	}
	var checks, diffstat json.RawMessage
	var checksOK, diffstatOK bool
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); checks, checksOK = part("mergeability") }()
	go func() { defer wg.Done(); diffstat, diffstatOK = part("diffstat") }()
	wg.Wait()
	raw, err = json.Marshal(struct {
		PR       json.RawMessage `json:"pr"`
		Checks   json.RawMessage `json:"checks"`
		Diffstat json.RawMessage `json:"diffstat"`
	}{get, checks, diffstat})
	return raw, checksOK && diffstatOK, err
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
