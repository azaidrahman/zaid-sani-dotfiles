package ui

import (
	"context"
	"fmt"
	"slices"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"bbprs/internal/actions"
	"bbprs/internal/bb"
	"bbprs/internal/gitops"
)

// The titles of the actions. A result popup shows the title.
const (
	approveTitle = "Approve"
	mergeTitle   = "Merge results"
	syncTitle    = "Sync results"
)

var orderNotes = map[bb.Order]string{
	bb.Oldest: "Order: oldest sent first",
	bb.Newest: "Order: newest sent first",
	bb.ByRepo: "Order: by repo, this repo first",
}

// key handles one key. A popup or the filter gets the key first.
func (m *Model) key(k tea.KeyMsg) tea.Cmd {
	switch {
	case k.Paste:
		// Pasted text never runs a key. In the filter, it is text.
		if m.filtering && m.popup == nil {
			m.filterKey(k)
		}
		return nil
	case k.Type == tea.KeyRunes && len(k.Runes) > 1:
		// The terminal can send many characters in one read, for example
		// when a key repeats. Each character is one key.
		var cmds []tea.Cmd
		for _, r := range k.Runes {
			cmds = append(cmds, m.oneKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}, Alt: k.Alt}))
			if m.quitting && m.busy == "" {
				break // the next keys must not start an action
			}
		}
		return tea.Batch(cmds...)
	}
	return m.oneKey(k)
}

// oneKey handles one key.
func (m *Model) oneKey(k tea.KeyMsg) tea.Cmd {
	switch {
	case k.String() == "ctrl+c":
		return tea.Quit
	case m.popup != nil:
		return m.popupKey(k)
	case m.filtering:
		m.filterKey(k)
		return nil
	}
	return m.runKey(k.String())
}

// runKey runs the key with the name key, as tea.Key.String gives it.
func (m *Model) runKey(key string) tea.Cmd {
	switch key {
	case "j", "down":
		m.move(1)
	case "k", "up":
		m.move(-1)
	case "J":
		m.scrollRight(1)
	case "K":
		m.scrollRight(-1)
	case "ctrl+d":
		m.page(1)
	case "ctrl+u":
		m.page(-1)
	case "h", "left":
		m.side(-1)
	case "l", "right":
		m.side(1)
	case "w":
		m.toggleWrap()
	case "tab":
		m.focus = cycle(focusOrder, m.focus, 1)
	case "shift+tab":
		m.focus = cycle(focusOrder, m.focus, -1)
	case "1":
		m.focus = focusStatus
	case "2":
		m.focus = focusPRs
	case "0":
		m.focus = focusMain
	case "[":
		m.cycleList(-1)
	case "]":
		m.cycleList(1)
	case "{":
		m.cycleView(-1)
	case "}":
		m.cycleView(1)
	case " ":
		m.toggle()
	case "enter":
		// [0] on the Changes view uses enter to go one level in, and [0] on
		// the Review view uses it to open the session of the review.
		switch {
		case m.focus == focusMain && m.view == "changes":
			m.goIn()
			return nil
		case m.focus == focusMain && m.view == "review":
			return m.openReview()
		}
		return m.review()
	case "s":
		return m.sync()
	case "a":
		return m.approve()
	case "m":
		m.merge()
	case "o":
		return m.open()
	case "c":
		return m.conflicts()
	case "R":
		m.aiReview()
	case "S":
		m.cycleOrder()
	case "r":
		m.refresh()
	case "/", "?":
		// While an action runs, its popup can open at any time. Then the
		// keys of a filter or of the menu must not reach that popup.
		switch {
		case m.busy != "":
			m.setFlash(m.busy+" runs. Wait for it to end.", yellow)
		case key == "/":
			m.filtering = true
			m.focus = focusPRs
		default:
			m.popup = menuPopup(m.reviewerName())
		}
	case "q":
		return m.quit()
	case "esc":
		return m.escape()
	}
	return nil
}

// cycle returns the item d steps after v in items, and goes round at the end.
func cycle[T comparable](items []T, v T, d int) T {
	i := 0
	for j, x := range items {
		if x == v {
			i = j
		}
	}
	return items[((i+d)%len(items)+len(items))%len(items)]
}

func indexOf[T comparable](items []T, v T) int {
	for i, x := range items {
		if x == v {
			return i
		}
	}
	return 0
}

