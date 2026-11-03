package ui

import (
	"context"
	"fmt"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"bbprs/internal/bb"
	"bbprs/internal/cmdlog"
	"bbprs/internal/review"
)

// The background review: the key R, the state files of the reviews, and the
// Review view of the main panel. The detached child "bb-prs --ai-review"
// does the review and writes the state file. The screen only reads it.

const (
	// openLine is the line of the Review view that opens the session of the
	// review. A click on it does the same as enter.
	openLine = "⏎ open the review session"
	// rawLines is the number of lines of the raw output that the Review
	// view shows after a failure.
	rawLines = 20
	// severityWidth is the width of the severity column of a finding:
	// "medium" and one space.
	severityWidth = 7
	// startWait is the time that a new start counts as a review that runs,
	// while its child has not written the state file yet.
	startWait = 10 * time.Second
)

// reviewEntry is the state file of the review of one PR at its last read. ok
// is false if the file is not valid.
type reviewEntry struct {
	mtime time.Time
	st    review.State
	ok    bool
}

// newStart is a start of a review whose child has not written the state file
// yet.
type newStart struct {
	pr bb.PR
	at time.Time
}

// agoText returns "just now" for an age d of less than a minute, else the
// age and "ago", for example "5m ago".
func agoText(d time.Duration) string {
	if d < time.Minute {
		return "just now"
	}
	return bb.Age(d) + " ago"
}

// loadReviewer loads the config of the reviewer. A good config replaces the
// config of the model.
func (m *Model) loadReviewer() (review.Config, error) {
	cfg, err := review.Default(), error(nil)
	if m.d.ReviewConfig != nil {
		cfg, err = m.d.ReviewConfig()
	}
	if err == nil {
		m.reviewer = cfg
	}
	return cfg, err
}

// reviewerName returns the name of the reviewer, for example "claude".
func (m Model) reviewerName() string {
	if name := clean(m.reviewer.Name); name != "" {
		return name
	}
	return review.Default().Name
}

// reviewerTitle returns the name of the reviewer with a capital letter, for
// the bar: "Claude".
func (m Model) reviewerTitle() string {
	name := m.reviewerName()
	r, n := utf8.DecodeRuneInString(name)
	return string(unicode.ToUpper(r)) + name[n:]
}

// syncReviews reads the state file of each PR of the lists again, and of the
// PR under the cursor. It reads a file only when its mtime changed. now is the
// time of the read.
func (m *Model) syncReviews(now time.Time) {
	m.reviewsAt = now
	for _, list := range []string{"open", "closed"} {
		for _, p := range m.caches[list].PRs {
			m.syncReview(p)
		}
	}
	if pr, ok := m.current(); ok {
		m.syncReview(pr)
	}
}

// syncReview reads the state file of the review of pr again, if its mtime
// changed.
func (m *Model) syncReview(pr bb.PR) {
	k, path := pr.Key(), m.d.Env.Paths.ReviewFile(pr.Repo, pr.ID)
	mt := modTime(path)
	if e, ok := m.reviews[k]; ok && e.mtime.Equal(mt) {
		return
	}
	if mt.IsZero() {
		delete(m.reviews, k)
		return
	}
	st, err := review.ReadState(path)
	m.reviews[k] = reviewEntry{mtime: mt, st: st, ok: err == nil}
	// A file that the child wrote after the start replaces the new start.
	if s, ok := m.newStarts[k]; ok && !mt.Before(s.at) {
		delete(m.newStarts, k)
	}
}

// newStartOf returns the time of the start of the review of pr, if the start
// was less than startWait ago and its child has not written the state file
// yet.
func (m *Model) newStartOf(pr bb.PR, now time.Time) (time.Time, bool) {
	s, ok := m.newStarts[pr.Key()]
	if ok && now.Sub(s.at) >= startWait {
		delete(m.newStarts, pr.Key())
		return time.Time{}, false
	}
	return s.at, ok
}

// runningCount returns the number of reviews that run: the new starts, and
// the running state files. It reads the files of the new starts first, so
// that a review does not count two times.
func (m *Model) runningCount(now time.Time) int {
	n := 0
	for _, s := range m.newStarts {
		m.syncReview(s.pr)
		if _, ok := m.newStartOf(s.pr, now); ok {
			n++
		}
	}
	return n + review.Running(m.d.Env.Paths.ReviewDir(), now)
}

