package ui

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"bbprs/internal/actions"
	"bbprs/internal/bb"
	"bbprs/internal/browser"
	"bbprs/internal/cmdlog"
	"bbprs/internal/gitops"
	"bbprs/internal/refresh"
	"bbprs/internal/store"
	"bbprs/internal/termtab"
)

// Deps holds what the model gets from main.
type Deps struct {
	Env     refresh.Env
	Actions actions.Deps
	Opener  browser.Opener
	Log     *cmdlog.Log
	// Spawn starts a detached refresh of the list "open" or "closed".
	Spawn func(list string, auto bool) error
	// Review returns the command that reviews the PR at url.
	Review func(url string) *exec.Cmd
	// PRConflicts runs "git <args>" with g, which records the command. The
	// caller gives "pr-conflicts" as the first argument. It returns the output
	// of the script. Its exit status 1 is normal, so the caller looks at the
	// worktree, not at the error.
	PRConflicts func(ctx context.Context, g gitops.Git, args ...string) (string, error)
	// Tab opens the terminal tab for the worktree of a conflict check.
	Tab termtab.Opener
	// NoTick stops the timer of the model. The tests use it.
	NoTick bool
	// PopupGuard is the time that a popup ignores keys after it opens. Each
	// confirm popup has it, and each popup that a message opens, for
	// example a result. Then a key that the user typed before the popup
	// showed cannot confirm or close it. Zero means 400ms.
	PopupGuard time.Duration
}

const (
	tickEvery   = 150 * time.Millisecond
	flashFor    = 4 * time.Second
	freshAge    = 3 * time.Minute // the same age as the automatic refresh
	maxActions  = 300
	openTimeout = 30 * time.Second
	popupGuard  = 400 * time.Millisecond
)

// The panels that can have focus.
const (
	focusStatus = "status"
	focusPRs    = "prs"
	focusMain   = "main"
)

var (
	focusOrder = []string{focusStatus, focusPRs, focusMain}
	// statusNames are the names of the tabs in the title of [1].
	statusNames = []string{"Status"}
	listOrder   = []string{"open", "closed", "log"}
	// listNames are the names of the lists in the title of the PR panel.
	listNames = []string{"Open", "Closed", "Log"}
	viewOrder = []string{"status", "changes", "activity"}
	// viewNames are the names of the views in the title of the main panel.
	viewNames = []string{"Status", "Changes", "Activity"}
	sortOrder = []bb.Order{bb.Oldest, bb.Newest, bb.ByRepo}
)

// sources names the data that each view of the main panel shows. Each name
// is a view of the refresh package. The Changes view shows the commit list
// and the diff of all the files of the PR.
var sources = map[string][]string{
	"status":   {"details"},
	"changes":  {"commits", "diff"},
	"activity": {"activity"},
}

// The levels of the Changes view. enter goes one level in, and esc goes one
// level out.
const (
	levelCommits = iota // the commit list, and the preview of the selected row
	levelFiles          // the files of the selected row, and the diff of one file
	levelZoom           // the diff of one file fills the main panel
)

// showTimeout is the time for the git command that loads the files of one
// commit.
const showTimeout = 30 * time.Second

// tickMsg comes every 150ms, unless NoTick is true.
type tickMsg time.Time

// viewMsg holds the JSON of one view of a PR. The key is memKey of the PR.
type viewMsg struct {
	key, view string
	raw       []byte
	err       error
}

// actionMsg holds the outcomes of an approve, a merge, or a sync. The title
// tells which action it was.
type actionMsg struct {
	title    string
	outcomes []actions.Outcome
}

type syncPlanMsg struct {
	plan actions.SyncPlan
	err  error
}

// openMsg is the result of "o". The text what names the page, for example
// "#11" or "commit a1b2c3d4".
type openMsg struct {
	what, host, note string
	err              error
}

// reviewMsg comes when tuicr exits.
type reviewMsg struct {
	pr  bb.PR
	err error
}

// behindMsg holds the behind counts of one load of the open list. The mtime
// is the modification time of the list file of that load.
type behindMsg struct {
	mtime  time.Time
	counts map[string]behind
}

// behind is the number of commits that a source branch is behind its
// destination. If ok is false, git did not find one of the branches.
type behind struct {
	n  int
	ok bool
}

