package ui

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"bbprs/internal/bb"
	"bbprs/internal/cmdlog"
	"bbprs/internal/refresh"
)

// The loads of the views of the PRs.
//
// A move of the cursor to another PR starts the reads of the disk of the PR
// at once, but no load with twg. It starts a timer. When the timer fires and
// the cursor is still on the same PR, the cursor stopped there, and the loads
// with twg of the PR start. A view in memory shows at once.
//
// A load first reads the copy of the source on the disk (refresh.Cached). A
// fresh copy is done. A stale copy shows at once, and an update with twg
// (refresh.Fetch) starts in the background. While the update runs, the title
// of [0] shows the mark "updating". If the update fails, the copy stays and
// the mark is "not updated". A missing source shows the loading text until
// its load with twg ends.
//
// The PR above and the PR below the cursor get their missing sources too, so
// that the next move shows them at once. They get no updates. At most
// maxFetches loads with twg run at the same time, and a load for the PR under
// the cursor goes before the loads of its neighbours.
//
// Each load has an id (Model.pending). A read and the load with twg that
// follows it have the same id. Only a message with the id of the load that
// runs now changes the source. Thus a load that ends after dropViews, or
// after a newer load started, changes nothing.

const (
	// settleAfter is the time that the cursor stays on a PR before the
	// loads of the PR start.
	settleAfter = 150 * time.Millisecond
	// maxFetches is the largest number of loads with twg that run at the
	// same time.
	maxFetches = 4
	// cursorSlots is the number of slots that the loads of the neighbours
	// leave free for the PR under the cursor.
	cursorSlots = 2
)

// settleMsg comes when the timer of a move of the cursor fires. seq tells
// which timer it is.
type settleMsg struct{ seq int }

// cachedMsg holds the copy of one source of pr from the disk. A copy that
// does not parse is missing. id is the id of the load.
type cachedMsg struct {
	k     viewKey
	pr    bb.PR
	state refresh.State
	data  viewData
	id    int
}

// fetchMsg holds the result of a load of one source with twg. partial is
// true for a details bundle with failed parts. id is the id of the load.
type fetchMsg struct {
	k       viewKey
	data    viewData
	err     error
	partial bool
	id      int
}

// job is one load with twg that waits for a slot. The job of the PR under
// the cursor has first set, and it goes before the jobs of the neighbours.
// id is the id of the load.
type job struct {
	k     viewKey
	pr    bb.PR
	first bool
	id    int
}

// begin gives a new load of the source k its id, and returns the id.
func (m *Model) begin(k viewKey) int {
	m.loadID++
	m.pending[k] = m.loadID
	return m.loadID
}

// loading is true while a load of the source k runs or waits.
func (m Model) loading(k viewKey) bool {
	_, ok := m.pending[k]
	return ok
}

// ours is true when id is the id of the load of the source k that runs now.
func (m Model) ours(k viewKey, id int) bool {
	cur, ok := m.pending[k]
	return ok && cur == id
}

// The places of a PR for its loads.
const (
	placeOther  = iota // not under the cursor, and not next to it
	placeNear          // the row above or below the cursor
	placeCursor        // under the cursor, and the cursor stopped there
)

// ensureView starts the loads of the view under the cursor, when the cursor
// stopped on its PR. Else it starts the timer and the reads of the disk of
// the PR. The loads are for each source that is not in memory and does not
// load now. The neighbours of the PR get their loads after the reads of the
// disk for the PR end, so that the loads with twg of the PR go first. On a
// visit (the first check of a PR and a view), a copy in memory that needs an
// update gets it. On the files level of a commit, ensureView also loads the
// files of the commit.
func (m *Model) ensureView() tea.Cmd {
	m.syncShown()
	if m.focus == focusStatus {
		return nil
	}
	pr, ok := m.current()
	if !ok {
		return nil
	}
	if pr.Key() != m.settled {
		// The PR is not under the cursor for its loads yet (see placeOf),
		// so a read starts no load with twg.
		cmds := []tea.Cmd{m.settle(pr.Key())}
		for _, src := range sources[m.view] {
			cmds = append(cmds, m.ensureSource(pr, src, false))
		}
		return tea.Batch(cmds...)
	}
	visit := memKey(pr) + " " + m.view
	update := visit != m.visited
	m.visited = visit
	var cmds []tea.Cmd
	reads := false
	for _, src := range sources[m.view] {
		cmds = append(cmds, m.ensureSource(pr, src, update))
		if _, r := m.reading[viewKey{memKey(pr), src}]; r {
			reads = true
		}
	}
	if !reads {
		for _, n := range m.neighbours() {
			for _, src := range sources[m.view] {
				cmds = append(cmds, m.ensureSource(n, src, false))
			}
		}
	}
	return tea.Batch(append(cmds, m.ensureCommit())...)
}

// settle starts the timer for the PR with the key key, if its timer does not
// run already.
func (m *Model) settle(key string) tea.Cmd {
	if key == m.waitFor {
		return nil
	}
	m.seq++
	m.waitFor = key
	seq, wait := m.seq, m.d.Settle
	if wait == 0 {
		wait = settleAfter
	}
	return tea.Tick(wait, func(time.Time) tea.Msg { return settleMsg{seq: seq} })
}

