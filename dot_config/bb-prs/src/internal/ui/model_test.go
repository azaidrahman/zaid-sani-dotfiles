package ui

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"bbprs/internal/actions"
	"bbprs/internal/bb"
	"bbprs/internal/browser"
	"bbprs/internal/cmdlog"
	"bbprs/internal/gitops"
	"bbprs/internal/gitops/gitopstest"
	"bbprs/internal/refresh"
	"bbprs/internal/review"
	"bbprs/internal/store"
	"bbprs/internal/termtab"
	"bbprs/internal/twg"
)

func TestMain(m *testing.M) {
	// The check of a PR for conflicts runs git in a test repo.
	cleanup := gitopstest.IsolateConfig()
	root, err := os.MkdirTemp("", "bb-prs-ui")
	must(err)
	viewAt = func(w, h int) string {
		dir, err := os.MkdirTemp(root, "view")
		must(err)
		// Four PRs, so that the test can count the rows of [2].
		prs := fixturePRs()
		fourth := prs[1]
		fourth.ID, fourth.Title = 13, "Log each retry of the worker"
		f := newFixture(dir, append(prs, fourth), nil)
		f.writeDetails(prs[0], "## Why\n\nA slow receiver makes the worker retry forever. See https://bitbucket.org/ws/cur/a/very/long/link/that/does/not/fit\n\n- Give each endpoint a budget")
		f.m = feed(f.m, tea.WindowSizeMsg{Width: w, Height: h})
		f.m = run(f.m, f.m.Init())
		return f.m.View()
	}
	code := m.Run()
	os.RemoveAll(root)
	cleanup()
	os.Exit(code)
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

// fixture is a model on a cache in a temporary directory. A fake twg appends
// its arguments to twgLog. Spawn adds "<list> <auto>" to spawns. StartReview
// adds "--ai-review <repo> <id> [--again]" to starts. The terminal opener is Rex, and it
// adds each command ("rex", then its arguments) to opened. The command that
// goes to a tab that is open fails, so that the opener opens a tab.
type fixture struct {
	m      Model
	paths  store.Paths
	spawns *[]string
	starts *[]string
	opened *[][]string
	twgLog string
}

// fixturePRs gives the open list. The oldest PR comes first.
func fixturePRs() []bb.PR {
	now := time.Now()
	pr := func(repo string, id int, role bb.Role, days int, title string) bb.PR {
		return bb.PR{
			Repo: repo, ID: id, Role: role, Src: "feat/x", Dst: "main",
			URL:    fmt.Sprintf("https://bitbucket.org/%s/pull-requests/%d", repo, id),
			Author: "Ana Tester", Title: title, UpdatedRaw: "2026-11-01T10:00:00",
			Sent: now.Add(-time.Duration(days) * 24 * time.Hour),
		}
	}
	return []bb.PR{
		pr("ws/cur", 11, bb.Mine, 3, "Add a retry budget to the webhook worker"),
		pr("ws/cur", 12, bb.Review, 2, "Fix the login redirect after an SSO timeout"),
		pr("ws/other", 5, bb.Review, 1, "Bump the 漢字 module 🚀"),
	}
}

// fixtureDiff is the diff that the fake twg prints for each PR. It changes
// two files.
const fixtureDiff = `diff --git a/api/retry.go b/api/retry.go
--- a/api/retry.go
+++ b/api/retry.go
@@ -1 +1 @@
-const budget = 0
+const budget = 5
diff --git a/docs/retry.md b/docs/retry.md
new file mode 100644
--- /dev/null
+++ b/docs/retry.md
@@ -0,0 +1 @@
+Each endpoint gets a retry budget.
`

// fixtureCommits is the commit list that the fake twg prints for each PR,
// newest first. fixtureFull is the full hash of the newest commit.
const (
	fixtureFull    = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
	fixtureCommits = `[
{"hash": "` + fixtureFull + `", "date": "2026-11-01T10:00:00+00:00",
 "message": "Add the retry budget\n\nEach endpoint gets five tries.", "author": {"raw": "Ana Tester <ana@example.com>"}},
{"hash": "b2c3d4e5f60718293a4b5c6d7e8f901234567890", "date": "2026-10-31T09:00:00+00:00",
 "message": "Write the retry docs", "author": {"raw": "Ana Tester <ana@example.com>"}}
]`
)

// commitDiff is the patch that the fake git of fakeGit prints for a commit.
const commitDiff = `diff --git a/api/budget.go b/api/budget.go
new file mode 100644
--- /dev/null
+++ b/api/budget.go
@@ -0,0 +1 @@
+const tries = 5
`

// fakeGit puts a fake git first on PATH. It appends its arguments to the file
// gitLog. If code is 0, it prints commitDiff for "show". Else each command
// exits with code, as when the checkout does not have the commit.
func fakeGit(t *testing.T, code int) (gitLog string) {
	bin := t.TempDir()
	gitLog = filepath.Join(bin, "git.log")
	script := "#!/bin/sh\necho \"$*\" >> '" + gitLog + "'\n"
	if code != 0 {
		script += fmt.Sprintf("exit %d\n", code)
	}
	script += "if [ \"$3\" = show ]; then\ncat <<'EOF'\n" + commitDiff + "EOF\nfi\n"
	must(os.WriteFile(filepath.Join(bin, "git"), []byte(script), 0o755))
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	return gitLog
}

func newFixture(dir string, prs []bb.PR, errs []string) fixture {
	twgLog := filepath.Join(dir, "twg.log")
	bin := filepath.Join(dir, "twg")
	script := "#!/bin/sh\necho \"$*\" >> '" + twgLog + "'\n" +
		"case \"$3\" in\ndiff) cat <<'EOF'\n" + fixtureDiff + "EOF\n;;\n" +
		"commits) cat <<'EOF'\n" + fixtureCommits + "\nEOF\n;;\n*) echo '{}' ;;\nesac\n"
	must(os.WriteFile(bin, []byte(script), 0o755))
	log := &cmdlog.Log{}
	runner := &twg.Runner{Bin: bin, Timeout: 5 * time.Second, Record: log.Add}
	paths := store.Paths{Cache: filepath.Join(dir, "cache"), State: filepath.Join(dir, "state")}
	env := refresh.Env{Paths: paths, Repo: "ws/cur", WS: "ws", Prompt: "ws/cur", Twg: runner}
	listFile := paths.ListFile(env.Prompt, "open")
	must(store.SaveList(listFile, store.ListCache{PRs: prs, Errors: errs, Saved: time.Now()}))

	spawns, starts, opened := &[]string{}, &[]string{}, &[][]string{}
	m := New(Deps{
		Env:     env,
		Actions: actions.Deps{Twg: runner, Paths: paths, Repo: env.Repo, ListFile: listFile, Log: log, Now: time.Now},
		Opener: browser.Opener{Host: "aqua", Force: "local", Run: func(context.Context, string, ...string) ([]byte, error) {
			return nil, nil
		}},
		Log: log,
		Spawn: func(list string, auto bool) error {
			*spawns = append(*spawns, fmt.Sprintf("%s %t", list, auto))
			return nil
		},
		Review: func(url string) *exec.Cmd { return exec.Command("true", url) },
		// sh is on the PATH, so the reviewer is there. No test runs it.
		ReviewConfig: func() (review.Config, error) {
			return review.Config{Name: "claude", Command: []string{"sh"}, Resume: []string{"claude", "--resume", "{session}"}}, nil
		},
		StartReview: func(repo string, id int, again bool) error {
			start := fmt.Sprintf("--ai-review %s %d", repo, id)
			if again {
				start += " --again"
			}
			*starts = append(*starts, start)
			return nil
		},
		Tab: termtab.Opener{
			Env: func(k string) string { return map[string]string{"REX_SESSION": "s1"}[k] },
			Run: func(_ context.Context, name string, args ...string) error {
				*opened = append(*opened, append([]string{name}, args...))
				if args[0] == "focus" {
					return errors.New("no such tab")
				}
				return nil
			},
		},
		NoTick: true,
		// A popup ignores keys until the test sends "wait".
		PopupGuard: time.Hour,
	})
	return fixture{m: feed(m, tea.WindowSizeMsg{Width: 120, Height: 40}), paths: paths, spawns: spawns,
		starts: starts, opened: opened, twgLog: twgLog}
}

// writeReview puts the state of a review of pr in the state directory.
func (f fixture) writeReview(pr bb.PR, st review.State) {
	must(review.WriteState(f.paths.ReviewFile(pr.Repo, pr.ID), st))
}

// doneReview is a finished review of pr with the session s-1. Its summary has
// an escape sequence, which the screen must not send.
func doneReview(pr bb.PR) review.State {
	now := time.Now()
	return review.State{
		Status: review.StatusDone, Started: now.Add(-7 * time.Minute), Finished: now.Add(-5 * time.Minute),
		Reviewer: "claude", Model: "haiku", Session: "s-1", Dir: "/work/review", Updated: pr.UpdatedRaw, Verdict: "request-changes",
		Summary:  "The budget never resets.\x1b]52;c;eA==\x07 Add a test.",
		Findings: []review.Finding{{File: "api/retry.go", Line: 12, Severity: "high", Note: "The budget is not reset after a success."}},
	}
}

// writeDetails puts a fresh details preview of pr with the description desc
// in the cache.
func (f fixture) writeDetails(pr bb.PR, desc string) {
	data, err := json.Marshal(map[string]any{
		"pr":     map[string]any{"id": pr.ID, "title": pr.Title, "state": "OPEN", "description": desc},
		"checks": []any{}, "diffstat": []any{},
	})
	must(err)
	f.writePreview(pr, "details", string(data))
}

// writePreview puts a fresh preview of the view of pr in the cache.
func (f fixture) writePreview(pr bb.PR, view, data string) {
	path := f.paths.PreviewFile(pr.Repo, pr.ID, pr.UpdatedRaw, view)
	must(os.MkdirAll(filepath.Dir(path), 0o755))
	must(os.WriteFile(path, []byte(data), 0o644))
}

func (f fixture) twg() string {
	data, err := os.ReadFile(f.twgLog)
	if err != nil && !os.IsNotExist(err) {
		panic(err)
	}
	return string(data)
}

// bar returns the last line of the view, without styles.
func (f fixture) bar() string {
	lines := strings.Split(ansi.Strip(f.m.View()), "\n")
	return lines[len(lines)-1]
}

// panel returns the lines of the main panel, with the styles and the border.
func (f fixture) panel() []string {
	return strings.Split(f.m.mainBox(layout(f.m.w, f.m.h).Main), "\n")
}

// mainText returns the text of the main panel, without the styles and the
// border.
func (f fixture) mainText() string {
	var lines []string
	for _, l := range f.panel() {
		lines = append(lines, strings.TrimSpace(strings.Trim(ansi.Strip(l), "│")))
	}
	return strings.Join(lines, "\n")
}

// logged reports whether the command log has a line that starts with prefix.
func (f fixture) logged(prefix string) bool {
	for _, l := range f.m.d.Log.Lines(100) {
		if strings.HasPrefix(l.Text, prefix) {
			return true
		}
	}
	return false
}

// keyMsg makes the message of a key. A text of more than one character is one
// message with all the runes, as the terminal sends fast keys. "paste:<text>"
// is pasted text.
func keyMsg(k string) tea.KeyMsg {
	switch k {
	case "space":
		return tea.KeyMsg{Type: tea.KeySpace, Runes: []rune{' '}}
	case "enter":
		return tea.KeyMsg{Type: tea.KeyEnter}
	case "esc":
		return tea.KeyMsg{Type: tea.KeyEsc}
	case "ctrl+d":
		return tea.KeyMsg{Type: tea.KeyCtrlD}
	case "ctrl+u":
		return tea.KeyMsg{Type: tea.KeyCtrlU}
	}
	if text, ok := strings.CutPrefix(k, "paste:"); ok {
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(text), Paste: true}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(k)}
}

