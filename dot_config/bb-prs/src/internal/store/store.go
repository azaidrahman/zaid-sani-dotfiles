// Package store keeps the files of bb-prs: the list cache, the lock of a
// refresh, the log of actions, the last workspace, and the preview files.
package store

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
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

// DropPreviews removes each preview file of a PR.
func (p Paths) DropPreviews(repo string, id int) {
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
