package gitops

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"strings"
	"testing"
	"time"

	"bbprs/internal/cmdlog"
	"bbprs/internal/gitops/gitopstest"
)

func TestMain(m *testing.M) {
	cleanup := gitopstest.IsolateConfig()
	code := m.Run()
	cleanup()
	os.Exit(code)
}

func TestCloneURL(t *testing.T) {
	tests := []struct {
		repo   string
		origin string // the origin URL of the pane
		want   string // empty: CloneURL refuses the name
	}{
		{"ws/app", "", "https://bitbucket.org/ws/app.git"},
		{"my.ws/a_b-1.x", "", "https://bitbucket.org/my.ws/a_b-1.x.git"},
		{"ws/app", "git@bitbucket.org:ws/cur.git", "git@bitbucket.org:ws/app.git"},
		{"ws/app", "ssh://git@bitbucket.org/ws/cur.git", "git@bitbucket.org:ws/app.git"},
		// SSH to another host does not tell how the user gets to Bitbucket.
		{"ws/app", "git@example.com:me/app.git", "https://bitbucket.org/ws/app.git"},
		// A name must be safe in a path and in a URL.
		{"ws", "", ""},
		{"ws/app/x", "", ""},
		{"-ws/app", "", ""},
		{"ws/-app", "", ""},
		{".ws/app", "", ""},
		{"ws/.git", "", ""},
		{"ws/a b", "", ""},
	}
	for _, tc := range tests {
		t.Run(tc.repo+" "+tc.origin, func(t *testing.T) {
			got, err := CloneURL(tc.repo, tc.origin)
			if (err != nil) != (tc.want == "") || got != tc.want {
				t.Errorf("CloneURL(%q, %q) = %q, %v; want %q", tc.repo, tc.origin, got, err, tc.want)
			}
		})
	}
}

func TestEnsureClone(t *testing.T) {
	tests := []struct {
		name      string
		before    func(t *testing.T, dir, url string)
		relative  bool          // give a relative folder
		timeout   time.Duration // the time limit of the clone, if not 0
		wantClone bool
		wantErr   string // text that the error holds
	}{
		{name: "a first use clones", wantClone: true},
		{name: "a second use does not clone again", before: func(t *testing.T, dir, url string) {
			if _, err := EnsureClone(context.Background(), dir, url, nil); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "a folder that is not a repo is cloned again", before: func(t *testing.T, dir, url string) {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, "junk"), nil, 0o600); err != nil {
				t.Fatal(err)
			}
		}, wantClone: true},
		{name: "a relative folder is refused", relative: true, wantErr: "not an absolute path"},
		{name: "a clone that hits its time limit", timeout: time.Nanosecond, wantClone: true, wantErr: "git stopped after 5 minutes"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			origin, _ := gitopstest.Repos(t)
			// A partial clone from a local path needs file:// and this.
			gitopstest.Git(t, origin, "config", "uploadpack.allowFilter", "true")
			url := "file://" + origin
			dir := filepath.Join(t.TempDir(), "repos", "ws", "app")
			if tc.relative {
				t.Chdir(t.TempDir())
				dir = filepath.Join("repos", "ws", "app")
			}
			if tc.timeout != 0 {
				old := cloneTimeout
				cloneTimeout = tc.timeout
				t.Cleanup(func() { cloneTimeout = old })
			}
			if tc.before != nil {
				tc.before(t, dir, url)
			}
			var log cmdlog.Log
			g, err := EnsureClone(context.Background(), dir, url, log.Add)
			clone := "git clone --quiet --filter=blob:none --no-checkout -- " + url + " "
			lines := log.Lines(10)
			if cloned := len(lines) == 1 && strings.HasPrefix(lines[0].Text, clone); cloned != tc.wantClone || len(lines) > 1 {
				t.Errorf("command log = %+v, want a clone: %t", lines, tc.wantClone)
			}
			entries, _ := os.ReadDir(filepath.Dir(dir))
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Errorf("error = %v, want %q", err, tc.wantErr)
				}
				// No clone, and no temporary folder, is left.
				if len(entries) != 0 {
					t.Errorf("the folder of the clone holds %v, want nothing", entries)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if g.Dir != dir {
				t.Errorf("Dir = %q, want %q", g.Dir, dir)
			}
			if _, ok := g.Behind("feat", "main"); !ok {
				t.Error("the clone does not have origin/feat and origin/main")
			}
			// The temporary folder of the clone is gone.
			if len(entries) != 1 {
				t.Errorf("the folder of the clone holds %v, want only app", entries)
			}
		})
	}
}

