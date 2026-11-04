package refresh

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"bbprs/internal/bb"
	"bbprs/internal/cmdlog"
	"bbprs/internal/store"
	"bbprs/internal/twg"
)

// testEnv makes an Env with a fake twg. The fake appends its arguments to
// the returned log file, prints out, and exits with code.
func testEnv(t *testing.T, out string, code int) (Env, string) {
	t.Helper()
	dir := t.TempDir()
	log := filepath.Join(dir, "twg.log")
	script := "#!/bin/sh\necho \"$*\" >> '" + log + "'\ncat <<'EOF_OUT'\n" + out + "\nEOF_OUT\nexit " + strconv.Itoa(code) + "\n"
	bin := filepath.Join(dir, "twg")
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	r := twg.New(nil)
	r.Bin = bin
	return Env{
		Paths:  store.Paths{Cache: filepath.Join(dir, "cache"), State: filepath.Join(dir, "state")},
		Repo:   "ws/cur",
		WS:     "ws",
		Prompt: "ws/cur",
		Twg:    r,
	}, log
}

func readLog(t *testing.T, log string) string {
	t.Helper()
	data, err := os.ReadFile(log)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return string(data)
}

func TestSourceRepo(t *testing.T) {
	tests := []struct {
		name    string
		preview string // the "pr" part of an old details preview; empty: none
		out     string // the output of the fake twg
		want    string
		wantErr string
		wantGet bool // twg gets the PR
	}{
		{name: "a details preview of an old update", preview: `{"source":{"repository":{"full_name":"ws/fork"}}}`, want: "ws/fork"},
		{name: "no preview: twg gets the PR one time", out: `{"source":{"repository":{"full_name":"ws/cur"}}}`, want: "ws/cur", wantGet: true},
		{name: "a PR without the field", out: `{}`, wantErr: "the PR has no source repo", wantGet: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			env, log := testEnv(t, tc.out, 0)
			pr := bb.PR{Repo: "ws/cur", ID: 7, Role: bb.Open, UpdatedRaw: "new"}
			if tc.preview != "" {
				// The source repo never changes, so a preview of any update and any age is good.
				path := env.Paths.PreviewFile(pr.Repo, pr.ID, "old", "details")
				bundle := `{"pr":` + tc.preview + `,"checks":[],"diffstat":[]}`
				if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte(bundle), 0o644); err != nil {
					t.Fatal(err)
				}
				old := time.Now().Add(-30 * 24 * time.Hour)
				if err := os.Chtimes(path, old, old); err != nil {
					t.Fatal(err)
				}
			}

			got, err := SourceRepo(context.Background(), env, pr)

			if got != tc.want || (err == nil) != (tc.wantErr == "") || err != nil && !strings.Contains(err.Error(), tc.wantErr) {
				t.Errorf("SourceRepo = %q, %v; want %q, an error with %q", got, err, tc.want, tc.wantErr)
			}
			calls := strings.Count(readLog(t, log), "bitbucket pull-requests get 7 --repo ws/cur -o json")
			if want := map[bool]int{true: 1}[tc.wantGet]; calls != want {
				t.Errorf("twg got the PR %d times, want %d", calls, want)
			}
		})
	}
}

// The calls must keep the arguments of the bash script.
func TestCalls(t *testing.T) {
	cases := []struct {
		list, repo string
		want       []string
	}{
		{"open", "ws/cur", []string{
			"bitbucket pull-requests query --repo ws/cur -n 50",
			"bitbucket inbox --workspace ws -n 50",
			"bitbucket inbox --workspace ws --role author -n 50",
		}},
		{"open", "", []string{
			"bitbucket inbox --workspace ws -n 50",
			"bitbucket inbox --workspace ws --role author -n 50",
		}},
		{"closed", "ws/cur", []string{
			"bitbucket pull-requests query --repo ws/cur --state MERGED -n 25",
			"bitbucket pull-requests query --repo ws/cur --state DECLINED -n 15",
			"bitbucket inbox --workspace ws --role author --state MERGED -n 15",
		}},
		{"closed", "", []string{
			"bitbucket inbox --workspace ws --role author --state MERGED -n 15",
		}},
	}
	for _, c := range cases {
		t.Run(c.list+" "+c.repo, func(t *testing.T) {
			var got []string
			for _, call := range Calls(c.list, c.repo, "ws") {
				got = append(got, strings.Join(call.Args, " "))
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Errorf("Calls(%q, %q) args =\n%q\nwant\n%q", c.list, c.repo, got, c.want)
			}
		})
	}
}

