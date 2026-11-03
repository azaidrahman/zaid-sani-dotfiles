package ui

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"bbprs/internal/actions"
	"bbprs/internal/bb"
)

type popupKind int

const (
	confirmKind popupKind = iota // y or enter runs yes; n, esc, or q cancels
	resultKind                   // any key closes it
	menuKind                     // the keys; enter runs the key under the cursor
)

// popup is a panel in the middle of the screen. The model has at most one.
type popup struct {
	kind  popupKind
	title string
	foot  string
	lines []string   // confirmKind and resultKind
	items []menuItem // menuKind
	// methods are the lines to choose from in a confirmKind popup. They come
	// after lines, and after holds the lines under them. If there are no
	// methods, the popup has nothing to choose. On a short screen, the popup
	// cuts its last lines, so the methods come first.
	methods []methodItem
	after   []string
	// verb names the action of a confirmKind popup. The body ends with an
	// empty line and the line of choice(verb).
	verb string
	idx  int // the cursor of the menu, or the chosen method
	yes  func(m *Model) tea.Cmd
}

// methodItem is one way to run the action of a confirm popup. The name is the
// line that the user chooses. The text says what the method does. It can be
// empty.
type methodItem struct {
	name, text string
	method     actions.Method
}

type menuItem struct {
	key, text string
	run       string // the name of the key that the item runs
}

// menuItems are the items of the ? menu. menuPopup writes the text of R,
// because the text has the name of the reviewer.
var menuItems = []menuItem{
	{"⏎", "Review in tuicr; in [0] Changes, go one level in", "enter"},
	{"⏎", "In [0] Review: open the review session", "enter"},
	{"space", "Select the PR (or click its left edge)", " "},
	{"s", "Sync: rebase or merge the destination in", "s"},
	{"a", "Approve; with more than one PR selected, ask first", "a"},
	{"m", "Approve and merge", "m"},
	{"R", "", "R"},
	{"o", "Open in the browser: the PR, or the commit in [0] Changes", "o"},
	{"c", "Check for conflicts, and open a worktree tab to fix them", "c"},
	{"[ ]", "Next list: Open, Closed, Log", "]"},
	{"{ }", "Next view: Status, Changes, Activity, Review", "}"},
	{"S", "Change the order", "S"},
	{"/", "Filter", "/"},
	{"r", "Load the list again", "r"},
	{"j k", "Move in the list, the commits, or the files, or scroll [0]", "j"},
	{"J K", "Scroll the right side, in [0] Changes", "J"},
	{"^d", "Half a page down, in [2] and [0]", "ctrl+d"},
	{"^u", "Half a page up, in [2] and [0]", "ctrl+u"},
	{"h l", "Scroll [0] sideways, with wrap off", "l"},
	{"w", "Line wrap on or off, in [0]", "w"},
	{"tab", "Focus the next panel", "tab"},
	{"1 2 0", "Focus Status, PRs, or Main", "2"},
	{"esc", "Back in [0] Changes, clear the filter or selection, or quit", "esc"},
	{"q", "Quit", "q"},
}

const (
	popupWidth = 72
	// popupText is the width of the text in a popup. It is the width of the
	// popup without the border, the margins, and one more space at the left.
	popupText = popupWidth - 5
)

// width returns the width of the popup on a screen of screen columns. The
// popup is popupWidth columns wide, or wider if a line needs more, for
// example a long command. It leaves 2 columns at each side of the screen. If
// a line is still too wide, the box cuts it, and the line ends with "…".
func (p *popup) width(screen int) int {
	need := popupWidth
	for _, l := range p.lines {
		need = max(need, ansi.StringWidth(l)+popupWidth-popupText)
	}
	if w := min(need, screen-4); w >= 20 {
		return w
	}
	return screen
}

// menuPopup returns the ? menu. reviewer is the name of the reviewer.
func menuPopup(reviewer string) *popup {
	items := slices.Clone(menuItems)
	for i, it := range items {
		if it.run == "R" {
			items[i].text = fmt.Sprintf("Review with %s in the background (see [0] Review)", reviewer)
		}
	}
	return &popup{kind: menuKind, title: "Keybindings", foot: "⏎ run · esc close", items: items}
}

func (m *Model) popupKey(k tea.KeyMsg) tea.Cmd { return m.popupRun(k.String()) }

// popupRun runs the key with the name key in the popup. A click on an item
// of the popup also runs its key here.
func (m *Model) popupRun(key string) tea.Cmd {
	p := m.popup
	if time.Now().Before(m.guardUntil) {
		return nil // a key that the user typed before the popup opened
	}
	switch p.kind {
	case menuKind:
		switch key {
		case "j", "down":
			p.idx = min(p.idx+1, len(p.items)-1)
		case "k", "up":
			p.idx = max(p.idx-1, 0)
		case "enter":
			m.popup = nil
			return m.runKey(p.items[p.idx].run)
		case "esc", "q", "?":
			m.popup = nil
		}
	case confirmKind:
		switch key {
		case "j", "down":
			p.idx = min(p.idx+1, max(len(p.methods)-1, 0))
		case "k", "up":
			p.idx = max(p.idx-1, 0)
		case "enter", "y":
			m.popup = nil
			return p.yes(m)
		case "esc", "n", "q":
			m.popup = nil
			m.setFlash("Cancelled. Nothing changed.", "")
		}
	default:
		m.popup = nil
	}
	return nil
}