// viewKey names one view of one PR in memory. The view is a name in sources.
type viewKey struct{ pr, view string }

// commitKey names the files of a commit in the view memory. A commit does not
// change, so its files stay in memory for the session.
func commitKey(full string) viewKey { return viewKey{pr: "commit " + full, view: "show"} }

// viewData is one view of a PR in memory. Only the field of the view is set.
type viewData struct {
	details bb.Details
	files   []bb.FileDiff
	events  []bb.Event
	commits []bb.Commit
	err     error
	// lines keeps the rendered lines of the view, so that a frame does not
	// render them again. A new load of the view gets a new map.
	lines map[renderKey]rendered
}

// renderKey tells which lines of a view are in viewData.lines. The Status
// view shows the behind count, so the count is part of the key. A diff keeps
// the lines of one file, so the index of the file is part of the key. The
// commit list keeps the lines of the preview of one row, so the row is part
// of the key.
type renderKey struct {
	width  int
	wrap   bool
	behind behind
	file   int
	row    int
}

// maxRendered is the number of keys that viewData.lines keeps. When the map
// is full, keep empties it.
const maxRendered = 8

// keep saves the rendered lines of the view under key. A view that failed to
// load has no map and keeps nothing.
func (v viewData) keep(key renderKey, r rendered) {
	if v.lines == nil {
		return
	}
	if len(v.lines) >= maxRendered {
		clear(v.lines)
	}
	v.lines[key] = r
}

// rendered holds the rendered lines of the main panel, and the width of the
// widest line. The side scroll needs that width for each frame, so the cache
// keeps it with the lines.
type rendered struct {
	lines  []string
	widest int
}

// newRendered measures the widest of lines.
func newRendered(lines []string) rendered {
	r := rendered{lines: lines}
	for _, l := range lines {
		r.widest = max(r.widest, ansi.StringWidth(l))
	}
	return r
}

// maxSide is the largest side scroll of the lines in a panel of width
// columns: the width of the widest line, less the width of the panel.
func (r rendered) maxSide(width int) int { return max(0, r.widest-width) }

// note is a short text in the bar. It goes away after a few seconds.
type note struct {
	text  string
	color lipgloss.Color // empty for the color of the terminal
	at    time.Time
}

// Model is the state of the PR picker. It implements tea.Model.
type Model struct {
	d Deps

	focus, list, view string
	order             bb.Order
	cursor, offset    map[string]int // for each list
	sel               map[string]bool
	filter            string
	filtering         bool
	popup             *popup
	flash             note
	busy              string
	busyAt            time.Time
	scroll            int
	// wrap is true when the main panel wraps long lines. With wrap off,
	// hscroll is the first column that the main panel shows.
	wrap    bool
	hscroll int
	// level is the level of the Changes view. row is the cursor of its
	// commit list: row 0 is All changes, and row i is commit i-1. rowOff is
	// the first row that the list shows. file is the file cursor of the
	// files level, and fileOff is the first file that the file list shows.
	// fileOf keeps the file cursor of each row that the user left, by
	// scopeKey. On the Changes view, scroll and hscroll scroll the right
	// side: the preview of the row, or the diff.
	level         int
	row, rowOff   int
	file, fileOff int
	fileOf        map[string]int
	// hintFor is the full hash of the commit for which enter showed the hint
	// that its files need the checkout.
	hintFor string
	// shownID is the key of the PR under the cursor at the last check of
	// syncShown. shown is the memKey of the data that the Changes view
	// shows. After a reload with a new update of the same PR, shown keeps
	// the old memKey until the new data loads.
	shownID, shown string
	w, h           int
	spin           int
	// quitting is true after the user quits. If an action runs, the model
	// quits when the action ends.
	quitting bool
	// guardUntil is the end of the guard time of the popup.
	guardUntil time.Time

	caches  map[string]store.ListCache // "open" and "closed"
	mtimes  map[string]time.Time
	locked  map[string]bool
	actions []store.Action
	behind  map[string]behind // by the key of the PR
	views   map[viewKey]viewData
	pending map[viewKey]bool
	// skipped holds the PRs that the running sync leaves, for its result.
	skipped []actions.Outcome
	cwd     string
	start   tea.Cmd
}

