package ui

import (
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// paneState tells how to draw the border of a panel.
type paneState int

const (
	plain     paneState = iota // no focus: a bright black border
	focused                    // the panel has focus: a green border
	searching                  // the filter is open: a cyan border
)

func (s paneState) border() lipgloss.Style {
	switch s {
	case focused:
		return fg(green)
	case searching:
		return fg(cyan)
	}
	return fg(gray)
}

// The places in a box that box draws. The title starts titleX columns after
// the left edge, after "╭─". The body starts 1 line under the top edge and
// bodyX columns after the left edge, after "│ ".
const (
	titleX = 2
	bodyX  = 2
)

// body returns the place of the body of a box that box draws in r.
func (r rect) body() rect {
	return rect{r.X + bodyX, r.Y + 1, max(0, r.W-2*bodyX), max(0, r.H-2)}
}

// box draws a panel with a rounded border. The panel is w columns wide and h
// lines high. The title is in the top line, after "╭─". The foot is at the
// right of the bottom line, before "─╯". The body is cut or padded to h−2
// lines, and each line of the body to w−4 columns. The caller styles the
// title. The foot is dim.
func box(title, foot string, body []string, w, h int, state paneState) string {
	if w <= 0 || h <= 0 {
		return ""
	}
	lines := make([]string, 0, h)
	if w < 4 {
		for range h {
			lines = append(lines, strings.Repeat(" ", w))
		}
		return strings.Join(lines, "\n")
	}
	b := state.border()

	title = cut(title, w-2*titleX)
	lines = append(lines, b.Render("╭─")+title+b.Render(strings.Repeat("─", w-3-ansi.StringWidth(title))+"╮"))
	if h == 1 {
		return lines[0]
	}

	side := b.Render("│")
	for i := range h - 2 {
		line := ""
		if i < len(body) {
			line = body[i]
		}
		lines = append(lines, side+" "+fit(line, w-2*bodyX)+" "+side)
	}

	foot = cut(clean(foot), w-4)
	fill := w - 3 - ansi.StringWidth(foot)
	if foot != "" {
		foot = dimStyle.Render(foot)
	}
	lines = append(lines, b.Render("╰"+strings.Repeat("─", fill))+foot+b.Render("─╯"))
	return strings.Join(lines, "\n")
}
