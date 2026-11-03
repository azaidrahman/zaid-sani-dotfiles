// Package ui draws the PR picker in the terminal.
package ui

import (
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"bbprs/internal/bb"
)

// The colors are ANSI numbers 0 to 15, so that they follow the theme of the
// terminal.
const (
	red     lipgloss.Color = "1"
	green   lipgloss.Color = "2"
	yellow  lipgloss.Color = "3"
	blue    lipgloss.Color = "4"
	magenta lipgloss.Color = "5"
	cyan    lipgloss.Color = "6"
	gray    lipgloss.Color = "8"
)

var (
	plainStyle = lipgloss.NewStyle()
	dimStyle   = lipgloss.NewStyle().Faint(true)
	boldStyle  = lipgloss.NewStyle().Bold(true)
	greenBold  = lipgloss.NewStyle().Foreground(green).Bold(true)
)

func fg(c lipgloss.Color) lipgloss.Style { return lipgloss.NewStyle().Foreground(c) }

var roleColors = map[bb.Role]lipgloss.Color{
	bb.Mine:     cyan,
	bb.Review:   yellow,
	bb.Open:     blue,
	bb.Merged:   green,
	bb.Declined: red,
}

// roleStyle gives the color of a role. A role without a color is plain.
func roleStyle(r bb.Role) lipgloss.Style {
	if c, ok := roleColors[r]; ok {
		return fg(c)
	}
	return plainStyle
}

// clean removes the control characters from s, so that text from Bitbucket
// cannot send escape sequences to the terminal or break a line. A tab or a
// line break becomes a space.
func clean(s string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r == '\t' || r == '\n' || r == '\r':
			return ' '
		case unicode.IsControl(r):
			return -1
		}
		return r
	}, s)
}

// cleanText is clean for a text of more than one line. It keeps the line
// breaks, and a tab becomes four spaces.
func cleanText(s string) string {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\t", "    ")
	return strings.Map(func(r rune) rune {
		if r != '\n' && unicode.IsControl(r) {
			return -1
		}
		return r
	}, s)
}

// fit cuts or pads s to exactly w columns. A cut text ends with "…" in the
// last column. Wide characters count as two columns.
func fit(s string, w int) string {
	if w <= 0 {
		return ""
	}
	n := ansi.StringWidth(s)
	if n <= w {
		return s + strings.Repeat(" ", w-n)
	}
	cut := ansi.Truncate(s, w-1, "")
	return cut + strings.Repeat(" ", w-1-ansi.StringWidth(cut)) + "…"
}

// fitRight is fit, but it puts the padding at the left.
func fitRight(s string, w int) string {
	if n := ansi.StringWidth(s); n < w {
		return strings.Repeat(" ", w-n) + s
	}
	return fit(s, w)
}

// cut shortens s to at most w columns. A cut text ends with "…".
func cut(s string, w int) string {
	if w <= 0 {
		return ""
	}
	return ansi.Truncate(s, w, "…")
}

// abbr shortens a name to "First L.".
func abbr(name string) string {
	f := strings.Fields(clean(name))
	switch len(f) {
	case 0:
		return ""
	case 1:
		return f[0]
	}
	r, _ := utf8.DecodeRuneInString(f[1])
	return f[0] + " " + string(r) + "."
}

// shortRepo returns the part of "<workspace>/<repo>" after the slash.
func shortRepo(repo string) string {
	if _, name, ok := strings.Cut(repo, "/"); ok {
		return name
	}
	return repo
}

// tabs returns the title of a panel: the number, then the names with " ─ "
// between them. The name at the index on is the current one. In a panel with
// focus, the number and the current name are green and bold.
func tabs(num string, names []string, on int, state paneState) string {
	hot := state == focused
	var b strings.Builder
	if num != "" {
		st := dimStyle
		if hot {
			st = greenBold
		}
		b.WriteString(st.Render(num) + " ")
	}
	for i, name := range names {
		if i > 0 {
			b.WriteString(fg(gray).Render(" ─ "))
		}
		st := dimStyle
		switch {
		case i == on && hot:
			st = greenBold
		case i == on && len(names) > 1:
			st = boldStyle
		case i == on:
			st = plainStyle
		}
		b.WriteString(st.Render(name))
	}
	return b.String()
}

// reset is the escape sequence that ends all styles.
const reset = "\x1b[0m"

// cursorLine gives a line the background of the cursor row: blue in the
// panel with focus, bright black in another panel. The background stays on
// after each reset in the line. If the terminal has no colors, the line does
// not change.
func cursorLine(line string, hasFocus bool) string {
	c := gray
	if hasFocus {
		c = blue
	}
	seq := lipgloss.ColorProfile().Color(string(c)).Sequence(true)
	if seq == "" {
		return line
	}
	on := "\x1b[" + seq + "m"
	return on + strings.ReplaceAll(line, reset, reset+on) + reset
}
