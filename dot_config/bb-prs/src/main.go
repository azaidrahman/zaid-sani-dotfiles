// Command bb-prs is a picker for Bitbucket pull requests. It shows the PRs in
// a terminal screen. You can review, sync, approve, and merge them.
//
// With no arguments, it starts the screen. With "--refresh <list> [--auto]",
// it loads one list into the cache and stops. The screen starts this child
// process, and the child lives on after the screen closes. With
// "--ai-review <repo> <id> [--again]", it runs the background reviewer on one
// PR. The screen starts that child in the same way.
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"bbprs/internal/actions"
	"bbprs/internal/bb"
	"bbprs/internal/browser"
	"bbprs/internal/cmdlog"
	"bbprs/internal/gitops"
	"bbprs/internal/refresh"
	"bbprs/internal/review"
	"bbprs/internal/store"
	"bbprs/internal/termtab"
	"bbprs/internal/twg"
	"bbprs/internal/ui"
)

const usage = `Usage: bb-prs

Show the open Bitbucket PRs for you.

  j/k      move in the list, or scroll the main panel
  tab      focus the next panel (shift+tab: the previous panel)
  1 2 0    focus Status, PRs, or Main
  [ ]      change the list: open, closed, log of your actions
  { }      change the tab of the main panel: Status, Changes, Activity,
           Review
  w        turn the line wrap of the main panel on or off (Main has focus)
  ctrl+d   move half a page down (ctrl+u: up) in the list, or in the main panel
  h/l      scroll the main panel sideways (Main has focus, and wrap is off)
  J/K      scroll the right side of the changes tab (there, j/k choose the
           commit or the file, and in the zoom j/k scroll the diff too)
  enter    review in tuicr (:submit posts comments, or comments and approval)
           in the changes tab of the main panel: show the files of the
           commit, then zoom the diff of the file (esc goes back)
  space    select a PR, to act on more than one (a click on the left edge of
           a row does the same)
  s        sync the selected PRs with their destination. A popup asks first,
           and you choose the method: rebase the source branch onto the
           destination (force-push with lease), or merge the destination
           into the source branch (one merge commit, normal push). Any open
           PR works. For a repo that is not the repo of the pane, bb-prs
           uses its own clone in ~/.cache/bb-prs/repos
  a        approve the selected PRs. If more than one PR is selected, a popup
           asks first
  m        approve and merge the selected PRs (asks first)
  R        review the selected PRs with Claude in the background (set
           another reviewer in ~/.config/bb-prs/reviewer.json). The AI column
           of the list shows the outcome, and the Review tab shows the
           summary and the findings. For a finished review, a popup asks:
           open the review session, or run the review again. In the Review
           tab, enter opens the review session
  o        open the PR in the browser (in the changes tab of the main panel:
           the selected commit)
  c        check the PR for conflicts. If it has any, make a worktree with the
           destination merged in, and open a terminal tab there (needs the
           checkout of the PR)
  S        change the order: oldest sent, newest sent, by repo
  r        load the list again
  /        filter by title, author, or repo
  ?        show all keys
  esc      go back in the changes tab, then clear the filter, then the
           selection, then quit
  q        quit

Mouse:
  click    focus a panel, choose a row, a file, or a tab, or run a key of
           the bar or of a popup. A click on the left edge of a PR row
           selects it (as space). In the changes tab, click the selected
           commit or file again to go in (as enter), and click the line
           "← ... (esc)" to go back
  wheel    move in the list, or scroll the main panel
  To select text, hold shift and drag (in most terminals). Without shift,
  bb-prs gets the drag.

Environment:
  BB_WORKSPACE      the workspace to use outside a Bitbucket repo
  BB_PRS_OPEN_HOST  where o opens the browser: local, aqua, or onyx
  BB_PRS_POPUP      if set, wait for a key after an error
`

var errNoWorkspace = errors.New("no workspace. Run bb-prs in a Bitbucket repo one time, or set BB_WORKSPACE.")

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(args []string) int {
	switch {
	case len(args) == 0:
		return runUI()
	case len(args) == 1 && (args[0] == "-h" || args[0] == "--help"):
		fmt.Print(usage)
		return 0
	case args[0] == "--refresh":
		return runRefresh(args[1:])
	case args[0] == "--ai-review":
		return runAIReview(args[1:])
	}
	fmt.Fprint(os.Stderr, usage)
	return 2
}