// New loads the cached lists and the log of actions. It also starts the
// automatic refresh of the open list.
func New(d Deps) Model {
	m := Model{
		d: d, focus: focusPRs, list: "open", view: "status", order: bb.Oldest,
		cursor: map[string]int{}, offset: map[string]int{}, sel: map[string]bool{}, fileOf: map[string]int{},
		caches: map[string]store.ListCache{}, mtimes: map[string]time.Time{}, locked: map[string]bool{},
		behind: map[string]behind{}, views: map[viewKey]viewData{}, pending: map[viewKey]bool{},
	}
	m.cwd = d.Env.Dir
	if m.cwd == "" {
		m.cwd, _ = os.Getwd()
	}
	var cmds []tea.Cmd
	for _, list := range []string{"open", "closed"} {
		cmds = append(cmds, m.loadList(list))
		m.locked[list] = store.Locked(m.listFile(list))
	}
	m.loadActions()
	m.autoRefresh("open")
	m.syncShown()
	m.start = tea.Batch(append(cmds, m.ensureView())...)
	return m
}

// Init starts the first loads and the timer.
func (m Model) Init() tea.Cmd { return tea.Batch(m.start, m.tick()) }

func (m Model) tick() tea.Cmd {
	if m.d.NoTick {
		return nil
	}
	return tea.Tick(tickEvery, func(t time.Time) tea.Msg { return tickMsg(t) })
}

// Update handles one message.
func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	cmd := m.update(msg)
	m.syncShown()
	m.follow()
	if m.quitting && m.busy == "" {
		return m, tea.Quit
	}
	return m, cmd
}

func (m *Model) update(msg tea.Msg) tea.Cmd {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.w, m.h = msg.Width, msg.Height
	case tea.KeyMsg:
		cmd := m.key(msg)
		return tea.Batch(cmd, m.ensureView())
	case tea.MouseMsg:
		cmd := m.mouse(msg)
		return tea.Batch(cmd, m.ensureView())
	case tickMsg:
		return m.onTick(time.Time(msg))
	case viewMsg:
		k := viewKey{msg.key, msg.view}
		delete(m.pending, k)
		if msg.err != nil {
			m.views[k] = viewData{err: msg.err}
		} else {
			m.views[k] = parseView(msg.view, msg.raw)
		}
	case behindMsg:
		if msg.mtime.Equal(m.mtimes["open"]) {
			m.behind = msg.counts
		}
	case actionMsg:
		m.onAction(msg)
		return m.ensureView()
	case syncPlanMsg:
		m.onSyncPlan(msg)
	case openMsg:
		m.onOpen(msg)
	case conflictMsg:
		m.onConflict(msg)
	case reviewMsg:
		m.onReview(msg)
		// The release of the terminal turns off the mouse, and the restore does
		// not turn it on again.
		return tea.Batch(m.ensureView(), tea.EnableMouseCellMotion)
	}
	return nil
}

func (m *Model) onTick(now time.Time) tea.Cmd {
	m.spin = (m.spin + 1) % len(spinFrames)
	if m.flash.text != "" && !m.quitting && now.Sub(m.flash.at) > flashFor {
		m.flash = note{}
	}
	var cmds []tea.Cmd
	for _, list := range []string{"open", "closed"} {
		path := m.listFile(list)
		m.locked[list] = store.Locked(path)
		if !modTime(path).Equal(m.mtimes[list]) {
			cmds = append(cmds, m.loadList(list))
		}
	}
	return tea.Batch(append(cmds, m.ensureView(), m.tick())...)
}

func (m *Model) listFile(list string) string {
	return m.d.Env.Paths.ListFile(m.d.Env.Prompt, list)
}

func modTime(path string) time.Time {
	info, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}
	return info.ModTime()
}