func TestRunKeepsLastGoodList(t *testing.T) {
	env, _ := testEnv(t, "ok: false\nerror:\n  message: \"Bitbucket API error: 429\"", 1)
	path := env.Paths.ListFile(env.Prompt, "open")
	hourAgo := time.Now().Add(-time.Hour)
	old := store.ListCache{PRs: []bb.PR{{Repo: "ws/cur", ID: 10, Role: bb.Open}}, Saved: hourAgo}
	if err := store.SaveList(path, old); err != nil {
		t.Fatal(err)
	}

	if err := Run(context.Background(), env, "open", false); err != nil {
		t.Fatal(err)
	}
	got, err := store.LoadList(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.PRs) != 1 || got.PRs[0].ID != 10 {
		t.Errorf("PRs = %+v, want the old PR 10", got.PRs)
	}
	if !got.Saved.Truncate(time.Second).Equal(hourAgo.Truncate(time.Second)) {
		t.Errorf("Saved = %v, want the old time %v", got.Saved, hourAgo)
	}
	errs := strings.Join(got.Errors, "\n")
	for _, want := range []string{"rate limit", "showing the list from " + hourAgo.Format("15:04")} {
		if !strings.Contains(errs, want) {
			t.Errorf("Errors %q lack %q", errs, want)
		}
	}
}

// The decisions of Run about the list file. Before Run, the list file holds
// the PRs 10 and 11. The inbox gives PR 7. In a row with a lock, another
// refresh holds the lock for 300ms, and it does not write the list. In the
// row with an action, an action writes the list without PR 10 while the
// inbox calls run.
func TestRunDecisions(t *testing.T) {
	cases := []struct {
		name   string
		auto   bool
		age    time.Duration // the age of the list file
		locked bool
		action bool
		calls  bool  // Run makes the inbox calls
		want   []int // the PRs of the list file after Run
	}{
		{name: "auto, a list of 9 minutes: no call", auto: true, age: 9 * time.Minute, want: []int{10, 11}},
		{name: "auto, a lock: wait, then no call", auto: true, age: time.Hour, locked: true, want: []int{10, 11}},
		// The user asks for data from after an action. The refresh that
		// holds the lock can have started before the action.
		{name: "not auto, a lock: wait, then refresh", age: time.Hour, locked: true, calls: true, want: []int{7}},
		{name: "an action changes the list file while the calls run: the refresh does not write the file",
			age: time.Hour, action: true, calls: true, want: []int{11}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env, log := testEnv(t, "", 0)
			path := env.Paths.ListFile(env.Prompt, "open")
			action := ""
			if c.action {
				action = `echo '{"prs":[{"repo":"ws/cur","id":11,"role":"open"}],"saved":"2026-11-01T10:00:00Z"}' > '` + path + `'; `
			}
			writeScript(t, env, log, `echo "$*" >> "$log"
case "$2" in
inbox) `+action+`echo '{"currentUser":{"uuid":"u"},"items":[{"id":7,"repo":"ws/cur","updatedOn":"u"}]}' ;;
*) echo '[]' ;;
esac`)
			at := time.Now().Add(-c.age)
			old := []bb.PR{{Repo: "ws/cur", ID: 10, Role: bb.Open}, {Repo: "ws/cur", ID: 11, Role: bb.Open}}
			if err := store.SaveList(path, store.ListCache{PRs: old, Saved: at}); err != nil {
				t.Fatal(err)
			}
			if err := os.Chtimes(path, at, at); err != nil {
				t.Fatal(err)
			}
			released := make(chan time.Time, 1)
			if c.locked {
				release, ok, err := store.TryLock(path, time.Minute)
				if err != nil || !ok {
					t.Fatalf("TryLock: ok=%v err=%v", ok, err)
				}
				go func() {
					time.Sleep(300 * time.Millisecond)
					released <- time.Now()
					release()
				}()
			}

			if err := Run(context.Background(), env, "open", c.auto); err != nil {
				t.Fatal(err)
			}

			if c.locked && time.Now().Before(<-released) {
				t.Error("Run returned before the lock went away")
			}
			if calls := strings.Contains(readLog(t, log), "bitbucket inbox "); calls != c.calls {
				t.Errorf("inbox calls: %t, want %t:\n%s", calls, c.calls, readLog(t, log))
			}
			got, err := store.LoadList(path)
			if err != nil {
				t.Fatal(err)
			}
			var ids []int
			for _, p := range got.PRs {
				ids = append(ids, p.ID)
			}
			if !slices.Equal(ids, c.want) {
				t.Errorf("PRs of the list file = %v, want %v", ids, c.want)
			}
		})
	}
}