// setup finds the repo, the workspace, and the list prompt for dir. In a
// Bitbucket repo, it saves the workspace. Outside one, the workspace comes
// from BB_WORKSPACE, then from the saved workspace.
func setup(dir string, paths store.Paths, getenv func(string) string) (refresh.Env, error) {
	env := refresh.Env{Paths: paths}
	if repo, ok := bb.ParseRemote(gitops.OriginURL(dir)); ok {
		top, err := gitops.Toplevel(dir)
		if err != nil {
			return env, err
		}
		env.Repo, env.WS, env.Dir = repo, repo[:strings.Index(repo, "/")], top
		// A failed save is not fatal. The workspace is known now.
		_ = paths.SaveWorkspace(env.WS)
	} else {
		env.WS = getenv("BB_WORKSPACE")
		if env.WS == "" {
			env.WS = paths.LoadWorkspace()
		}
		if env.WS == "" {
			return env, errNoWorkspace
		}
	}
	env.Prompt = env.Repo
	if env.Prompt == "" {
		env.Prompt = env.WS
	}
	return env, nil
}

// fail prints the error. In a popup, it then waits for a key, so that the
// message stays on the screen when the popup closes.
func fail(err error) int {
	fmt.Fprintf(os.Stderr, "bb-prs: %s\n", err)
	if os.Getenv("BB_PRS_POPUP") != "" {
		if tty, terr := os.Open("/dev/tty"); terr == nil {
			defer tty.Close()
			fmt.Fprint(os.Stderr, "Press Enter to close.")
			_, _ = bufio.NewReader(tty).ReadString('\n')
		}
	}
	return 1
}

func runRefresh(args []string) int {
	if len(args) < 1 || len(args) > 2 || (args[0] != "open" && args[0] != "closed") ||
		(len(args) == 2 && args[1] != "--auto") {
		fmt.Fprint(os.Stderr, usage)
		return 2
	}
	// The child must live after the terminal closes.
	signal.Ignore(syscall.SIGHUP)
	// On a stop signal, cancel the context, so that Run releases the lock.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// The child has no terminal, so it prints errors and never waits for a key.
	wd, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(os.Stderr, "bb-prs: %s\n", err)
		return 1
	}
	env, err := setup(wd, store.DefaultPaths(), os.Getenv)
	if err != nil {
		fmt.Fprintf(os.Stderr, "bb-prs: %s\n", err)
		return 1
	}
	env.Twg = twg.New(nil)
	env.Now = time.Now
	if err := refresh.Run(ctx, env, args[0], len(args) == 2); err != nil {
		fmt.Fprintf(os.Stderr, "bb-prs: %s\n", err)
		return 1
	}
	return 0
}

// runAIReview is the detached child of the key R. The usage text of the
// screen does not list it, because only the screen starts it. With --again,
// the child replaces a done review. Without it, the child does not touch a
// done review.
func runAIReview(args []string) int {
	again := len(args) == 3 && args[2] == "--again"
	id, err := 0, error(nil)
	if len(args) == 2 || again {
		id, err = strconv.Atoi(args[1])
	}
	if len(args) != 2 && !again || err != nil || id < 1 || strings.Count(args[0], "/") != 1 || strings.HasPrefix(args[0], "/") || strings.HasSuffix(args[0], "/") {
		fmt.Fprintln(os.Stderr, "Usage: bb-prs --ai-review <workspace/repo> <id> [--again]")
		return 2
	}
	repo := args[0]
	// The child must live after the terminal closes.
	signal.Ignore(syscall.SIGHUP)
	// On a stop signal, cancel the context. The child then writes the state
	// "failed" and releases the lock.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// The state file has a known path before the setup. A failure before the
	// review writes the state "failed", so that the screen shows the error.
	paths := store.DefaultPaths()
	early := func(name string, err error) int {
		fmt.Fprintf(os.Stderr, "bb-prs: %s\n", err)
		_ = review.Fail(paths, name, repo, id, again, err.Error())
		return 1
	}
	cfg, err := review.Load(review.ConfigPath())
	if err != nil {
		return early("", fmt.Errorf("The reviewer config is not valid: %s.", err))
	}
	wd, err := os.Getwd()
	if err != nil {
		return early(cfg.Name, err)
	}
	env, err := setup(wd, paths, os.Getenv)
	if err != nil {
		return early(cfg.Name, err)
	}
	env.Twg = twg.New(nil)
	env.Now = time.Now
	switch err := review.Child(ctx, env, cfg, repo, id, again); {
	case errors.Is(err, review.ErrLocked), errors.Is(err, review.ErrDone):
		return 0 // Another child reviews this PR, or its review is done.
	case err != nil:
		fmt.Fprintf(os.Stderr, "bb-prs: %s\n", err)
		return 1
	}
	return 0
}

