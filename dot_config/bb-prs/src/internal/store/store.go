// Package store keeps the files of bb-prs: the list cache, the lock of a
// refresh, the log of actions, the last workspace, and the preview files.
package store

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"bbprs/internal/bb"
)

// Paths holds the two directories of bb-prs.
type Paths struct {
	Cache, State string
}

// DefaultPaths reads the directories from the XDG variables. An empty
// variable counts as not set.
func DefaultPaths() Paths {
	home, _ := os.UserHomeDir()
	dir := func(env, fallback string) string {
		if v := os.Getenv(env); v != "" {
			return filepath.Join(v, "bb-prs")
		}
		return filepath.Join(home, fallback, "bb-prs")
	}
	return Paths{
		Cache: dir("XDG_CACHE_HOME", ".cache"),
		State: dir("XDG_STATE_HOME", ".local/state"),
	}
}

// ListFile returns the path of the cache file of one list.
func (p Paths) ListFile(prompt, list string) string {
	name := "list-" + strings.ReplaceAll(prompt, "/", "_") + "-" + list + ".v3.json"
	return filepath.Join(p.Cache, name)
}

// ListFiles returns the paths of the files of the list in the workspace ws:
// the list outside a repo (the prompt ws), and the list of each repo of ws
// (the prompt ws/<repo>). The inbox calls of ws load the PRs of each of these
// lists. A path is in the result if its file or its lock exists. The first
// refresh of a list holds the lock before the file exists.
func (p Paths) ListFiles(ws, list string) []string {
	var out []string
	for _, prompt := range []string{ws, ws + "/*"} {
		pattern := p.ListFile(prompt, list)
		files, _ := filepath.Glob(pattern)
		locks, _ := filepath.Glob(pattern + ".lock")
		for _, l := range locks {
			files = append(files, strings.TrimSuffix(l, ".lock"))
		}
		slices.Sort(files)
		out = append(out, slices.Compact(files)...)
	}
	return out
}

// WarmBackoff returns the path of the marker file of a rate limit in a warm
// run. While the file is new, the warm runs make no call.
func (p Paths) WarmBackoff() string { return filepath.Join(p.State, "warm-backoff") }

// ReviewDir returns the directory of the review state files.
func (p Paths) ReviewDir() string { return filepath.Join(p.State, "reviews") }

// ReviewFile returns the path of the state file of the review of one PR.
func (p Paths) ReviewFile(repo string, id int) string {
	return filepath.Join(p.ReviewDir(), strings.ReplaceAll(repo, "/", "_")+"-"+strconv.Itoa(id)+".json")
}

// ReviewWorkDir returns the working folder of a review of a PR that is not in
// the repo of the pane.
func (p Paths) ReviewWorkDir() string { return filepath.Join(p.ReviewDir(), "work") }

// RepoDir returns the folder of the own clone of bb-prs for repo, a full
// name such as "ws/app". A sync of a PR that is not in the repo of the pane
// uses this clone. RepoDir does not check the name: check it first.
func (p Paths) RepoDir(repo string) string {
	return filepath.Join(p.Cache, "repos", filepath.FromSlash(repo))
}

// ListCache is the content of a list file.
type ListCache struct {
	PRs    []bb.PR   `json:"prs"`
	Errors []string  `json:"errors,omitempty"`
	Saved  time.Time `json:"saved"`
}

// LoadList reads a list file. A missing file gives an empty cache and no
// error.
func LoadList(path string) (ListCache, error) {
	var c ListCache
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return c, nil
	}
	if err != nil {
		return c, err
	}
	err = json.Unmarshal(data, &c)
	return c, err
}

// SaveList writes a list file. It writes a temporary file in the same
// directory and then renames it, so a reader never sees a partial file.
func SaveList(path string, c ListCache) error {
	data, err := json.Marshal(c)
	if err != nil {
		return err
	}
	return writeAtomic(path, data)
}

// WriteAtomic writes a file in one step: a temporary file in the same
// directory, and then a rename. It makes the directory if necessary.
func WriteAtomic(path string, data []byte) error { return writeAtomic(path, data) }

