package refresh

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
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

func TestRunAutoSkipsFreshList(t *testing.T) {
	env, log := testEnv(t, "[]", 0)
	path := env.Paths.ListFile(env.Prompt, "open")
	if err := store.SaveList(path, store.ListCache{Saved: time.Now()}); err != nil {
		t.Fatal(err)
	}
	if err := Run(context.Background(), env, "open", true); err != nil {
		t.Fatal(err)
	}
	if got := readLog(t, log); got != "" {
		t.Errorf("twg ran: %q", got)
	}
}

func TestRunWaitsForLock(t *testing.T) {
	env, log := testEnv(t, "[]", 0)
	path := env.Paths.ListFile(env.Prompt, "open")
	release, ok, err := store.TryLock(path, time.Minute)
	if err != nil || !ok {
		t.Fatalf("TryLock: ok=%v err=%v", ok, err)
	}
	released := make(chan time.Time, 1)
	go func() {
		time.Sleep(300 * time.Millisecond)
		released <- time.Now()
		release()
	}()
	if err := Run(context.Background(), env, "open", false); err != nil {
		t.Fatal(err)
	}
	done := time.Now()
	if done.Before(<-released) {
		t.Error("Run returned before the lock went away")
	}
	if got := readLog(t, log); got != "" {
		t.Errorf("twg ran: %q", got)
	}
}

// A details bundle with a failed part must not stay in the cache. Else the
// Status tab shows "Merge unknown" until the preview gets old. The next load
// calls twg again, and the command log tells about the failure.
func TestLoadViewFailedPart(t *testing.T) {
	env, log := testEnv(t, "", 0)
	// The fake fails the mergeability call only.
	script := "#!/bin/sh\necho \"$*\" >> '" + log + "'\n" +
		"if [ \"$3\" = mergeability ]; then echo 'server error'; exit 1; fi\necho '{}'\n"
	if err := os.WriteFile(env.Twg.Bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	cmds := &cmdlog.Log{}
	env.Twg.Record = cmds.Add
	pr := bb.PR{Repo: "ws/cur", ID: 7, Role: bb.Open, UpdatedRaw: "u"}

	for range 2 {
		if _, err := LoadView(context.Background(), env, pr, "details"); err != nil {
			t.Fatal(err)
		}
	}
	if n := strings.Count(readLog(t, log), "pull-requests get 7 "); n != 2 {
		t.Errorf("twg got the PR %d times, want 2: the second load must not use the cache", n)
	}
	var failed int
	for _, l := range cmds.Lines(50) {
		if l.Text == "✗ mergeability: server error" {
			failed++
		}
	}
	if failed != 2 {
		t.Errorf("command log = %+v, want the failure line once for each load", cmds.Lines(50))
	}
}
