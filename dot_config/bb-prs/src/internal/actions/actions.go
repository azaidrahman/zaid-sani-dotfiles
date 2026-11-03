// Package actions runs the changes that the user starts from the list: approve,
// approve and merge, sync a branch, and open a review. Each function logs to
// the command log and to the log of actions.
package actions

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"bbprs/internal/bb"
	"bbprs/internal/cmdlog"
	"bbprs/internal/gitops"
	"bbprs/internal/store"
	"bbprs/internal/twg"
)

const (
	// syncTimeout is the time for the sync of one PR.
	syncTimeout = 2 * time.Minute
	// mergeTimeout is the time for one merge call, which waits for Bitbucket.
	mergeTimeout = 5 * time.Minute
)

// Deps holds what the actions need. Git is the clone of the pane. It is nil
// outside a repo. Repo is the repo of that clone. GitFor returns the own clone
// of bb-prs for another repo. It makes the clone on the first use, and it
// gives each git command to record. SourceRepo returns the repo of the source
// branch of a PR whose SrcRepo is empty, and it gives each twg command to
// record. ListFile is the cache file of the open list.
type Deps struct {
	Twg        *twg.Runner
	Git        *gitops.Git
	GitFor     func(ctx context.Context, repo string, record func(string)) (*gitops.Git, error)
	SourceRepo func(ctx context.Context, pr bb.PR, record func(string)) (string, error)
	Paths      store.Paths
	Repo       string
	ListFile   string
	Log        *cmdlog.Log
	Now        func() time.Time

	// addLine adds a line to the entry of the command log that begin made.
	addLine func(string)
}

// Outcome is the result for one PR. Text is the line for the result popup.
// OK is true if the PR got the change that the user asked for.
type Outcome struct {
	PR   bb.PR
	OK   bool
	Text string
}

// Behind is a PR whose source branch is behind the destination branch. Git
// is the clone that PlanSync fetched. RunSync syncs the PR in that clone.
type Behind struct {
	PR      bb.PR
	Commits int
	Git     *gitops.Git
}

// SyncPlan is the result of PlanSync. Todo holds the PRs that RunSync
// changes. Skipped holds the PRs that it leaves, with the reason.
type SyncPlan struct {
	Todo    []Behind
	Skipped []Outcome
}

// Method is the way that RunSync updates a source branch.
type Method string

const (
	// MethodRebase rebases the source branch onto the destination branch, and
	// force pushes with a lease.
	MethodRebase Method = "rebase"
	// MethodMerge merges the destination branch into the source branch, and
	// pushes without force.
	MethodMerge Method = "merge"
)

// Approve approves each open PR that is not yours.
func Approve(ctx context.Context, d Deps, prs []bb.PR) []Outcome {
	var acted []bb.PR
	for _, pr := range prs {
		if pr.IsOpen() && pr.Role != bb.Mine {
			acted = append(acted, pr)
		}
	}
	d = d.begin("Approve", acted)

	out := make([]Outcome, 0, len(prs))
	for _, pr := range prs {
		switch {
		case !pr.IsOpen():
			out = append(out, skipped(pr, "not an open PR, skipped"))
		case pr.Role == bb.Mine:
			out = append(out, skipped(pr, "your own PR, no approval"))
		default:
			text, ok := d.approve(ctx, pr)
			out = append(out, Outcome{PR: pr, OK: ok, Text: fmt.Sprintf("#%d %s", pr.ID, text)})
		}
	}
	return out
}