// send feeds the keys to the model, one at a time. The name "wait" is not a
// key: it lets the guard time of the popup pass.
func send(m Model, keys ...string) Model {
	for _, k := range keys {
		if k == "wait" {
			m.guardUntil = time.Time{}
			continue
		}
		m = feed(m, keyMsg(k))
	}
	return m
}

// feed gives msg to the model, and then runs the command that it returns.
func feed(m Model, msg tea.Msg) Model {
	next, cmd := m.Update(msg)
	return run(next.(Model), cmd)
}

var cmdType = reflect.TypeOf((*tea.Cmd)(nil)).Elem()

// run runs cmd at once and feeds its message back. A batch or a sequence is a
// list of commands, and run runs each of them. A quit message stops it: a
// model that quits returns tea.Quit for each message.
func run(m Model, cmd tea.Cmd) Model {
	if cmd == nil {
		return m
	}
	msg := cmd()
	if _, ok := msg.(tea.QuitMsg); msg == nil || ok {
		return m
	}
	if v := reflect.ValueOf(msg); v.Kind() == reflect.Slice && v.Type().Elem() == cmdType {
		for i := range v.Len() {
			m = run(m, v.Index(i).Interface().(tea.Cmd))
		}
		return m
	}
	return feed(m, msg)
}

// sends runs cmd and reports whether it gives a message of the type of want,
// for example tea.QuitMsg. It also looks into a batch or a sequence.
func sends(cmd tea.Cmd, want tea.Msg) bool {
	if cmd == nil {
		return false
	}
	msg := cmd()
	if reflect.TypeOf(msg) == reflect.TypeOf(want) {
		return true
	}
	if v := reflect.ValueOf(msg); v.Kind() == reflect.Slice && v.Type().Elem() == cmdType {
		for i := range v.Len() {
			if sends(v.Index(i).Interface().(tea.Cmd), want) {
				return true
			}
		}
	}
	return false
}