// stateOf returns the state of the review of pr as the screen shows it. A new
// start shows as a review that runs.
func (m *Model) stateOf(pr bb.PR, now time.Time) (review.State, bool) {
	st, ok := m.reviewOf(pr)
	if at, starting := m.newStartOf(pr, now); starting {
		st, ok = review.State{Status: review.StatusRunning, Started: at}, true
	}
	return shownState(st, now), ok
}

// skipNote tells why the review of pr does not start, or it is "". n is the
// number of PRs that start before pr, and room is the number of reviews that
// can start.
func (m *Model) skipNote(pr bb.PR, n, room int, now time.Time) string {
	st, ok := m.stateOf(pr, now)
	switch {
	case ok && st.Status == review.StatusRunning:
		return "review runs, skipped"
	case ok && st.Status == review.StatusDone:
		return "review exists, skipped"
	case n >= room:
		return fmt.Sprintf("over the limit of %d, skipped", review.MaxRunning)
	}
	return ""
}

// reviewOf returns the state of the review of pr from the last read. It is
// false if pr has no review.
func (m Model) reviewOf(pr bb.PR) (review.State, bool) {
	e, ok := m.reviews[pr.Key()]
	return e.st, ok && e.ok
}

// shownState returns the state of a review as the screen shows it. A running
// state that is older than review.LockStale belongs to a dead child, so it
// shows as failed.
func shownState(st review.State, now time.Time) review.State {
	if st.Status == review.StatusRunning && !st.Live(now) {
		st.Status = review.StatusFailed
		if st.Error == "" {
			st.Error = "The review stopped before it wrote an outcome."
		}
	}
	return st
}

// staleReview is true when pr changed after the start of the review st.
func staleReview(pr bb.PR, st review.State) bool {
	return st.Status != review.StatusRunning && st.Updated != "" && pr.UpdatedRaw != "" && st.Updated != pr.UpdatedRaw
}

// verdictStyle gives the color of a verdict.
func verdictStyle(verdict string) lipgloss.Style {
	switch verdict {
	case "approve":
		return fg(green)
	case "comment":
		return fg(yellow)
	case "request-changes":
		return fg(red)
	}
	return dimStyle
}

// severityStyle gives the color of the severity of a finding.
func severityStyle(severity string) lipgloss.Style {
	switch severity {
	case "high":
		return fg(red)
	case "medium":
		return fg(yellow)
	}
	return dimStyle
}

// capText tells that the cap of reviews that run at the same time is full.
var capText = fmt.Sprintf("%d reviews run already. Wait for one to end.", review.MaxRunning)

// aiReview handles R. It reviews the targets in the background. For one PR,
// a review that runs gets a note, and a finished review gets a popup: open
// its session, or run it again. For more than one PR, a popup asks first. It
// reviews only the PRs with no review, or with a failed one.
func (m *Model) aiReview() {
	if m.busy != "" {
		return
	}
	cfg, err := m.loadReviewer()
	if err != nil {
		m.setFlash(fmt.Sprintf("The reviewer config is not valid: %v.", err), red)
		return
	}
	if !m.openOnly(m.reviewerTitle() + " review") {
		return
	}
	prs := m.targets()
	if len(prs) == 0 {
		return
	}
	if err := cfg.Available(); err != nil {
		m.setFlash(err.Error(), red)
		return
	}
	now := time.Now()
	for _, p := range prs {
		m.syncReview(p)
	}
	room := review.MaxRunning - m.runningCount(now)
	if len(prs) > 1 {
		m.showPopup(m.reviewConfirm(prs, room, now))
		return
	}
	pr := prs[0]
	st, ok := m.stateOf(pr, now)
	switch {
	case ok && st.Status == review.StatusRunning:
		m.setFlash(fmt.Sprintf("A review of #%d runs already (started %s).", pr.ID, agoText(now.Sub(st.Started))), yellow)
	case ok && st.Status == review.StatusDone:
		m.showPopup(reviewChoice(pr, st))
	case room <= 0:
		m.setFlash(capText, yellow)
	default:
		m.startReviews(prs, false)
	}
}

