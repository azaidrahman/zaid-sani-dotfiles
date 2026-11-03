package ui

import (
	"fmt"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"

	"bbprs/internal/bb"
	"bbprs/internal/review"
)

func TestBox(t *testing.T) {
	out := box("[2] Open", "1 of 3", []string{"a", "a very long line that does not fit in the box"}, 20, 5, focused)
	lines := strings.Split(out, "\n")
	if len(lines) != 5 {
		t.Fatalf("got %d lines, want 5:\n%s", len(lines), ansi.Strip(out))
	}
	for i, l := range lines {
		if w := lipgloss.Width(l); w != 20 {
			t.Errorf("line %d has width %d, want 20: %q", i, w, ansi.Strip(l))
		}
	}
	if top := ansi.Strip(lines[0]); !strings.HasPrefix(top, "╭─[2] Open") {
		t.Errorf("top line = %q, want the prefix ╭─[2] Open", top)
	}
	if bottom := ansi.Strip(lines[4]); !strings.HasSuffix(bottom, "1 of 3─╯") {
		t.Errorf("bottom line = %q, want the suffix 1 of 3─╯", bottom)
	}
}

func TestFormatRow(t *testing.T) {
	// The colors of the AI cell show only with a color profile.
	old := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.ANSI)
	t.Cleanup(func() { lipgloss.SetColorProfile(old) })

	now := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	pr := func(repo string, id int, title string) bb.PR {
		return bb.PR{Repo: repo, ID: id, Role: bb.Review, Author: "Ana Tester", Title: title, Sent: now.Add(-72 * time.Hour), UpdatedRaw: "2026-11-02T10:00:00"}
	}
	draft := pr("ws/cur", 27, "Pin the image")
	draft.Draft = true
	// done returns a finished review of the PR update updated.
	done := func(verdict, updated string) *review.State {
		return &review.State{Status: review.StatusDone, Started: now.Add(-time.Hour), Verdict: verdict, Updated: updated}
	}
	const cur = "2026-11-02T10:00:00"
	cases := []struct {
		name   string
		pr     bb.PR
		behind int
		rv     *review.State
		width  int
		want   string // a part of the row, without styles
		suffix string // the end of the row, without styles
		cell   string // a part of the row with styles: the AI cell
	}{
		{"columns", pr("ws/cur", 41, "Fix the login redirect"), 2, nil, 80, "   #41   3d ● review     ↓2 Ana T.    ·    Fix", "", ""},
		{"other repo", pr("ws/other", 5, "Bump a module"), 0, nil, 80, "   #5   3d ● review        Ana T.    other Bump", "", ""},
		{"draft", draft, 0, nil, 80, "·    [draft] Pin", "", ""},
		{"wide title", pr("ws/cur", 9, strings.Repeat("🚀漢", 20)), 0, nil, 50, "", "…", ""},
		{"AI running", pr("ws/cur", 41, "Fix"), 0, &review.State{Status: review.StatusRunning, Started: now.Add(-time.Minute)}, 80, "review  •", "", "\x1b[2m•\x1b[0m"},
		{"AI running, but the child is dead", pr("ws/cur", 41, "Fix"), 0, &review.State{Status: review.StatusRunning, Started: now.Add(-13 * time.Minute)}, 80, "review  ✗", "", "\x1b[31m✗\x1b[0m"},
		{"AI approve", pr("ws/cur", 41, "Fix"), 0, done("approve", cur), 80, "review  •", "", "\x1b[32m•\x1b[0m"},
		{"AI comment", pr("ws/cur", 41, "Fix"), 0, done("comment", cur), 80, "review  •", "", "\x1b[33m•\x1b[0m"},
		{"AI request-changes", pr("ws/cur", 41, "Fix"), 0, done("request-changes", cur), 80, "review  •", "", "\x1b[31m•\x1b[0m"},
		{"AI failed", pr("ws/cur", 41, "Fix"), 0, &review.State{Status: review.StatusFailed, Started: now.Add(-time.Hour)}, 80, "review  ✗", "", "\x1b[31m✗\x1b[0m"},
		{"AI stale: the PR changed since", pr("ws/cur", 41, "Fix"), 0, done("approve", "2026-11-01T10:00:00"), 80, "review  •", "", "\x1b[2m•\x1b[0m"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			row := FormatRow(c.pr, "ws/cur", c.behind, c.rv, false, now, repoWidth("ws/cur", []string{c.pr.Repo}), c.width)
			plain := ansi.Strip(row)
			if w := lipgloss.Width(row); w != c.width {
				t.Errorf("width = %d, want %d: %q", w, c.width, plain)
			}
			if !strings.Contains(plain, c.want) {
				t.Errorf("row = %q, want it to contain %q", plain, c.want)
			}
			if !strings.HasSuffix(plain, c.suffix) {
				t.Errorf("row = %q, want the suffix %q", plain, c.suffix)
			}
			if !strings.Contains(row, c.cell) {
				t.Errorf("row = %q, want the AI cell %q", row, c.cell)
			}
		})
	}

	t.Run("header", func(t *testing.T) {
		h := listHeader("open", 5, 60)
		plain := ansi.Strip(h)
		if w := lipgloss.Width(h); w != 60 {
			t.Errorf("width = %d, want 60: %q", w, plain)
		}
		if a, b, c := strings.Index(plain, "PR#"), strings.Index(plain, "AGE"), strings.Index(plain, "TITLE"); a < 0 || a > b || b > c {
			t.Errorf("header = %q, want PR# before AGE before TITLE", plain)
		}
		// Each header names the column of its cell in a row.
		row := ansi.Strip(FormatRow(pr("ws/cur", 41, "Fix"), "ws/cur", 2, done("approve", cur), false, now, 5, 60))
		col := func(s, part string) int { return ansi.StringWidth(s[:strings.Index(s, part)]) }
		for head, cell := range map[string]string{"AI": "•", "↓": "↓2", "AUTHOR": "Ana T."} {
			if col(plain, head) != col(row, cell) {
				t.Errorf("header %q at column %d, cell %q at column %d:\n%s\n%s", head, col(plain, head), cell, col(row, cell), plain, row)
			}
		}
	})
}