// move moves the cursor of the list, or scrolls the main panel. On the
// Changes view, [0] moves the row cursor of the commit list or the file
// cursor, or it scrolls the diff in the zoom.
func (m *Model) move(d int) {
	switch m.focus {
	case focusMain:
		if m.view == "changes" {
			switch m.level {
			case levelCommits:
				m.moveRow(d)
			case levelFiles:
				m.moveFile(d)
			default:
				m.scrollRight(d)
			}
			return
		}
		m.scroll = max(0, min(m.scroll+d, m.maxScroll()))
	case focusStatus:
		m.focus = focusPRs
	default:
		m.moveCursor(d)
	}
}

// moveCursor moves the cursor of the list d rows. If the cursor moves, the
// main panel starts at its top left. If the cursor stays, for example on k at
// the first row, the main panel stays too.
func (m *Model) moveCursor(d int) {
	if n := m.rowCount(); n > 0 {
		cur := m.index(n)
		m.cursor[m.list] = max(0, min(cur+d, n-1))
		if m.cursor[m.list] != cur {
			m.resetScroll()
		}
	}
}

// halfPage is the number of lines that ctrl+d and ctrl+u move in a panel
// that shows rows lines. It is half of the rows, and at least 1.
func halfPage(rows int) int { return max(1, rows/2) }

// page moves half a page down, or up if d is less than 0. It moves the cursor
// of the list in [2]. In [0], it scrolls the content, or the right side on
// the Changes view. In [1], it does nothing.
func (m *Model) page(d int) {
	switch m.focus {
	case focusPRs:
		m.move(d * halfPage(m.rowsHeight()))
	case focusMain:
		if c, ok := m.changesData(); ok {
			m.scrollRight(d * halfPage(m.changesPlaces(c).diffH))
			return
		}
		_, rows := m.mainSize()
		m.move(d * halfPage(rows))
	}
}

// sideStep is the number of columns that h and l scroll the main panel.
const sideStep = 8

// needMain is true when [0] has focus. Else it asks the user to focus [0].
func (m *Model) needMain() bool {
	if m.focus == focusMain {
		return true
	}
	m.setFlash("Press 0 to focus the main panel first.", yellow)
	return false
}

// side scrolls the main panel d steps to the right, or to the left if d is
// less than 0. It works only when [0] has focus and wrap is off.
func (m *Model) side(d int) {
	if !m.needMain() || m.wrap {
		return
	}
	// Start from the scroll that the panel shows. After a resize, it can be
	// less than hscroll.
	most := m.maxHScroll()
	m.hscroll = max(0, min(min(m.hscroll, most)+d*sideStep, most))
}

// toggleWrap turns the line wrap of the main panel on or off. It works only
// when [0] has focus.
func (m *Model) toggleWrap() {
	if !m.needMain() {
		return
	}
	m.wrap, m.hscroll = !m.wrap, 0
	m.scroll = min(m.scroll, m.maxScroll())
	if m.wrap {
		m.setFlash("Line wrap on", cyan)
	} else {
		m.setFlash("Line wrap off", cyan)
	}
}

// moveRow moves the row cursor of the commit list d rows. The preview of a
// new row starts at its top left.
func (m *Model) moveRow(d int) {
	c, ok := m.changesData()
	if !ok {
		return
	}
	n := c.rows()
	if next := max(0, min(m.rowIndex(n)+d, n-1)); next != m.rowIndex(n) {
		m.row, m.scroll, m.hscroll = next, 0, 0
	}
}

// moveFile moves the file cursor of the files level d files. A new file
// starts at the top left of its diff.
func (m *Model) moveFile(d int) {
	c, ok := m.changesData()
	if !ok {
		return
	}
	v, ok := m.scopeFiles(c)
	n := len(v.files)
	if !ok || n == 0 {
		return
	}
	if next := max(0, min(m.fileIndex(n)+d, n-1)); next != m.fileIndex(n) {
		m.file, m.scroll, m.hscroll = next, 0, 0
	}
}

// scrollRight scrolls the right side of the Changes view d lines down, or up
// if d is less than 0: the preview of the row, or the diff. It works only
// when [0] has focus.
func (m *Model) scrollRight(d int) {
	if m.focus != focusMain || m.view != "changes" {
		return
	}
	m.scrollBy(d)
}

// scrollBy scrolls the main panel d lines down, or up if d is less than 0.
// On the Changes view, it scrolls the right side.
func (m *Model) scrollBy(d int) {
	// Start from the scroll that the panel shows. After a resize, it can be
	// less than scroll.
	most := m.maxScroll()
	m.scroll = max(0, min(min(m.scroll, most)+d, most))
}

