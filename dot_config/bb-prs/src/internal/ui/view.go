package ui

import (
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"bbprs/internal/bb"
	"bbprs/internal/gitops"
	"bbprs/internal/review"
	"bbprs/internal/store"
)

// spinFrames are the frames of the spinner of the sketch.
var spinFrames = spinner.MiniDot.Frames

// barItem is one item of the bar: "<name>: <keys>". A click on the item
// runs the key run. An item with two keys runs the forward key.
type barItem struct{ name, keys, run string }

func (b barItem) label() string { return b.name + ": " + b.keys }

// barSep is the text between two items of the bar.
const barSep = " | "

// options are the keys in the bar, for each panel with focus. A narrow bar
// cuts the end, so "Page" comes after "Keybindings". The item of R gets the
// name of the reviewer. On the Review view, the item of enter is "Open".
var options = map[string][]barItem{
	focusPRs: {{"Review", "⏎", "enter"}, {"Sync", "s", "s"}, {"Approve", "a", "a"}, {"Merge", "m", "m"},
		{"Claude", "R", "R"}, {"Browser", "o", "o"}, {"Conflicts", "c", "c"}, {"Select", "space", " "},
		{"Filter", "/", "/"}, {"Lists", "[ ]", "]"}, {"Views", "{ }", "}"}, {"Keybindings", "?", "?"},
		{"Page", "^d/^u", "ctrl+d"}},
	focusMain: {{"Scroll", "j/k", "j"}, {"Sideways", "h/l", "l"}, {"Wrap", "w", "w"}, {"Views", "{ }", "}"},
		{"Review", "⏎", "enter"}, {"Claude", "R", "R"}, {"Browser", "o", "o"}, {"PR list", "2", "2"},
		{"Keybindings", "?", "?"}, {"Page", "^d/^u", "ctrl+d"}},
	focusStatus: {{"Refresh", "r", "r"}, {"PR list", "2", "2"}, {"Keybindings", "?", "?"}, {"Quit", "q", "q"}},
}

// changesOptions are the keys in the bar when [0] has focus on the Changes
// view, for each level.
var changesOptions = [][]barItem{
	levelCommits: {{"Commit", "j/k", "j"}, {"Files", "⏎", "enter"}, {"Open", "o", "o"}, {"Scroll", "J/K", "J"},
		{"Wrap", "w", "w"}, {"Sideways", "h/l", "l"}, {"Views", "{ }", "}"}, {"Keybindings", "?", "?"},
		{"Page", "^d/^u", "ctrl+d"}},
	levelFiles: {{"File", "j/k", "j"}, {"Zoom", "⏎", "enter"}, {"Back", "esc", "esc"}, {"Open", "o", "o"},
		{"Scroll", "J/K", "J"}, {"Wrap", "w", "w"}, {"Sideways", "h/l", "l"}, {"Keybindings", "?", "?"},
		{"Page", "^d/^u", "ctrl+d"}},
	levelZoom: {{"Scroll", "j/k", "j"}, {"Back", "esc", "esc"}, {"Open", "o", "o"}, {"Wrap", "w", "w"},
		{"Sideways", "h/l", "l"}, {"Keybindings", "?", "?"}, {"Page", "^d/^u", "ctrl+d"}},
}

var orderNames = map[bb.Order]string{
	bb.Oldest: "oldest sent first",
	bb.Newest: "newest sent first",
	bb.ByRepo: "by repo",
}

// View draws the screen.
func (m Model) View() string {
	if m.w <= 0 || m.h <= 0 {
		return ""
	}
	p := layout(m.w, m.h)
	status, prs := m.statusBox(p.Status), m.prsBox(p.PRs)
	main, cmds := m.mainBox(p.Main), m.cmdlogBox(p.Cmdlog)
	var lines []string
	if p.Wide {
		left, right := split(status, prs), split(main, cmds)
		for i := range p.Bar.Y {
			l, r := strings.Repeat(" ", p.Status.W), ""
			if i < len(left) {
				l = left[i]
			}
			if i < len(right) {
				r = right[i]
			}
			lines = append(lines, l+r)
		}
	} else {
		lines = split(status, prs, main, cmds)
	}
	if p.Bar.H > 0 {
		lines = append(lines, m.bar())
	}
	if m.popup != nil {
		lines = m.overlay(lines)
	}
	return strings.Join(lines, "\n")
}

// split returns the lines of the boxes, from the top. A box of 0 lines is "".
func split(boxes ...string) []string {
	var out []string
	for _, b := range boxes {
		if b != "" {
			out = append(out, strings.Split(b, "\n")...)
		}
	}
	return out
}