func TestSync(t *testing.T) {
	tests := []struct {
		name   string
		src    string
		want   SyncResult
		before func(t *testing.T, origin string)
		check  func(t *testing.T, origin, sha string)
	}{
		{
			name: "clean rebase is pushed",
			src:  "feat",
			want: Synced,
			check: func(t *testing.T, origin, sha string) {
				got := gitopstest.Git(t, origin, "rev-list", "--count", "feat..main") + " " +
					gitopstest.Git(t, origin, "rev-list", "--count", "main..feat")
				if got != "0 1" {
					t.Errorf("feat..main and main..feat = %q, want %q", got, "0 1")
				}
			},
		},
		{
			name: "conflict leaves the branch",
			src:  "clash",
			want: Conflict,
			check: func(t *testing.T, origin, sha string) {
				if got := gitopstest.Git(t, origin, "rev-parse", "clash"); got != sha {
					t.Errorf("clash changed to %s, want %s", got, sha)
				}
			},
		},
		{
			name: "lost lease keeps the new commit",
			src:  "feat2",
			want: Failed,
			// A second clone pushes to feat2 after the first clone fetched.
			before: func(t *testing.T, origin string) {
				other := filepath.Join(t.TempDir(), "other")
				gitopstest.Git(t, filepath.Dir(other), "clone", "-q", origin, other)
				gitopstest.Git(t, other, "checkout", "-q", "feat2")
				gitopstest.Commit(t, other, "d.txt", "late")
				gitopstest.Git(t, other, "push", "-q", "origin", "feat2")
			},
			check: func(t *testing.T, origin, sha string) {
				if got := gitopstest.Git(t, origin, "log", "-1", "--format=%s", "feat2"); got != "late" {
					t.Errorf("feat2 tip is %q, want %q", got, "late")
				}
			},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			origin, work := gitopstest.Repos(t)
			sha := gitopstest.Git(t, origin, "rev-parse", tc.src)
			if tc.before != nil {
				tc.before(t, origin)
			}
			var recorded []string
			g := Git{Dir: work, Record: func(s string) { recorded = append(recorded, s) }}
			got, msg := g.Sync(context.Background(), tc.src, "main")
			if got != tc.want {
				t.Fatalf("Sync = %v (%q), want %v", got, msg, tc.want)
			}
			t.Logf("message: %q", msg)
			tc.check(t, origin, sha)
			if n := len(strings.Split(gitopstest.Git(t, work, "worktree", "list"), "\n")); n != 1 {
				t.Errorf("worktree list has %d lines, want 1", n)
			}
			if len(recorded) == 0 || !strings.HasPrefix(recorded[0], "git ") || strings.Contains(recorded[0], "-C") {
				t.Errorf("recorded commands = %q", recorded)
			}
		})
	}
}

func TestSyncMerge(t *testing.T) {
	tests := []struct {
		name    string
		src     string
		want    SyncResult
		wantMsg string // text that the message holds
		before  func(t *testing.T, origin string)
		check   func(t *testing.T, origin, sha string)
	}{
		{
			name: "clean merge is pushed on the old head",
			src:  "feat",
			want: Synced,
			check: func(t *testing.T, origin, sha string) {
				gitopstest.Git(t, origin, "merge-base", "--is-ancestor", "main", "feat")
				if got := gitopstest.Git(t, origin, "rev-parse", "feat^1"); got != sha {
					t.Errorf("first parent of feat is %s, want the old head %s", got, sha)
				}
				if got, want := gitopstest.Git(t, origin, "rev-parse", "feat^2"), gitopstest.Git(t, origin, "rev-parse", "main"); got != want {
					t.Errorf("second parent of feat is %s, want main %s", got, want)
				}
			},
		},
		{
			name: "conflict leaves the branch",
			src:  "clash",
			want: Conflict,
			check: func(t *testing.T, origin, sha string) {
				if got := gitopstest.Git(t, origin, "rev-parse", "clash"); got != sha {
					t.Errorf("clash changed to %s, want %s", got, sha)
				}
			},
		},
		{
			name:    "a push after the fetch keeps the new commit",
			src:     "feat2",
			want:    Failed,
			wantMsg: "rejected",
			// A second clone pushes to feat2 after the first clone fetched.
			before: func(t *testing.T, origin string) {
				other := filepath.Join(t.TempDir(), "other")
				gitopstest.Git(t, filepath.Dir(other), "clone", "-q", origin, other)
				gitopstest.Git(t, other, "checkout", "-q", "feat2")
				gitopstest.Commit(t, other, "d.txt", "late")
				gitopstest.Git(t, other, "push", "-q", "origin", "feat2")
			},
			check: func(t *testing.T, origin, sha string) {
				if got := gitopstest.Git(t, origin, "log", "-1", "--format=%s", "feat2"); got != "late" {
					t.Errorf("feat2 tip is %q, want %q", got, "late")
				}
			},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			origin, work := gitopstest.Repos(t)
			sha := gitopstest.Git(t, origin, "rev-parse", tc.src)
			if tc.before != nil {
				tc.before(t, origin)
			}
			var recorded []string
			g := Git{Dir: work, Record: func(s string) { recorded = append(recorded, s) }}
			got, msg := g.SyncMerge(context.Background(), tc.src, "main")
			if got != tc.want {
				t.Fatalf("SyncMerge = %v (%q), want %v", got, msg, tc.want)
			}
			if !strings.Contains(msg, tc.wantMsg) {
				t.Errorf("message = %q, want it to contain %q", msg, tc.wantMsg)
			}
			tc.check(t, origin, sha)
			if n := len(strings.Split(gitopstest.Git(t, work, "worktree", "list"), "\n")); n != 1 {
				t.Errorf("worktree list has %d lines, want 1", n)
			}
			// A merge sync never forces a push.
			for _, c := range recorded {
				if strings.HasPrefix(c, "git push") && strings.Contains(c, "force") {
					t.Errorf("recorded %q, want a push without force", c)
				}
			}
		})
	}
}