// reviewChoice asks what to do with the finished review st of pr: open its
// session (the default), or run the review again.
func reviewChoice(pr bb.PR, st review.State) *popup {
	p := &popup{
		kind: confirmKind, title: fmt.Sprintf("Review of #%d", pr.ID), foot: "j/k choose · ⏎ choose · esc cancel",
		lines: append(prLine(pr, ""), ""),
		methods: []methodItem{
			{name: "Open the review session"},
			{name: "Run the review again (the old result is replaced)"},
		},
		verb: "Choose",
	}
	p.yes = func(m *Model) tea.Cmd {
		if p.idx == 0 {
			return m.openSession(pr, st)
		}
		if m.runningCount(time.Now()) >= review.MaxRunning {
			m.setFlash(capText, yellow)
			return nil
		}
		m.startReviews([]bb.PR{pr}, true)
		return nil
	}
	return p
}

// reviewConfirm asks before the review of more than one PR. It lists each
// PR. A PR with a review that runs or that finished gets a note, and so does
// each PR over the cap. The popup reviews only the other PRs. If no PR is
// left, the popup only tells it. When the user confirms, the popup reads the
// states and counts the cap again, because another bb-prs can start or end a
// review while the popup is open.
func (m *Model) reviewConfirm(prs []bb.PR, room int, now time.Time) *popup {
	var todo []bb.PR
	var lines []string
	for _, p := range prs {
		note := m.skipNote(p, len(todo), room, now)
		if note == "" {
			todo = append(todo, p)
		} else {
			note = "(" + note + ")"
		}
		lines = append(lines, prLine(p, note)...)
	}
	title := m.reviewerTitle() + " review"
	if len(todo) == 0 {
		lines = append(append([]string{"Nothing to review.", ""}, lines...), "", dimStyle.Render("Any key closes this."))
		return &popup{kind: resultKind, title: title, lines: lines}
	}
	lines = append([]string{fmt.Sprintf("Review these PRs with %s?", m.reviewerName()), ""}, lines...)
	return &popup{kind: confirmKind, title: title, lines: lines, verb: "Review", yes: func(m *Model) tea.Cmd {
		m.startChecked(todo)
		return nil
	}}
}

// startChecked reads the state of each PR again, and counts the cap again.
// Then it starts the review of each PR that has no review that runs or that
// finished, as far as the cap lets it. The bar tells which PRs it skipped.
func (m *Model) startChecked(prs []bb.PR) {
	now := time.Now()
	room := review.MaxRunning - m.runningCount(now)
	var run []bb.PR
	var skipped []string
	for _, p := range prs {
		m.syncReview(p)
		if note := m.skipNote(p, len(run), room, now); note != "" {
			skipped = append(skipped, fmt.Sprintf("#%d: %s.", p.ID, note))
			continue
		}
		run = append(run, p)
	}
	switch {
	case len(run) == 0:
		m.setFlash("Nothing to review. "+strings.Join(skipped, " "), yellow)
	case m.startReviews(run, false) && len(skipped) > 0:
		m.setFlash(m.flash.text+" "+strings.Join(skipped, " "), yellow)
	}
}

// startReviews starts the detached child that reviews each PR. With again,
// the child replaces a done review. Until the child writes the state file,
// the start counts as a review that runs. It returns false if a start failed,
// or if the model cannot start a child.
func (m *Model) startReviews(prs []bb.PR, again bool) bool {
	if m.d.StartReview == nil {
		return false
	}
	title := m.reviewerTitle()
	flag := ""
	if again {
		flag = " --again"
	}
	for _, p := range prs {
		if m.d.Log != nil {
			m.d.Log.Begin(fmt.Sprintf("%s review of #%d (bb-prs --ai-review %s %d%s, detached)", title, p.ID, p.Repo, p.ID, flag))
		}
		// The time comes before the start, so that the state file of the
		// child is never older than it.
		m.newStarts[p.Key()] = newStart{pr: p, at: time.Now()}
		if err := m.d.StartReview(p.Repo, p.ID, again); err != nil {
			delete(m.newStarts, p.Key())
			m.setFlash(fmt.Sprintf("Could not start the review of #%d: %v", p.ID, err), red)
			return false
		}
	}
	if len(prs) == 1 {
		m.setFlash(fmt.Sprintf("%s reviews #%d in the background.", title, prs[0].ID), green)
	} else {
		m.setFlash(fmt.Sprintf("%s reviews %d PRs in the background.", title, len(prs)), green)
	}
	return true
}