// The Review tab shows the state of the review of the PR under the cursor.
// Text from the reviewer must not send a control character to the terminal.
func TestReviewTab(t *testing.T) {
	pr := fixturePRs()[0]
	done := doneReview(pr)
	stale := done
	stale.Updated = "2026-10-30T10:00:00"
	failed := review.State{
		Status: review.StatusFailed, Started: time.Now().Add(-time.Hour), Finished: time.Now().Add(-time.Hour),
		Reviewer: "claude", Model: "haiku", Error: "The reviewer gave no outcome.", Raw: "I could not\x1b[2J finish the review.",
	}
	cases := []struct {
		name      string
		st        *review.State
		want, not []string
	}{
		{"done", &done, []string{
			"Reviewer  claude · haiku", "Status    done 5m ago", "Verdict   request-changes", "⏎ open the review session",
			"The budget never resets.]52;c;eA== Add a test.", "high   api/retry.go:12  The budget is not reset after a success.",
		}, []string{"stale"}},
		{"stale", &stale, []string{"Status    done 5m ago (stale: the PR changed since)"}, nil},
		{"failed", &failed, []string{"Status    failed", "Error     The reviewer gave no outcome.", "I could not[2J finish the review."},
			[]string{"⏎ open the review session"}},
		{"none", nil, []string{"No review yet. Press R to review with claude."}, []string{"Reviewer"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t.TempDir(), fixturePRs(), nil)
			if c.st != nil {
				f.writeReview(pr, *c.st)
			}
			f.m = feed(f.m, tea.WindowSizeMsg{Width: 250, Height: 40})
			// The tick reads the state files at most one time in reviewsEvery.
			f.m = send(feed(f.m, tickMsg(time.Now().Add(reviewsEvery))), "{")
			got := f.mainText()
			for _, want := range c.want {
				if !strings.Contains(got, want) {
					t.Errorf("panel =\n%s\nwant %q", got, want)
				}
			}
			for _, not := range c.not {
				if strings.Contains(got, not) {
					t.Errorf("panel =\n%s\nwant no %q", got, not)
				}
			}
			if raw := strings.Join(f.panel(), "\n"); strings.Contains(raw, "\x1b") {
				t.Errorf("panel has an escape character: %q", raw)
			}
		})
	}
}