func (m Model) spinner() string { return fg(cyan).Render(spinFrames[m.spin%len(spinFrames)]) }

// shownList is the list that Status and the spinner tell about. The log list
// has no refresh, so it is the open list.
func (m Model) shownList() string {
	if m.list == "log" {
		return "open"
	}
	return m.list
}

// ago returns "just now" or the age of t, for example "5m ago".
func (m Model) ago(t time.Time) string { return agoText(time.Since(t)) }

func (m Model) statusBox(r rect) string {
	state := plain
	if m.focus == focusStatus {
		state = focused
	}
	env := m.d.Env
	first := fg(green).Render("✓") + " " + boldStyle.Render(clean(shortRepo(env.Repo))) + " " +
		dimStyle.Render("→") + " " + fg(cyan).Render(clean(env.WS)) + " " + dimStyle.Render("· origin on bitbucket.org")
	if env.Repo == "" {
		first = dimStyle.Render("· not in a Bitbucket repo →") + " " + fg(cyan).Render(clean(env.WS))
	}
	list := m.shownList()
	c := m.caches[list]
	var second string
	switch {
	case m.locked[list]:
		second = m.spinner() + " " + fg(cyan).Render("loading the "+list+" list")
	case c.Saved.IsZero():
		second = dimStyle.Render("No " + list + " list yet. Press r to load it.")
	case len(c.Errors) > 0:
		second = fg(red).Render("! the last refresh failed") + " " + dimStyle.Render("· list loaded "+m.ago(c.Saved))
	default:
		second = fg(green).Render("✓") + " " + dimStyle.Render("list loaded "+m.ago(c.Saved))
	}
	return box(tabs("[1]", statusNames, 0, state), "", []string{first, second}, r.W, r.H, state)
}

// errorLines returns the red lines of the errors of the current list.
func (m Model) errorLines(width int) []string {
	if m.list == "log" {
		return nil
	}
	var lines []string
	for _, e := range m.caches[m.list].Errors {
		lines = append(lines, wrap(fg(red).Render("! "), clean(e), fg(red), width)...)
	}
	return lines
}

// rowsHeight is the number of rows that the PR panel shows under the header
// and the errors.
func (m *Model) rowsHeight() int { return m.listPlace(layout(m.w, m.h).PRs).rows }

// listPlace tells what the body of the PR panel shows: the header row, the
// error lines, and then rows rows of the list, from the row off. The list
// has n rows, and idx is the row of the cursor.
type listPlace struct {
	errs              []string
	n, idx, off, rows int
}

// listPlace returns what the PR panel in r shows.
func (m *Model) listPlace(r rect) listPlace {
	errs := m.errorLines(r.body().W)
	n := m.rowCount()
	idx := m.index(n)
	rows := max(0, r.body().H-1-len(errs))
	return listPlace{errs: errs, n: n, idx: idx, off: window(m.offset[m.list], max(idx, 0), rows, n), rows: rows}
}

func (m Model) prsBox(r rect) string {
	if r.H <= 0 {
		return ""
	}
	state := plain
	switch {
	case m.filtering:
		state = searching
	case m.focus == focusPRs:
		state = focused
	}
	title := tabs("[2]", listNames, indexOf(listOrder, m.list), state)
	if m.locked[m.shownList()] {
		title += " " + m.spinner()
	}

	width := r.body().W
	pl := m.listPlace(r)
	errs, n, idx, rows, off := pl.errs, pl.n, pl.idx, pl.rows, pl.off
	cur := m.d.Env.Repo
	now := m.now()
	var prs []bb.PR
	var acts []store.Action
	if m.list == "log" {
		acts = m.logRows()
	} else {
		prs = m.prRows()
	}
	var repos []string
	if m.list == "log" {
		for _, a := range acts {
			repos = append(repos, a.Repo)
		}
	} else {
		for _, p := range prs {
			repos = append(repos, p.Repo)
		}
	}
	repoW := repoWidth(cur, repos)
	body := append([]string{listHeader(m.list, repoW, width)}, errs...)
	for i := off; i < min(n, off+rows); i++ {
		var line string
		if m.list == "log" {
			a := acts[i]
			line = FormatActionRow(a, cur, m.sel[fmt.Sprintf("%s#%d", a.Repo, a.ID)], repoW, width)
		} else {
			p := prs[i]
			b, _ := m.behindOf(p)
			var rv *review.State
			if st, ok := m.reviewOf(p); ok {
				rv = &st
			}
			line = FormatRow(p, cur, b, rv, m.sel[p.Key()], now, repoW, width)
		}
		if i == idx {
			line = cursorLine(line, m.focus == focusPRs)
		}
		body = append(body, line)
	}
	if n == 0 {
		switch {
		case m.filter != "":
			body = append(body, dimStyle.Render("No PRs match “"+clean(m.filter)+"”. esc clears the filter."))
		case len(errs) == 0:
			body = append(body, dimStyle.Render("This list is empty."))
		}
	}

	order := "your actions"
	switch m.list {
	case "open":
		order = orderNames[m.order]
	case "closed":
		order = "newest closed first"
	}
	foot := fmt.Sprintf("%s · %d of %d", order, idx+1, n)
	return box(title, foot, body, r.W, r.H, state)
}