// Merge approves each open PR and merges it, one PR at a time. It merges a PR
// also if the approval failed, because the PR can already have enough
// approvals. A failure does not stop the other PRs. A merged PR leaves the
// list file.
func Merge(ctx context.Context, d Deps, prs []bb.PR) []Outcome {
	var open []bb.PR
	for _, pr := range prs {
		if pr.IsOpen() {
			open = append(open, pr)
		}
	}
	d = d.begin("Approve and merge", open)

	out := make([]Outcome, 0, len(prs))
	for _, pr := range prs {
		if !pr.IsOpen() {
			out = append(out, skipped(pr, "not an open PR, skipped"))
			continue
		}
		var parts []string
		if pr.Role != bb.Mine {
			text, _ := d.approve(ctx, pr)
			parts = append(parts, text)
		}
		id := strconv.Itoa(pr.ID)
		// --wait waits until Bitbucket ends the merge. That can take more
		// than the usual timeout, and then a good merge looks failed.
		long := *d.Twg
		long.Timeout = mergeTimeout
		err := long.Do(ctx, "bitbucket", "pull-requests", "merge", "--pull-request", id,
			"--repo", pr.Repo, "--merge-strategy", "merge_commit", "--close-source-branch", "--wait")
		d.record(pr, "merge", result(err), note(err))
		if err != nil {
			parts = append(parts, "merge failed: "+err.Error())
		} else {
			parts = append(parts, "merged")
			d.dropFromList(pr)
			d.Paths.DropPreviews(pr.Repo, pr.ID)
		}
		out = append(out, Outcome{PR: pr, OK: err == nil, Text: fmt.Sprintf("#%d %s", pr.ID, strings.Join(parts, " · "))})
	}
	return out
}

// PlanSync finds the PRs that RunSync can change. A PR of the repo of the
// pane uses the clone of the pane. A PR of another repo uses the own clone of
// bb-prs, from GitFor. PlanSync fetches origin one time for each repo. If the
// clone or the fetch of a repo fails, PlanSync skips only the PRs of that
// repo, with the reason.
func PlanSync(ctx context.Context, d Deps, prs []bb.PR) SyncPlan {
	var plan SyncPlan
	var open []bb.PR
	for _, pr := range prs {
		if pr.IsOpen() {
			open = append(open, pr)
		} else {
			plan.Skipped = append(plan.Skipped, skipped(pr, "not an open PR, skipped"))
		}
	}
	if len(open) == 0 {
		return plan
	}
	d = d.begin("Fetch origin to sync", open)
	clones := map[string]clone{}
	for _, pr := range open {
		// Check the source repo before any git work for the PR.
		if reason := d.checkSource(ctx, pr); reason != "" {
			plan.Skipped = append(plan.Skipped, skipped(pr, reason))
			continue
		}
		c, done := clones[pr.Repo]
		if !done {
			c = d.fetch(ctx, pr.Repo)
			clones[pr.Repo] = c
		}
		if c.fail != "" {
			plan.Skipped = append(plan.Skipped, skipped(pr, c.fail))
			continue
		}
		n, ok := c.git.Behind(pr.Src, pr.Dst)
		switch {
		case !ok:
			plan.Skipped = append(plan.Skipped, skipped(pr, fmt.Sprintf("no branch %s or %s on origin", pr.Src, pr.Dst)))
		case n == 0:
			plan.Skipped = append(plan.Skipped, skipped(pr, "up to date with "+pr.Dst))
		default:
			plan.Todo = append(plan.Todo, Behind{PR: pr, Commits: n, Git: c.git})
		}
	}
	return plan
}

// clone is the fetched clone of one repo. If fail is not empty, the clone or
// the fetch failed, and fail is the reason to skip the PRs of the repo.
type clone struct {
	git  *gitops.Git
	fail string
}

// fetch gets the clone of repo, and fetches origin there. A reason to skip
// holds only the first line of the error.
func (d Deps) fetch(ctx context.Context, repo string) clone {
	g := d.Git
	if !d.inPane(repo) {
		if d.GitFor == nil {
			return clone{fail: fmt.Sprintf("could not clone %s: Deps.GitFor is not set", repo)}
		}
		var err error
		if g, err = d.GitFor(ctx, repo, d.addLine); err != nil {
			return clone{fail: fmt.Sprintf("could not clone %s: %s", repo, firstLine(err))}
		}
	}
	if err := g.Fetch(ctx); err != nil {
		return clone{fail: "git fetch failed: " + firstLine(err)}
	}
	return clone{git: g}
}

