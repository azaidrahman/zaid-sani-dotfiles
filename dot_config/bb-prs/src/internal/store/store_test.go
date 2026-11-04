package store

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"bbprs/internal/bb"
)

func TestActions(t *testing.T) {
	p := Paths{Cache: t.TempDir(), State: t.TempDir()}
	file := filepath.Join(p.State, "actions.tsv")
	old := "2026-11-02 14:05\tapprove\tok\tws/cur\t12\thttps://bitbucket.org/ws/cur/pull-requests/12\tfeat\tmain\tOld title\t-\n"
	if err := os.WriteFile(file, []byte(old), 0o600); err != nil {
		t.Fatal(err)
	}
	when := time.Date(2026, 11, 2, 15, 30, 0, 0, time.Local)
	err := p.AppendAction(Action{
		Time: when, Action: "merge", Result: "failed", Repo: "ws/cur", ID: 13,
		URL: "https://bitbucket.org/ws/cur/pull-requests/13", Src: "fix", Dst: "main",
		Title: "New\ttitle",
	})
	if err != nil {
		t.Fatal(err)
	}

	got, err := p.ReadActions(300)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 {
		t.Fatalf("got %d actions, want 2", len(got))
	}
	if got[0].ID != 13 || got[0].Title != "New title" || got[0].Note != "" || !got[0].Time.Equal(when) {
		t.Errorf("newest action wrong: %+v", got[0])
	}
	if got[1].ID != 12 || got[1].Action != "approve" || got[1].Note != "" || got[1].Title != "Old title" {
		t.Errorf("old action wrong: %+v", got[1])
	}
	if one, _ := p.ReadActions(1); len(one) != 1 || one[0].ID != 13 {
		t.Errorf("ReadActions(1) = %+v", one)
	}

	raw, _ := os.ReadFile(file)
	lines := strings.Split(strings.TrimSuffix(string(raw), "\n"), "\n")
	want := "2026-11-02 15:30\tmerge\tfailed\tws/cur\t13\thttps://bitbucket.org/ws/cur/pull-requests/13\tfix\tmain\tNew title\t-"
	if lines[1] != want {
		t.Errorf("new line = %q, want %q", lines[1], want)
	}
}

func TestLock(t *testing.T) {
	tests := []struct {
		name   string
		setup  func(lock string)
		wantOK bool
	}{
		{"no lock", func(string) {}, true},
		{"fresh lock", func(l string) { _ = os.Mkdir(l, 0o755) }, false},
		{"stale lock", func(l string) {
			_ = os.Mkdir(l, 0o755)
			old := time.Now().Add(-3 * time.Minute)
			_ = os.Chtimes(l, old, old)
		}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "list.json")
			tt.setup(path + ".lock")
			// Another process holds the lock when TryLock cannot take it.
			if held := Held(path, 2*time.Minute); held != !tt.wantOK {
				t.Errorf("Held = %t, want %t", held, !tt.wantOK)
			}
			release, ok, err := TryLock(path, 2*time.Minute)
			if err != nil {
				t.Fatal(err)
			}
			if ok != tt.wantOK {
				t.Fatalf("ok = %v, want %v", ok, tt.wantOK)
			}
			if !ok {
				return
			}
			if !Locked(path) {
				t.Error("Locked is false while the lock is held")
			}
			release()
			if Locked(path) {
				t.Error("Locked is true after release")
			}
		})
	}
}

// The time of a use is the modification time of its file. A use at the
// limit counts, and a new mark moves an old use to now.
func TestUsed(t *testing.T) {
	p := Paths{Cache: t.TempDir(), State: t.TempDir()}
	if got := p.UsedSince(time.Time{}); got != nil {
		t.Errorf("UsedSince with no marks = %q, want none", got)
	}
	now := time.Now().Truncate(time.Second)
	for prompt, age := range map[string]time.Duration{"ws/b": 0, "ws": time.Hour, "ws/a": 9 * time.Hour} {
		if err := p.MarkUsed(prompt); err != nil {
			t.Fatal(err)
		}
		at := now.Add(-age)
		if err := os.Chtimes(filepath.Join(p.State, "used", strings.ReplaceAll(prompt, "/", "_")), at, at); err != nil {
			t.Fatal(err)
		}
	}
	since := now.Add(-time.Hour)
	if got, want := p.UsedSince(since), []string{"ws", "ws/b"}; !reflect.DeepEqual(got, want) {
		t.Errorf("UsedSince = %q, want %q", got, want)
	}
	if err := p.MarkUsed("ws/a"); err != nil {
		t.Fatal(err)
	}
	if got, want := p.UsedSince(since), []string{"ws", "ws/a", "ws/b"}; !reflect.DeepEqual(got, want) {
		t.Errorf("UsedSince after a new mark = %q, want %q", got, want)
	}
}

func TestListRoundTrip(t *testing.T) {
	p := Paths{Cache: t.TempDir(), State: t.TempDir()}
	path := p.ListFile("ws/cur", "open")
	if want := filepath.Join(p.Cache, "list-ws_cur-open.v3.json"); path != want {
		t.Errorf("ListFile = %q, want %q", path, want)
	}
	if c, err := LoadList(path); err != nil || len(c.PRs) != 0 {
		t.Fatalf("missing file: %+v, %v", c, err)
	}

	prs := []bb.PR{{Repo: "ws/cur", ID: 7, Role: bb.Mine, Title: "A", UpdatedRaw: "2026-11-02T10:00:00Z"}}
	if err := SaveList(path, ListCache{PRs: prs, Saved: time.Now()}); err != nil {
		t.Fatal(err)
	}
	c, err := LoadList(path)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(c.PRs, prs) {
		t.Errorf("PRs = %+v, want %+v", c.PRs, prs)
	}
	if !Fresh(path, 3*time.Minute) {
		t.Error("Fresh is false for a new file")
	}
	if err := SaveList(path, ListCache{PRs: prs, Errors: []string{"boom"}}); err != nil {
		t.Fatal(err)
	}
	if Fresh(path, 3*time.Minute) {
		t.Error("Fresh is true for a file with errors")
	}
}
