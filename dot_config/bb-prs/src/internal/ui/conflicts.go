package ui

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"bbprs/internal/bb"
	"bbprs/internal/cmdlog"
	"bbprs/internal/gitops"
)

const (
	// conflictTimeout is the time for the check of one PR. It covers the
	// fetch, the worktree, and the tab.
	conflictTimeout = 2 * time.Minute
	// conflictTitle is the title of the popup of the check.
	conflictTitle = "Conflicts"
	// maxConflictFiles is the number of conflicted files that the popup
	// lists. The next steps must stay on the screen.
	maxConflictFiles = 8
)

// conflictMsg holds the popup that the check of a PR made.
type conflictMsg struct{ popup *popup }

// conflicts checks the PR under the cursor for conflicts with its
// destination. If it has conflicts, the check makes a worktree with the
// destination merged in, and opens a terminal tab there. The picker stays
// open.
func (m *Model) conflicts() tea.Cmd {
	if m.busy != "" || !m.openOnly("Conflict check") {
		return nil
	}
	pr, ok := m.current()
	if !ok {
		return nil
	}
	if pr.Repo != m.d.Env.Repo || m.d.Env.Dir == "" {
		m.setFlash(fmt.Sprintf("Conflict check needs the checkout. Open bb-prs in %s.", clean(pr.Repo)), yellow)
		return nil
	}
	m.startBusy("Checking conflicts…")
	d := m.d
	e := d.Log.Begin(fmt.Sprintf("Check conflicts of #%d", pr.ID))
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), conflictTimeout)
		defer cancel()
		return conflictMsg{popup: checkConflicts(ctx, d, e, pr)}
	}
}

func (m *Model) onConflict(msg conflictMsg) {
	m.busy = ""
	m.showPopup(msg.popup)
}

// checkConflicts runs the check and returns the popup for its result. Each
// command goes to the entry e.
func checkConflicts(ctx context.Context, d Deps, e *cmdlog.Entry, pr bb.PR) *popup {
	g := gitops.Git{Dir: d.Env.Dir, Record: e.Add}
	if err := g.Fetch(ctx); err != nil {
		return conflictFailure(pr, "git fetch failed: "+err.Error())
	}
	files, err := g.Conflicts(ctx, pr.Src, pr.Dst)
	if err != nil {
		return conflictFailure(pr, err.Error())
	}
	if len(files) == 0 {
		return &popup{kind: resultKind, title: conflictTitle, lines: []string{
			fg(green).Render("✓") + " " + fmt.Sprintf("No conflicts between %s and %s.", clean(pr.Src), clean(pr.Dst)),
			"", dimStyle.Render("Any key closes this."),
		}}
	}

	// The worktree is next to the checkout, as the script puts it by default.
	dir := filepath.Join(filepath.Dir(d.Env.Dir), filepath.Base(d.Env.Dir)+fmt.Sprintf("-pr%d", pr.ID))
	reused := false
	if _, err := os.Stat(dir); err == nil {
		// Reuse the directory only if it is a git worktree. A worktree has a
		// .git file. Else a tab there would not help the user.
		if _, err := os.Stat(filepath.Join(dir, ".git")); err != nil {
			return conflictFailure(pr, dir+" exists, but it is not a git worktree. Move it or remove it, then check again.")
		}
		reused = true
	} else {
		if d.PRConflicts == nil {
			return conflictFailure(pr, "git pr-conflicts is not available.")
		}
		args := []string{"pr-conflicts", fmt.Sprint(pr.ID), "--resolve", "--no-fetch", "--plain", "--worktree", dir}
		// The script exits with 1 when it leaves conflicts. That is normal.
		// The worktree is the sign of success.
		out, runErr := d.PRConflicts(ctx, g, args...)
		if _, err := os.Stat(dir); err != nil {
			text := lastLines(out, 5)
			if text == "" && runErr != nil {
				text = runErr.Error()
			}
			return conflictFailure(pr, "git pr-conflicts did not make the worktree. "+text)
		}
	}

	tab := d.Tab
	tab.Record = e.Add
	where, tabErr := tab.Open(ctx, dir, fmt.Sprintf("PR #%d conflicts", pr.ID), fmt.Sprintf("pr%d", pr.ID))
	return conflictResult(pr, files, dir, where, reused, tabErr)
}

