package actions

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	"bbprs/internal/bb"
	"bbprs/internal/cmdlog"
	"bbprs/internal/gitops"
	"bbprs/internal/gitops/gitopstest"
	"bbprs/internal/store"
	"bbprs/internal/twg"
)

func TestMain(m *testing.M) {
	cleanup := gitopstest.IsolateConfig()
	code := m.Run()
	cleanup()
	os.Exit(code)
}

// newDeps makes Deps with a fake twg that always succeeds. Both the twg
// runner and git write their commands to the log.
func newDeps(t *testing.T, repo string) Deps {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "twg")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	log := &cmdlog.Log{}
	return Deps{
		Twg:      &twg.Runner{Bin: bin, Timeout: 5 * time.Second, Record: log.Add},
		Paths:    store.Paths{Cache: filepath.Join(dir, "cache"), State: filepath.Join(dir, "state")},
		Repo:     repo,
		ListFile: filepath.Join(dir, "cache", "list.json"),
		Log:      log,
		Now:      time.Now,
	}
}

func TestMerge(t *testing.T) {
	d := newDeps(t, "ws/cur")
	prs := []bb.PR{
		{Repo: "ws/cur", ID: 11, Role: bb.Mine},
		{Repo: "ws/cur", ID: 12, Role: bb.Review},
		{Repo: "ws/cur", ID: 13, Role: bb.Merged},
	}
	if err := store.SaveList(d.ListFile, store.ListCache{PRs: append([]bb.PR{{Repo: "ws/cur", ID: 20, Role: bb.Open}}, prs...)}); err != nil {
		t.Fatal(err)
	}
	preview := d.Paths.PreviewFile("ws/cur", 12, "u", "pr")
	if err := os.MkdirAll(filepath.Dir(preview), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(preview, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	got := Merge(context.Background(), d, prs)

	var texts []string
	for _, o := range got {
		texts = append(texts, o.Text)
	}
	wantTexts := []string{"#11 merged", "#12 approved · merged", "#13 not an open PR, skipped"}
	if !reflect.DeepEqual(texts, wantTexts) {
		t.Errorf("outcome texts = %q, want %q", texts, wantTexts)
	}

	flags := " --merge-strategy merge_commit --close-source-branch --wait"
	wantLog := []cmdlog.Line{
		{Head: true, Text: "Approve and merge #11, #12"},
		{Text: "twg bitbucket pull-requests merge --pull-request 11 --repo ws/cur" + flags},
		{Text: "twg bitbucket pull-requests approve 12 --repo ws/cur"},
		{Text: "twg bitbucket pull-requests merge --pull-request 12 --repo ws/cur" + flags},
	}
	// The times of the calls change from run to run. Compare the lines
	// without them.
	took := regexp.MustCompile(`  \d+\.\d s$`)
	lines := d.Log.Lines(10)
	for i := range lines {
		lines[i].Text = took.ReplaceAllString(lines[i].Text, "")
	}
	if !reflect.DeepEqual(lines, wantLog) {
		t.Errorf("log = %+v, want %+v", lines, wantLog)
	}

	actions, err := d.Paths.ReadActions(10)
	if err != nil {
		t.Fatal(err)
	}
	var seen []string
	for i := len(actions) - 1; i >= 0; i-- { // oldest first
		seen = append(seen, actions[i].Action+" "+actions[i].Result+" "+strconv.Itoa(actions[i].ID))
	}
	if want := []string{"merge ok 11", "approve ok 12", "merge ok 12"}; !reflect.DeepEqual(seen, want) {
		t.Errorf("actions.tsv = %q, want %q", seen, want)
	}

	list, err := store.LoadList(d.ListFile)
	if err != nil {
		t.Fatal(err)
	}
	var left []string
	for _, p := range list.PRs {
		left = append(left, p.Key())
	}
	if want := []string{"ws/cur#20", "ws/cur#13"}; !reflect.DeepEqual(left, want) {
		t.Errorf("list file keeps %q, want %q", left, want)
	}
	if _, err := os.Stat(preview); !os.IsNotExist(err) {
		t.Errorf("preview of #12 still exists (err %v)", err)
	}
}

// cacheClone returns a GitFor that clones origin, a local repo, for each
// repo. The clones are in the cache folder of d. Each call adds the repo to
// calls.
func cacheClone(d Deps, origin string, calls *[]string) func(context.Context, string, func(string)) (*gitops.Git, error) {
	return func(ctx context.Context, repo string, record func(string)) (*gitops.Git, error) {
		*calls = append(*calls, repo)
		return gitops.EnsureClone(ctx, d.Paths.RepoDir(repo), "file://"+origin, record)
	}
}

// partialOrigin builds the repos of gitopstest.Repos. A partial clone from
// a local path needs file:// and uploadpack.allowFilter on the origin.
func partialOrigin(t *testing.T) (origin, work string) {
	t.Helper()
	origin, work = gitopstest.Repos(t)
	gitopstest.Git(t, origin, "config", "uploadpack.allowFilter", "true")
	return origin, work
}

// RunSync names the chosen method in the head of its entry in the command
// log, in the outcome, and in the note of the log of actions. The commands of
// git go under that head. TestSync and TestSyncMerge of gitops check what each
// method does to the branch.
func TestRunSync(t *testing.T) {
	tests := []struct {
		name   string
		cache  bool // not in a repo: sync ws/app in the own clone of bb-prs
		src    string
		method Method
		head   string
		text   string
		result string // the result in the log of actions
	}{
		{name: "rebase", src: "feat", method: MethodRebase, head: "Sync #2 (rebase feat onto main)", text: "#2 synced onto main", result: "ok"},
		{name: "merge", src: "feat", method: MethodMerge, head: "Sync #2 (merge main into feat)", text: "#2 merged main in", result: "ok"},
		{name: "conflict in the clone of the pane", src: "clash", method: MethodRebase, head: "Sync #2 (rebase clash onto main)",
			text: "#2 conflicts, nothing changed. Run: git pr-conflicts 2", result: "conflict"},
		{name: "rebase in the own clone is pushed", cache: true, src: "feat", method: MethodRebase, head: "Sync #2 (rebase feat onto main)",
			text: "#2 synced onto main", result: "ok"},
		{name: "conflict in the own clone", cache: true, src: "clash", method: MethodRebase, head: "Sync #2 (rebase clash onto main)",
			text: "#2 conflicts, nothing changed. Run git pr-conflicts 2 in a clone of app.", result: "conflict"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			origin, work := partialOrigin(t)
			d := newDeps(t, "ws/cur")
			pr := bb.PR{Repo: "ws/cur", ID: 2, Role: bb.Open, Src: tc.src, Dst: "main"}
			if tc.cache {
				d.Repo, pr.Repo = "", "ws/app"
				d.GitFor = cacheClone(d, origin, new([]string))
			} else {
				d.Git = &gitops.Git{Dir: work, Record: d.Log.Add}
			}
			pr.SrcRepo = pr.Repo
			plan := PlanSync(context.Background(), d, []bb.PR{pr})
			if len(plan.Todo) != 1 {
				t.Fatalf("plan = %+v, want #2 to do", plan)
			}

			outs := RunSync(context.Background(), d, plan, tc.method)

			if len(outs) != 1 || outs[0].OK != (tc.result == "ok") || outs[0].Text != tc.text {
				t.Fatalf("outcomes = %+v, want one outcome, ok: %t, with text %q", outs, tc.result == "ok", tc.text)
			}
			lines := d.Log.Lines(100)
			at := slices.IndexFunc(lines, func(l cmdlog.Line) bool { return l.Head && l.Text == tc.head })
			if at < 0 || at+1 == len(lines) || !strings.HasPrefix(lines[at+1].Text, "git rev-parse") {
				t.Errorf("log = %+v, want the head %q with the git commands under it", lines, tc.head)
			}
			acts, err := d.Paths.ReadActions(5)
			if err != nil || len(acts) != 1 || acts[0].Action != "sync" || acts[0].Result != tc.result || acts[0].Note != string(tc.method) {
				t.Errorf("actions = %+v (err %v), want one sync, %s, with note %q", acts, err, tc.result, tc.method)
			}
			if tc.result == "ok" {
				// The push reached origin: the source branch has main in it.
				gitopstest.Git(t, origin, "merge-base", "--is-ancestor", "main", tc.src)
			}
		})
	}
}

func TestPlanSync(t *testing.T) {
	tests := []struct {
		name        string
		pane        bool // bb-prs runs in a clone of ws/cur
		before      func(t *testing.T, origin string)
		prs         []bb.PR
		wantTodo    []string // "#<id> <clone> <commits>"; the clone is pane or own
		wantSkipped []string // {origin} is the path of the origin
		wantCalls   []string // the repos that GitFor gets
		wantGit     []string // the first two words of each git command in the log
	}{
		{
			name: "a PR of the repo of the pane uses the clone of the pane",
			pane: true,
			prs: []bb.PR{
				{Repo: "ws/cur", ID: 2, Role: bb.Open, Src: "feat", Dst: "main", SrcRepo: "ws/cur"},
				{Repo: "ws/cur", ID: 3, Role: bb.Open, Src: "main", Dst: "main", SrcRepo: "ws/cur"},
				{Repo: "ws/cur", ID: 4, Role: bb.Open, Src: "gone", Dst: "main", SrcRepo: "ws/cur"},
			},
			wantTodo:    []string{"#2 pane 1"},
			wantSkipped: []string{"#3 up to date with main", "#4 no branch gone or main on origin"},
			wantGit:     []string{"git fetch"},
		},
		{
			name: "not in a repo: each repo uses its own clone, and a failed clone skips only its PRs",
			prs: []bb.PR{
				{Repo: "ws/app", ID: 5, Role: bb.Open, Src: "feat", Dst: "main", SrcRepo: "ws/app"},
				{Repo: "ws/bad", ID: 6, Role: bb.Open, Src: "feat", Dst: "main", SrcRepo: "ws/bad"},
				// Bitbucket does not care about the case of a repo name.
				{Repo: "ws/app", ID: 7, Role: bb.Open, Src: "feat2", Dst: "main", SrcRepo: "WS/App"},
			},
			wantTodo:    []string{"#5 own 1", "#7 own 1"},
			wantSkipped: []string{"#6 could not clone ws/bad: fatal: repository not found"},
			wantCalls:   []string{"ws/app", "ws/bad"},
			wantGit:     []string{"git clone", "git fetch"},
		},
		{
			name: "a failed fetch skips the PRs of its repo, with the first line of git",
			pane: true,
			before: func(t *testing.T, origin string) {
				if err := os.RemoveAll(origin); err != nil {
					t.Fatal(err)
				}
			},
			prs:         []bb.PR{{Repo: "ws/cur", ID: 8, Role: bb.Open, Src: "feat", Dst: "main", SrcRepo: "ws/cur"}},
			wantSkipped: []string{"#8 git fetch failed: fatal: '{origin}' does not appear to be a git repository"},
			wantGit:     []string{"git fetch"},
		},
		{
			// A sync of a fork PR would change a branch of the same name in
			// the destination repo.
			name:        "a PR from a fork is skipped before any git work",
			prs:         []bb.PR{{Repo: "ws/app", ID: 9, Role: bb.Open, Src: "feat", Dst: "main", SrcRepo: "ws/fork"}},
			wantSkipped: []string{"#9 from a fork, sync it in its own repo"},
		},
		{
			name: "an empty source repo comes from SourceRepo, and a failure skips the PR",
			pane: true,
			prs: []bb.PR{
				{Repo: "ws/cur", ID: 10, Role: bb.Open, Src: "feat", Dst: "main"},
				{Repo: "ws/cur", ID: 11, Role: bb.Open, Src: "feat2", Dst: "main"},
			},
			wantTodo:    []string{"#10 pane 1"},
			wantSkipped: []string{"#11 could not check the source repo: twg failed"},
			wantGit:     []string{"git fetch"},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			origin, work := partialOrigin(t)
			d := newDeps(t, "")
			if tc.pane {
				d.Repo = "ws/cur"
				d.Git = &gitops.Git{Dir: work, Record: d.Log.Add}
			}
			var calls []string
			clone := cacheClone(d, origin, &calls)
			d.GitFor = func(ctx context.Context, repo string, record func(string)) (*gitops.Git, error) {
				if repo == "ws/bad" {
					calls = append(calls, repo)
					return nil, errors.New("fatal: repository not found\nfatal: could not read from remote")
				}
				return clone(ctx, repo, record)
			}
			// The fake knows the source repo of each PR, except #11.
			d.SourceRepo = func(_ context.Context, pr bb.PR, _ func(string)) (string, error) {
				if pr.SrcRepo != "" {
					t.Errorf("SourceRepo got #%d, whose SrcRepo is %q", pr.ID, pr.SrcRepo)
				}
				if pr.ID == 11 {
					return "", errors.New("twg failed\nmore text")
				}
				return pr.Repo, nil
			}
			if tc.before != nil {
				tc.before(t, origin)
			}

			plan := PlanSync(context.Background(), d, tc.prs)

			var todo []string
			for _, b := range plan.Todo {
				where := b.Git.Dir
				switch {
				case where == work:
					where = "pane"
				case where == d.Paths.RepoDir(b.PR.Repo):
					where = "own"
				}
				todo = append(todo, fmt.Sprintf("#%d %s %d", b.PR.ID, where, b.Commits))
			}
			if !reflect.DeepEqual(todo, tc.wantTodo) {
				t.Errorf("Todo = %q, want %q", todo, tc.wantTodo)
			}
			var skipped []string
			for _, o := range plan.Skipped {
				skipped = append(skipped, o.Text)
			}
			var wantSkipped []string
			for _, s := range tc.wantSkipped {
				wantSkipped = append(wantSkipped, strings.ReplaceAll(s, "{origin}", origin))
			}
			if !reflect.DeepEqual(skipped, wantSkipped) {
				t.Errorf("Skipped = %q, want %q", skipped, wantSkipped)
			}
			if !reflect.DeepEqual(calls, tc.wantCalls) {
				t.Errorf("GitFor calls = %q, want %q", calls, tc.wantCalls)
			}
			var git []string
			for _, l := range d.Log.Lines(100) {
				if f := strings.Fields(l.Text); !l.Head && len(f) > 1 {
					git = append(git, f[0]+" "+f[1])
				}
			}
			if !reflect.DeepEqual(git, tc.wantGit) {
				t.Errorf("git commands = %q, want %q", git, tc.wantGit)
			}
		})
	}
}