// goIn goes one level in on the Changes view: from a row to its files, and
// from a file to the zoom of its diff. The files of a commit come from the
// checkout. For a PR of another repo, the preview shows a hint, and nothing
// runs. If the load of the files failed, enter loads them again, for example
// after a fetch.
func (m *Model) goIn() {
	c, ok := m.changesData()
	if !ok {
		return
	}
	switch m.level {
	case levelCommits:
		cm, isCommit := m.rowCommit(c)
		if isCommit && !m.hasCheckout(c.pr) {
			m.hintFor = cm.Full
			return
		}
		if v, ok := m.scopeFiles(c); ok && v.err != nil {
			delete(m.views, m.scopeViewKey(c))
		}
		m.level, m.file, m.fileOff = levelFiles, m.fileOf[m.scopeKey(c)], 0
		m.scroll, m.hscroll = 0, 0
	case levelFiles:
		v, ok := m.scopeFiles(c)
		switch {
		case ok && v.err != nil:
			delete(m.views, m.scopeViewKey(c))
		case ok && len(v.files) > 0:
			m.level = levelZoom
			m.scroll = min(m.scroll, m.maxScroll())
		}
	}
}

// goOut goes one level out on the Changes view: from the zoom to the files,
// and from the files to the commit list. fileOf keeps the file cursor of the
// row. It works also when the main panel shows the overview.
func (m *Model) goOut() {
	c, ok := m.cursorChanges()
	switch m.level {
	case levelZoom:
		m.level = levelFiles
		if ok {
			m.scroll = min(m.scroll, m.rightMax(c))
		}
	case levelFiles:
		if ok {
			m.fileOf[m.scopeKey(c)] = m.file
		}
		m.level, m.scroll, m.hscroll = levelCommits, 0, 0
	}
}

// resetScroll puts the main panel back at its top left. The Changes view
// goes back to its commit list, with the cursor on All changes, and it
// forgets the file cursors. A new PR or a new view starts there.
func (m *Model) resetScroll() {
	m.scroll, m.hscroll = 0, 0
	m.level, m.row, m.rowOff, m.file, m.fileOff, m.hintFor = levelCommits, 0, 0, 0, 0, ""
	clear(m.fileOf)
}

// cycleList goes to the previous or the next list.
func (m *Model) cycleList(d int) { m.showList(cycle(listOrder, m.list, d)) }

// showList shows the list. A list of PRs gets an automatic refresh. If the
// list shows already, nothing changes.
func (m *Model) showList(list string) {
	if list == m.list {
		return
	}
	m.list = list
	clear(m.sel)
	m.resetScroll()
	if m.focus == focusStatus {
		m.focus = focusPRs
	}
	if m.list == "log" {
		m.loadActions()
		return
	}
	m.autoRefresh(m.list)
}

func (m *Model) cycleView(d int) { m.showView(cycle(viewOrder, m.view, d)) }

// showView shows the view in the main panel. If the view shows already,
// nothing changes.
func (m *Model) showView(view string) {
	if view == m.view {
		return
	}
	m.view = view
	m.resetScroll()
	if m.focus == focusStatus {
		m.focus = focusPRs
	}
}

func (m *Model) cycleOrder() {
	if m.list != "open" {
		m.setFlash("The order applies to the open list.", yellow)
		return
	}
	// Keep the cursor on the same PR. Approve runs at once, so a cursor on
	// another PR approves the wrong PR.
	keep := m.currentKey()
	m.order = cycle(sortOrder, m.order, 1)
	for i, p := range m.prRows() {
		if p.Key() == keep {
			m.cursor[m.list] = i
		}
	}
	m.setFlash(orderNotes[m.order], cyan)
}

// toggle selects the row under the cursor, or clears its selection.
func (m *Model) toggle() {
	if m.focus != focusPRs {
		return
	}
	if key := m.currentKey(); key != "" {
		if m.sel[key] {
			delete(m.sel, key)
		} else {
			m.sel[key] = true
		}
	}
}

// escape goes one level out on the Changes view, also when [0] does not have
// focus. Else it clears the filter, then the selection, and then quits.
func (m *Model) escape() tea.Cmd {
	switch {
	case m.view == "changes" && m.level > levelCommits:
		m.goOut()
	case m.filter != "":
		m.filter = ""
	case len(m.sel) > 0:
		clear(m.sel)
	default:
		return m.quit()
	}
	return nil
}