// openReview opens the session of the review of the PR under the cursor:
// enter on the Review view, or a click on its open line.
func (m *Model) openReview() tea.Cmd {
	pr, ok := m.current()
	if !ok {
		return nil
	}
	m.syncReview(pr)
	st, ok := m.stateOf(pr, time.Now())
	switch {
	case !ok:
		m.setFlash(fmt.Sprintf("No review yet. Press R to review with %s.", m.reviewerName()), yellow)
		return nil
	case st.Status == review.StatusRunning:
		m.setFlash(fmt.Sprintf("The review of #%d runs. Its session opens when it ends.", pr.ID), yellow)
		return nil
	}
	return m.openSession(pr, st)
}

// sessionTimeout is the time for each command that selects or opens the tab
// of a session. The select and the open each get this time.
const sessionTimeout = 10 * time.Second

// sessionMsg comes when the tab of a review session is open, or the open
// failed. key is the key of the PR. text is the text for the bar, and color
// is its color.
type sessionMsg struct {
	key   string
	text  string
	color lipgloss.Color
}

// onSession shows the outcome of the open of a session. A new open of the
// session of the PR can start now.
func (m *Model) onSession(msg sessionMsg) {
	delete(m.opening, msg.key)
	m.setFlash(msg.text, msg.color)
}

// reviewWindow returns the name of the tmux window of the review of pr. It
// has only the characters that a tmux target accepts without a change.
func reviewWindow(pr bb.PR) string {
	name := fmt.Sprintf("review-%s-%d", shortRepo(pr.Repo), pr.ID)
	return strings.Map(func(r rune) rune {
		if r < utf8.RuneSelf && (unicode.IsLetter(r) || unicode.IsDigit(r) || r == '-' || r == '_') {
			return r
		}
		return '-'
	}, name)
}

// openSession opens the session of the review st of pr, or goes to it if its
// tab is open already. The commands run in the command that it returns. While
// an open of the session of pr runs, it does nothing, so that a second enter
// or click does not open a second tab.
func (m *Model) openSession(pr bb.PR, st review.State) tea.Cmd {
	k := pr.Key()
	if m.opening[k] {
		return nil
	}
	if st.Session == "" {
		m.setFlash("This review has no session to open.", yellow)
		return nil
	}
	cfg, err := m.loadReviewer()
	if err != nil {
		m.setFlash(fmt.Sprintf("The reviewer config is not valid: %v.", err), red)
		return nil
	}
	shownDir := clean(st.Dir)
	if len(cfg.Resume) == 0 {
		m.setFlash(fmt.Sprintf("The reviewer has no resume command. The folder of the review of #%d is %s.", pr.ID, shownDir), yellow)
		return nil
	}
	if !review.ValidSession(st.Session) {
		m.setFlash(fmt.Sprintf("Could not open the review session of #%d: %q is not a valid session id.", pr.ID, clean(st.Session)), red)
		return nil
	}
	if st.Dir == "" {
		m.setFlash(fmt.Sprintf("Could not open the review session of #%d: the review has no folder.", pr.ID), red)
		return nil
	}
	// Each entry is one argument. The session id has only safe characters.
	argv := make([]string, len(cfg.Resume))
	for i, a := range cfg.Resume {
		argv[i] = strings.ReplaceAll(a, "{session}", st.Session)
	}
	label := clean(fmt.Sprintf("review %s#%d", shortRepo(pr.Repo), pr.ID))
	window := reviewWindow(pr)
	tab := m.d.Tab
	var entry *cmdlog.Entry
	if m.d.Log != nil {
		entry = m.d.Log.Begin(fmt.Sprintf("Open the review session of #%d", pr.ID))
		tab.Record = entry.Add
	}
	m.opening[k] = true
	return func() tea.Msg {
		fail := func(err error) tea.Msg {
			return sessionMsg{k, fmt.Sprintf("Could not open the review session of #%d: %s", pr.ID, clean(err.Error())), red}
		}
		// The select and the open each get their own time.
		ctx, cancel := context.WithTimeout(context.Background(), sessionTimeout)
		_, jumped, err := tab.Jump(ctx, label, window)
		cancel()
		switch {
		case err != nil:
			return fail(err)
		case jumped:
			return sessionMsg{k, fmt.Sprintf("Switched to the review session of #%d.", pr.ID), green}
		}
		ctx, cancel = context.WithTimeout(context.Background(), sessionTimeout)
		defer cancel()
		where, err := tab.OpenWith(ctx, st.Dir, label, window, argv)
		switch {
		case err != nil:
			return fail(err)
		case where == "":
			// No Rex or tmux: the user runs the command. Each word is safe
			// for a shell.
			words := []string{"cd", shellWord(st.Dir), "&&"}
			for _, a := range argv {
				words = append(words, shellWord(a))
			}
			entry.Add(strings.Join(words, " "))
			return sessionMsg{k, "No Rex or tmux. The resume command is in the command log.", yellow}
		}
		return sessionMsg{k, fmt.Sprintf("Opened the review session of #%d in %s.", pr.ID, where), green}
	}
}