func TestKeyFlows(t *testing.T) {
	merge := "bitbucket pull-requests merge --pull-request "
	cases := []struct {
		name  string
		keys  []string
		check func(t *testing.T, f fixture)
	}{
		{"next list", []string{"space", "]"}, func(t *testing.T, f fixture) {
			if f.m.list != "closed" || len(f.m.sel) != 0 {
				t.Errorf("list = %q, selection = %v, want closed and empty", f.m.list, f.m.sel)
			}
			if !slices.Contains(*f.spawns, "closed true") {
				t.Errorf("Spawn calls = %q, want closed true", *f.spawns)
			}
		}},
		{"select two", []string{"space", "j", "space"}, func(t *testing.T, f fixture) {
			if bar := f.bar(); !strings.Contains(bar, "2 selected") {
				t.Errorf("bar = %q, want 2 selected", bar)
			}
		}},
		{"approve of two PRs asks", []string{"space", "j", "space", "a"}, func(t *testing.T, f fixture) {
			if f.m.popup == nil || f.m.popup.kind != confirmKind || f.m.busy != "" {
				t.Fatalf("popup = %+v, busy = %q, want the approve confirm and nothing running", f.m.popup, f.m.busy)
			}
			text := ansi.Strip(strings.Join(f.m.popup.lines, "\n"))
			for _, want := range []string{"Approve these PRs?", "cur#11", "(your own PR, no approval)", "cur#12"} {
				if !strings.Contains(text, want) {
					t.Errorf("popup = %q, want %q", text, want)
				}
			}
			if log := f.twg(); strings.Contains(log, " approve ") {
				t.Errorf("twg log = %q, want no approve", log)
			}
			// esc cancels, and nothing runs.
			if f.m = send(f.m, "wait", "esc"); f.m.popup != nil || strings.Contains(f.twg(), " approve ") || !strings.Contains(f.bar(), "Cancelled. Nothing changed.") {
				t.Errorf("popup = %+v, twg log = %q, bar = %q, want a cancel", f.m.popup, f.twg(), f.bar())
			}
			// y approves the PR that is not yours.
			f.m = send(f.m, "a", "wait", "y")
			log := f.twg()
			if !strings.Contains(log, "pull-requests approve 12 --repo ws/cur") || strings.Contains(log, "approve 11 ") {
				t.Errorf("twg log = %q, want the approve of #12 only", log)
			}
		}},
		{"approve of two of your own PRs does not ask", nil, func(t *testing.T, f fixture) {
			prs := fixturePRs()
			prs[1].Role = bb.Mine
			f = newFixture(t.TempDir(), prs, nil)
			f.m = send(f.m, "space", "j", "space", "a")
			if f.m.popup != nil || strings.Contains(f.twg(), " approve ") {
				t.Fatalf("popup = %+v, twg log = %q, want no popup and no approve", f.m.popup, f.twg())
			}
			if bar, want := f.bar(), "#11 your own PR, no approval · #12 your own PR, no approval"; !strings.Contains(bar, want) {
				t.Errorf("bar = %q, want %q", bar, want)
			}
		}},
		{"merge asks", []string{"space", "j", "space", "m"}, func(t *testing.T, f fixture) {
			if f.m.popup == nil || f.m.popup.kind != confirmKind {
				t.Fatalf("popup = %+v, want a confirm popup", f.m.popup)
			}
			text := ansi.Strip(strings.Join(f.m.popup.lines, "\n"))
			if !strings.Contains(text, "#11") || !strings.Contains(text, "#12") {
				t.Errorf("popup = %q, want #11 and #12", text)
			}
		}},
		{"merge cancelled", []string{"space", "j", "space", "m", "wait", "n"}, func(t *testing.T, f fixture) {
			if f.m.popup != nil {
				t.Errorf("popup = %+v, want none", f.m.popup)
			}
			if log := f.twg(); strings.Contains(log, merge) {
				t.Errorf("twg log = %q, want no merge", log)
			}
			if bar := f.bar(); !strings.Contains(bar, "Cancelled") {
				t.Errorf("bar = %q, want Cancelled", bar)
			}
		}},
		{"merge confirmed", []string{"space", "j", "space", "m", "wait", "y"}, func(t *testing.T, f fixture) {
			log := f.twg()
			for _, id := range []string{"11", "12"} {
				if !strings.Contains(log, merge+id+" --repo ws/cur") {
					t.Errorf("twg log = %q, want the merge of #%s", log, id)
				}
			}
			if f.m.popup == nil || f.m.popup.kind != resultKind {
				t.Errorf("popup = %+v, want a result popup", f.m.popup)
			}
			if !slices.Contains(*f.spawns, "open false") {
				t.Errorf("Spawn calls = %q, want open false", *f.spawns)
			}
		}},
		{"order keeps the cursor PR", []string{"S"}, func(t *testing.T, f fixture) {
			if got, want := f.m.currentKey(), fixturePRs()[0].Key(); got != want {
				t.Errorf("cursor on %s after S, want %s", got, want)
			}
		}},
		{"approve on the closed list", []string{"]", "a"}, func(t *testing.T, f fixture) {
			if log := f.twg(); log != "" {
				t.Errorf("twg log = %q, want no call", log)
			}
			if bar := f.bar(); !strings.Contains(bar, "works on the open list only") {
				t.Errorf("bar = %q, want the open list rule", bar)
			}
		}},
		{"grouped runes", []string{"jj"}, func(t *testing.T, f fixture) {
			if got := f.m.currentKey(); got != "ws/other#5" {
				t.Errorf("cursor on %q, want ws/other#5 (two rows down)", got)
			}
		}},
		{"conflict check outside the repo", []string{"jj", "c"}, func(t *testing.T, f fixture) {
			if bar := f.bar(); !strings.Contains(bar, "Conflict check needs the checkout. Open bb-prs in ws/other.") {
				t.Errorf("bar = %q, want the outside-the-repo text", bar)
			}
			if f.m.busy != "" {
				t.Errorf("busy = %q, want nothing to run", f.m.busy)
			}
			for _, l := range f.m.d.Log.Lines(50) {
				if strings.HasPrefix(l.Text, "Check conflicts") {
					t.Errorf("command log has %q, want no check", l.Text)
				}
			}
		}},
		{"merge and y in one read", []string{"my"}, func(t *testing.T, f fixture) {
			if f.m.popup == nil || f.m.popup.kind != confirmKind {
				t.Errorf("popup = %+v, want the merge confirm, still open", f.m.popup)
			}
			if log := f.twg(); strings.Contains(log, merge) {
				t.Errorf("twg log = %q, want no merge", log)
			}
		}},
		{"sync popup: choose a method, cancel, then run the merge", nil, func(t *testing.T, f fixture) {
			// A fake git that succeeds. It shows which method ran.
			bin := t.TempDir()
			must(os.WriteFile(filepath.Join(bin, "git"), []byte("#!/bin/sh\nexit 0\n"), 0o755))
			t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
			// gitLines returns the git commands in the command log.
			gitLines := func() (lines []string) {
				for _, l := range f.m.d.Log.Lines(50) {
					if strings.HasPrefix(l.Text, "git ") {
						lines = append(lines, l.Text)
					}
				}
				return lines
			}
			f.m.busy = "Fetching origin…" // as after s
			plan := actions.SyncPlan{Todo: []actions.Behind{{PR: fixturePRs()[0], Commits: 2, Git: &gitops.Git{Dir: t.TempDir()}}}}
			f.m = send(feed(f.m, syncPlanMsg{plan: plan}), "wait")
			// The popup wraps long lines, so compare the words.
			shown := func() string {
				return strings.Join(strings.Fields(ansi.Strip(strings.Join(f.m.popup.body(popupText), "\n"))), " ")
			}
			for _, want := range []string{
				"▸ Rebase feat/x onto main",
				"rewrites its commits, force-push with lease; the author must reset the local branch",
				"Merge main into feat/x",
				"one merge commit, normal push; rewrites nothing",
			} {
				if got := shown(); !strings.Contains(got, want) {
					t.Errorf("popup = %q, want %q", got, want)
				}
			}
			f.m = send(f.m, "j")
			if got := shown(); !strings.Contains(got, "▸ Merge main into feat/x") || strings.Contains(got, "▸ Rebase") {
				t.Errorf("popup after j = %q, want the merge chosen", got)
			}
			f.m = send(f.m, "esc")
			if f.m.popup != nil || f.m.busy != "" || len(gitLines()) != 0 {
				t.Errorf("popup = %+v, busy = %q, git commands = %q, want a closed popup and no sync", f.m.popup, f.m.busy, gitLines())
			}

			// The popup opens again with Rebase chosen. j and enter run the merge.
			f.m.busy = "Fetching origin…"
			f.m = send(feed(f.m, syncPlanMsg{plan: plan}), "wait", "j", "enter")
			var merged, rebased bool
			for _, l := range gitLines() {
				merged = merged || strings.Contains(l, " merge --no-ff ")
				rebased = rebased || strings.Contains(l, " rebase ")
			}
			if !merged || rebased {
				t.Errorf("git commands = %q, want the merge and no rebase", gitLines())
			}
			if f.m.popup == nil || f.m.popup.kind != resultKind {
				t.Errorf("popup = %+v, want a result popup", f.m.popup)
			}
		}},
		{"w, h, and l outside [0]", nil, func(t *testing.T, f fixture) {
			for _, k := range []string{"w", "h", "l"} {
				f.m.flash = note{}
				f.m = send(f.m, k)
				if bar := f.bar(); !strings.Contains(bar, "Press 0 to focus the main panel first.") {
					t.Errorf("bar after %s = %q, want the text that asks for [0]", k, bar)
				}
			}
			if f.m.wrap || f.m.hscroll != 0 {
				t.Errorf("wrap = %t, hscroll = %d, want no change", f.m.wrap, f.m.hscroll)
			}
		}},
		{"ctrl+d and ctrl+u in [2]", nil, func(t *testing.T, f fixture) {
			// 10 PRs. At 14 lines, [2] shows 6 rows, so a half page is 3.
			var prs []bb.PR
			for i := range 10 {
				p := fixturePRs()[0]
				p.ID += i
				prs = append(prs, p)
			}
			f = newFixture(t.TempDir(), prs, nil)
			f.m = feed(f.m, tea.WindowSizeMsg{Width: 120, Height: 14})
			f.m = send(f.m, "ctrl+d")
			if got := f.m.cursor["open"]; got != 3 {
				t.Errorf("cursor after ctrl+d = %d, want 3", got)
			}
			f.m = send(f.m, "ctrl+d", "ctrl+d", "ctrl+d")
			if got, off := f.m.cursor["open"], f.m.offset["open"]; got != 9 || off != 4 {
				t.Errorf("cursor, offset after 4 ctrl+d = %d, %d, want 9 (the last row), 4 (in view)", got, off)
			}
			if f.m = send(f.m, "ctrl+u"); f.m.cursor["open"] != 6 {
				t.Errorf("cursor after ctrl+u = %d, want 6", f.m.cursor["open"])
			}
		}},
		{"ctrl+d and ctrl+u in [0] Status", nil, func(t *testing.T, f fixture) {
			// At 20 lines, [0] shows 8 lines, so a half page is 4.
			f.writeDetails(fixturePRs()[0], strings.Repeat("A line of the description.\n\n", 20))
			f.m = feed(f.m, tea.WindowSizeMsg{Width: 120, Height: 20})
			f.m = run(f.m, f.m.Init())
			f.m = send(f.m, "0", "ctrl+d")
			if f.m.scroll != 4 {
				t.Errorf("scroll after ctrl+d = %d, want 4", f.m.scroll)
			}
			if f.m = send(f.m, "ctrl+u", "ctrl+u"); f.m.scroll != 0 {
				t.Errorf("scroll after ctrl+u twice = %d, want 0", f.m.scroll)
			}
			f.m = send(f.m, "1", "ctrl+d")
			if f.m.scroll != 0 {
				t.Errorf("scroll after ctrl+d in [1] = %d, want 0", f.m.scroll)
			}
		}},
		{"pasted text", []string{"paste:m"}, func(t *testing.T, f fixture) {
			if f.m.popup != nil || f.m.busy != "" {
				t.Errorf("popup = %+v, busy = %q, want nothing to run", f.m.popup, f.m.busy)
			}
		}},
		{"next view", []string{"}"}, func(t *testing.T, f fixture) {
			if f.m.view != "changes" {
				t.Errorf("view after } from status = %q, want changes", f.m.view)
			}
			if f.m = send(f.m, "}"); f.m.view != "activity" {
				t.Errorf("view after } from changes = %q, want activity", f.m.view)
			}
		}},
		{"changes: the files of All changes, zoom, and go back", []string{"}", "0", "enter", "j", "enter"}, func(t *testing.T, f fixture) {
			if log := f.twg(); !strings.Contains(log, "bitbucket pull-requests diff 11 --repo ws/cur\n") {
				t.Errorf("twg log = %q, want the diff of #11", log)
			}
			// The header of the file list. The column of the counts has the
			// width of its rows.
			const header, second = "ST  +/-", "+Each endpoint gets a retry budget."
			if got := f.mainText(); strings.Contains(got, header) ||
				!strings.Contains(got, second) || strings.Contains(got, "budget = 5") {
				t.Errorf("zoomed panel =\n%s\nwant only the diff of the second file", got)
			}
			if f.logged("Review") {
				t.Error("command log has a review, want none")
			}

			// In the zoom, j scrolls the diff, and the file stays. At 14
			// lines, the panel shows 2 of the 3 lines of the diff.
			f.m = feed(f.m, tea.WindowSizeMsg{Width: 120, Height: 14})
			f.m = send(f.m, "j")
			if got := f.mainText(); strings.Contains(got, "docs/retry.md") || !strings.Contains(got, second) {
				t.Errorf("zoomed panel after j =\n%s\nwant the second file, scrolled one line", got)
			}
			f.m = feed(f.m, tea.WindowSizeMsg{Width: 120, Height: 40})

			// esc ends the zoom also when another panel has focus.
			f.m = send(f.m, "2", "esc")
			if f.m.quitting {
				t.Fatal("esc quit, want the end of the zoom")
			}
			if got := f.mainText(); strings.Split(got, "\n")[1] != "← All changes (esc)" ||
				!strings.Contains(got, header) || !strings.Contains(got, second) {
				t.Errorf("panel after esc =\n%s\nwant the scope, the file list, and the diff of the second file", got)
			}
			// At 120 columns the list is on top of the diff. At 250 columns
			// the list is at the left of the diff.
			for _, w := range []int{120, 250} {
				f.m = feed(f.m, tea.WindowSizeMsg{Width: w, Height: 40})
				head := ansi.Strip(f.panel()[2]) // under the line of the scope
				if side := strings.Contains(head, "│ docs/retry.md"); side != (w == 250) {
					t.Errorf("width %d: first line = %q, want the diff beside the list: %t", w, head, w == 250)
				}
			}
		}},
		{"changes: the files of a commit come from git, and esc goes back", nil, func(t *testing.T, f fixture) {
			gitLog := fakeGit(t, 0)
			f.m.d.Env.Dir = t.TempDir()
			f.m = send(f.m, "}", "0", "j", "enter")
			got := f.mainText()
			for _, want := range []string{"← a1b2c3d4 (esc)", "api/budget.go", "+const tries = 5"} {
				if !strings.Contains(got, want) {
					t.Errorf("panel =\n%s\nwant %q", got, want)
				}
			}
			// TestShow checks the options of git show.
			data, _ := os.ReadFile(gitLog)
			if calls := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n"); len(calls) != 1 ||
				!strings.HasPrefix(calls[0], "-C "+f.m.d.Env.Dir+" show ") || !strings.HasSuffix(calls[0], " "+fixtureFull) {
				t.Errorf("git calls = %q, want one git -C %s show of %s", data, f.m.d.Env.Dir, fixtureFull)
			}
			if !f.logged("Load commit a1b2c3d4") {
				t.Error("command log has no head Load commit a1b2c3d4")
			}

			f.m = send(f.m, "esc")
			if f.m.quitting {
				t.Fatal("esc quit, want the commit list")
			}
			got = f.mainText()
			for _, want := range []string{"All changes  2 files", "a1b2c3d4  11-01  Ana T.  Add the retry budget",
				"Commit  " + fixtureFull, "1 file  +1 -0", "⏎ files · o open in browser"} {
				if !strings.Contains(got, want) {
					t.Errorf("panel after esc =\n%s\nwant %q", got, want)
				}
			}
		}},
		{"changes: esc with [1] focus goes one level out, and does not quit", []string{"}", "0", "enter", "enter", "1", "esc"}, func(t *testing.T, f fixture) {
			if f.m.quitting || f.m.level != levelFiles {
				t.Errorf("quitting = %t, level = %d, want no quit and the files level (%d)", f.m.quitting, f.m.level, levelFiles)
			}
		}},
		{"changes: a list reload keeps the row of the same PR, or goes back to the commit list", nil, func(t *testing.T, f fixture) {
			// The update of #11 has a new update time. Its commit list puts a
			// new commit first, or it does not have the commit of the cursor.
			const newer = "2026-11-02T09:00:00"
			moved := `[{"hash": "c3d4e5f60718293a4b5c6d7e8f90123456789012", "date": "2026-11-02T08:00:00+00:00",
 "message": "Fix the budget", "author": {"raw": "Ana Tester <ana@example.com>"}},` + fixtureCommits[1:]
			gone := `[{"hash": "b2c3d4e5f60718293a4b5c6d7e8f901234567890", "date": "2026-10-31T09:00:00+00:00",
 "message": "Write the retry docs", "author": {"raw": "Ana Tester <ana@example.com>"}}]`
			updated := fixturePRs()
			updated[0].UpdatedRaw = newer
			rows := []struct {
				name    string
				local   bool // the commit files come from a fake git
				keys    []string
				prs     []bb.PR // the open list after the reload
				commits string  // the commit list of the update; "" is the one of the fake twg
				// The cursor, the level, the row, and the file after the reload.
				pr               string
				level, row, file int
			}{
				{"another PR: #11 is gone", false, []string{"}", "0", "enter", "j"}, fixturePRs()[1:], "", "ws/cur#12", levelCommits, 0, 0},
				{"same PR, new update, All changes", false, []string{"}", "0", "enter", "j"}, updated, "", "ws/cur#11", levelFiles, 0, 1},
				{"same PR, new update, the commit is still there", true, []string{"}", "0", "j", "enter"}, updated, moved, "ws/cur#11", levelFiles, 2, 0},
				{"same PR, new update, the commit is gone", true, []string{"}", "0", "j", "enter"}, updated, gone, "ws/cur#11", levelCommits, 0, 0},
			}
			for _, r := range rows {
				t.Run(r.name, func(t *testing.T) {
					f := newFixture(t.TempDir(), fixturePRs(), nil)
					if r.local {
						fakeGit(t, 0)
						f.m.d.Env.Dir = t.TempDir()
					}
					f.m = send(f.m, r.keys...)
					if f.m.level != levelFiles {
						t.Fatalf("level = %d before the reload, want the files level", f.m.level)
					}
					if r.commits != "" {
						path := f.paths.PreviewFile("ws/cur", 11, newer, "commits")
						must(os.MkdirAll(filepath.Dir(path), 0o755))
						must(os.WriteFile(path, []byte(r.commits), 0o644))
					}
					// No key moves the cursor: the timer sees the new list file.
					path := f.paths.ListFile("ws/cur", "open")
					must(store.SaveList(path, store.ListCache{PRs: r.prs, Saved: time.Now()}))
					later := time.Now().Add(time.Minute)
					must(os.Chtimes(path, later, later))
					f.m = feed(f.m, tickMsg(time.Now()))
					if got := f.m.currentKey(); got != r.pr {
						t.Fatalf("cursor on %q after the reload, want %s", got, r.pr)
					}
					if f.m.level != r.level || f.m.row != r.row || f.m.file != r.file {
						t.Errorf("level, row, file = %d, %d, %d, want %d, %d, %d", f.m.level, f.m.row, f.m.file, r.level, r.row, r.file)
					}
					if c, _ := f.m.changesData(); r.row > 0 && f.m.scopeKey(c) != fixtureFull {
						t.Errorf("scope = %q, want the commit %s", f.m.scopeKey(c), fixtureFull)
					}
				})
			}
		}},
		{"changes: o opens the commit, or the PR on All changes", nil, func(t *testing.T, f fixture) {
			var opened []string
			f.m.d.Opener.Run = func(_ context.Context, name string, args ...string) ([]byte, error) {
				opened = append(opened, name+" "+strings.Join(args, " "))
				return nil, nil
			}
			f.m = send(f.m, "}", "0", "j", "o", "k", "o")
			want := []string{"open https://bitbucket.org/ws/cur/commits/" + fixtureFull, "open https://bitbucket.org/ws/cur/pull-requests/11"}
			if !slices.Equal(opened, want) {
				t.Errorf("opened = %q, want %q", opened, want)
			}
		}},
		{"changes: a commit of a PR in another repo shows the hint, and runs no git", nil, func(t *testing.T, f fixture) {
			gitLog := fakeGit(t, 0)
			f.m.d.Env.Dir = t.TempDir()
			f.m = send(f.m, "jj", "}", "0", "j", "enter")
			const hint = "The files of a commit need the checkout of ws/other. Press o to open it in the browser."
			if got := f.mainText(); !strings.Contains(squash(got), squash(hint)) {
				t.Errorf("panel =\n%s\nwant the hint %q", got, hint)
			}
			if _, err := os.Stat(gitLog); err == nil || f.logged("Load commit") || f.m.level != levelCommits {
				t.Errorf("git ran: %t, command log has Load commit: %t, level = %d, want no git and the commit list",
					err == nil, f.logged("Load commit"), f.m.level)
			}
		}},
		{"changes: a commit that the checkout does not have shows the fetch hint, and enter loads it again", nil, func(t *testing.T, f fixture) {
			gitLog := fakeGit(t, 128)
			f.m.d.Env.Dir = t.TempDir()
			const hint = "The checkout does not have commit a1b2c3d4. Run git fetch origin, then press enter to load it again."
			shows := func() int {
				data, _ := os.ReadFile(gitLog)
				return strings.Count(string(data), " show ")
			}
			for i, step := range []struct {
				keys  []string
				shows int
				level int
			}{
				{[]string{"}", "0", "j", "enter"}, 1, levelFiles},
				{[]string{"enter"}, 2, levelFiles},
				{[]string{"esc"}, 2, levelCommits},
			} {
				f.m = send(f.m, step.keys...)
				if got := f.mainText(); !strings.Contains(squash(got), squash(hint)) || shows() != step.shows || f.m.level != step.level {
					t.Errorf("step %d: git show ran %d times, level = %d, panel =\n%s\nwant %d times, level %d, and the hint %q",
						i, shows(), f.m.level, got, step.shows, step.level, hint)
				}
			}
		}},
		{"changes: ctrl+d and ctrl+u in the zoom stop at the ends of the diff", nil, func(t *testing.T, f fixture) {
			// At 120×40, the zoom shows 28 lines, so a half page is 14. The
			// diff has 62 lines: the line of the file, the hunk line, and 60
			// lines. Thus the scroll stops at 62−28 = 34.
			f.writePreview(fixturePRs()[0], "diff", "diff --git a/long.go b/long.go\n--- a/long.go\n+++ b/long.go\n@@ -1,0 +1,60 @@\n"+
				strings.Repeat("+a line\n", 60))
			f.m = send(f.m, "}", "0", "enter", "enter", "ctrl+d", "ctrl+d", "ctrl+d", "ctrl+d")
			if f.m.level != levelZoom || f.m.scroll != 34 {
				t.Errorf("level = %d, scroll after ctrl+d four times = %d, want the zoom (%d) and 34", f.m.level, f.m.scroll, levelZoom)
			}
			if f.m = send(f.m, "ctrl+u", "ctrl+u", "ctrl+u"); f.m.scroll != 0 {
				t.Errorf("scroll after ctrl+u three times = %d, want 0", f.m.scroll)
			}
		}},
		{"changes: k and ctrl+u on the first PR keep the files level", []string{"}", "0", "enter", "j", "2", "k", "ctrl+u"}, func(t *testing.T, f fixture) {
			if f.m.level != levelFiles || f.m.file != 1 {
				t.Errorf("level = %d, file = %d, want the files level (%d) and file 1: the cursor did not move", f.m.level, f.m.file, levelFiles)
			}
		}},
		{"R with a missing reviewer", nil, func(t *testing.T, f fixture) {
			f.m.d.ReviewConfig = func() (review.Config, error) {
				return review.Config{Name: "claude", Command: []string{"bb-prs-no-such-reviewer"}}, nil
			}
			f.m = send(f.m, "R")
			const want = `Reviewer "claude" not found. Install it, or set the reviewer in ~/.config/bb-prs/reviewer.json.`
			if bar := f.bar(); !strings.Contains(bar, want) || len(*f.starts) != 0 {
				t.Errorf("bar = %q, starts = %q, want %q and no start", bar, *f.starts, want)
			}
		}},
		{"R with no review starts it, and a second R in the same read does not", []string{"RR"}, func(t *testing.T, f fixture) {
			if want := []string{"--ai-review ws/cur 11"}; !slices.Equal(*f.starts, want) {
				t.Errorf("starts = %q, want %q", *f.starts, want)
			}
			if bar, want := f.bar(), "A review of #11 runs already (started just now)."; !strings.Contains(bar, want) {
				t.Errorf("bar = %q, want %q", bar, want)
			}
		}},
		{"R while a review runs", nil, func(t *testing.T, f fixture) {
			f.writeReview(fixturePRs()[0], review.State{Status: review.StatusRunning, Started: time.Now().Add(-2 * time.Minute)})
			f.m = send(f.m, "R")
			const want = "A review of #11 runs already (started 2m ago)."
			if bar := f.bar(); !strings.Contains(bar, want) || len(*f.starts) != 0 {
				t.Errorf("bar = %q, starts = %q, want %q and no start", bar, *f.starts, want)
			}
		}},
		{"R on a finished review: choose to run it again, cancel, or open the session", nil, func(t *testing.T, f fixture) {
			f.writeReview(fixturePRs()[0], doneReview(fixturePRs()[0]))
			f.m = send(f.m, "R")
			if f.m.popup == nil || f.m.popup.title != "Review of #11" || len(*f.starts) != 0 {
				t.Fatalf("popup = %+v, starts = %q, want the popup Review of #11 and no start", f.m.popup, *f.starts)
			}
			shown := strings.Join(strings.Fields(ansi.Strip(strings.Join(f.m.popup.body(popupText), "\n"))), " ")
			for _, want := range []string{"▸ Open the review session", "Run the review again (the old result is replaced)"} {
				if !strings.Contains(shown, want) {
					t.Errorf("popup = %q, want %q", shown, want)
				}
			}
			if f.m = send(f.m, "wait", "esc"); f.m.popup != nil || len(*f.starts) != 0 || len(*f.opened) != 0 {
				t.Errorf("popup = %+v, starts = %q, opened = %q after esc, want nothing", f.m.popup, *f.starts, *f.opened)
			}
			if f.m = send(f.m, "R", "wait", "enter"); len(*f.opened) != 2 || len(*f.starts) != 0 {
				t.Errorf("opened = %q, starts = %q after enter, want the session opened and no review", *f.opened, *f.starts)
			}
			// Only this choice gives the child --again.
			if f.m = send(f.m, "R", "wait", "j", "enter"); f.m.popup != nil || !slices.Equal(*f.starts, []string{"--ai-review ws/cur 11 --again"}) {
				t.Errorf("popup = %+v, starts = %q after j and enter, want one new review with --again", f.m.popup, *f.starts)
			}
		}},
		{"enter on the Review view opens the session: the tab label and the resume argv", []string{"{", "0"}, func(t *testing.T, f fixture) {
			f.writeReview(fixturePRs()[0], doneReview(fixturePRs()[0]))
			f.m = send(f.m, "enter")
			want := [][]string{
				{"rex", "focus", "-s", "s1", "review cur#11"},
				{"rex", "run", "-s", "s1", "-c", "/work/review", "--label", "review cur#11", "--", "claude", "--resume", "s-1"},
			}
			if !reflect.DeepEqual(*f.opened, want) {
				t.Errorf("commands = %q, want %q", *f.opened, want)
			}
			if bar, want := f.bar(), "Opened the review session of #11 in a Rex tab."; !strings.Contains(bar, want) {
				t.Errorf("bar = %q, want %q", bar, want)
			}
		}},
		{"two quick enters on the Review view open one tab", []string{"{", "0"}, func(t *testing.T, f fixture) {
			f.writeReview(fixturePRs()[0], doneReview(fixturePRs()[0]))
			// The second enter comes before the open of the first enter ends.
			next, first := f.m.Update(keyMsg("enter"))
			next, second := next.(Model).Update(keyMsg("enter"))
			if f.m = run(run(next.(Model), first), second); len(*f.opened) != 2 {
				t.Fatalf("commands = %q, want one open (focus, then run)", *f.opened)
			}
			if f.m = send(f.m, "enter"); len(*f.opened) != 4 {
				t.Errorf("commands = %q, want a new open after the first open ended", *f.opened)
			}
		}},
		{"enter on the Review view with no Rex or tmux puts the resume command in the command log", []string{"{", "0"}, func(t *testing.T, f fixture) {
			f.m.d.Tab.Env = func(string) string { return "" }
			st := doneReview(fixturePRs()[0])
			st.Dir = "/work/my review"
			f.writeReview(fixturePRs()[0], st)
			f.m = send(f.m, "enter")
			if want := "cd '/work/my review' && claude --resume s-1"; !f.logged(want) {
				t.Errorf("command log = %+v, want %q", f.m.d.Log.Lines(20), want)
			}
			if bar, want := f.bar(), "No Rex or tmux. The resume command is in the command log."; !strings.Contains(bar, want) {
				t.Errorf("bar = %q, want %q", bar, want)
			}
		}},
		{"enter on the Review view while the review runs", []string{"{", "0"}, func(t *testing.T, f fixture) {
			f.writeReview(fixturePRs()[0], review.State{Status: review.StatusRunning, Started: time.Now().Add(-time.Minute)})
			f.m = send(f.m, "enter")
			if bar, want := f.bar(), "The review of #11 runs. Its session opens when it ends."; len(*f.opened) != 0 || !strings.Contains(bar, want) {
				t.Errorf("commands = %q, bar = %q, want no command and %q", *f.opened, bar, want)
			}
		}},
		{"enter on the Review view refuses a session id with a bad character", []string{"{", "0"}, func(t *testing.T, f fixture) {
			st := doneReview(fixturePRs()[0])
			st.Session = "s-1; rm -rf ~"
			f.writeReview(fixturePRs()[0], st)
			f.m = send(f.m, "enter")
			if bar := f.bar(); len(*f.opened) != 0 || !strings.Contains(bar, "not a valid session id") {
				t.Errorf("commands = %q, bar = %q, want no command and a refusal", *f.opened, bar)
			}
		}},
		{"R on two selected PRs, one with a finished review", []string{"space", "j", "space"}, func(t *testing.T, f fixture) {
			f.writeReview(fixturePRs()[0], doneReview(fixturePRs()[0]))
			f.m = send(f.m, "R")
			if f.m.popup == nil || f.m.popup.kind != confirmKind || len(*f.starts) != 0 {
				t.Fatalf("popup = %+v, starts = %q, want a confirm popup and no start", f.m.popup, *f.starts)
			}
			text := ansi.Strip(strings.Join(f.m.popup.lines, "\n"))
			for _, want := range []string{"Review these PRs with claude?", "cur#11", "review exists, skipped", "cur#12"} {
				if !strings.Contains(text, want) {
					t.Errorf("popup = %q, want %q", text, want)
				}
			}
			if f.m = send(f.m, "wait", "y"); !slices.Equal(*f.starts, []string{"--ai-review ws/cur 12"}) {
				t.Errorf("starts = %q, want the review of #12 only", *f.starts)
			}
		}},
		{"R on two PRs: a review that ends while the popup is open does not start again", []string{"space", "j", "space", "R"}, func(t *testing.T, f fixture) {
			if f.m.popup == nil || f.m.popup.kind != confirmKind {
				t.Fatalf("popup = %+v, want a confirm popup", f.m.popup)
			}
			// Another bb-prs finishes a review of #12.
			f.writeReview(fixturePRs()[1], doneReview(fixturePRs()[1]))
			f.m = send(f.m, "wait", "y")
			if want := []string{"--ai-review ws/cur 11"}; !slices.Equal(*f.starts, want) {
				t.Errorf("starts = %q, want %q", *f.starts, want)
			}
			if bar, want := f.bar(), "#12: review exists, skipped."; !strings.Contains(bar, want) {
				t.Errorf("bar = %q, want %q", bar, want)
			}
		}},
		{"R over the cap", nil, func(t *testing.T, f fixture) {
			for id := range review.MaxRunning {
				must(review.WriteState(f.paths.ReviewFile("ws/busy", id+1), review.State{Status: review.StatusRunning, Started: time.Now()}))
			}
			f.m = send(f.m, "R")
			const want = "3 reviews run already. Wait for one to end."
			if bar := f.bar(); !strings.Contains(bar, want) || len(*f.starts) != 0 {
				t.Errorf("bar = %q, starts = %q, want %q and no start", bar, *f.starts, want)
			}
		}},
		{"the mouse works again after tuicr", nil, func(t *testing.T, f fixture) {
			// tuicr turns off the mouse, and Bubble Tea does not turn it on
			// again.
			if _, cmd := f.m.Update(reviewMsg{pr: fixturePRs()[0]}); !sends(cmd, tea.EnableMouseCellMotion()) {
				t.Error("the commands after the review do not turn on the mouse")
			}
		}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t.TempDir(), fixturePRs(), nil)
			f.m = send(f.m, c.keys...)
			c.check(t, f)
		})
	}
}