// choiceItems are the items of the last line of a confirm popup: the item
// that runs the action of verb, and the item that cancels.
func choiceItems(verb string) []barItem {
	return []barItem{{verb, "⏎ or y", "enter"}, {"Cancel", "esc or n", "esc"}}
}

// choice is the last line of a confirm popup.
func choice(verb string) string {
	items := choiceItems(verb)
	return fg(blue).Render(items[0].label()) + dimStyle.Render(barSep) + fg(blue).Render(items[1].label())
}

func idText(id int) string { return boldStyle.Render(fmt.Sprintf("#%d", id)) }

// prLine returns the line of a PR in a confirm popup, wrapped to the width of
// the popup. A note follows the title, in dim.
func prLine(p bb.PR, note string) []string {
	prefix := "  " + fg(cyan).Render(clean(shortRepo(p.Repo))) + idText(p.ID) + "  "
	lines := wrap(prefix, clean(p.Title), plainStyle, popupText)
	if note == "" {
		return lines
	}
	// The note goes after the title. If it does not fit, it gets its own line.
	last := len(lines) - 1
	if ansi.StringWidth(lines[last])+1+ansi.StringWidth(note) <= popupText {
		lines[last] += " " + dimStyle.Render(note)
		return lines
	}
	return append(lines, strings.Repeat(" ", ansi.StringWidth(prefix))+dimStyle.Render(note))
}

// approveConfirm asks before the approval of more than one PR. The PRs of the
// user show a note, because the approval skips them.
func approveConfirm(prs []bb.PR) *popup {
	lines := []string{"Approve these PRs?", ""}
	for _, p := range prs {
		note := ""
		if p.Role == bb.Mine {
			note = "(your own PR, no approval)"
		}
		lines = append(lines, prLine(p, note)...)
	}
	return &popup{kind: confirmKind, title: "Approve", lines: lines, verb: "Approve", yes: func(m *Model) tea.Cmd {
		return m.runApprove(prs)
	}}
}

func mergeConfirm(prs []bb.PR) *popup {
	lines := []string{"Approve and merge these PRs?", dimStyle.Render("Merge commit. The source branch closes."), ""}
	for _, p := range prs {
		lines = append(lines, prLine(p, "")...)
	}
	return &popup{kind: confirmKind, title: "Approve and merge", lines: lines, verb: "Merge", yes: func(m *Model) tea.Cmd {
		m.startBusy("Merging…")
		d := m.d.Actions
		return func() tea.Msg {
			return actionMsg{title: mergeTitle, outcomes: actions.Merge(context.Background(), d, prs)}
		}
	}}
}

// syncMethods returns the two methods of the sync popup. For one PR, they
// name its branches.
func syncMethods(plan actions.SyncPlan) []methodItem {
	rebase, merge := "Rebase each source branch onto its destination", "Merge each destination into its source"
	if len(plan.Todo) == 1 {
		pr := plan.Todo[0].PR
		rebase = fmt.Sprintf("Rebase %s onto %s", clean(pr.Src), clean(pr.Dst))
		merge = fmt.Sprintf("Merge %s into %s", clean(pr.Dst), clean(pr.Src))
	}
	return []methodItem{
		{rebase, "rewrites its commits, force-push with lease; the author must reset the local branch", actions.MethodRebase},
		{merge, "one merge commit, normal push; rewrites nothing", actions.MethodMerge},
	}
}

func syncConfirm(plan actions.SyncPlan) *popup {
	after := []string{""}
	for _, b := range plan.Todo {
		after = append(after, fmt.Sprintf("  %s  %s is %s commit(s) behind %s", idText(b.PR.ID),
			fg(magenta).Render(clean(b.PR.Src)), fg(magenta).Render(fmt.Sprint(b.Commits)), clean(b.PR.Dst)))
	}
	after = append(after, skipLines(plan.Skipped)...)
	p := &popup{
		kind: confirmKind, title: "Sync", foot: "j/k choose · ⏎ run · esc cancel",
		lines: []string{"How do you want to sync these branches?", ""}, methods: syncMethods(plan), after: after,
		verb: "Sync",
	}
	p.yes = func(m *Model) tea.Cmd {
		m.startBusy("Syncing…")
		m.skipped = plan.Skipped
		d := m.d.Actions
		method := p.methods[p.idx].method
		return func() tea.Msg {
			return actionMsg{title: syncTitle, outcomes: actions.RunSync(context.Background(), d, plan, method)}
		}
	}
	return p
}