func (m Model) mainBox(r rect) string {
	if r.H <= 0 {
		return ""
	}
	state := plain
	if m.focus == focusMain {
		state = focused
	}
	names, on := m.mainTabs()
	title := tabs("[0]", names, on, state)
	if mark := m.updateMark(); mark != "" {
		title += dimStyle.Render(" · ") + mark
	}
	if c, ok := m.changesData(); ok {
		return box(title, "", m.changesBody(c), r.W, r.H, state)
	}
	width, rows := m.mainSize()
	rl := m.mainLines(width)
	lines := rl.lines
	top := max(0, min(m.scroll, len(lines)-rows))
	body := lines[top:min(len(lines), top+rows)]
	if !m.wrap && m.focus != focusStatus {
		// The panel or the lines can change after a side scroll. Then the
		// scroll must not go past the widest line.
		hs := min(m.hscroll, rl.maxSide(width))
		cutLines := make([]string, len(body))
		for i, l := range body {
			cutLines[i] = sideCut(l, hs, width)
		}
		body = cutLines
	}
	return box(title, "", body, r.W, r.H, state)
}

// mainTabs returns the names of the tabs in the title of the main panel, and
// the index of the current one. When [1] has focus, the panel shows the
// overview, and it has one tab.
func (m Model) mainTabs() ([]string, int) {
	if m.focus == focusStatus {
		return []string{"Overview"}, 0
	}
	return viewNames, indexOf(viewOrder, m.view)
}

// changesBody returns the lines of the Changes view at its level. The commits
// level shows the commit list and the preview of the selected row. The files
// level shows the line of the scope, then the file list and the diff of the
// file under the file cursor. The zoom shows only the diff. Each line has the
// width of the panel.
func (m Model) changesBody(c changes) []string {
	p := m.changesPlaces(c)
	right := m.rightPart(m.rightLines(c, p.diffW), p.diffW, p.diffH)
	switch m.level {
	case levelCommits:
		return joinPlaces(m.commitList(c, p.listW, p.listH), right, p)
	case levelFiles:
		width, _ := m.mainSize()
		v, _ := m.scopeFiles(c)
		return append([]string{fit(m.scopeLine(c), width)}, joinPlaces(m.fileList(v.files, p.listW, p.listH), right, p)...)
	}
	return right
}

// joinPlaces puts the lines of the list and of the right side in the places
// p. The list has p.listH lines of p.listW columns, and the right side has
// p.diffH lines of p.diffW columns.
func joinPlaces(list, right []string, p diffPlaces) []string {
	if p.listH == 0 {
		return right
	}
	if p.wide {
		sep := " " + fg(gray).Render("│") + " "
		for i := range list {
			list[i] += sep + right[i]
		}
		return list
	}
	if p.diffH > 0 {
		list = append(list, fg(gray).Render(strings.Repeat("─", p.listW)))
	}
	return append(list, right...)
}

// scopeLine returns the first line of the files level. It names the selected
// row, and esc goes back to the commit list.
func (m Model) scopeLine(c changes) string {
	name := "All changes"
	if cm, ok := m.rowCommit(c); ok {
		name = clean(cm.Hash)
	}
	return fg(cyan).Render("←") + " " + boldStyle.Render(name) + " " + dimStyle.Render("(esc)")
}