// onSettle handles the timer. Only the timer of the last move counts. If the
// cursor is still on the PR of the timer, the cursor stopped there. Then the
// loads that wait for the old PR go away, and the loads of the new PR start.
func (m *Model) onSettle(msg settleMsg) tea.Cmd {
	if msg.seq != m.seq {
		return nil
	}
	if key := m.currentKey(); key == m.waitFor {
		m.settled = key
		m.dropQueue()
	}
	m.waitFor = ""
	return m.ensureView()
}

// ensureSource starts the load of the source src of pr, if the source is not
// in memory and does not load now. The load reads the disk first (see
// onCached). If update is true and the copy in memory needs an update, the
// update starts.
func (m *Model) ensureSource(pr bb.PR, src string, update bool) tea.Cmd {
	k := viewKey{memKey(pr), src}
	if m.loading(k) {
		return nil
	}
	if v, ok := m.views[k]; ok {
		// A failed update tries again after LiveFor. A closed PR does not
		// expire, so else its failed update would not try again.
		retry := v.failed && m.now().Sub(v.at) >= refresh.LiveFor
		if update && v.err == nil && (v.stale || retry || refresh.Expired(pr, src, v.at, m.now())) {
			return m.enqueue(job{k: k, pr: pr, first: true, id: m.begin(k)})
		}
		return nil
	}
	id := m.begin(k)
	m.reading[k] = id
	env := m.d.Env
	return func() tea.Msg {
		raw, state, saved := refresh.Cached(env, pr, src)
		msg := cachedMsg{k: k, pr: pr, state: state, id: id}
		if state != refresh.Missing {
			if msg.data = parseView(src, raw); msg.data.err != nil {
				msg.state, msg.data = refresh.Missing, viewData{}
			}
			msg.data.at = saved
		}
		return msg
	}
}

// onCached puts the copy from the disk in memory. A stale copy of the PR
// under the cursor gets an update. A stale copy of another PR waits for a
// visit. A missing source loads with twg for the PR under the cursor and for
// its neighbours. After a read for the PR under the cursor, the neighbours
// can get their loads (see ensureView).
func (m *Model) onCached(msg cachedMsg) tea.Cmd {
	if m.reading[msg.k] == msg.id {
		delete(m.reading, msg.k)
	}
	if !m.ours(msg.k, msg.id) {
		return nil // an older load, or dropViews removed the views of the PR
	}
	place := m.placeOf(msg.pr)
	var cmd tea.Cmd
	switch {
	case msg.state == refresh.Missing && place == placeOther:
		delete(m.pending, msg.k)
	case msg.state == refresh.Missing:
		cmd = m.enqueue(job{k: msg.k, pr: msg.pr, first: place == placeCursor, id: msg.id})
	default:
		msg.data.stale = msg.state == refresh.Stale
		m.put(msg.k, msg.data)
		if msg.data.stale && place == placeCursor {
			cmd = m.enqueue(job{k: msg.k, pr: msg.pr, first: true, id: msg.id})
		} else {
			delete(m.pending, msg.k)
		}
	}
	if place == placeCursor {
		return tea.Batch(cmd, m.ensureView())
	}
	return cmd
}

// onFetch puts the result of a load with twg in memory. If the load fails,
// a copy in memory stays, and the title of [0] tells that it is not updated.
// A details bundle with failed parts has the good parts of the copy (see
// fetch), and it is not updated too. Then the next job of the queue starts.
func (m *Model) onFetch(msg fetchMsg) tea.Cmd {
	m.fetching--
	if m.ours(msg.k, msg.id) {
		delete(m.pending, msg.k)
		old, had := m.views[msg.k]
		switch {
		case msg.err == nil:
			msg.data.at, msg.data.failed = m.now(), msg.partial
			m.put(msg.k, msg.data)
		case had && old.err == nil:
			old.failed = true
			m.views[msg.k] = old
		default:
			m.views[msg.k] = viewData{err: msg.err}
		}
	}
	return m.pump()
}

// put stores the data v of the source k. A new copy of the commit list of
// the Changes view that shows keeps the cursor on the same commit, as
// keepScope does. If the commit is not in the new list, the view starts again
// at its commit list.
func (m *Model) put(k viewKey, v viewData) {
	old, had := m.views[k]
	m.views[k] = v
	c, ok := m.cursorChanges()
	if !had || k.view != "commits" || !ok || c.key != k.pr {
		return
	}
	i := m.rowIndex(1 + len(old.commits))
	if i == 0 {
		return // All changes
	}
	full := old.commits[i-1].Full
	if j := slices.IndexFunc(v.commits, func(cm bb.Commit) bool { return cm.Full == full }); j >= 0 {
		m.row = j + 1
		return
	}
	m.resetScroll()
}

// enqueue adds j to the queue. A job of the PR under the cursor goes after
// the other jobs of that PR, and before the jobs of the neighbours. Then the
// jobs that have a slot start.
func (m *Model) enqueue(j job) tea.Cmd {
	i := len(m.queue)
	if j.first {
		i = 0
		for i < len(m.queue) && m.queue[i].first {
			i++
		}
	}
	m.queue = slices.Insert(slices.Clip(m.queue), i, j)
	return m.pump()
}

