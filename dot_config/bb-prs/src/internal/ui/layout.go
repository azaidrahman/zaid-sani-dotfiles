package ui

// rect is the place of a panel on the screen. Y is the first line. A rect
// with H 0 is not shown.
type rect struct{ X, Y, W, H int }

// has is true when the cell at the column x and the line y is in r.
func (r rect) has(x, y int) bool {
	return x >= r.X && x < r.X+r.W && y >= r.Y && y < r.Y+r.H
}

// panes holds the rects of the screen. Wide is true when Status and PRs are
// in a left column, and Main and the command log in a right column.
type panes struct {
	Status, PRs, Main, Cmdlog, Bar rect
	Wide                           bool
}

const (
	wideMin      = 100 // the smallest width for two columns
	statusHeight = 4
	barHeight    = 1
	cmdlogWide   = 9
	cmdlogNarrow = 7
	// prsMin is the height of PRs in one column: the border, the header
	// row, and 4 PR rows. cmdlogMin is the height of the smallest command
	// log: the border and 1 line.
	prsMin    = 7
	cmdlogMin = 3
)

// layout divides a screen of w columns and h lines into the panels. The bar
// is the last line. A wide screen (w ≥ 100) has two columns, and the left
// column is 11/24 of w. Status has 4 lines and the command log 9. PRs and
// Main get the rest of their columns. A narrow screen has one column: Status
// (4 lines), PRs (40% of the free lines), Main (the rest of the free lines),
// and the command log (7 lines). The free lines are the lines that the other
// panels and the bar do not use. On a low narrow screen, PRs get prsMin
// lines. The command log gives its lines first: it shrinks to cmdlogMin
// lines, or it hides. If the screen is too low, the panels at the top keep
// their heights, and the panels at the bottom get fewer lines, or 0.
func layout(w, h int) panes {
	w, h = max(w, 0), max(h, 0)
	var p panes
	bar := min(barHeight, h)
	col := h - bar
	p.Bar = rect{0, col, w, bar}

	if w >= wideMin {
		p.Wide = true
		left := w * 11 / 24
		hs := stack(col, statusHeight, col-statusHeight)
		p.Status = rect{0, 0, left, hs[0]}
		p.PRs = rect{0, hs[0], left, hs[1]}
		hs = stack(col, col-cmdlogWide, cmdlogWide)
		p.Main = rect{left, 0, w - left, hs[0]}
		p.Cmdlog = rect{left, hs[0], w - left, hs[1]}
		return p
	}

	rest := max(col-statusHeight, 0) // the lines of PRs, Main, and the command log
	cmds := cmdlogNarrow
	prs := max(rest-cmds, 0) * 2 / 5
	if need := prsMin - prs; need > 0 {
		if cmds-need >= cmdlogMin {
			cmds -= need
		} else {
			cmds = 0
		}
		prs = prsMin
	}
	hs := stack(col, statusHeight, prs, rest-prs-cmds, cmds)
	y := 0
	for i, r := range []*rect{&p.Status, &p.PRs, &p.Main, &p.Cmdlog} {
		*r = rect{0, y, w, hs[i]}
		y += hs[i]
	}
	return p
}

// stack gives each panel its wanted height, from the top, in total lines. If
// the lines are not sufficient, the panels at the bottom get fewer, or 0.
func stack(total int, want ...int) []int {
	out := make([]int, len(want))
	for i, n := range want {
		out[i] = max(0, min(n, total))
		total -= out[i]
	}
	return out
}
