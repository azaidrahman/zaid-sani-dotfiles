package ui

import (
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

// The hit test finds what is under the pointer with the same rects, strings,
// and windows that View uses: layout, the titles of tabs, the bar, listPlace,
// rowWindow, fileWindow, and the place of the popup. View runs after each
// Update, so the state of the model is the state of the last frame.

// wheelStep is the number of lines that one step of the wheel scrolls the
// main panel.
const wheelStep = 3

// mouse handles one mouse message. It acts on a press of the left button and
// on the wheel. It ignores the other buttons, the release, and the motion.
func (m *Model) mouse(msg tea.MouseMsg) tea.Cmd {
	if msg.Action != tea.MouseActionPress {
		return nil
	}
	switch msg.Button {
	case tea.MouseButtonLeft:
		return m.click(msg.X, msg.Y)
	case tea.MouseButtonWheelDown:
		m.wheel(msg.X, msg.Y, 1)
	case tea.MouseButtonWheelUp:
		m.wheel(msg.X, msg.Y, -1)
	}
	return nil
}

// click handles a left click at the column x and the line y. While a popup is
// open, the click goes only to the popup, as a key does. A click on an item
// of the bar runs the key of the item with runKey, as a key press does.
// While the filter is typed, the bar shows no items, so no click types into
// the filter. A click on a panel gives it the focus, and it ends the typing
// of the filter. A click on a border or on the command log does nothing.
func (m *Model) click(x, y int) tea.Cmd {
	if m.popup != nil {
		return m.clickPopup(x, y)
	}
	p := layout(m.w, m.h)
	switch {
	case p.Bar.has(x, y):
		for _, s := range m.barSpans() {
			if x >= s.x0 && x < s.x1 {
				return m.runKey(s.run)
			}
		}
	case p.Status.has(x, y):
		if _, ok := titleTab(p.Status, x, y, "[1]", statusNames); ok || p.Status.body().has(x, y) {
			m.clickFocus("1")
		}
	case p.PRs.has(x, y):
		m.clickPRs(p.PRs, x, y)
	case p.Main.has(x, y):
		return m.clickMain(p.Main, x, y)
	}
	return nil
}

// clickFocus gives the focus to a panel with the key of the panel. A click
// also ends the typing of the filter, as ⏎ does. The filter stays.
func (m *Model) clickFocus(key string) {
	m.filtering = false
	m.runKey(key)
}

// clickPRs handles a click in the PR panel r. A click on a name in the title
// shows that list. A click on a row moves the cursor to that row. A click on
// the header row or on an error line only gives the focus to [2].
func (m *Model) clickPRs(r rect, x, y int) {
	if i, ok := titleTab(r, x, y, "[2]", listNames); ok {
		m.clickFocus("2")
		if i >= 0 {
			m.showList(listOrder[i])
		}
		return
	}
	b := r.body()
	if !b.has(x, y) {
		return
	}
	pl := m.listPlace(r)
	line := y - b.Y - 1 - len(pl.errs) // the line under the header and the errors
	m.clickFocus("2")
	if i := pl.off + line; line >= 0 && line < pl.rows && i < pl.n && i != pl.idx {
		m.moveCursor(i - pl.idx)
	}
}

// clickMain handles a click in the main panel r. A click on a name in the
// title shows that view. On the Changes view, a click on a row of the commit
// list or on a file selects it. If [0] has the focus, a click on the selected
// row or file goes in, as ⏎ does. On the files level, a click on the line of
// the scope goes one level out, as esc does.
func (m *Model) clickMain(r rect, x, y int) tea.Cmd {
	names, _ := m.mainTabs()
	if i, ok := titleTab(r, x, y, "[0]", names); ok {
		overview := m.focus == focusStatus
		m.clickFocus("0")
		if i >= 0 && !overview {
			m.showView(viewOrder[i])
		}
		return nil
	}
	b := r.body()
	if !b.has(x, y) {
		return nil
	}
	// Look before the focus moves: when [1] has focus, [0] shows the
	// overview, not the Changes view.
	c, ok := m.changesData()
	had := m.focus == focusMain
	m.clickFocus("0")
	if !ok {
		return nil
	}
	if m.level == levelFiles && y == b.Y && x-b.X < ansi.StringWidth(ansi.Strip(m.scopeLine(c))) {
		return m.runKey("esc")
	}
	l := m.listRect(c, b)
	if !l.has(x, y) {
		return nil
	}
	line := y - l.Y
	var i, cur, n int
	switch m.level {
	case levelCommits:
		n = c.rows()
		i, cur = m.rowWindow(c, l.H)+line, m.rowIndex(n)
	case levelFiles:
		// The first line of the file list is its header. A click on it only
		// gives the focus.
		if line == 0 {
			return nil
		}
		v, _ := m.scopeFiles(c)
		n = len(v.files)
		i, cur = m.fileWindow(n, m.changesPlaces(c).listRows())+line-1, m.fileIndex(n)
	}
	switch {
	case i >= n:
		// A line under the rows, for example the line that tells that the
		// commits load.
	case i == cur && had:
		return m.runKey("enter")
	case m.level == levelCommits:
		m.moveRow(i - cur)
	default:
		m.moveFile(i - cur)
	}
	return nil
}

// listRect returns the place on the screen of the list of the Changes view
// c, in the body b of the main panel. On the files level, the list is under
// the line of the scope. In the zoom, the list has no lines.
func (m Model) listRect(c changes, b rect) rect {
	p := m.changesPlaces(c)
	top := b.Y
	if m.level == levelFiles {
		top++
	}
	return rect{b.X, top, p.listW, p.listH}
}

// wheel scrolls the panel under the pointer d steps down, or up if d is less
// than 0. In [2], a step moves the cursor one row. In [0], a step scrolls
// wheelStep lines, or on the list of the Changes view, it moves the row or
// the file cursor one row. The focus does not move. While a popup is open,
// the wheel does nothing.
func (m *Model) wheel(x, y, d int) {
	if m.popup != nil {
		return
	}
	p := layout(m.w, m.h)
	switch {
	case p.PRs.has(x, y):
		m.moveCursor(d)
	case p.Main.has(x, y):
		c, ok := m.changesData()
		switch {
		case !ok || !m.listRect(c, p.Main.body()).has(x, y):
			m.scrollBy(d * wheelStep)
		case m.level == levelCommits:
			m.moveRow(d)
		default:
			m.moveFile(d)
		}
	}
}

// clickPopup handles a click while a popup is open. The guard time of the
// popup applies, as for a key. A click acts as the key that it stands for.
// Each kind of popup gets these clicks:
//   - A result popup: a click on the popup closes it, as a key does.
//   - The ? menu: a click on an item runs it, as ⏎ on the item does.
//   - A confirm popup: a click on the item that confirms runs the action, as
//     ⏎ does. A click on Cancel cancels, as esc does. A click on a method
//     (its name or its text) selects the method, as j and k do. It does not
//     run it.
//
// Other clicks do nothing. View draws m.h lines, so the popup has the place
// that overlay gives it.
func (m *Model) clickPopup(x, y int) tea.Cmd {
	p := m.popup
	if time.Now().Before(m.guardUntil) || m.w < 4 {
		return nil
	}
	pl := p.place(m.w, m.h)
	b := pl.r.body()
	switch {
	case p.kind == resultKind && pl.r.has(x, y):
		return m.popupRun("enter")
	case !b.has(x, y):
		return nil
	}
	k := y - b.Y
	switch i := pl.item[k]; {
	case i >= 0 && p.kind == menuKind:
		p.idx = i
		return m.popupRun("enter")
	case i >= 0:
		p.idx = i
	case p.verb != "" && k == len(pl.body)-1:
		line := ansi.Truncate(ansi.Strip(pl.body[k]), b.W, "")
		for _, s := range itemSpans(line, choiceItems(p.verb)) {
			if x-b.X >= s.x0 && x-b.X < s.x1 {
				return m.popupRun(s.run)
			}
		}
	}
	return nil
}

// titleTab returns the part of the title of the box r at the column x and the
// line y: -1 for the number, or the index of a name. The title is the one
// that tabs makes from num and names. It is false when no part is there.
func titleTab(r rect, x, y int, num string, names []string) (int, bool) {
	if y != r.Y {
		return 0, false
	}
	return tabAt(num, names, x-r.X-titleX, r.W-2*titleX)
}

// tabAt returns the part of a title of tabs at the column x of the title: -1
// for the number, or the index of a name. It reads the text that tabs makes,
// so the columns follow that text. The box shows room columns of the title.
// It is false between the parts, and after the title.
func tabAt(num string, names []string, x, room int) (int, bool) {
	if x < 0 || x >= room {
		return 0, false
	}
	title := ansi.Strip(tabs(num, names, -1, plain))
	from := 0
	for i, part := range append([]string{num}, names...) {
		j := strings.Index(title[from:], part)
		if part == "" || j < 0 {
			continue
		}
		start := ansi.StringWidth(title[:from+j])
		from += j + len(part)
		if x >= start && x < start+ansi.StringWidth(part) {
			return i - 1, true
		}
	}
	return 0, false
}

// barSpan is the place of one item in the bar: the columns from x0 to x1,
// and the key that the item runs.
type barSpan struct {
	x0, x1 int
	run    string
}

// barSpans returns the places of the items that the bar shows in full. It
// reads the left side of the line that bar draws, so the columns follow that
// line. An item that the bar cuts does nothing, because its label does not
// show.
func (m Model) barSpans() []barSpan {
	room := m.barRoom(ansi.StringWidth(m.barRight()))
	return itemSpans(ansi.Truncate(ansi.Strip(m.bar()), room, ""), m.barItems())
}

// itemSpans returns the places of the items in line, a line without styles.
// It finds the label of each item in order, and it stops at the first label
// that the line does not show in full.
func itemSpans(line string, items []barItem) []barSpan {
	var out []barSpan
	from := 0
	for _, it := range items {
		label := it.label()
		j := strings.Index(line[from:], label)
		if j < 0 {
			break
		}
		x := ansi.StringWidth(line[:from+j])
		from += j + len(label)
		out = append(out, barSpan{x, x + ansi.StringWidth(label), it.run})
	}
	return out
}