func writeAtomic(path string, data []byte) error {
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

// Fresh is true when the file exists, has no errors, and is younger than
// maxAge. It uses the modification time of the file.
func Fresh(path string, maxAge time.Duration) bool {
	info, err := os.Stat(path)
	if err != nil || time.Since(info.ModTime()) >= maxAge {
		return false
	}
	c, err := LoadList(path)
	return err == nil && len(c.Errors) == 0
}

// TryLock makes the directory "<path>.lock". If the lock exists and is older
// than stale, TryLock removes it and tries one more time. If another process
// holds the lock, ok is false and err is nil. Call release to remove the lock.
func TryLock(path string, stale time.Duration) (release func(), ok bool, err error) {
	lock := path + ".lock"
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, false, err
	}
	for attempt := 0; attempt < 2; attempt++ {
		err = os.Mkdir(lock, 0o755)
		if err == nil {
			return func() { _ = os.Remove(lock) }, true, nil
		}
		if !errors.Is(err, fs.ErrExist) {
			return nil, false, err
		}
		info, serr := os.Stat(lock)
		if serr != nil {
			continue // The holder released the lock. Try again.
		}
		if time.Since(info.ModTime()) <= stale {
			return nil, false, nil
		}
		if rerr := os.RemoveAll(lock); rerr != nil {
			return nil, false, rerr
		}
	}
	return nil, false, nil
}

// TryLockOwned is TryLock for a lock with an owner. It writes token to the
// file "owner" in the lock. After a stale lock, another process can hold the
// lock: owns tells if the lock still holds token. release removes the lock
// only while it holds token.
func TryLockOwned(path string, stale time.Duration, token string) (owns func() bool, release func(), ok bool, err error) {
	if _, ok, err = TryLock(path, stale); !ok || err != nil {
		return nil, nil, ok, err
	}
	lock := path + ".lock"
	owner := filepath.Join(lock, "owner")
	if err := writeAtomic(owner, []byte(token)); err != nil {
		_ = os.RemoveAll(lock)
		return nil, nil, false, err
	}
	owns = func() bool {
		data, err := os.ReadFile(owner)
		return err == nil && string(data) == token
	}
	release = func() {
		if owns() {
			_ = os.RemoveAll(lock)
		}
	}
	return owns, release, true, nil
}

// Held is true when a process holds the lock of path: the lock exists and is
// not older than stale. TryLock takes an older lock.
func Held(path string, stale time.Duration) bool {
	info, err := os.Stat(path + ".lock")
	return err == nil && time.Since(info.ModTime()) <= stale
}

// Locked is true when the lock of a path exists.
func Locked(path string) bool {
	_, err := os.Stat(path + ".lock")
	return err == nil
}

// Action is one line of the log of actions.
type Action struct {
	Time                       time.Time
	Action, Result, Repo       string
	ID                         int
	URL, Src, Dst, Title, Note string
}

const actionTimeLayout = "2006-01-02 15:04"

func (p Paths) actionsFile() string { return filepath.Join(p.State, "actions.tsv") }