// renderReview returns the lines of the Review view of pr. rv is the state of
// its review, or nil. name is the name of the reviewer. The lines are the
// reviewer and the model, the status, the verdict, the open line, the summary,
// and the findings. After a failure, they are the error and the start of the
// raw output. With wrap on, the long lines wrap at width.
func renderReview(pr bb.PR, rv *review.State, name string, now time.Time, width int, wrapOn bool) []string {
	ww := wrapAt(width, wrapOn)
	if rv == nil {
		return wrap("", fmt.Sprintf("No review yet. Press R to review with %s.", name), dimStyle, ww)
	}
	st := shownState(*rv, now)
	who := clean(st.Reviewer)
	if who == "" {
		who = name
	}
	if model := clean(st.Model); model != "" {
		who += " " + dimStyle.Render("·") + " " + model
	}
	var status string
	switch st.Status {
	case review.StatusRunning:
		age := "less than a minute"
		if d := now.Sub(st.Started); d >= time.Minute {
			age = bb.Age(d)
		}
		status = fg(cyan).Render("running for " + age)
	case review.StatusDone:
		when := st.Finished
		if when.IsZero() {
			when = st.Started
		}
		status = fg(green).Render("done " + agoText(now.Sub(when)))
	case review.StatusFailed:
		status = fg(red).Render("failed")
	default:
		status = clean(st.Status)
	}
	if staleReview(pr, st) {
		status += " " + fg(yellow).Render("(stale: the PR changed since)")
	}
	fields := [][2]string{{"Reviewer", who}, {"Status", status}}
	if st.Status == review.StatusDone {
		fields = append(fields, [2]string{"Verdict", verdictStyle(st.Verdict).Render(clean(st.Verdict))})
	}
	if st.Status == review.StatusFailed && st.Error != "" {
		fields = append(fields, [2]string{"Error", fg(red).Render(clean(st.Error))})
	}
	const lw = len("Reviewer") + 2
	var lines []string
	for _, f := range fields {
		lines = append(lines, field(f[0], f[1], lw, ww)...)
	}
	if st.Session != "" && st.Status != review.StatusRunning {
		lines = append(lines, "", fg(blue).Render(openLine))
	}
	if st.Status == review.StatusDone {
		lines = append(lines, divider("Summary", width))
		if s := strings.TrimSpace(cleanText(st.Summary)); s != "" {
			lines = append(lines, plainText(s, ww)...)
		} else {
			lines = append(lines, dimStyle.Render("No summary."))
		}
		lines = append(lines, divider("Findings", width))
		if len(st.Findings) == 0 {
			lines = append(lines, dimStyle.Render("No findings."))
		}
		for _, fd := range st.Findings {
			prefix := severityStyle(fd.Severity).Render(fit(clean(fd.Severity), severityWidth))
			loc := clean(fd.File)
			if fd.Line > 0 {
				loc += fmt.Sprintf(":%d", fd.Line)
			}
			if loc != "" {
				prefix += fg(cyan).Render(loc) + "  "
			}
			lines = append(lines, wrap(prefix, clean(fd.Note), plainStyle, ww)...)
		}
	}
	if raw := strings.TrimSpace(cleanText(st.Raw)); st.Status == review.StatusFailed && raw != "" {
		lines = append(lines, divider("Output", width))
		parts := strings.Split(raw, "\n")
		for _, l := range parts[:min(len(parts), rawLines)] {
			lines = append(lines, wrap("", l, dimStyle, ww)...)
		}
	}
	return lines
}
