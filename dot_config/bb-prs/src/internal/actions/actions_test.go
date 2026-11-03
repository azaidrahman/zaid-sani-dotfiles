package actions

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
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
	if lines := d.Log.Lines(10); !reflect.DeepEqual(lines, wantLog) {
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

// RunSync names the chosen method in the head of its entry in the command
// log, in the outcome, and in the note of the log of actions. TestSync and
// TestSyncMerge check what each method does to the branch.
func TestRunSync(t *testing.T) {
	tests := []struct {
		method Method
		head   string
		text   string
	}{
		{method: MethodRebase, head: "Sync #2 (rebase feat onto main)", text: "#2 synced onto main"},
		{method: MethodMerge, head: "Sync #2 (merge main into feat)", text: "#2 merged main in"},
	}
	for _, tc := range tests {
		t.Run(string(tc.method), func(t *testing.T) {
			_, work := gitopstest.Repos(t)
			d := newDeps(t, "ws/cur")
			d.Git = &gitops.Git{Dir: work}
			pr := bb.PR{Repo: "ws/cur", ID: 2, Role: bb.Open, Src: "feat", Dst: "main"}

			outs := RunSync(context.Background(), d, SyncPlan{Todo: []Behind{{PR: pr, Commits: 1}}}, tc.method)

			if len(outs) != 1 || !outs[0].OK || outs[0].Text != tc.text {
				t.Fatalf("outcomes = %+v, want one ok outcome with text %q", outs, tc.text)
			}
			if lines := d.Log.Lines(50); len(lines) == 0 || !lines[0].Head || lines[0].Text != tc.head {
				t.Errorf("log = %+v, want the head %q first", lines, tc.head)
			}
			acts, err := d.Paths.ReadActions(5)
			if err != nil || len(acts) != 1 || acts[0].Action != "sync" || acts[0].Result != "ok" || acts[0].Note != string(tc.method) {
				t.Errorf("actions = %+v (err %v), want one sync, ok, with note %q", acts, err, tc.method)
			}
		})
	}
}

func TestPlanSync(t *testing.T) {
	_, work := gitopstest.Repos(t)
	d := newDeps(t, "ws/cur")
	d.Git = &gitops.Git{Dir: work, Record: d.Log.Add}
	prs := []bb.PR{
		{Repo: "ws/other", ID: 1, Role: bb.Open, Src: "feat", Dst: "main"},
		{Repo: "ws/cur", ID: 2, Role: bb.Open, Src: "feat", Dst: "main"},
		{Repo: "ws/cur", ID: 3, Role: bb.Open, Src: "main", Dst: "main"},
		{Repo: "ws/cur", ID: 4, Role: bb.Open, Src: "gone", Dst: "main"},
	}

	plan, err := PlanSync(context.Background(), d, prs)
	if err != nil {
		t.Fatal(err)
	}

	if len(plan.Todo) != 1 || plan.Todo[0].PR.ID != 2 || plan.Todo[0].Commits != 1 {
		t.Errorf("Todo = %+v, want #2 with 1 commit", plan.Todo)
	}
	var skipped []string
	for _, o := range plan.Skipped {
		skipped = append(skipped, o.Text)
	}
	want := []string{
		"#1 not in ws/cur",
		"#3 up to date with main",
		"#4 no branch gone or main on origin",
	}
	if !reflect.DeepEqual(skipped, want) {
		t.Errorf("Skipped = %q, want %q", skipped, want)
	}
}