// writeScript makes the fake twg of env run body. The body can use the
// variable log: the file that keeps the calls.
func writeScript(t *testing.T, env Env, log, body string) {
	t.Helper()
	script := "#!/bin/sh\nlog='" + log + "'\n" + body + "\n"
	if err := os.WriteFile(env.Twg.Bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

// writePreview writes the preview file of one view of pr for the update
// updated. The file is age old.
func writePreview(t *testing.T, env Env, pr bb.PR, updated, view, data string, age time.Duration) {
	t.Helper()
	path := env.Paths.PreviewFile(pr.Repo, pr.ID, updated, view)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(data), 0o644); err != nil {
		t.Fatal(err)
	}
	at := time.Now().Add(-age)
	if err := os.Chtimes(path, at, at); err != nil {
		t.Fatal(err)
	}
}

// The cache rule. A pinned copy of the same update is good at any age. A
// copy of live data is fresh for one minute. A copy of an older update is
// stale, and the newest such copy shows.
func TestCached(t *testing.T) {
	open := bb.PR{Repo: "ws/app", ID: 7, Role: bb.Open, UpdatedRaw: "new"}
	closed := open
	closed.Role = "merged"
	type file struct {
		updated string
		age     time.Duration
		data    string
	}
	cases := []struct {
		name  string
		pr    bb.PR
		view  string
		files []file
		want  State
		data  string
	}{
		{"pinned: the same update, a month old", open, "commits", []file{{"new", 30 * 24 * time.Hour, "c"}}, Fresh, "c"},
		{"live: younger than a minute", open, "details", []file{{"new", 30 * time.Second, "d"}}, Fresh, "d"},
		{"live: older than a minute", open, "details", []file{{"new", 2 * time.Minute, "d"}}, Stale, "d"},
		{"live: the activity", open, "activity", []file{{"new", 2 * time.Minute, "a"}}, Stale, "a"},
		{"a closed PR is pinned", closed, "details", []file{{"new", 2 * time.Hour, "d"}}, Fresh, "d"},
		// The newest file is neither the first nor the last by name.
		{"older updates only: the newest copy", open, "diff",
			[]file{{"u1", 2 * time.Hour, "u1"}, {"u2", 5 * time.Minute, "u2"}, {"u3", time.Hour, "u3"}}, Stale, "u2"},
		{"no file", open, "details", nil, Missing, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env, _ := testEnv(t, "", 0)
			for _, f := range c.files {
				writePreview(t, env, c.pr, f.updated, c.view, f.data, f.age)
			}
			raw, state, _ := Cached(env, c.pr, c.view)
			if state != c.want || string(raw) != c.data {
				t.Errorf("Cached = %q, state %d; want %q, state %d", raw, state, c.data, c.want)
			}
		})
	}
}

