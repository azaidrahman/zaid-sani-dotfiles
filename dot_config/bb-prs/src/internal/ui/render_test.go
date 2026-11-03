package ui

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"bbprs/internal/bb"
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
	now := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	pr := func(repo string, id int, title string) bb.PR {
		return bb.PR{Repo: repo, ID: id, Role: bb.Review, Author: "Ana Tester", Title: title, Sent: now.Add(-72 * time.Hour)}
	}
	draft := pr("ws/cur", 27, "Pin the image")
	draft.Draft = true
	cases := []struct {
		name   string
		pr     bb.PR
		behind int
		width  int
		want   string // a part of the row, without styles
		suffix string // the end of the row, without styles
	}{
		{"columns", pr("ws/cur", 41, "Fix the login redirect"), 2, 80, "   #41   3d ● review  ↓2 Ana T.    ·    Fix", ""},
		{"other repo", pr("ws/other", 5, "Bump a module"), 0, 80, "   #5   3d ● review     Ana T.    other Bump", ""},
		{"draft", draft, 0, 80, "·    [draft] Pin", ""},
		{"wide title", pr("ws/cur", 9, strings.Repeat("🚀漢", 20)), 0, 50, "", "…"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			row := FormatRow(c.pr, "ws/cur", c.behind, false, now, repoWidth("ws/cur", []string{c.pr.Repo}), c.width)
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
	})
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