// loadList reads the file of a list again. The cursor stays on the same PR.
// For the open list, it returns a command that counts the commits behind.
func (m *Model) loadList(list string) tea.Cmd {
	path := m.listFile(list)
	keep := ""
	if list == m.list {
		keep = m.currentKey()
	}
	c, err := store.LoadList(path)
	if err != nil {
		c = m.caches[list]
		c.Errors = []string{"could not read the list file: " + err.Error()}
	}
	m.caches[list] = c
	m.mtimes[list] = modTime(path)
	if keep != "" {
		for i, p := range m.prRows() {
			if p.Key() == keep {
				m.cursor[list] = i
			}
		}
	}
	// A view that failed can load again after a refresh.
	for k, v := range m.views {
		if v.err != nil {
			delete(m.views, k)
		}
	}
	if list != "open" || m.d.Env.Dir == "" {
		return nil
	}
	return countBehind(m.d.Env.Dir, m.d.Env.Repo, c.PRs, m.mtimes[list])
}

// countBehind counts the commits behind for each PR of repo, with git in dir.
func countBehind(dir, repo string, prs []bb.PR, mtime time.Time) tea.Cmd {
	return func() tea.Msg {
		g := gitops.Git{Dir: dir}
		counts := map[string]behind{}
		for _, p := range prs {
			if p.Repo == repo {
				n, ok := g.Behind(p.Src, p.Dst)
				counts[p.Key()] = behind{n, ok}
			}
		}
		return behindMsg{mtime: mtime, counts: counts}
	}
}

func (m *Model) loadActions() {
	if acts, err := m.d.Env.Paths.ReadActions(maxActions); err == nil {
		m.actions = acts
	}
}

// autoRefresh starts the automatic refresh of a list. The child skips a list
// that is fresh, and the command log tells it.
func (m *Model) autoRefresh(list string) {
	if store.Fresh(m.listFile(list), freshAge) {
		m.d.Log.Begin(strings.ToUpper(list[:1]) + list[1:] + " list is fresh (less than 3 minutes). No calls.")
	} else {
		m.logRefresh(list)
	}
	m.spawn(list, true)
}

// logRefresh writes the calls of a refresh of list to the command log. The
// refresh of the open list also fetches in a checkout.
func (m *Model) logRefresh(list string) {
	env := m.d.Env
	e := m.d.Log.Begin(fmt.Sprintf("Refresh the %s list (bb-prs --refresh %s, detached)", list, list))
	for _, c := range refresh.Calls(list, env.Repo, env.WS) {
		e.Add("twg " + strings.Join(c.Args, " ") + " -o json")
	}
	if list == "open" && env.Dir != "" {
		e.Add("git fetch -q origin")
	}
}

func (m *Model) spawn(list string, auto bool) {
	if m.d.Spawn == nil {
		return
	}
	if err := m.d.Spawn(list, auto); err != nil {
		m.setFlash("Could not start the refresh: "+err.Error(), red)
	}
}

func (m *Model) setFlash(text string, color lipgloss.Color) {
	m.flash = note{text: text, color: color, at: time.Now()}
}

func (m *Model) startBusy(label string) {
	m.busy, m.busyAt = label, time.Now()
}

// showPopup opens a popup with the guard time: a confirm popup, or a popup
// that a message brings. It closes the filter and the menu. For a short
// time, the popup ignores keys.
func (m *Model) showPopup(p *popup) {
	guard := m.d.PopupGuard
	if guard == 0 {
		guard = popupGuard
	}
	m.filtering = false
	m.popup = p
	m.guardUntil = time.Now().Add(guard)
}

// prRows returns the PRs of the current list, in the order and with the
// filter.
func (m *Model) prRows() []bb.PR {
	return bb.Filter(m.sortedRows(), m.filter)
}

// sortedRows returns the PRs of the current list in the order, without the
// filter.
func (m *Model) sortedRows() []bb.PR {
	prs := append([]bb.PR(nil), m.caches[m.list].PRs...)
	bb.Sort(prs, m.list, m.order, m.d.Env.Repo)
	return prs
}

// logRows returns the actions of the log list, with the filter.
func (m *Model) logRows() []store.Action {
	q := strings.ToLower(strings.TrimSpace(m.filter))
	if q == "" {
		return m.actions
	}
	var out []store.Action
	for _, a := range m.actions {
		if strings.Contains(strings.ToLower(fmt.Sprintf("%s\n%s\n#%d", a.Title, a.Repo, a.ID)), q) {
			out = append(out, a)
		}
	}
	return out
}

func (m *Model) rowCount() int {
	if m.list == "log" {
		return len(m.logRows())
	}
	return len(m.prRows())
}