// quit quits. While an action runs, the model quits when the action ends, so
// that the action can finish and write its log. ctrl+c quits at once.
func (m *Model) quit() tea.Cmd {
	m.quitting = true
	if m.busy == "" {
		return tea.Quit
	}
	m.setFlash(m.busy+" runs. bb-prs quits when it ends.", yellow)
	return nil
}

func (m *Model) filterKey(k tea.KeyMsg) {
	switch k.Type {
	case tea.KeyEsc:
		m.filter, m.filtering = "", false
	case tea.KeyEnter:
		m.filtering = false
	case tea.KeyBackspace:
		if r := []rune(m.filter); len(r) > 0 {
			m.filter = string(r[:len(r)-1])
		}
	case tea.KeySpace:
		m.filter += " "
	case tea.KeyRunes:
		m.filter += clean(string(k.Runes))
	default:
		return
	}
	m.cursor[m.list] = 0
	m.resetScroll()
}

// refresh starts a refresh of the current list.
func (m *Model) refresh() {
	if m.list == "log" {
		m.setFlash("The log is on this Mac. There is nothing to load.", "")
		return
	}
	m.logRefresh(m.list)
	m.spawn(m.list, false)
}

// openOnly is true on the open list. On another list, it tells the user that
// the action needs the open list.
func (m *Model) openOnly(action string) bool {
	if m.list == "open" {
		return true
	}
	m.setFlash(action+" works on the open list only. Press [ or ] to go to Open.", yellow)
	return false
}

// approve approves the PR under the cursor at once. With more than one
// target, it asks first. The popup runs the approval for the PRs that it
// lists. If each target is your own PR, there is nothing to approve: it does
// not ask, and the bar tells it, as for one own PR.
func (m *Model) approve() tea.Cmd {
	if m.busy != "" || !m.openOnly("Approve") {
		return nil
	}
	prs := m.targets()
	if len(prs) == 0 {
		return nil
	}
	allMine := !slices.ContainsFunc(prs, func(p bb.PR) bool { return p.Role != bb.Mine })
	if len(prs) > 1 && !allMine {
		m.showPopup(approveConfirm(prs))
		return nil
	}
	return m.runApprove(prs)
}

// runApprove approves prs.
func (m *Model) runApprove(prs []bb.PR) tea.Cmd {
	m.startBusy("Approving…")
	d := m.d.Actions
	return func() tea.Msg {
		return actionMsg{title: approveTitle, outcomes: actions.Approve(context.Background(), d, prs)}
	}
}

// merge asks first. The popup runs the merge. The popup has the guard time,
// so that a "y" in the same read as the "m" cannot confirm it.
func (m *Model) merge() {
	if m.busy != "" || !m.openOnly("Merge") {
		return
	}
	if prs := m.targets(); len(prs) > 0 {
		m.showPopup(mergeConfirm(prs))
	}
}

// sync makes the plan first. The plan shows in a popup, and the popup runs
// the sync.
func (m *Model) sync() tea.Cmd {
	if m.busy != "" || !m.openOnly("Sync") {
		return nil
	}
	prs := m.targets()
	if len(prs) == 0 {
		return nil
	}
	d := m.d.Actions
	m.startBusy("Fetching origin…")
	return func() tea.Msg {
		plan, err := actions.PlanSync(context.Background(), d, prs)
		return syncPlanMsg{plan: plan, err: err}
	}
}

// open opens the PR under the cursor in the browser of the Mac where the
// user sits. When [0] has focus on the Changes view, it opens the selected
// commit, or the PR on All changes. A commit without a full hash opens the
// PR, so that the URL never ends in "commits/".
func (m *Model) open() tea.Cmd {
	if m.busy != "" {
		return nil
	}
	pr, ok := m.current()
	if !ok {
		return nil
	}
	url, what := pr.URL, fmt.Sprintf("#%d", pr.ID)
	if c, ok := m.changesData(); ok && m.focus == focusMain {
		if cm, ok := m.rowCommit(c); ok && gitops.IsFullHash(cm.Full) {
			url, what = commitURL(pr.Repo, cm.Full), "commit "+clean(cm.Hash)
		}
	}
	m.startBusy("Opening " + what + "…")
	o := m.d.Opener
	if m.d.Log != nil {
		// The commands of this open go under its own head.
		o.Record = m.d.Log.Begin("Open " + what + " in the browser").Add
	}
	return func() tea.Msg {
		// The commands of the opener have no timeout of their own.
		ctx, cancel := context.WithTimeout(context.Background(), openTimeout)
		defer cancel()
		host, note, err := o.Open(ctx, url)
		return openMsg{what: what, host: host, note: note, err: err}
	}
}