// checkSource returns the reason to skip pr if the source branch is not in
// the repo of the PR, or if the source repo is not known. A sync of a PR from
// a fork would change the branch of the same name in the repo of the PR.
// SourceRepo finds the source repo only if the list did not tell it.
func (d Deps) checkSource(ctx context.Context, pr bb.PR) string {
	src := pr.SrcRepo
	if src == "" {
		if d.SourceRepo == nil {
			return "could not check the source repo: Deps.SourceRepo is not set"
		}
		var err error
		if src, err = d.SourceRepo(ctx, pr, d.addLine); err != nil {
			return "could not check the source repo: " + firstLine(err)
		}
		if src == "" {
			return "could not check the source repo: the PR has no source repo"
		}
	}
	// Bitbucket does not care about the case of a repo name.
	if !strings.EqualFold(src, pr.Repo) {
		return "from a fork, sync it in its own repo"
	}
	return ""
}

// firstLine returns the first line of the text of err.
func firstLine(err error) string {
	first, _, _ := strings.Cut(err.Error(), "\n")
	return first
}

// inPane reports whether repo is the repo of the clone of the pane.
func (d Deps) inPane(repo string) bool { return d.Git != nil && repo == d.Repo }

// RunSync updates the source branch of each PR of the plan with the method.
// It syncs each PR in the clone that PlanSync fetched. Rebase puts the
// commits of the source branch on the destination branch, and force pushes
// with a lease. Merge merges the destination branch into the source branch,
// and pushes without force. Each PR has 2 minutes. Then git stops, for
// example if ssh waits for a passphrase.
func RunSync(ctx context.Context, d Deps, plan SyncPlan, method Method) []Outcome {
	prs := make([]bb.PR, len(plan.Todo))
	for i, b := range plan.Todo {
		prs[i] = b.PR
	}
	d = d.beginWith("Sync", syncDetail(prs, method), prs)

	out := make([]Outcome, 0, len(prs))
	for _, b := range plan.Todo {
		pr := b.PR
		res, msg := d.sync(ctx, b, method)
		o := Outcome{PR: pr}
		switch res {
		case gitops.Synced:
			o.OK = true
			if method == MethodMerge {
				o.Text = fmt.Sprintf("#%d merged %s in", pr.ID, pr.Dst)
			} else {
				o.Text = fmt.Sprintf("#%d synced onto %s", pr.ID, pr.Dst)
			}
			d.record(pr, "sync", "ok", string(method))
			d.Paths.DropPreviews(pr.Repo, pr.ID)
		case gitops.Conflict:
			o.Text = d.conflictText(pr)
			d.record(pr, "sync", "conflict", string(method))
		default:
			o.Text = fmt.Sprintf("#%d sync failed: %s", pr.ID, msg)
			d.record(pr, "sync", "failed", string(method)+": "+msg)
		}
		out = append(out, o)
	}
	return out
}

// conflictText tells the user how to see the conflicts of pr. The own clone
// of bb-prs is not a folder of the user. Thus, for a PR of another repo, the
// text names the repo, not a command to run here.
func (d Deps) conflictText(pr bb.PR) string {
	if d.inPane(pr.Repo) {
		return fmt.Sprintf("#%d conflicts, nothing changed. Run: git pr-conflicts %d", pr.ID, pr.ID)
	}
	_, name, _ := strings.Cut(pr.Repo, "/")
	return fmt.Sprintf("#%d conflicts, nothing changed. Run git pr-conflicts %d in a clone of %s.", pr.ID, pr.ID, name)
}

// syncDetail names the method for the head line of the command log. For one
// PR it also names the branches.
func syncDetail(prs []bb.PR, method Method) string {
	if len(prs) != 1 {
		return string(method)
	}
	if method == MethodMerge {
		return fmt.Sprintf("merge %s into %s", prs[0].Dst, prs[0].Src)
	}
	return fmt.Sprintf("rebase %s onto %s", prs[0].Src, prs[0].Dst)
}