func runUI() int {
	for _, name := range []string{"twg", "git"} {
		if _, err := exec.LookPath(name); err != nil {
			return fail(fmt.Errorf("%s is not installed", name))
		}
	}
	wd, err := os.Getwd()
	if err != nil {
		return fail(err)
	}
	self, err := os.Executable()
	if err != nil {
		return fail(err)
	}
	paths := store.DefaultPaths()
	env, err := setup(wd, paths, os.Getenv)
	if err != nil {
		return fail(err)
	}

	log := &cmdlog.Log{}
	env.Twg = twg.New(log.Add)
	env.Now = time.Now

	acts := actions.Deps{
		Twg: env.Twg, Paths: paths, Repo: env.Repo,
		ListFile: paths.ListFile(env.Prompt, "open"), Log: log, Now: time.Now,
	}
	var origin string
	if env.Dir != "" {
		acts.Git = &gitops.Git{Dir: env.Dir, Record: log.Add}
		origin = gitops.OriginURL(env.Dir)
	}
	// A sync of a PR of another repo uses the own clone of bb-prs. CloneURL
	// checks the name before the name goes into the path.
	acts.GitFor = func(ctx context.Context, repo string, record func(string)) (*gitops.Git, error) {
		url, err := gitops.CloneURL(repo, origin)
		if err != nil {
			return nil, err
		}
		return gitops.EnsureClone(ctx, paths.RepoDir(repo), url, record)
	}
	// Sync skips a PR from a fork. If the list does not tell the source repo,
	// a details preview or one twg call tells it. The twg command goes under
	// the head of the sync in the command log.
	acts.SourceRepo = func(ctx context.Context, pr bb.PR, record func(string)) (string, error) {
		e := env
		if record != nil {
			r := *env.Twg
			r.Record = record
			e.Twg = &r
		}
		return refresh.SourceRepo(ctx, e, pr)
	}

	model := ui.New(ui.Deps{
		Env:     env,
		Actions: acts,
		Opener: browser.Opener{
			Host:   hostname(),
			Force:  strings.ToLower(os.Getenv("BB_PRS_OPEN_HOST")),
			Run:    browser.Default,
			Record: log.Add,
		},
		Log: log,
		PRConflicts: func(ctx context.Context, g gitops.Git, args ...string) (string, error) {
			return g.Run(ctx, args...)
		},
		Tab: termtab.Opener{Env: os.Getenv, Run: termtab.Default},
		Spawn: func(list string, auto bool) error {
			args := []string{"--refresh", list}
			if auto {
				args = append(args, "--auto")
			}
			return refresh.Spawn(self, wd, args...)
		},
		Review: func(url string) *exec.Cmd { return exec.Command("tuicr", "pr", url) },
		ReviewConfig: func() (review.Config, error) {
			return review.Load(review.ConfigPath())
		},
		StartReview: func(repo string, id int, again bool) error {
			return review.Start(self, wd, repo, id, again)
		},
	})
	// Mouse reporting, as lazygit does. Then a plain drag does not select
	// text. The usage text tells the user to drag with shift.
	if _, err := tea.NewProgram(model, tea.WithAltScreen(), tea.WithMouseCellMotion()).Run(); err != nil {
		return fail(err)
	}
	return 0
}

// hostname returns the short name of this Mac in lower case. It reads the
// LocalHostName, as the op wrapper does. On an office network, the kernel host
// name can be a name from DHCP or DNS. If scutil fails, it uses that name to
// the first dot.
func hostname() string {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "scutil", "--get", "LocalHostName").Output()
	h := strings.TrimSpace(string(out))
	if err != nil || h == "" {
		h, _ = os.Hostname()
		h, _, _ = strings.Cut(h, ".")
	}
	return strings.ToLower(h)
}