// index returns the cursor of the current list inside n rows, or -1 if there
// are no rows.
func (m *Model) index(n int) int {
	if n == 0 {
		return -1
	}
	return max(0, min(m.cursor[m.list], n-1))
}

// current returns the PR under the cursor. On the log list, it is the PR of
// the action.
func (m *Model) current() (bb.PR, bool) {
	if m.list == "log" {
		rows := m.logRows()
		i := m.index(len(rows))
		if i < 0 {
			return bb.PR{}, false
		}
		return m.prOfAction(rows[i]), true
	}
	rows := m.prRows()
	i := m.index(len(rows))
	if i < 0 {
		return bb.PR{}, false
	}
	return rows[i], true
}

func (m *Model) currentKey() string {
	if pr, ok := m.current(); ok {
		return pr.Key()
	}
	return ""
}

// prOfAction finds the PR of an action in the lists. If it is not there, it
// makes a PR from the fields of the action.
func (m *Model) prOfAction(a store.Action) bb.PR {
	for _, list := range []string{"open", "closed"} {
		for _, p := range m.caches[list].PRs {
			if p.Repo == a.Repo && p.ID == a.ID {
				return p
			}
		}
	}
	return bb.PR{Repo: a.Repo, ID: a.ID, URL: a.URL, Src: a.Src, Dst: a.Dst, Title: a.Title}
}

// targets returns the selected PRs of the current list in the order of the
// list, or else the PR under the cursor. A selected PR that the filter hides
// is also a target, because the bar counts it.
func (m *Model) targets() []bb.PR {
	if len(m.sel) == 0 {
		rows := m.prRows()
		if i := m.index(len(rows)); i >= 0 {
			return []bb.PR{rows[i]}
		}
		return nil
	}
	var out []bb.PR
	for _, p := range m.sortedRows() {
		if m.sel[p.Key()] {
			out = append(out, p)
		}
	}
	return out
}

// behindOf returns the behind count of a PR of the current repo.
func (m *Model) behindOf(pr bb.PR) (int, bool) {
	if pr.Repo != m.d.Env.Repo {
		return 0, false
	}
	b, ok := m.behind[pr.Key()]
	return b.n, ok && b.ok
}

// memKey names a PR in the view memory. A changed PR gets a new key.
func memKey(pr bb.PR) string { return pr.Key() + "@" + pr.UpdatedRaw }

// syncShown puts the main panel back at its start when another PR comes
// under the cursor, also without a key. For example, a reload removed the PR.
// Then the Changes view starts again at its commit list, and no load uses
// the level of the old PR. For a new update of the same PR, keepScope keeps
// the level and the row.
func (m *Model) syncShown() {
	id, key := "", ""
	if pr, ok := m.current(); ok {
		id, key = pr.Key(), memKey(pr)
	}
	switch {
	case id != m.shownID:
		m.shownID, m.shown = id, key
		m.resetScroll()
	case key != m.shown:
		m.keepScope(key)
	}
}

// keepScope moves the Changes view to the data of a new update of the same
// PR, with the memKey key. Until the commit list and the diff of the update
// load, the view shows the old data. Then the cursor goes to the same row in
// the new list: All changes, or the same commit. If the commit is not in the
// new list, or the new list failed, the view starts again at its commit list.
func (m *Model) keepScope(key string) {
	if m.view != "changes" {
		m.shown = key
		return
	}
	list, listOK := m.views[viewKey{key, "commits"}]
	if _, diffOK := m.views[viewKey{key, "diff"}]; !listOK || !diffOK {
		return // the update loads
	}
	old, _ := m.cursorChanges()
	cm, isCommit := m.rowCommit(old)
	m.shown = key
	switch {
	case list.err != nil || (!old.listOK && m.row > 0):
		m.resetScroll()
	case !isCommit:
		m.row = 0
	default:
		i := slices.IndexFunc(list.commits, func(c bb.Commit) bool { return c.Full == cm.Full })
		if i < 0 {
			m.resetScroll()
			return
		}
		m.row = i + 1
	}
}

