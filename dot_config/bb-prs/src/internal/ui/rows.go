package ui

import (
	"fmt"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"bbprs/internal/bb"
	"bbprs/internal/store"
)

// mark returns the first column of a row: a green "┃" for a selected row.
func mark(selected bool) string {
	if selected {
		return fg(green).Render("┃")
	}
	return " "
}

// Widths of the columns of the lists. The mark of the selection comes first.
const (
	idWidth      = 6  // "#" and the number, aligned to the right
	maxRepoWidth = 16 // the most columns of the repo column
	minRepoWidth = 4  // the width of the header "REPO"
)

// repoWidth returns the width of the repo column for the repos of the rows
// that the list shows. It is the width of the widest short name, at least 4
// and at most 16. The repo cur shows as "·", which is one column wide.
func repoWidth(cur string, repos []string) int {
	w := minRepoWidth
	for _, r := range repos {
		if r != cur {
			w = max(w, ansi.StringWidth(clean(shortRepo(r))))
		}
	}
	return min(w, maxRepoWidth)
}

// repoCell returns the repo column of a row, padded to w columns, and a
// space. It shows "·" if repo is the current repo cur.
func repoCell(repo, cur string, w int) string {
	if repo == cur {
		return dimStyle.Render(fit("·", w)) + " "
	}
	return fg(cyan).Render(fit(clean(shortRepo(repo)), w)) + " "
}

// idCell returns the PR number column of a row, aligned to the right, and a
// space.
func idCell(id int) string {
	return boldStyle.Render(fitRight(fmt.Sprintf("#%d", id), idWidth)) + " "
}

// listHeader returns the header row of a list: "open", "closed", or "log".
// The columns have the same widths as the rows. repoW is the width of the repo
// column. The row is dim, and it is exactly width columns wide.
func listHeader(list string, repoW, width int) string {
	var b strings.Builder
	b.WriteString(" ")
	b.WriteString(fitRight("PR#", idWidth) + " ")
	if list == "log" {
		b.WriteString(fit("TIME", 12) + "  " + fit("RESULT", 14))
	} else {
		b.WriteString(fitRight("AGE", 4) + "   " + fit("ROLE", 8) + fit("↓", 3) + fit("AUTHOR", 9) + " ")
	}
	b.WriteString(fit("REPO", repoW) + " TITLE")
	return dimStyle.Render(fit(b.String(), width))
}

// FormatRow returns the row of a PR in the list. The columns are: the mark of
// the selection, the id, the age, the role, the commits behind the
// destination, the author, the repo, and the title. The repo column is repoW
// columns wide, and it shows "·" for the repo cur. The age of an open PR is
// the time since it was sent. The age of a closed PR is the time since its
// last change. A behind count of 0 shows nothing. The row is exactly width
// columns wide.
func FormatRow(p bb.PR, cur string, behind int, selected bool, now time.Time, repoW, width int) string {
	when := p.Sent
	if !p.IsOpen() {
		when = p.Updated
	}
	age := ""
	if !when.IsZero() {
		age = bb.Age(now.Sub(when))
	}
	down := ""
	if behind > 0 {
		down = fmt.Sprintf("↓%d", behind)
	}

	var b strings.Builder
	b.WriteString(mark(selected))
	b.WriteString(idCell(p.ID))
	b.WriteString(dimStyle.Render(fitRight(age, 4)) + " ")
	b.WriteString(roleStyle(p.Role).Render("●") + " ")
	b.WriteString(fit(clean(string(p.Role)), 8))
	b.WriteString(fg(magenta).Render(fit(down, 3)))
	b.WriteString(dimStyle.Render(fit(abbr(p.Author), 9)) + " ")
	b.WriteString(repoCell(p.Repo, cur, repoW))
	if p.Draft {
		b.WriteString(dimStyle.Render("[draft]") + " ")
	}
	b.WriteString(clean(p.Title))
	return fit(b.String(), width)
}

// actionWord returns the word and the color of a line of the log of actions.
// The words are the same as in the bash script.
func actionWord(action, result string) (string, lipgloss.Color) {
	switch {
	case action == "approve" && result == "ok":
		return "approved", green
	case action == "merge" && result == "ok":
		return "merged", green
	case action == "sync" && result == "ok":
		return "synced", green
	case action == "review":
		return "reviewed", blue
	case result == "conflict":
		return action + " conflict", yellow
	}
	return action + " failed", red
}

// FormatActionRow returns the row of one action in the log list: the mark of
// the selection, the id, the time, the result, the repo, the title, and the
// note. The repo column is repoW columns wide, and it shows "·" for the repo
// cur. The row is exactly width columns wide.
func FormatActionRow(a store.Action, cur string, selected bool, repoW, width int) string {
	word, color := actionWord(clean(a.Action), a.Result)
	when := ""
	if !a.Time.IsZero() {
		when = a.Time.Format("01-02 15:04")
	}

	var b strings.Builder
	b.WriteString(mark(selected))
	b.WriteString(idCell(a.ID))
	b.WriteString(dimStyle.Render(fit(when, 12)))
	b.WriteString(fg(color).Render("●") + " ")
	b.WriteString(fit(word, 14))
	b.WriteString(repoCell(a.Repo, cur, repoW))
	b.WriteString(clean(a.Title))
	if a.Note != "" {
		b.WriteString(" " + dimStyle.Render("("+clean(a.Note)+")"))
	}
	return fit(b.String(), width)
}