// Fetch of the details bundle. The clock is 10:05. The pr part of saved is
// from 10:00, and the pr part of savedOld is from 09:40.
func TestFetchDetails(t *testing.T) {
	pr := bb.PR{Repo: "ws/app", ID: 7, Role: bb.Open, UpdatedRaw: "u"}
	now := time.Date(2026, 11, 1, 10, 5, 0, 0, time.UTC)
	const saved = `{"pr":{"id":7,"title":"Old"},"checks":{"old":1},"diffstat":[{"d":1}],"pr_at":"2026-11-01T10:00:00Z"}`
	const savedOld = `{"pr":{"id":7,"title":"Old"},"checks":{"old":1},"diffstat":[{"d":1}],"pr_at":"2026-11-01T09:40:00Z"}`
	cases := []struct {
		name string
		// saved is the bundle of the same update on the disk, or "".
		saved string
		// body is the fake twg. It appends its calls to the file log.
		body  string
		check func(t *testing.T, env Env, log string, cmds *cmdlog.Log)
	}{
		{"a new update: the three calls start at the same time", "",
			`echo "start $3" >> "$log"
if [ "$3" = get ]; then sleep 0.5; echo "end get" >> "$log"; fi
echo '{}'`,
			func(t *testing.T, env Env, log string, _ *cmdlog.Log) {
				if _, err := Fetch(context.Background(), env, pr, "details"); err != nil {
					t.Fatal(err)
				}
				calls := readLog(t, log)
				end := strings.Index(calls, "end get")
				for _, sub := range []string{"mergeability", "diffstat"} {
					if i := strings.Index(calls, "start "+sub); i < 0 || i > end {
						t.Errorf("calls =\n%s\nwant the start of %s before the end of get", calls, sub)
					}
				}
				if _, state, _ := Cached(env, pr, "details"); state != Fresh {
					t.Errorf("state of the saved bundle = %d, want fresh", state)
				}
			}},
		{"the same update, a pr part younger than 15 minutes: only mergeability", saved,
			`echo "$3" >> "$log"
echo '{"new":1}'`,
			func(t *testing.T, env Env, log string, _ *cmdlog.Log) {
				if _, err := Fetch(context.Background(), env, pr, "details"); err != nil {
					t.Fatal(err)
				}
				if calls := readLog(t, log); calls != "mergeability\n" {
					t.Errorf("calls = %q, want mergeability only", calls)
				}
				const want = `{"pr":{"id":7,"title":"Old"},"checks":{"new":1},"diffstat":[{"d":1}],"pr_at":"2026-11-01T10:00:00Z"}`
				if raw, _, _ := Cached(env, pr, "details"); string(raw) != want {
					t.Errorf("saved bundle = %s, want %s", raw, want)
				}
			}},
		{"the same update, a pr part older than 15 minutes: get and mergeability", savedOld,
			`echo "$3" >> "$log"
case "$3" in get) echo '{"id":7,"title":"New"}' ;; *) echo '{"new":1}' ;; esac`,
			func(t *testing.T, env Env, log string, _ *cmdlog.Log) {
				if _, err := Fetch(context.Background(), env, pr, "details"); err != nil {
					t.Fatal(err)
				}
				calls := strings.Fields(readLog(t, log))
				if slices.Sort(calls); !slices.Equal(calls, []string{"get", "mergeability"}) {
					t.Errorf("calls = %q, want get and mergeability", calls)
				}
				const want = `{"pr":{"id":7,"title":"New"},"checks":{"new":1},"diffstat":[{"d":1}],"pr_at":"2026-11-01T10:05:00Z"}`
				if raw, _, _ := Cached(env, pr, "details"); string(raw) != want {
					t.Errorf("saved bundle = %s, want %s", raw, want)
				}
			}},
		{"get fails: the other two calls stop", "",
			`if [ "$3" = get ]; then echo 'not found'; exit 1; fi
sleep 5
echo '{}'`,
			func(t *testing.T, env Env, _ string, _ *cmdlog.Log) {
				start := time.Now()
				if _, err := Fetch(context.Background(), env, pr, "details"); err == nil {
					t.Error("Fetch gave no error, want the error of get")
				}
				if d := time.Since(start); d > 2*time.Second {
					t.Errorf("Fetch took %s, want the stop of mergeability and diffstat", d)
				}
			}},
		// An action drops the previews of a PR. A fetch that started before
		// it has the old data.
		{"the previews are dropped while the fetch runs: the fetch does not save", "",
			`echo "$3" >> "$log"
touch "$log.started"
sleep 0.3
echo '{}'`,
			func(t *testing.T, env Env, log string, _ *cmdlog.Log) {
				dropped := make(chan struct{})
				go func() {
					defer close(dropped)
					for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
						if _, err := os.Stat(log + ".started"); err == nil {
							env.Paths.DropPreviews(pr.Repo, pr.ID)
							return
						}
					}
				}()
				if _, err := Fetch(context.Background(), env, pr, "details"); err != nil {
					t.Fatal(err)
				}
				<-dropped
				if _, state, _ := Cached(env, pr, "details"); state != Missing {
					t.Errorf("state = %d after the drop, want missing", state)
				}
				// A fetch that starts after the drop saves.
				if _, err := Fetch(context.Background(), env, pr, "details"); err != nil {
					t.Fatal(err)
				}
				if _, state, _ := Cached(env, pr, "details"); state != Fresh {
					t.Errorf("state = %d after a new fetch, want fresh", state)
				}
			}},
		// Else the Status tab shows "Merge unknown" until the copy gets old.
		{"a failed part: the bundle is not saved, the error names the part, and the next fetch loads it again", "",
			`echo "$3" >> "$log"
if [ "$3" = mergeability ]; then echo 'server error'; exit 1; fi
echo '{}'`,
			func(t *testing.T, env Env, log string, cmds *cmdlog.Log) {
				for range 2 {
					var partial *PartialError
					if _, err := Fetch(context.Background(), env, pr, "details"); !errors.As(err, &partial) ||
						!slices.Equal(partial.Parts, []string{"mergeability"}) {
						t.Fatalf("error = %v, want a partial bundle without mergeability", err)
					}
				}
				if n := strings.Count(readLog(t, log), "get\n"); n != 2 {
					t.Errorf("twg got the PR %d times, want 2", n)
				}
				var failed int
				for _, l := range cmds.Lines(50) {
					if l.Text == "✗ mergeability: server error" {
						failed++
					}
				}
				if failed != 2 {
					t.Errorf("command log = %+v, want the failure line once for each fetch", cmds.Lines(50))
				}
			}},
		{"a failed update keeps the copy", saved,
			`echo "$3" >> "$log"
echo 'server error'; exit 1`,
			func(t *testing.T, env Env, log string, _ *cmdlog.Log) {
				if _, err := Fetch(context.Background(), env, pr, "details"); err == nil {
					t.Error("Fetch gave no error, want the error of mergeability")
				}
				if raw, _, _ := Cached(env, pr, "details"); string(raw) != saved {
					t.Errorf("bundle = %s, want the old copy %s", raw, saved)
				}
			}},
		// The UI shows no merge state for a closed PR. A mergeability call
		// for it costs a call, and a failure of it would make each closed PR
		// a partial bundle that is never saved.
		{"a closed PR: no mergeability call, and the bundle is saved", "",
			`echo "$3" >> "$log"
if [ "$3" = mergeability ]; then echo 'server error'; exit 1; fi
echo '{}'`,
			func(t *testing.T, env Env, log string, _ *cmdlog.Log) {
				merged := pr
				merged.Role = bb.Merged
				if _, err := Fetch(context.Background(), env, merged, "details"); err != nil {
					t.Fatalf("Fetch = %v, want no error", err)
				}
				calls := strings.Fields(readLog(t, log))
				if slices.Sort(calls); !slices.Equal(calls, []string{"diffstat", "get"}) {
					t.Errorf("calls = %q, want get and diffstat only", calls)
				}
				if _, state, _ := Cached(env, merged, "details"); state != Fresh {
					t.Errorf("state of the bundle = %d, want fresh", state)
				}
			}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env, log := testEnv(t, "", 0)
			env.Now = func() time.Time { return now }
			writeScript(t, env, log, c.body)
			cmds := &cmdlog.Log{}
			env.Twg.Record = cmds.Add
			if c.saved != "" {
				writePreview(t, env, pr, pr.UpdatedRaw, "details", c.saved, 2*time.Minute)
			}
			c.check(t, env, log, cmds)
		})
	}
}