// commitList returns height lines of width columns: All changes, and one row
// for each commit, from rowOff. The row of the cursor has the cursor
// background. While the commit list loads, or if its load failed, a line
// under All changes tells it.
func (m Model) commitList(c changes, width, height int) []string {
	n := c.rows()
	idx := m.rowIndex(n)
	aw := 0
	for _, cm := range c.list.commits {
		aw = max(aw, ansi.StringWidth(abbr(cm.Who)))
	}
	aw = min(aw, labelWidth)
	var out []string
	off := m.rowWindow(c, height)
	for i := off; i < min(n, off+height); i++ {
		row := allRow(c.diff, c.diffOK, width)
		if i > 0 {
			row = commitRow(c.list.commits[i-1], aw, width)
		}
		if i == idx {
			row = cursorLine(row, m.focus == focusMain)
		}
		out = append(out, row)
	}
	switch {
	case !c.listOK:
		out = append(out, fit(dimStyle.Render("Loading the commits…"), width))
	case c.list.err != nil:
		text := clean(fmt.Sprintf("Could not load the commits of #%d: %v", c.pr.ID, c.list.err))
		out = append(out, fit(fg(red).Render(text), width))
	}
	for len(out) < height {
		out = append(out, fit("", width))
	}
	return out[:height]
}

// rowWindow returns the first row that the commit list of c shows in height
// lines.
func (m Model) rowWindow(c changes, height int) int {
	return window(m.rowOff, m.rowIndex(c.rows()), height, c.rows())
}

// fileWindow returns the first file that the file list shows in rows rows
// under its header, for n files.
func (m Model) fileWindow(n, rows int) int {
	return window(m.fileOff, max(m.fileIndex(n), 0), rows, n)
}

// rightLines returns the lines of the right side of the Changes view, for a
// part of width columns. The commits level shows the preview of the selected
// row. The other levels show the diff of the file under the file cursor, or
// a message. A message always wraps at width. With wrap off, a line of a
// diff can be wider than width.
func (m Model) rightLines(c changes, width int) rendered {
	if m.level == levelCommits {
		return m.preview(c, width)
	}
	if note, st := m.scopeNote(c); note != "" {
		return newRendered(wrap("", note, st, width))
	}
	v, _ := m.scopeFiles(c)
	idx := m.fileIndex(len(v.files))
	key := renderKey{width: wrapAt(width, m.wrap), wrap: m.wrap, file: idx}
	if r, ok := v.lines[key]; ok {
		return r
	}
	r := newRendered(renderDiff(v.files[idx], wrapAt(width, m.wrap)))
	v.keep(key, r)
	return r
}

// scopeNote returns a message and its style for the files of the selected
// row. The right side shows the message when it has no diff to show. The
// message is a hint about the checkout or the fetch, a load that runs or
// failed, or no files. It is "" when the files loaded.
func (m Model) scopeNote(c changes) (string, lipgloss.Style) {
	cm, isCommit := m.rowCommit(c)
	v, ok := m.scopeFiles(c)
	switch {
	case isCommit && !m.hasCheckout(c.pr):
		return checkoutHint(c.pr), fg(yellow)
	case !ok:
		return "Loading…", dimStyle
	case isCommit && errors.Is(v.err, gitops.ErrNoCommit):
		return fetchHint(cm), fg(yellow)
	case isCommit && v.err != nil:
		return clean(fmt.Sprintf("Could not load commit %s: %v", cm.Hash, v.err)), fg(red)
	case v.err != nil:
		return clean(fmt.Sprintf("Could not load the diff of #%d: %v", c.pr.ID, v.err)), fg(red)
	case len(v.files) == 0 && isCommit:
		return "This commit changes no files.", dimStyle
	case len(v.files) == 0:
		return "This PR changes no files.", dimStyle
	}
	return "", plainStyle
}

// previewKeys is the last line of the preview of a row.
const previewKeys = "⏎ files · o open in browser"

// preview returns the lines of the preview of the selected row of the commit
// list, for a part of width columns. The lines are the head of the row, the
// stats of its files when they are known, and the keys. The line cache of the
// commit list keeps the head of each row.
func (m Model) preview(c changes, width int) rendered {
	row := m.rowIndex(c.rows())
	key := renderKey{width: wrapAt(width, m.wrap), wrap: m.wrap, row: row}
	head, ok := c.list.lines[key]
	if !ok {
		var cm *bb.Commit
		if row > 0 {
			cm = &c.list.commits[row-1]
		}
		head = newRendered(previewHead(c.pr, cm, wrapAt(width, m.wrap)))
		c.list.keep(key, head)
	}
	tail := []string{""}
	if stats := m.statsLines(c, width); len(stats) > 0 {
		tail = append(append(tail, stats...), "")
	}
	t := newRendered(append(tail, dimStyle.Render(previewKeys)))
	// Clip, so that the append does not write into the lines in the cache.
	return rendered{lines: append(slices.Clip(head.lines), t.lines...), widest: max(head.widest, t.widest)}
}