// With wrap off, the main panel cuts a long line, and l scrolls it sideways.
// With wrap on, the line wraps.
func TestMainWrap(t *testing.T) {
	long := strings.Repeat("0123456789", 20) // 200 columns and no space
	cases := []struct {
		name   string
		keys   []string
		resize int      // if not 0, the screen width after the keys
		want   []string // the lines of the main panel with the long line, without styles
	}{
		{"cut", nil, 0, []string{long[:39] + "…"}},
		{"sideways", []string{"l"}, 0, []string{long[8:47] + "…"}},
		{"wrap", []string{"w"}, 0, []string{long[:40], long[40:80], long[80:120], long[120:160], long[160:]}},
		// 10 steps go to column 80. At 300 columns, the panel has 159
		// columns of text, so the side scroll stops at 200−159 = 41.
		{"enlarge the window after l", []string{"llllllllll"}, 300, []string{long[41:]}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t.TempDir(), fixturePRs(), nil)
			f.writeDetails(fixturePRs()[0], long)
			// A narrow screen: the main panel has 40 columns of text.
			f.m = feed(f.m, tea.WindowSizeMsg{Width: 44, Height: 60})
			f.m = run(f.m, f.m.Init())
			f.m = send(f.m, append([]string{"0"}, c.keys...)...)
			if c.resize > 0 {
				f.m = feed(f.m, tea.WindowSizeMsg{Width: c.resize, Height: 60})
			}
			var got []string
			for _, l := range strings.Split(ansi.Strip(f.m.mainBox(layout(f.m.w, f.m.h).Main)), "\n") {
				if strings.Contains(l, "56789") {
					got = append(got, strings.TrimSpace(strings.Trim(l, "│")))
				}
			}
			if !slices.Equal(got, c.want) {
				t.Errorf("lines = %q, want %q", got, c.want)
			}
		})
	}
}