// The decisions of the warm run, with fake uses, a fake idle time, a fake
// clock, and a fake twg. The workspace is ws. The rows also check the
// thresholds: a use of 7 hours, an idle time of 14 minutes, a list of 6
// minutes, and a marker of 40 minutes do not stop the run.
func TestWarm(t *testing.T) {
	const limit = `printf 'ok: false\nerror:\n  message: "Bitbucket API error: 429"\n'; exit 1`
	const views = `case "$3" in diff) echo 'diff --git a/x b/x' ;; *) echo '[]' ;; esac`
	const inboxPR = `echo '{"currentUser":{"uuid":"u"},"items":[{"id":7,"repo":"ws/app","updatedOn":"u"}]}'`
	prs := func(ids ...int) []bb.PR {
		var out []bb.PR
		for _, id := range ids {
			out = append(out, bb.PR{Repo: "ws/app", ID: id, Role: bb.Review, UpdatedRaw: "u"})
		}
		return out
	}
	// list is one open list file. The prompt ws/app or ws/other names the
	// list of that repo.
	type list struct {
		age    time.Duration // the age of the file; 0 for no file
		prs    []bb.PR
		locked bool // another refresh holds the lock of the file
	}
	ws := map[string]time.Duration{"ws": time.Hour}
	both := map[string]time.Duration{"ws": time.Hour, "ws/app": time.Hour}
	cases := []struct {
		name   string
		used   map[string]time.Duration // the age of the last use, by prompt
		idle   time.Duration
		marker time.Duration // the age of the backoff marker; 0 for none
		lists  map[string]list
		// The fake twg: the output of the inbox calls, of the repo query, and
		// of the preview calls. An empty query gives no PR.
		inbox, query, preview string
		wantLine              string // the start of the line
		wantOK                bool
		// The numbers of inbox calls, of repo queries, and of preview calls,
		// from min to max. Two inbox calls run at the same time, so after a
		// rate limit the second call can start or not.
		inboxes, queries, previews [2]int
		wantMarker                 bool     // the run writes a new marker
		saved                      []string // the prompts of the list files that the run writes
	}{
		// wsx is another workspace, not a repo of ws.
		{name: "no use of the workspace in 8 hours: no call",
			used:     map[string]time.Duration{"ws": 9 * time.Hour, "wsx": time.Hour, "wsx/app": time.Minute},
			wantLine: "not used here in 8h: no calls", wantOK: true},
		{name: "idle: no call", used: ws, idle: 20 * time.Minute, wantLine: "idle for 20m: no calls", wantOK: true},
		{name: "a rate limit 5 minutes ago: no call", used: ws, marker: 5 * time.Minute, wantLine: "backoff", wantOK: true},
		{name: "a refresh holds the lock: no call", used: ws, lists: map[string]list{"ws": {locked: true}},
			wantLine: "busy", wantOK: true},
		{name: "a refresh of another list of the workspace holds its lock: no call", used: ws,
			lists: map[string]list{"ws/other": {locked: true}}, wantLine: "busy", wantOK: true},
		{name: "a refresh holds the lock of the second list: no call, and the run releases the first lock", used: both,
			lists: map[string]list{"ws/app": {locked: true}}, wantLine: "busy", wantOK: true},
		// PR 1 is in both lists.
		{name: "fresh lists: the prefetch of each PR of the lists, one time", used: both,
			lists:    map[string]list{"ws": {age: 4 * time.Minute, prs: prs(1)}, "ws/app": {age: 3 * time.Minute, prs: prs(1, 2)}},
			preview:  views,
			wantLine: "fresh 2 lists (ws, ws/app), 4m old: 2 PRs, prefetched 8 views", wantOK: true, previews: [2]int{12, 12}},
		{name: "an old marker and a fresh list: the prefetch runs", used: ws, marker: 40 * time.Minute,
			lists: map[string]list{"ws": {age: 4 * time.Minute, prs: prs(1)}}, preview: views,
			wantLine: "fresh 1 list (ws), 4m old: 1 PR, prefetched 4 views", wantOK: true, previews: [2]int{6, 6}},
		{name: "active, a use of 7 hours, and a list of 6 minutes: refresh and prefetch",
			used: map[string]time.Duration{"ws": 7 * time.Hour}, idle: 14 * time.Minute,
			lists: map[string]list{"ws": {age: 6 * time.Minute, prs: prs(1)}}, inbox: inboxPR, preview: views,
			wantLine: "refreshed 1 list (ws): 1 PR, prefetched 4 views", wantOK: true,
			inboxes: [2]int{2, 2}, previews: [2]int{6, 6}, saved: []string{"ws"}},
		{name: "only the list of a repo was used: no refresh of the list of the workspace",
			used: map[string]time.Duration{"ws/app": time.Hour}, inbox: inboxPR, preview: views,
			wantLine: "refreshed 1 list (ws/app): 1 PR, prefetched 4 views", wantOK: true,
			inboxes: [2]int{2, 2}, queries: [2]int{1, 1}, previews: [2]int{6, 6}, saved: []string{"ws/app"}},
		// The slow inbox makes the loads of the two lists wait for the
		// same calls at the same time.
		{name: "one old list: both lists refresh, and each inbox call runs one time", used: both,
			lists: map[string]list{"ws": {age: 4 * time.Minute, prs: prs(1)}, "ws/app": {age: 6 * time.Minute, prs: prs(1)}},
			inbox: "sleep 0.3; " + inboxPR, preview: views,
			wantLine: "refreshed 2 lists (ws, ws/app): 1 PR, prefetched 4 views", wantOK: true,
			inboxes: [2]int{2, 2}, queries: [2]int{1, 1}, previews: [2]int{6, 6}, saved: []string{"ws", "ws/app"}},
		{name: "a rate limit in the refresh: the marker, and no prefetch", used: ws, inbox: limit, preview: views,
			wantLine: "failed: rate limit", inboxes: [2]int{1, 2}, wantMarker: true, saved: []string{"ws"}},
		// 429 is in the number of the PR, not a status.
		{name: "a failure that names PR #1429: no marker", used: ws, preview: views,
			inbox:    `printf 'ok: false\nerror:\n  message: "pull request #1429 not found"\n'; exit 1`,
			wantLine: "refreshed 1 list (ws): 0 PRs, prefetched 0 views, failed: could not load the review inbox: pull request #1429 not found",
			inboxes:  [2]int{2, 2}, saved: []string{"ws"}},
		// For example, the repo of a used list is gone. Its query fails on
		// each run, and the other lists must stay warm.
		{name: "a failed list: the prefetch of the PRs that loaded, and the error", used: both,
			inbox: inboxPR, query: `echo 'repository not found'; exit 1`, preview: views,
			wantLine: "refreshed 2 lists (ws, ws/app): 1 PR, prefetched 4 views, failed: could not load the open PRs of ws/app: repository not found",
			inboxes:  [2]int{2, 2}, queries: [2]int{1, 1}, previews: [2]int{6, 6}, saved: []string{"ws", "ws/app"}},
		// 5 PRs need 30 preview calls. The prefetch stops at the first
		// failure: the loads that run at that time end, and no other starts.
		{name: "a rate limit in the prefetch: the marker, and the prefetch stops", used: ws,
			lists: map[string]list{"ws": {age: 4 * time.Minute, prs: prs(1, 2, 3, 4, 5)}}, preview: limit,
			wantLine: "fresh 1 list (ws), 4m old: 5 PRs, failed: rate limit", wantMarker: true, previews: [2]int{1, 12}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env, log := testEnv(t, "", 0)
			query := c.query
			if query == "" {
				query = `echo '[]'`
			}
			writeScript(t, env, log, `echo "$*" >> "$log"
case "$2 $3" in
"inbox "*) `+c.inbox+` ;;
"pull-requests query") `+query+` ;;
*) `+c.preview+` ;;
esac`)
			now := time.Now()
			env.Now = func() time.Time { return now }
			age := func(path string, d time.Duration) {
				if err := os.Chtimes(path, now.Add(-d), now.Add(-d)); err != nil {
					t.Fatal(err)
				}
			}
			for prompt, d := range c.used {
				if err := env.Paths.MarkUsed(prompt); err != nil {
					t.Fatal(err)
				}
				age(filepath.Join(env.Paths.State, "used", strings.ReplaceAll(prompt, "/", "_")), d)
			}
			for prompt, l := range c.lists {
				path := env.Paths.ListFile(prompt, "open")
				if l.age > 0 {
					if err := store.SaveList(path, store.ListCache{PRs: l.prs, Saved: now.Add(-l.age)}); err != nil {
						t.Fatal(err)
					}
					age(path, l.age)
				}
				if l.locked {
					if _, ok, err := store.TryLock(path, time.Minute); err != nil || !ok {
						t.Fatalf("TryLock: %t, %v", ok, err)
					}
				}
			}
			marker := env.Paths.WarmBackoff()
			if c.marker > 0 {
				if err := store.WriteAtomic(marker, nil); err != nil {
					t.Fatal(err)
				}
				age(marker, c.marker)
			}

			line, ok := Warm(context.Background(), env, func(context.Context) (time.Duration, bool) { return c.idle, true })

			if !strings.HasPrefix(line, c.wantLine) || ok != c.wantOK {
				t.Errorf("Warm = %q, %t; want the start %q, %t", line, ok, c.wantLine, c.wantOK)
			}
			calls := readLog(t, log)
			inbox, queries := strings.Count(calls, "bitbucket inbox "), strings.Count(calls, "bitbucket pull-requests query ")
			previews := strings.Count(calls, "bitbucket pull-requests ") - queries
			if inbox < c.inboxes[0] || inbox > c.inboxes[1] || queries < c.queries[0] || queries > c.queries[1] ||
				previews < c.previews[0] || previews > c.previews[1] {
				t.Errorf("calls =\n%s\nwant %v inbox calls, %v repo queries, and %v preview calls", calls, c.inboxes, c.queries, c.previews)
			}
			info, err := os.Stat(marker)
			if fresh := err == nil && now.Sub(info.ModTime()) < time.Minute; fresh != c.wantMarker {
				t.Errorf("a new marker: %t, want %t", fresh, c.wantMarker)
			}
			for _, prompt := range []string{"ws", "ws/app", "ws/other"} {
				path := env.Paths.ListFile(prompt, "open")
				info, err := os.Stat(path)
				if written := err == nil && now.Sub(info.ModTime()) < time.Minute; written != slices.Contains(c.saved, prompt) {
					t.Errorf("the run wrote the list of %s: %t, want %t", prompt, written, !written)
				}
				if store.Locked(path) && !c.lists[prompt].locked {
					t.Errorf("the run left the lock of the list of %s", prompt)
				}
			}
		})
	}
}