// sync runs the sync of one PR with its own timeout, in the clone of the
// plan. The git commands go under the head of the sync.
func (d Deps) sync(ctx context.Context, b Behind, method Method) (gitops.SyncResult, string) {
	ctx, cancel := context.WithTimeout(ctx, syncTimeout)
	defer cancel()
	g := *b.Git
	if d.addLine != nil {
		g.Record = d.addLine
	}
	sync := g.Sync
	if method == MethodMerge {
		sync = g.SyncMerge
	}
	res, msg := sync(ctx, b.PR.Src, b.PR.Dst)
	if res == gitops.Failed && errors.Is(ctx.Err(), context.DeadlineExceeded) {
		msg = "git stopped after 2 minutes. It can wait for a password or a passphrase."
	}
	return res, msg
}

// LogReview logs that the user opened a review of pr. The review can add
// comments or an approval, so it also drops the previews of the PR.
func LogReview(d Deps, pr bb.PR) {
	d.record(pr, "review", "opened", "")
	d.Paths.DropPreviews(pr.Repo, pr.ID)
}

func skipped(pr bb.PR, reason string) Outcome {
	return Outcome{PR: pr, Text: fmt.Sprintf("#%d %s", pr.ID, reason)}
}

func result(err error) string {
	if err != nil {
		return "failed"
	}
	return "ok"
}

func note(err error) string {
	if err != nil {
		return err.Error()
	}
	return ""
}

// begin adds a head line to the command log, for example "Approve #12, #14".
// It returns a copy of d whose twg and git write their commands under that
// head. Another action that runs at the same time cannot mix its lines in. If
// prs is empty, begin adds nothing and returns d.
func (d Deps) begin(verb string, prs []bb.PR) Deps {
	return d.beginWith(verb, "", prs)
}

// beginWith is begin with a detail. The head line ends with the detail in
// parentheses, for example "Sync #41 (merge main into fix/x)".
func (d Deps) beginWith(verb, detail string, prs []bb.PR) Deps {
	if d.Log == nil || len(prs) == 0 {
		return d
	}
	ids := make([]string, len(prs))
	for i, pr := range prs {
		ids[i] = "#" + strconv.Itoa(pr.ID)
	}
	head := verb + " " + strings.Join(ids, ", ")
	if detail != "" {
		head += " (" + detail + ")"
	}
	e := d.Log.Begin(head)
	d.addLine = e.Add
	if d.Twg != nil {
		r := *d.Twg
		r.Record = e.Add
		d.Twg = &r
	}
	if d.Git != nil {
		g := *d.Git
		g.Record = e.Add
		d.Git = &g
	}
	return d
}

// approve approves one PR, logs it, and returns the text for the popup.
func (d Deps) approve(ctx context.Context, pr bb.PR) (text string, ok bool) {
	err := d.Twg.Do(ctx, "bitbucket", "pull-requests", "approve", strconv.Itoa(pr.ID), "--repo", pr.Repo)
	d.record(pr, "approve", result(err), note(err))
	if err != nil {
		return "approval failed: " + err.Error(), false
	}
	d.Paths.DropPreviews(pr.Repo, pr.ID)
	return "approved", true
}

// record adds one line to the log of actions. A failed write is not an error
// for the user: the action already happened.
func (d Deps) record(pr bb.PR, action, result, note string) {
	now := time.Now
	if d.Now != nil {
		now = d.Now
	}
	_ = d.Paths.AppendAction(store.Action{
		Time: now().Local(), Action: action, Result: result,
		Repo: pr.Repo, ID: pr.ID, URL: pr.URL, Src: pr.Src, Dst: pr.Dst,
		Title: pr.Title, Note: note,
	})
}

// dropFromList removes pr from the list file, for example after a merge. A
// missing file or a PR that is not in the list changes nothing.
func (d Deps) dropFromList(pr bb.PR) {
	c, err := store.LoadList(d.ListFile)
	if err != nil {
		return
	}
	kept := c.PRs[:0:0]
	for _, p := range c.PRs {
		if p.Repo != pr.Repo || p.ID != pr.ID {
			kept = append(kept, p)
		}
	}
	if len(kept) == len(c.PRs) {
		return
	}
	c.PRs = kept
	_ = store.SaveList(d.ListFile, c)
}