// conflictFailure is the popup for a check that failed. The text can have
// many lines.
func conflictFailure(pr bb.PR, text string) *popup {
	lines := []string{fg(red).Render("✗") + " " + fmt.Sprintf("The conflict check of #%d failed.", pr.ID), ""}
	for _, l := range strings.Split(cleanText(text), "\n") {
		lines = append(lines, wrap("  ", l, plainStyle, popupText)...)
	}
	lines = append(lines, "", dimStyle.Render("Any key closes this."))
	return &popup{kind: resultKind, title: conflictTitle, lines: lines}
}

// conflictResult is the popup for a PR with conflicts: the files, where the
// worktree is, and the next steps.
func conflictResult(pr bb.PR, files []string, dir, where string, reused bool, tabErr error) *popup {
	noun := "files"
	if len(files) == 1 {
		noun = "file"
	}
	lines := []string{fmt.Sprintf("%s conflicts with %s in %d %s:", idText(pr.ID), clean(pr.Dst), len(files), noun)}
	for i, f := range files {
		if i == maxConflictFiles {
			lines = append(lines, dimStyle.Render(fmt.Sprintf("  … and %d more", len(files)-i)))
			break
		}
		lines = append(lines, wrap("  "+fg(yellow).Render("!")+" ", clean(f), plainStyle, popupText)...)
	}
	lines = append(lines, "")
	if reused {
		lines = append(lines, wrap("", "Reused the existing worktree "+clean(dir)+".", plainStyle, popupText)...)
	}
	switch {
	case tabErr != nil:
		lines = append(lines, wrap("", "The worktree is ready, but the tab did not open: "+clean(tabErr.Error()), fg(yellow), popupText)...)
		lines = append(lines, wrap("  ", clean(dir), plainStyle, popupText)...)
	case where == "":
		lines = append(lines, wrap("", "The worktree is ready. There is no Rex or tmux, so no tab opened. Go to:", plainStyle, popupText)...)
		lines = append(lines, wrap("  ", clean(dir), plainStyle, popupText)...)
	default:
		lines = append(lines, wrap("", "Opened "+where+" in the worktree:", plainStyle, popupText)...)
		lines = append(lines, wrap("  ", clean(dir), plainStyle, popupText)...)
	}
	lines = append(lines, "", dimStyle.Render("Next steps, in the tab:"))
	// Each command stays on one line, so that the user can copy it. A wrap
	// can break a branch name at a "-". The popup gets wider for a long line.
	for _, step := range []string{
		"git diff --name-only --diff-filter=U",
		"git add -A && git merge --continue",
		"git push origin " + shellWord(fmt.Sprintf("merge/pr-%d:%s", pr.ID, clean(pr.Src))),
		fmt.Sprintf("git pr-conflicts %d --cleanup", pr.ID),
	} {
		lines = append(lines, "  "+fg(cyan).Render(step))
	}
	lines = append(lines, "", dimStyle.Render("Any key closes this."))
	return &popup{kind: resultKind, title: conflictTitle, lines: lines}
}

// lastLines returns the last n lines of out.
func lastLines(out string, n int) string {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// shellWord returns s as one word for a shell. A word of plain characters
// stays as it is. Any other word goes in single quotes. A branch name can hold
// characters that a shell runs, for example ";" or "$(".
func shellWord(s string) string {
	plain := s != ""
	for _, r := range s {
		if !strings.ContainsRune("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:-", r) {
			plain = false
		}
	}
	if plain {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