// statsLines returns the lines about the files of the selected row: the
// stats, or a message. The files of a commit load on enter, so before that
// a commit has no lines, unless enter showed a hint.
func (m Model) statsLines(c changes, width int) []string {
	if cm, ok := m.rowCommit(c); ok {
		if _, loaded := m.views[commitKey(cm.Full)]; !loaded && m.hintFor != cm.Full {
			return nil
		}
	}
	if note, st := m.scopeNote(c); note != "" {
		return wrap("", note, st, width)
	}
	v, _ := m.scopeFiles(c)
	return []string{fileStats(v.files)}
}

// fileList returns height lines of width columns: the header row, and the
// rows of the files from fileOff. The row of the file cursor has the cursor
// background.
func (m Model) fileList(files []bb.FileDiff, width, height int) []string {
	cw := countWidth(files)
	out := []string{fileHeader(cw, width)}
	n := len(files)
	idx := m.fileIndex(n)
	rows := max(0, height-1)
	off := m.fileWindow(n, rows)
	for i := off; i < min(n, off+rows); i++ {
		row := fileRow(files[i], cw, width)
		if i == idx {
			row = cursorLine(row, m.focus == focusMain)
		}
		out = append(out, row)
	}
	for len(out) < height {
		out = append(out, fit("", width))
	}
	return out[:height]
}

// rightPart returns height lines of width columns of the right side rl, from
// the scroll. With wrap off, the side scroll applies too. Each scroll stops
// at the end of the lines, also after a resize.
func (m Model) rightPart(rl rendered, width, height int) []string {
	lines := rl.lines
	top := max(0, min(m.scroll, len(lines)-height))
	hs := 0
	if !m.wrap {
		hs = min(m.hscroll, rl.maxSide(width))
	}
	out := make([]string, height)
	for i := range out {
		l := ""
		if j := top + i; j < len(lines) {
			l = sideCut(lines[j], hs, width)
		}
		out[i] = fit(l, width)
	}
	return out
}

// maxScroll is the largest scroll of the main panel. On the Changes view, it
// is the largest scroll of the right side.
func (m *Model) maxScroll() int {
	if c, ok := m.changesData(); ok {
		return m.rightMax(c)
	}
	width, height := m.mainSize()
	return max(0, len(m.mainLines(width).lines)-height)
}

// rightMax is the largest scroll of the right side of the Changes view c, at
// its level.
func (m Model) rightMax(c changes) int {
	p := m.changesPlaces(c)
	return max(0, len(m.rightLines(c, p.diffW).lines)-p.diffH)
}

// maxHScroll is the largest side scroll of the main panel. On the Changes
// view, it is the largest side scroll of the right side.
func (m *Model) maxHScroll() int {
	if c, ok := m.changesData(); ok {
		p := m.changesPlaces(c)
		return m.rightLines(c, p.diffW).maxSide(p.diffW)
	}
	width, _ := m.mainSize()
	return m.mainLines(width).maxSide(width)
}

// mainLines returns the lines of the main panel for a panel of width
// columns: the overview, or the Status, Activity, or Review view of the PR
// under the cursor. With wrap off, a line of a view can be wider than width.
func (m Model) mainLines(width int) rendered {
	if m.focus == focusStatus {
		return newRendered(renderOverview(m.overview(), width))
	}
	pr, ok := m.current()
	if !ok {
		return newRendered([]string{dimStyle.Render("Nothing to show.")})
	}
	if m.view == "review" {
		// The status has the age of the review, so the lines change with the
		// time, and the cache does not keep them.
		var rv *review.State
		if st, ok := m.reviewOf(pr); ok {
			rv = &st
		}
		lines := renderReview(pr, rv, m.reviewerName(), time.Now(), width, m.wrap)
		if m.wrap {
			lines = wrapLines(lines, width)
		}
		return newRendered(lines)
	}
	src := sources[m.view][0]
	v, ok := m.views[viewKey{memKey(pr), src}]
	switch {
	case !ok:
		return newRendered([]string{dimStyle.Render("Loading…")})
	case v.err != nil:
		return newRendered(wrap("", clean(fmt.Sprintf("Could not load the %s of #%d: %v", src, pr.ID, v.err)), fg(red), wrapAt(width, m.wrap)))
	}
	n, known := m.behindOf(pr)
	key := renderKey{width: width, wrap: m.wrap, behind: behind{n, known}}
	if r, ok := v.lines[key]; ok {
		return r
	}
	var lines []string
	switch m.view {
	case "activity":
		lines = renderActivity(v.events, wrapAt(width, m.wrap))
	default:
		open := pr.IsOpen()
		if v.details.State != "" {
			open = strings.EqualFold(v.details.State, "OPEN")
		}
		lines = renderStatus(v.details, n, known, open, width, m.wrap)
	}
	if m.wrap {
		lines = wrapLines(lines, width)
	}
	r := newRendered(lines)
	v.keep(key, r)
	return r
}