// A refresh of the open list prefetches each view of each PR that has no
// file of its update. A second refresh, with no change of a PR, makes no
// preview call.
func TestRunPrefetch(t *testing.T) {
	env, log := testEnv(t, "", 0)
	writeScript(t, env, log, `echo "$*" >> "$log"
case "$2 $3" in
"inbox "*) echo '{"currentUser":{"uuid":"u"},"items":[{"id":7,"repo":"ws/app","updatedOn":"2026-11-01T10:00:00"}]}' ;;
"pull-requests diff") echo 'diff --git a/x b/x' ;;
*) echo '[]' ;;
esac`)
	previews := func() int {
		n := 0
		for _, sub := range []string{"get", "mergeability", "diffstat", "commits", "diff", "activity"} {
			n += strings.Count(readLog(t, log), "pull-requests "+sub+" 7 ")
		}
		return n
	}
	if err := Run(context.Background(), env, "open", false); err != nil {
		t.Fatal(err)
	}
	if n := previews(); n != 6 {
		t.Errorf("first refresh: %d preview calls, want 6 (the bundle, the commits, the diff, the activity):\n%s", n, readLog(t, log))
	}
	if err := Run(context.Background(), env, "open", false); err != nil {
		t.Fatal(err)
	}
	if n := previews(); n != 6 {
		t.Errorf("second refresh: %d preview calls in all, want no new call:\n%s", n, readLog(t, log))
	}
}