// commitURL returns the page of a commit on Bitbucket. The opener checks the
// URL before it runs a command.
func commitURL(repo, full string) string {
	return "https://bitbucket.org/" + repo + "/commits/" + full
}

// review gives the terminal to tuicr. reviewMsg comes when tuicr exits.
func (m *Model) review() tea.Cmd {
	if m.busy != "" || m.d.Review == nil {
		return nil
	}
	pr, ok := m.current()
	if !ok {
		return nil
	}
	m.d.Log.Begin(fmt.Sprintf("Review #%d", pr.ID)).Add("tuicr pr " + pr.URL)
	return tea.ExecProcess(m.d.Review(pr.URL), func(err error) tea.Msg {
		return reviewMsg{pr: pr, err: err}
	})
}

// onAction shows the outcomes of an action. Then it clears the selection and
// refreshes the open list.
func (m *Model) onAction(msg actionMsg) {
	m.busy = ""
	for _, o := range msg.outcomes {
		m.dropViews(o.PR)
	}
	switch msg.title {
	case approveTitle:
		m.setFlash(approveNote(msg.outcomes))
	case mergeTitle:
		m.removeMerged(msg.outcomes)
		m.showPopup(resultPopup(mergeTitle, msg.outcomes, nil))
	case syncTitle:
		m.showPopup(resultPopup(syncTitle, msg.outcomes, m.skipped))
		m.skipped = nil
	}
	clear(m.sel)
	m.loadActions()
	m.logRefresh("open")
	m.spawn("open", false)
}

// approveNote returns the outcomes of an approval on one line, and its color.
func approveNote(outs []actions.Outcome) (string, lipgloss.Color) {
	texts := make([]string, len(outs))
	color := yellow
	for i, o := range outs {
		texts[i] = o.Text
		switch {
		case !o.OK && strings.Contains(o.Text, "failed"):
			color = red
		case o.OK && color != red:
			color = green
		}
	}
	return strings.Join(texts, " · "), color
}

// removeMerged removes the merged PRs from the open list in memory.
func (m *Model) removeMerged(outs []actions.Outcome) {
	gone := map[string]bool{}
	for _, o := range outs {
		if o.OK {
			gone[o.PR.Key()] = true
		}
	}
	c := m.caches["open"]
	var kept []bb.PR
	for _, p := range c.PRs {
		if !gone[p.Key()] {
			kept = append(kept, p)
		}
	}
	c.PRs = kept
	m.caches["open"] = c
}

func (m *Model) onSyncPlan(msg syncPlanMsg) {
	m.busy = ""
	switch {
	case msg.err != nil:
		m.setFlash(msg.err.Error(), red)
	case len(msg.plan.Todo) == 0:
		m.showPopup(nothingToSync(msg.plan.Skipped))
	default:
		m.showPopup(syncConfirm(msg.plan))
	}
}

func (m *Model) onOpen(msg openMsg) {
	m.busy = ""
	if msg.err != nil {
		m.setFlash(fmt.Sprintf("Could not open %s: %v", msg.what, msg.err), red)
		return
	}
	text := fmt.Sprintf("Opened %s on %s.", msg.what, msg.host)
	if msg.note == "" {
		m.setFlash(text, green)
		return
	}
	m.setFlash(text+" "+strings.ToUpper(msg.note[:1])+msg.note[1:]+".", yellow)
}

func (m *Model) onReview(msg reviewMsg) {
	actions.LogReview(m.d.Actions, msg.pr)
	m.dropViews(msg.pr)
	m.loadActions()
	// The review can change the PR, so refresh the list. An automatic
	// refresh of a fresh list makes no calls.
	if m.list != "log" {
		m.autoRefresh(m.list)
	}
	if msg.err != nil {
		m.setFlash(fmt.Sprintf("tuicr failed for #%d: %v", msg.pr.ID, msg.err), red)
		return
	}
	m.setFlash(fmt.Sprintf("Back from tuicr. #%d loaded again.", msg.pr.ID), green)
}