// ensureView starts the loads of the data of the view under the cursor: each
// source that is not in memory and does not load now. On the files level of
// a commit, it also loads the files of the commit.
func (m *Model) ensureView() tea.Cmd {
	m.syncShown()
	if m.focus == focusStatus {
		return nil
	}
	pr, ok := m.current()
	if !ok {
		return nil
	}
	var cmds []tea.Cmd
	for _, src := range sources[m.view] {
		cmds = append(cmds, m.ensureSource(pr, src))
	}
	return tea.Batch(append(cmds, m.ensureCommit())...)
}

// ensureSource starts the load of the source src of pr with twg, if the
// source is not in memory and does not load now.
func (m *Model) ensureSource(pr bb.PR, src string) tea.Cmd {
	k := viewKey{memKey(pr), src}
	if _, ok := m.views[k]; ok || m.pending[k] {
		return nil
	}
	m.pending[k] = true
	env := m.d.Env
	if r := env.Twg; r != nil && m.d.Log != nil {
		// The head line goes to the command log before the first twg call.
		// A view from the cache makes no call and adds no head line. The
		// calls of this load go under its own head.
		log, head := m.d.Log, fmt.Sprintf("Load the %s of #%d", src, pr.ID)
		var once sync.Once
		var e *cmdlog.Entry
		named := *r
		named.Record = func(line string) {
			once.Do(func() { e = log.Begin(head) })
			e.Add(line)
		}
		env.Twg = &named
	}
	return func() tea.Msg {
		raw, err := refresh.LoadView(context.Background(), env, pr, src)
		return viewMsg{key: k.pr, view: src, raw: raw, err: err}
	}
}

// ensureCommit starts the load of the files of the selected commit with the
// local git, on the files level of the Changes view. It runs only for a PR
// of the repo of the checkout, and only if the files are not in memory and
// do not load now.
func (m *Model) ensureCommit() tea.Cmd {
	c, ok := m.changesData()
	if !ok || m.level == levelCommits {
		return nil
	}
	cm, ok := m.rowCommit(c)
	if !ok || !m.hasCheckout(c.pr) {
		return nil
	}
	k := commitKey(cm.Full)
	if _, ok := m.views[k]; ok || m.pending[k] {
		return nil
	}
	m.pending[k] = true
	g := gitops.Git{Dir: m.d.Env.Dir, Record: m.d.Log.Begin("Load commit " + clean(cm.Hash)).Add}
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), showTimeout)
		defer cancel()
		raw, err := g.Show(ctx, cm.Full)
		return viewMsg{key: k.pr, view: k.view, raw: raw, err: err}
	}
}

// hasCheckout is true when the files of the commits of pr can come from the
// checkout: pr is a PR of the repo of the checkout.
func (m Model) hasCheckout(pr bb.PR) bool {
	return m.d.Env.Dir != "" && pr.Repo == m.d.Env.Repo
}

// dropViews removes each view of pr from memory.
func (m *Model) dropViews(pr bb.PR) {
	prefix := pr.Key() + "@"
	for k := range m.views {
		if strings.HasPrefix(k.pr, prefix) {
			delete(m.views, k)
		}
	}
	for k := range m.pending {
		if strings.HasPrefix(k.pr, prefix) {
			delete(m.pending, k)
		}
	}
}

// parseView reads the raw data of the source src. The source "show" is the
// patch of a commit.
func parseView(src string, raw []byte) viewData {
	v := viewData{lines: map[renderKey]rendered{}}
	switch src {
	case "details":
		var b struct {
			PR       json.RawMessage `json:"pr"`
			Checks   json.RawMessage `json:"checks"`
			Diffstat json.RawMessage `json:"diffstat"`
		}
		if v.err = json.Unmarshal(raw, &b); v.err == nil {
			v.details, v.err = bb.ParseDetails(b.PR, b.Checks, b.Diffstat)
		}
	case "diff", "show":
		v.files = bb.ParseDiff(raw)
	case "activity":
		v.events, v.err = bb.ParseActivity(raw)
	default:
		v.commits, v.err = bb.ParseCommits(raw)
	}
	return v
}

// follow keeps the cursor row of the list in the panel. On the Changes view,
// it also keeps the row cursor in the commit list, or the file cursor in the
// file list. The zoom does not show the file list, so its first row stays.
func (m *Model) follow() {
	m.offset[m.list] = m.listPlace(layout(m.w, m.h).PRs).off
	c, ok := m.changesData()
	if !ok {
		return
	}
	switch p := m.changesPlaces(c); m.level {
	case levelCommits:
		m.rowOff = m.rowWindow(c, p.listH)
	case levelFiles:
		v, _ := m.scopeFiles(c)
		n := len(v.files)
		m.fileOff = m.fileWindow(n, p.listRows())
	}
}