// pump starts the jobs of the queue while fewer than maxFetches loads with
// twg run. A job of a neighbour starts only while fewer than maxFetches −
// cursorSlots loads run, so that the PR under the cursor always has free
// slots. The jobs of the PR under the cursor are first in the queue, so no
// such job waits after a job of a neighbour. pump skips a job of a load that
// does not run now.
func (m *Model) pump() tea.Cmd {
	var cmds []tea.Cmd
	for len(m.queue) > 0 {
		j := m.queue[0]
		if !m.ours(j.k, j.id) {
			m.queue = m.queue[1:]
			continue
		}
		limit := maxFetches
		if !j.first {
			limit -= cursorSlots
		}
		if m.fetching >= limit {
			break
		}
		m.queue = m.queue[1:]
		m.fetching++
		cmds = append(cmds, m.fetch(j))
	}
	return tea.Batch(cmds...)
}

// dropQueue removes the jobs that wait for a slot. A load that runs goes on.
func (m *Model) dropQueue() {
	for _, j := range m.queue {
		if m.ours(j.k, j.id) {
			delete(m.pending, j.k)
		}
	}
	m.queue = nil
}

// fetch returns the command that loads the source of j with twg. The calls
// of the load go under their own head in the command log, and so does a
// failure. If parts of a details bundle fail, the parts of the copy in
// memory take their place (refresh.KeepParts).
func (m *Model) fetch(j job) tea.Cmd {
	env, src := m.d.Env, j.k.view
	old := m.views[j.k].bundle
	var e *cmdlog.Entry
	if r := env.Twg; r != nil && m.d.Log != nil {
		verb := "Load"
		if v, ok := m.views[j.k]; ok && v.err == nil {
			verb = "Update"
		}
		e = m.d.Log.Begin(fmt.Sprintf("%s the %s of #%d", verb, src, j.pr.ID))
		named := *r
		named.Record = e.Add
		env.Twg = &named
	}
	return func() tea.Msg {
		raw, err := refresh.Fetch(context.Background(), env, j.pr, src)
		// The twg runner recorded the failed parts.
		var partial *refresh.PartialError
		isPartial := errors.As(err, &partial)
		if isPartial {
			err = nil
			if old != nil {
				raw = refresh.KeepParts(raw, old, partial.Parts)
			}
		}
		var data viewData
		if err == nil {
			if data = parseView(src, raw); data.err != nil {
				err = data.err
			}
		}
		if err != nil {
			e.Add("✗ " + src + ": " + err.Error())
		}
		return fetchMsg{k: j.k, data: data, err: err, partial: isPartial, id: j.id}
	}
}

// placeOf tells the place of pr for its loads. A PR is under the cursor only
// when the cursor stopped on it.
func (m *Model) placeOf(pr bb.PR) int {
	cur, ok := m.current()
	switch {
	case !ok || cur.Key() != m.settled:
		return placeOther
	case memKey(pr) == memKey(cur):
		return placeCursor
	}
	for _, n := range m.neighbours() {
		if memKey(n) == memKey(pr) {
			return placeNear
		}
	}
	return placeOther
}

// neighbours returns the PRs of the rows above and below the cursor.
func (m *Model) neighbours() []bb.PR {
	cur, ok := m.current()
	if !ok {
		return nil
	}
	i := m.index(m.rowCount())
	var out []bb.PR
	for _, j := range []int{i - 1, i + 1} {
		if pr, ok := m.rowPR(j); ok && pr.Key() != cur.Key() {
			out = append(out, pr)
		}
	}
	return out
}

// rowPR returns the PR of the row i of the current list. On the log list, it
// is the PR of the action.
func (m *Model) rowPR(i int) (bb.PR, bool) {
	if m.list == "log" {
		rows := m.logRows()
		if i < 0 || i >= len(rows) {
			return bb.PR{}, false
		}
		return m.prOfAction(rows[i]), true
	}
	rows := m.prRows()
	if i < 0 || i >= len(rows) {
		return bb.PR{}, false
	}
	return rows[i], true
}

// updateMark returns the mark after the tabs in the title of [0]: a dim
// "updating" while the view shows a copy and its update runs, or a yellow
// "not updated" after the update failed. Else it is "".
func (m Model) updateMark() string {
	if m.focus == focusStatus {
		return ""
	}
	pr, ok := m.current()
	if !ok {
		return ""
	}
	key := memKey(pr)
	if c, ok := m.cursorChanges(); ok {
		key = c.key
	}
	var updating, failed bool
	for _, src := range sources[m.view] {
		k := viewKey{key, src}
		v, ok := m.views[k]
		switch {
		case !ok || v.err != nil:
		case m.loading(k):
			updating = true
		case v.failed:
			failed = true
		}
	}
	switch {
	case updating:
		return dimStyle.Render("updating")
	case failed:
		return fg(yellow).Render("not updated")
	}
	return ""
}