// AppendAction adds one line to the log. A tab in a field becomes a space. An
// empty field becomes "-". A zero time becomes the current time.
func (p Paths) AppendAction(a Action) error {
	if a.Time.IsZero() {
		a.Time = time.Now()
	}
	fields := []string{
		a.Time.Format(actionTimeLayout), a.Action, a.Result, a.Repo,
		strconv.Itoa(a.ID), a.URL, a.Src, a.Dst, a.Title, a.Note,
	}
	for i, f := range fields {
		f = strings.NewReplacer("\t", " ", "\n", " ", "\r", " ").Replace(f)
		if f == "" {
			f = "-"
		}
		fields[i] = f
	}
	if err := os.MkdirAll(p.State, 0o755); err != nil {
		return err
	}
	f, err := os.OpenFile(p.actionsFile(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	_, err = f.WriteString(strings.Join(fields, "\t") + "\n")
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// ReadActions returns at most max actions, the newest first. A missing file
// gives no actions and no error.
func (p Paths) ReadActions(max int) ([]Action, error) {
	data, err := os.ReadFile(p.actionsFile())
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	lines := strings.Split(string(data), "\n")
	var out []Action
	for i := len(lines) - 1; i >= 0 && len(out) < max; i-- {
		if lines[i] == "" {
			continue
		}
		out = append(out, parseAction(lines[i]))
	}
	return out, nil
}

func parseAction(line string) Action {
	f := strings.Split(line, "\t")
	for len(f) < 10 {
		f = append(f, "-")
	}
	for i := range f {
		if f[i] == "-" {
			f[i] = ""
		}
	}
	t, _ := time.ParseInLocation(actionTimeLayout, f[0], time.Local)
	id, _ := strconv.Atoi(f[4])
	return Action{
		Time: t, Action: f[1], Result: f[2], Repo: f[3], ID: id,
		URL: f[5], Src: f[6], Dst: f[7], Title: f[8], Note: f[9],
	}
}

// SaveWorkspace keeps the last workspace.
func (p Paths) SaveWorkspace(ws string) error {
	return writeAtomic(filepath.Join(p.State, "workspace"), []byte(ws+"\n"))
}

// LoadWorkspace returns the last workspace, or an empty string.
func (p Paths) LoadWorkspace() string {
	data, err := os.ReadFile(filepath.Join(p.State, "workspace"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func (p Paths) previewDir() string { return filepath.Join(p.Cache, "preview") }

func previewPrefix(repo string, id int) string {
	return strings.ReplaceAll(repo, "/", "_") + "-" + strconv.Itoa(id) + "-"
}

// PreviewFile returns the path of the preview of one view of a PR. The name
// holds only the letters and digits of the update time, so a changed PR gets a
// new file.
func (p Paths) PreviewFile(repo string, id int, updated, view string) string {
	var keep strings.Builder
	for _, r := range updated {
		if r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' {
			keep.WriteRune(r)
		}
	}
	return filepath.Join(p.previewDir(), previewPrefix(repo, id)+keep.String()+"-"+view+".json")
}

// FindPreview returns the newest preview file of one view of a PR, of any
// update time and of any age. The newest file is the one with the latest
// modification time. If there is no file, ok is false.
func (p Paths) FindPreview(repo string, id int, view string) (data []byte, ok bool) {
	entries, err := os.ReadDir(p.previewDir())
	if err != nil {
		return nil, false
	}
	prefix, suffix := previewPrefix(repo, id), "-"+view+".json"
	newest, at := "", time.Time{}
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), prefix) || !strings.HasSuffix(e.Name(), suffix) {
			continue
		}
		if info, err := e.Info(); err == nil && (newest == "" || info.ModTime().After(at)) {
			newest, at = e.Name(), info.ModTime()
		}
	}
	if newest == "" {
		return nil, false
	}
	data, err = os.ReadFile(filepath.Join(p.previewDir(), newest))
	return data, err == nil
}

// DropPreviews removes each preview file of a PR. It also writes the drop
// marker of the PR (see DroppedAt).
func (p Paths) DropPreviews(repo string, id int) {
	_ = writeAtomic(p.dropFile(repo, id), nil)
	entries, err := os.ReadDir(p.previewDir())
	if err != nil {
		return
	}
	prefix := previewPrefix(repo, id)
	for _, e := range entries {
		if strings.HasPrefix(e.Name(), prefix) {
			_ = os.Remove(filepath.Join(p.previewDir(), e.Name()))
		}
	}
}

// DroppedAt returns the time of the last DropPreviews of a PR, or the zero
// time. A load that started before that time can have data from before an
// action, so it must not save its data.
func (p Paths) DroppedAt(repo string, id int) time.Time {
	info, err := os.Stat(p.dropFile(repo, id))
	if err != nil {
		return time.Time{}
	}
	return info.ModTime()
}

// dropFile returns the path of the drop marker of a PR. Its name does not
// start with the prefix of the previews of the PR, so DropPreviews and
// FindPreview do not see it. PruneOldPreviews removes an old marker.
func (p Paths) dropFile(repo string, id int) string {
	return filepath.Join(p.previewDir(), "dropped-"+strings.TrimSuffix(previewPrefix(repo, id), "-"))
}

// PruneOldPreviews removes each preview file that is older than maxAge.
func (p Paths) PruneOldPreviews(maxAge time.Duration) {
	entries, err := os.ReadDir(p.previewDir())
	if err != nil {
		return
	}
	for _, e := range entries {
		info, err := e.Info()
		if err == nil && !e.IsDir() && time.Since(info.ModTime()) > maxAge {
			_ = os.Remove(filepath.Join(p.previewDir(), e.Name()))
		}
	}
}