func nothingToSync(skipped []actions.Outcome) *popup {
	lines := append([]string{"Nothing to sync.", ""}, skipLines(skipped)...)
	lines = append(lines, "", dimStyle.Render("Any key closes this."))
	return &popup{kind: resultKind, title: "Sync", lines: lines}
}

// resultPopup lists the outcomes, then the PRs that the action skipped.
func resultPopup(title string, outs, skipped []actions.Outcome) *popup {
	var lines []string
	for _, o := range outs {
		id, rest, _ := strings.Cut(clean(o.Text), " ")
		mark := fg(red).Render("✗")
		switch {
		case o.OK:
			mark = fg(green).Render("✓")
		case strings.Contains(rest, "conflicts"):
			mark = fg(yellow).Render("!")
		}
		lines = append(lines, wrap(mark+" "+boldStyle.Render(id)+"  ", rest, plainStyle, popupText)...)
	}
	lines = append(lines, skipLines(skipped)...)
	lines = append(lines, "", dimStyle.Render("Any key closes this."))
	return &popup{kind: resultKind, title: title, lines: lines}
}

// skipLines gives a dim line for each skipped PR, with the reason.
func skipLines(skipped []actions.Outcome) []string {
	var lines []string
	for _, o := range skipped {
		id, rest, _ := strings.Cut(clean(o.Text), " ")
		lines = append(lines, wrap(dimStyle.Render("  "+id+"  "), rest, dimStyle, popupText)...)
	}
	return lines
}

// body returns the lines of the popup for a text width of w.
func (p *popup) body(w int) []string {
	out, _ := p.bodyLines(w)
	return out
}

// bodyLines returns the lines of the popup for a text width of w. For each
// line, item holds the index of the method that the line shows (its name or
// its text), or of the menu item, or -1.
func (p *popup) bodyLines(w int) (out []string, item []int) {
	add := func(line string, i int) {
		out, item = append(out, line), append(item, i)
	}
	if p.kind != menuKind {
		for _, l := range p.lines {
			add(" "+l, -1)
		}
		for i, it := range p.methods {
			mark, name := "  ", plainStyle.Render(it.name)
			if i == p.idx {
				mark, name = "▸ ", boldStyle.Render(it.name)
			}
			row := fit(" "+mark+name, w)
			if i == p.idx {
				row = cursorLine(row, true)
			}
			add(row, i)
			if it.text == "" {
				continue
			}
			for _, l := range wrap("     ", it.text, dimStyle, w-1) {
				add(" "+l, i)
			}
		}
		for _, l := range p.after {
			add(" "+l, -1)
		}
		if p.verb != "" {
			add("", -1)
			add(" "+choice(p.verb), -1)
		}
		return out, item
	}
	for i, it := range p.items {
		row := fit(" "+fit(fg(green).Render(it.key), 8)+it.text, w)
		if i == p.idx {
			row = cursorLine(row, true)
		}
		add(row, i)
	}
	return out, item
}

// popupPlace is the place of the popup on the screen, and its body lines.
// item is the same as in bodyLines.
type popupPlace struct {
	r    rect
	body []string
	item []int
}

// place returns the place of the popup in the middle of a screen of w
// columns and h lines.
func (p *popup) place(w, h int) popupPlace {
	pw := p.width(w)
	body, item := p.bodyLines(pw - 2*bodyX)
	ph := min(len(body)+2, h)
	return popupPlace{r: rect{(w - pw) / 2, (h - ph) / 2, pw, ph}, body: body, item: item}
}

// overlay draws the popup in the middle of the screen lines. The screen
// behind it is dim.
func (m Model) overlay(lines []string) []string {
	if len(lines) == 0 || m.w < 4 {
		return lines
	}
	pl := m.popup.place(m.w, len(lines))
	x, y, pw := pl.r.X, pl.r.Y, pl.r.W
	frame := strings.Split(box(greenBold.Render(clean(m.popup.title)), m.popup.foot, pl.body, pw, pl.r.H, focused), "\n")

	out := make([]string, len(lines))
	for i, l := range lines {
		plain := ansi.Strip(l)
		if i < y || i >= y+len(frame) {
			out[i] = dimStyle.Render(plain)
			continue
		}
		left := ansi.Truncate(plain, x, "")
		left += strings.Repeat(" ", x-ansi.StringWidth(left))
		right := ""
		if rest := ansi.StringWidth(plain) - x - pw; rest > 0 {
			right = ansi.TruncateLeft(plain, x+pw, "")
			if ansi.StringWidth(right) > rest {
				// A wide character crosses the right edge of the popup.
				right = ansi.TruncateLeft(plain, x+pw+1, "")
			}
			right = strings.Repeat(" ", max(0, rest-ansi.StringWidth(right))) + right
		}
		out[i] = dimStyle.Render(left) + frame[i-y] + dimStyle.Render(right)
	}
	return out
}