// changes holds the data of the Changes view of one PR: the commit list and
// the diff of all the files. The key is the memKey of the data. An ok field
// is false while its data loads. A load can have failed.
type changes struct {
	pr             bb.PR
	key            string
	list, diff     viewData
	listOK, diffOK bool
}

// rows is the number of rows of the commit list: All changes, then the
// commits.
func (c changes) rows() int { return 1 + len(c.list.commits) }

// changesData returns the data of the Changes view of the PR under the
// cursor, if the main panel shows the Changes view.
func (m Model) changesData() (changes, bool) {
	if m.focus == focusStatus {
		return changes{}, false
	}
	return m.cursorChanges()
}

// cursorChanges returns the data of the Changes view of the PR under the
// cursor, if the view is Changes. The main panel can show the overview.
func (m Model) cursorChanges() (changes, bool) {
	if m.view != "changes" {
		return changes{}, false
	}
	pr, ok := m.current()
	if !ok {
		return changes{}, false
	}
	key := memKey(pr)
	if pr.Key() == m.shownID {
		// After a reload with a new update of the PR, the view shows the old
		// data until the new data loads. Then no wrong row shows.
		key = m.shown
	}
	c := changes{pr: pr, key: key}
	c.list, c.listOK = m.views[viewKey{key, "commits"}]
	c.diff, c.diffOK = m.views[viewKey{key, "diff"}]
	return c, true
}

// rowIndex returns the row cursor of the commit list inside n rows.
func (m Model) rowIndex(n int) int { return max(0, min(m.row, n-1)) }

// rowCommit returns the commit of the selected row. It is false on All
// changes.
func (m Model) rowCommit(c changes) (bb.Commit, bool) {
	i := m.rowIndex(c.rows())
	if i == 0 {
		return bb.Commit{}, false
	}
	return c.list.commits[i-1], true
}

// scopeKey names the selected row in fileOf: the full hash of the commit, or
// "" for All changes.
func (m Model) scopeKey(c changes) string {
	cm, _ := m.rowCommit(c)
	return cm.Full
}

// scopeViewKey names the files of the selected row in the view memory: the
// files of the commit, or the diff of the PR for All changes.
func (m Model) scopeViewKey(c changes) viewKey {
	if cm, ok := m.rowCommit(c); ok {
		return commitKey(cm.Full)
	}
	return viewKey{c.key, "diff"}
}

// scopeFiles returns the files of the selected row. It is false while the
// files load.
func (m Model) scopeFiles(c changes) (viewData, bool) {
	v, ok := m.views[m.scopeViewKey(c)]
	return v, ok
}

// fileIndex returns the file cursor inside n files, or -1 if there are no
// files.
func (m Model) fileIndex(n int) int {
	if n == 0 {
		return -1
	}
	return max(0, min(m.file, n-1))
}

// mainSize returns the width and the height of the text of the main panel.
func (m Model) mainSize() (width, height int) {
	b := layout(m.w, m.h).Main.body()
	return b.W, b.H
}

// changesPlaces returns the places of the list and of the right side of the
// Changes view at its level. On the files level, the line of the scope is
// the first line, and the places are under it. The zoom gives the full panel
// to the diff.
func (m Model) changesPlaces(c changes) diffPlaces {
	width, height := m.mainSize()
	switch m.level {
	case levelCommits:
		return splitDiffs(width, height, c.rows(), false)
	case levelFiles:
		v, _ := m.scopeFiles(c)
		return splitDiffs(width, max(0, height-1), len(v.files)+1, false)
	}
	return splitDiffs(width, height, 0, true)
}

// window returns the first row to show, so that the row idx is in a panel of
// rows lines.
func window(off, idx, rows, n int) int {
	if rows <= 0 {
		return 0
	}
	if idx < off {
		off = idx
	}
	if idx >= off+rows {
		off = idx - rows + 1
	}
	return max(0, min(off, n-rows))
}
