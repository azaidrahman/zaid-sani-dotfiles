package ui

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	"bbprs/internal/bb"
	"bbprs/internal/cmdlog"
	"bbprs/internal/gitops"
	"bbprs/internal/gitops/gitopstest"
	"bbprs/internal/refresh"
	"bbprs/internal/termtab"
)

// squash removes the styles and all the white space from s. The popup wraps
// long words, so the test compares the text without its spaces.
func squash(s string) string {
	return strings.Join(strings.Fields(ansi.Strip(s)), "")
}

// TestCheckConflicts runs the check on a real test repo. A fake script stands
// in for git pr-conflicts, and a fake runner stands in for rex.
func TestCheckConflicts(t *testing.T) {
	// The script gets the worktree directory as its last argument.
	makesDir := "#!/bin/sh\nfor a; do last=$a; done\nmkdir -p \"$last\" && : > \"$last/.git\"\nexit 1\n"
	makesNothing := "#!/bin/sh\necho 'no such PR'\nexit 2\n"
	// The start of each command. TestConflicts and TestOpen check the full
	// merge-tree and rex commands. Here, the tab must open in the worktree.
	const (
		fetch   = "git fetch -q origin"
		tree    = "git merge-tree "
		resolve = "git pr-conflicts 11 --resolve --no-fetch --plain --worktree $DIR"
		rex     = "rex run -s s1 -c $DIR "
	)
	// A branch name of 50 characters. The popup must not break the push
	// command at a "-".
	const long = "feature/make-the-picker-show-the-diff-of-all-files"
	tests := []struct {
		name      string
		src       string
		script    string
		before    func(t *testing.T, work, dir string)
		tabErr    error
		wantLines []string // the start of each command in the entry; $DIR is the worktree
		wantText  []string // the popup text, without spaces
		wantWhole string   // a command that a line of the popup on the screen holds in full
	}{
		{
			name: "no conflicts", src: "feat",
			wantLines: []string{fetch, tree},
			wantText:  []string{"Noconflictsbetweenfeatandmain."},
		},
		{
			name: "conflicts: the script makes the worktree, a tab opens", src: "clash", script: makesDir,
			wantLines: []string{fetch, tree, resolve, rex},
			wantText: []string{"#11conflictswithmainin1file:", "a.txt", "OpenedaRextab", "$DIR",
				"gitdiff--name-only--diff-filter=U", "gitadd-A&&gitmerge--continue",
				"gitpushoriginmerge/pr-11:clash", "gitpr-conflicts11--cleanup"},
		},
		{
			name: "conflicts: the script makes no worktree", src: "clash", script: makesNothing,
			wantLines: []string{fetch, tree, resolve},
			wantText:  []string{"didnotmaketheworktree", "nosuchPR"},
		},
		{
			name: "conflicts: the tab fails", src: "clash", script: makesDir, tabErr: errors.New("no server"),
			wantLines: []string{fetch, tree, resolve, rex},
			wantText:  []string{"thetabdidnotopen:noserver", "$DIR", "gitpr-conflicts11--cleanup"},
		},
		{
			name: "a worktree exists: reuse it, run no script", src: "clash",
			before: func(t *testing.T, work, dir string) {
				must(os.MkdirAll(dir, 0o755))
				must(os.WriteFile(filepath.Join(dir, ".git"), nil, 0o644))
			},
			wantLines: []string{fetch, tree, rex},
			wantText:  []string{"Reusedtheexistingworktree$DIR", "OpenedaRextab"},
		},
		{
			name: "a plain directory is in the way", src: "clash",
			before:    func(t *testing.T, work, dir string) { must(os.MkdirAll(dir, 0o755)) },
			wantLines: []string{fetch, tree},
			wantText:  []string{"$DIR", "isnotagitworktree"},
		},
		{
			name: "a long branch name: the push command stays on one line", src: long, script: makesDir,
			before: func(t *testing.T, work, dir string) {
				gitopstest.Git(t, work, "push", "-q", "origin", "clash:refs/heads/"+long)
			},
			wantLines: []string{fetch, tree, resolve, rex},
			wantWhole: "git push origin merge/pr-11:" + long,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			_, work := gitopstest.Repos(t)
			dir := work + "-pr11"
			bin := t.TempDir()
			if tc.script != "" {
				must(os.WriteFile(filepath.Join(bin, "git-pr-conflicts"), []byte(tc.script), 0o755))
			}
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			if tc.before != nil {
				tc.before(t, work, dir)
			}
			log := &cmdlog.Log{}
			d := Deps{
				Env: refresh.Env{Dir: work},
				PRConflicts: func(ctx context.Context, g gitops.Git, args ...string) (string, error) {
					return g.Run(ctx, args...)
				},
				Tab: termtab.Opener{
					Env: func(k string) string { return map[string]string{"REX_SESSION": "s1"}[k] },
					Run: func(context.Context, string, ...string) error { return tc.tabErr },
				},
			}
			pr := bb.PR{Repo: "ws/cur", ID: 11, Src: tc.src, Dst: "main"}
			p := checkConflicts(context.Background(), d, log.Begin("Check conflicts of #11"), pr)

			var lines []string
			for _, l := range log.Lines(50) {
				if !l.Head {
					lines = append(lines, l.Text)
				}
			}
			ok := len(lines) == len(tc.wantLines)
			for i := 0; ok && i < len(lines); i++ {
				ok = strings.HasPrefix(lines[i], strings.ReplaceAll(tc.wantLines[i], "$DIR", dir))
			}
			if !ok {
				t.Errorf("entry lines =\n%q\nwant lines that start with\n%q ($DIR is %s)", lines, tc.wantLines, dir)
			}
			text := squash(strings.Join(p.lines, "\n"))
			for _, w := range tc.wantText {
				if w = strings.ReplaceAll(w, "$DIR", squash(dir)); !strings.Contains(text, w) {
					t.Errorf("popup = %q, want it to hold %q", text, w)
				}
			}
			if tc.wantWhole != "" {
				screen := ansi.Strip(strings.Join(Model{w: 120, popup: p}.overlay(make([]string, 40)), "\n"))
				if !strings.Contains(screen, tc.wantWhole) {
					t.Errorf("screen =\n%s\nwant a line that holds %q", screen, tc.wantWhole)
				}
			}
		})
	}
}

// A branch name goes into a command that the user pastes into a shell.
func TestShellWord(t *testing.T) {
	cases := []struct{ in, want string }{
		{"merge/pr-11:feat/x_1.2", "merge/pr-11:feat/x_1.2"},
		{"feat/$(rm -rf x)", "'feat/$(rm -rf x)'"},
		{"a'b", `'a'\''b'`},
	}
	for _, c := range cases {
		if got := shellWord(c.in); got != c.want {
			t.Errorf("shellWord(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