func TestEmptyAndFailedList(t *testing.T) {
	const msg = "could not load the review inbox: Bitbucket API error: 429 (Bitbucket rate limit: wait some minutes, then r)"
	f := newFixture(t.TempDir(), nil, []string{msg})
	// The panel of the list must be wide enough for the full line.
	f.m = feed(f.m, tea.WindowSizeMsg{Width: 250, Height: 40})
	if view := ansi.Strip(f.m.View()); !strings.Contains(view, msg) {
		t.Errorf("view lacks the error line:\n%s", view)
	}
	f.m = send(f.m, "j", "k", "enter", "m", "s", "a", "o")
	if log := f.twg(); log != "" {
		t.Errorf("twg log = %q, want no call", log)
	}
}

// A key that the user typed while the sync plan loads must not confirm the
// sync popup that opens next.
func TestTypedKeysDoNotConfirm(t *testing.T) {
	f := newFixture(t.TempDir(), fixturePRs(), nil)
	f.m.d.PopupGuard = time.Hour
	f.m.busy = "Fetching origin…" // as after s
	f.m = send(f.m, "/")
	plan := actions.SyncPlan{Todo: []actions.Behind{{PR: fixturePRs()[0], Commits: 2}}}
	f.m = feed(f.m, syncPlanMsg{plan: plan})
	f.m = send(f.m, "enter")
	if f.m.popup == nil || f.m.popup.kind != confirmKind {
		t.Errorf("popup = %+v, want the sync confirm, still open", f.m.popup)
	}
	if f.m.filtering {
		t.Error("the filter is open")
	}
}

func TestQuitWaitsForAction(t *testing.T) {
	f := newFixture(t.TempDir(), fixturePRs(), nil)
	f.m.focus = focusStatus // so that no view load joins the command of the key
	next, approve := f.m.Update(keyMsg("a"))
	f.m = next.(Model)
	next, cmd := f.m.Update(keyMsg("q"))
	f.m = next.(Model)
	if sends(cmd, tea.QuitMsg{}) {
		t.Fatal("q quit while the approval runs")
	}
	if bar := f.bar(); !strings.Contains(bar, "Approving… runs. bb-prs quits when it ends.") {
		t.Errorf("bar = %q, want the text of the pending quit", bar)
	}
	if _, cmd = f.m.Update(approve()); !sends(cmd, tea.QuitMsg{}) {
		t.Error("no quit when the approval ended")
	}
}