// Text from Bitbucket must not send a control character to the terminal.
func TestClean(t *testing.T) {
	cases := []struct {
		name, in, want string
		text           bool // cleanText, for a text of more than one line
	}{
		{"escape sequence", "a\x1b]52;c;x\x07b", "a]52;c;xb", false},
		{"C1 CSI", "\u009b31mred", "31mred", false},
		{"tab", "a\tb", "a b", false},
		{"line break", "a\nb", "a b", false},
		{"plain text", "Bump the 漢字 module 🚀", "Bump the 漢字 module 🚀", false},
		{"text: OSC 52 and ESC in many lines", "one\x1b]52;c;eA==\x07\r\ntwo\x1b[2J\tx\n\u009bthree\r",
			"one]52;c;eA==\ntwo[2J    x\nthree", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f, name := clean, "clean"
			if c.text {
				f, name = cleanText, "cleanText"
			}
			if got := f(c.in); got != c.want {
				t.Errorf("%s(%q) = %q, want %q", name, c.in, got, c.want)
			}
		})
	}
}

// viewAt renders the full view of the model at the size w×h, with fixture
// data. Task 9 sets it, because the model is part of Task 9.
var viewAt func(w, h int) string

func TestViewSizes(t *testing.T) {
	cases := []struct {
		w, h    int
		stacked bool // [1] Status, then [2], then [0], from the top
		side    bool // [1] Status and [0] on the same line
		rows    int  // the PR rows that [2] shows at least, in the stacked layout
	}{
		{w: 120, h: 40, side: true},
		// 24 lines is the height of a default terminal. There, [2] must show
		// four PRs: the command log gives up its lines first.
		{w: 80, h: 24, stacked: true, rows: 4},
		{w: 30, h: 10},
	}
	for _, c := range cases {
		t.Run(fmt.Sprintf("%dx%d", c.w, c.h), func(t *testing.T) {
			lines := strings.Split(viewAt(c.w, c.h), "\n")
			if len(lines) > c.h {
				t.Errorf("got %d lines, want at most %d", len(lines), c.h)
			}
			for i, l := range lines {
				if w := lipgloss.Width(l); w > c.w {
					t.Errorf("line %d has width %d, want at most %d: %q", i, w, c.w, ansi.Strip(l))
				}
			}
			find := func(s string) int {
				for i, l := range lines {
					if strings.Contains(ansi.Strip(l), s) {
						return i
					}
				}
				return -1
			}
			status, prs, main := find("[1] Status"), find("[2]"), find("[0]")
			if c.stacked && !(status >= 0 && status < prs && prs < main) {
				t.Errorf("lines of [1] Status, [2], [0] = %d, %d, %d, want them in this order", status, prs, main)
			}
			if c.side && (status < 0 || status != main) {
				t.Errorf("lines of [1] Status and [0] = %d, %d, want the same line", status, main)
			}
			if c.rows > 0 && prs >= 0 {
				// Each PR row has the dot of its role. The box ends at its
				// bottom border.
				n := 0
				for _, l := range lines[prs+1:] {
					l = ansi.Strip(l)
					if strings.HasPrefix(l, "╰") {
						break
					}
					if strings.Contains(l, "●") {
						n++
					}
				}
				if n < c.rows {
					t.Errorf("[2] shows %d PR rows, want at least %d", n, c.rows)
				}
			}
		})
	}
}