func TestConflicts(t *testing.T) {
	tests := []struct {
		src     string
		want    []string
		wantErr bool
	}{
		{"feat", nil, false},
		{"clash", []string{"a.txt"}, false},
		{"nope", nil, true}, // a branch that origin does not have
	}
	for _, tc := range tests {
		t.Run(tc.src, func(t *testing.T) {
			_, work := gitopstest.Repos(t)
			var log cmdlog.Log
			g := Git{Dir: work, Record: log.Add}
			got, err := g.Conflicts(context.Background(), tc.src, "main")
			if (err != nil) != tc.wantErr {
				t.Fatalf("Conflicts error = %v, want an error: %t", err, tc.wantErr)
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("Conflicts(%s, main) = %q, want %q", tc.src, got, tc.want)
			}
			// merge-tree works in memory. The checkout stays clean.
			if status := gitopstest.Git(t, work, "status", "--porcelain"); status != "" {
				t.Errorf("git status = %q, want clean", status)
			}
			// The command log shows the time of the command at the end of its
			// line.
			want := regexp.MustCompile(`^` + regexp.QuoteMeta("git merge-tree -z --write-tree --name-only --no-messages "+
				"refs/remotes/origin/main refs/remotes/origin/"+tc.src) + `  \d+\.\d s$`)
			if lines := log.Lines(10); len(lines) != 1 || !want.MatchString(lines[0].Text) {
				t.Errorf("command log = %+v, want one line that matches %s", lines, want)
			}
		})
	}
}

// The list load calls Behind for each PR, so Behind must not record. The
// counts are in TestPlanSync of the actions package.
func TestBehindRecordsNothing(t *testing.T) {
	_, work := gitopstest.Repos(t)
	g := Git{Dir: work, Record: func(s string) { t.Errorf("Behind recorded %q", s) }}
	if _, ok := g.Behind("feat", "main"); !ok {
		t.Fatal("Behind did not find origin/feat and origin/main")
	}
}

func TestShow(t *testing.T) {
	_, work := gitopstest.Repos(t)
	// A merge of main into feat. main changed a.txt after feat forked.
	gitopstest.Git(t, work, "checkout", "-q", "feat")
	gitopstest.Git(t, work, "merge", "-q", "--no-ff", "-m", "Merge main into feat", "main")
	tests := []struct {
		name    string
		hash    string
		want    string // text that the patch starts with
		wantErr error
	}{
		{"a known commit", gitopstest.Git(t, work, "rev-parse", "refs/remotes/origin/feat"), "diff --git a/b.txt b/b.txt\nnew file mode", nil},
		{"a merge commit: the changes from the first parent", gitopstest.Git(t, work, "rev-parse", "HEAD"), "diff --git a/a.txt b/a.txt", nil},
		{"an unknown commit", "0123456789abcdef0123456789abcdef01234567", "", ErrNoCommit},
		// Only a full hash runs git. Then a hash cannot be an option or a ref.
		{"an option", "--output=x", "", errBadHash},
		{"a ref name", "main", "", errBadHash},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var recorded []string
			g := Git{Dir: work, Record: func(s string) { recorded = append(recorded, s) }}
			got, err := g.Show(context.Background(), tc.hash)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("Show error = %v, want %v", err, tc.wantErr)
			}
			// --format= removes the head of the commit, so the patch comes first.
			if !strings.HasPrefix(string(got), tc.want) {
				t.Errorf("Show = %q, want the patch only, from %q", got, tc.want)
			}
			want := "git show --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ " +
				"--format= --patch --diff-merges=first-parent " + tc.hash
			switch {
			case tc.wantErr == errBadHash && len(recorded) > 0:
				t.Errorf("recorded = %q, want no command", recorded)
			case tc.wantErr != errBadHash && (len(recorded) == 0 || recorded[0] != want):
				t.Errorf("recorded = %q, want %q first", recorded, want)
			}
		})
	}
}