func (m Model) overview() overview {
	open := m.caches["open"].PRs
	o := overview{
		Repo: m.d.Env.Repo, Workspace: m.d.Env.WS, Dir: m.cwd,
		Open: len(open), Closed: len(m.caches["closed"].PRs), Logged: len(m.actions),
	}
	for _, p := range open {
		switch p.Role {
		case bb.Review:
			o.Review++
		case bb.Mine:
			o.Mine++
		}
		if n, ok := m.behindOf(p); ok && n > 0 {
			o.Behind++
		}
	}
	return o
}

// cmdlogBox shows the newest lines of the command log at the bottom.
func (m Model) cmdlogBox(r rect) string {
	if r.H <= 0 {
		return ""
	}
	n := r.body().H
	var lines []string
	if m.d.Log != nil {
		for _, l := range m.d.Log.Lines(n) {
			if l.Head {
				lines = append(lines, clean(l.Text))
			} else {
				lines = append(lines, fg(cyan).Render("  "+clean(l.Text)))
			}
		}
	}
	if pad := n - len(lines); pad > 0 {
		lines = append(make([]string, pad), lines...)
	}
	return box("Command log", "", lines, r.W, r.H, plain)
}

// bar returns the bottom line: the keys, the filter, the action that runs,
// or a short result. The right side shows the selection, the filter, or the
// name of the program.
func (m Model) bar() string {
	var left, right string
	switch items := m.barItems(); {
	case items != nil:
		keys := make([]string, 0, len(items))
		for _, it := range items {
			keys = append(keys, fg(blue).Render(it.label()))
		}
		left = strings.Join(keys, dimStyle.Render(barSep))
	case m.filtering:
		left = fg(cyan).Render("Filter:") + " " + clean(m.filter) + fg(cyan).Render("▌")
		right = dimStyle.Render("⏎ keep · esc clear")
	case m.busy != "" && (m.flash.text == "" || m.flash.at.Before(m.busyAt)):
		left = m.spinner() + " " + fg(cyan).Render(m.busy)
	default:
		// A flash that comes while an action runs keeps the spinner.
		st := plainStyle
		if m.flash.color != "" {
			st = fg(m.flash.color)
		}
		left = st.Render(clean(m.flash.text))
		if m.busy != "" {
			left = m.spinner() + " " + left
		}
	}
	if right == "" {
		right = m.barRight()
	}
	room := m.barRoom(ansi.StringWidth(right))
	out := fit(" "+left, room)
	if room < m.w {
		out += " " + right + " "
	}
	return out
}

// barItems returns the items that the bar shows. It is nil when the bar
// shows the filter, an action that runs, or a short result.
func (m Model) barItems() []barItem {
	switch {
	case m.filtering || m.busy != "" || m.flash.text != "":
		return nil
	case m.focus == focusMain && m.view == "changes":
		return changesOptions[m.level]
	}
	items := slices.Clone(options[m.focus])
	for i, it := range items {
		switch {
		case it.run == "R":
			items[i].name = m.reviewerTitle()
		case it.run == "enter" && m.focus == focusMain && m.view == "review":
			items[i].name = "Open"
		}
	}
	return items
}

// barRight returns the right side of the bar while no filter is typed: the
// number of selected PRs, the filter, or the name of the program.
func (m Model) barRight() string {
	switch {
	case len(m.sel) > 0:
		return fg(green).Render(fmt.Sprintf("%d selected", len(m.sel)))
	case m.filter != "":
		return fg(cyan).Render("filter: " + clean(m.filter))
	}
	return dimStyle.Render("bb-prs")
}

// barRoom returns the columns of the left side of the bar, for a right side
// of rw columns. The right side has a space at each side. On a narrow
// screen, the bar has no right side.
func (m Model) barRoom(rw int) int {
	if m.w < rw+4 {
		return m.w
	}
	return m.w - rw - 2
}
