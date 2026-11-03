package ui

import (
	"fmt"
	"os"
	"strings"
	"sync"

	"github.com/charmbracelet/glamour"
	gansi "github.com/charmbracelet/glamour/ansi"
	"github.com/charmbracelet/glamour/styles"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"bbprs/internal/bb"
)

// The main panel has two modes. With wrap on, a renderer wraps each long
// free text at the width. A free text is, for example, a title, a list of
// names, or a comment. The model wraps each other long line. With wrap off, a
// renderer gets the width 0 and wraps no line. Then the panel cuts each line
// at the side scroll and at the width.

// labelWidth is the width of a label column, for example "Workspace".
const labelWidth = 12

// minWrap is the smallest width that wrap uses. Below it, a text stays on one
// line, and the panel cuts it.
const minWrap = 10

// wrapAt returns the width at which a renderer wraps: width with wrap on, or
// 0 (no wrap) with wrap off.
func wrapAt(width int, on bool) int {
	if on {
		return width
	}
	return 0
}

// wrapStyled breaks the styled text s into lines of at most width columns.
// A style continues on the next line. If s fits, or if width is less than
// minWrap, s stays on one line.
func wrapStyled(s string, width int) []string {
	if width < minWrap || ansi.StringWidth(s) <= width {
		return []string{s}
	}
	return strings.Split(lipgloss.NewStyle().Width(width).Render(s), "\n")
}

// wrapLines breaks each line that is wider than width.
func wrapLines(lines []string, width int) []string {
	out := make([]string, 0, len(lines))
	for _, l := range lines {
		out = append(out, wrapStyled(l, width)...)
	}
	return out
}

// sideCut returns the part of line that starts at the column from and fits
// in width columns. If the line goes on after the panel, the part ends with
// "…". The styles of the line stay.
func sideCut(line string, from, width int) string {
	if from > 0 {
		rest := ansi.StringWidth(line) - from
		if rest <= 0 {
			return ""
		}
		part := ansi.TruncateLeft(line, from, "")
		if ansi.StringWidth(part) > rest {
			// A wide character crosses the left edge. A space takes its place.
			part = " " + ansi.TruncateLeft(line, from+1, "")
		}
		line = part
	}
	return cut(line, width)
}

// wrap breaks the plain text s into lines that fit in width columns, and
// styles each line with st. The first line starts with prefix. The next lines
// start with spaces, so that they line up under the first line.
func wrap(prefix, s string, st lipgloss.Style, width int) []string {
	pw := ansi.StringWidth(prefix)
	room := width - pw
	if room < minWrap {
		return []string{prefix + st.Render(s)}
	}
	parts := strings.Split(ansi.Wrap(s, room, ""), "\n")
	out := make([]string, len(parts))
	for i, part := range parts {
		lead := prefix
		if i > 0 {
			lead = strings.Repeat(" ", pw)
		}
		out[i] = lead + st.Render(part)
	}
	return out
}

// label returns a dim label in a column of labelWidth.
func label(s string) string { return dimStyle.Render(fit(s, labelWidth)) }

// names returns the names joined by ", " and the style st. If the list is
// empty, it returns the word none and the dim style.
func names(list []string, st lipgloss.Style, none string) (string, lipgloss.Style) {
	if len(list) == 0 {
		return none, dimStyle
	}
	return clean(strings.Join(list, ", ")), st
}

// stateWord returns the state of a PR in its color.
func stateWord(state string) string {
	state = strings.ToUpper(clean(state))
	switch state {
	case "OPEN":
		return fg(green).Render(state)
	case "MERGED":
		return fg(magenta).Render(state)
	case "DECLINED":
		return fg(red).Render(state)
	case "":
		return dimStyle.Render("?")
	}
	return state
}

// mergeState returns the merge state of an open PR, the failed checks, and
// the text of the git check. The state is "ready" (green) only if the git
// check passed and no other check failed. It is "blocked" (red) if the git
// check or another check failed. Else it is the status of the git check in
// dim, or "unknown" if there is no git check. The text of the git check
// always shows.
func mergeState(d bb.Details) string {
	git := clean(d.Merge)
	if git == "" {
		git = "unknown"
	}
	gitStyle := dimStyle
	var state string
	switch status := strings.ToUpper(clean(d.GitStatus)); {
	case status == "FAILED":
		state = fg(red).Render("blocked")
		gitStyle = fg(red)
	case len(d.Failing) > 0:
		state = fg(red).Render("blocked")
	case status == "PASSED" || status == "SUCCESSFUL":
		state = fg(green).Render("ready")
	case status == "":
		state = dimStyle.Render("unknown")
	default:
		state = dimStyle.Render(strings.ToLower(status))
	}
	if len(d.Failing) > 0 {
		state += "  " + dimStyle.Render("failing:") + " " + clean(strings.Join(d.Failing, ", "))
	}
	return state + "  " + dimStyle.Render("git:") + " " + gitStyle.Render(git)
}

// fileStyle gives the color of the status letter of a changed file.
func fileStyle(status string) lipgloss.Style {
	switch status {
	case "A":
		return fg(green)
	case "D":
		return fg(red)
	}
	return fg(yellow)
}

// wideDiffs is the smallest width of the text of the main panel that puts
// the list of the Changes view at the left of the right side. In a narrower
// panel, the list is on top, and the right side is under it.
const wideDiffs = 90

// diffPlaces holds the sizes of the list and of the right side of the Changes
// view. The list is the commit list or the file list. The right side is the
// preview of a row or the diff of a file. The file list has a header row.
// listH is 0 when the diff fills the panel.
type diffPlaces struct {
	wide                       bool
	listW, listH, diffW, diffH int
}

// listRows is the number of files that the file list shows under its header.
func (p diffPlaces) listRows() int { return max(0, p.listH-1) }

// splitDiffs divides a panel of width columns and height lines between the
// list and the right side. The list needs lines lines. With zoom on, the
// right side gets the full panel. A wide panel (wideDiffs columns or more)
// puts the list at the left, in 2/5 of the width. Then " │ " is between the
// list and the right side. A narrower panel puts the list on top, with a line
// of "─" under it. There, the list gets at most a third of the height, but at
// least 3 lines.
func splitDiffs(width, height, lines int, zoom bool) diffPlaces {
	width, height = max(width, 0), max(height, 0)
	switch {
	case zoom:
		return diffPlaces{diffW: width, diffH: height}
	case width >= wideDiffs:
		listW := (width - 3) * 2 / 5
		return diffPlaces{wide: true, listW: listW, listH: height, diffW: width - 3 - listW, diffH: height}
	}
	listH := min(max(min(height/3, lines), 3), height)
	return diffPlaces{listW: width, listH: listH, diffW: width, diffH: max(0, height-listH-1)}
}

// fileCounts returns the counts of the added and the removed lines of a
// file: "+N" in green and "-N" in red. A binary file has the dim word "bin".
func fileCounts(f bb.FileDiff) string {
	if f.Binary {
		return dimStyle.Render("bin")
	}
	return fg(green).Render(fmt.Sprintf("+%d", f.Added)) + " " + fg(red).Render(fmt.Sprintf("-%d", f.Removed))
}

// countWidth returns the width of the column of the counts in the file list.
func countWidth(files []bb.FileDiff) int {
	cw := len("+/-")
	for _, f := range files {
		if !f.Binary {
			cw = max(cw, len(fmt.Sprintf("+%d -%d", f.Added, f.Removed)))
		}
	}
	return cw
}

// fileHeader returns the header row of the file list.
func fileHeader(cw, width int) string {
	return dimStyle.Render(fit("ST  "+fit("+/-", cw)+"  FILE", width))
}

// filePath returns the path of a file. A renamed file shows "old → new".
func filePath(f bb.FileDiff) string {
	if f.OldPath != "" {
		return clean(f.OldPath) + " → " + clean(f.Path)
	}
	return clean(f.Path)
}

// fileRow returns the row of one file in a file list of width columns: the
// status letter, the counts in a column of cw, and the path. A long path
// loses its start, so that the name of the file stays.
func fileRow(f bb.FileDiff, cw, width int) string {
	counts := fileCounts(f)
	counts += strings.Repeat(" ", max(0, cw-ansi.StringWidth(counts)))
	room := width - 2 - 2 - cw - 2
	return fit(fileStyle(f.Status).Render(fit(f.Status, 2))+"  "+counts+"  "+cutLeft(filePath(f), room), width)
}

// cutLeft shortens the plain text s to at most w columns. A cut text starts
// with "…", so that the end of s stays.
func cutLeft(s string, w int) string {
	n := ansi.StringWidth(s)
	switch {
	case w <= 0:
		return ""
	case n <= w:
		return s
	}
	rest := ansi.TruncateLeft(s, n-w+1, "")
	if ansi.StringWidth(rest) > w-1 {
		// A wide character crosses the cut. It goes too.
		rest = ansi.TruncateLeft(s, n-w+2, "")
	}
	return "…" + rest
}

// renderDiff returns the lines of the diff of one file: a head line with the
// path and the counts, then the lines of the hunks. A line that starts with
// "+" is green, with "-" red, and with "@@" cyan. If width is not 0, a long
// line wraps at width, and the next lines keep its color.
func renderDiff(f bb.FileDiff, width int) []string {
	lines := wrapStyled(boldStyle.Render(filePath(f))+"  "+fileCounts(f), width)
	switch {
	case f.Binary:
		return append(lines, dimStyle.Render("Binary file. There is no text diff to show."))
	case len(f.Lines) == 0:
		return append(lines, dimStyle.Render("No text changes in this file."))
	}
	for _, l := range f.Lines {
		text := cleanText(l)
		color := lipgloss.Color("")
		switch {
		case strings.HasPrefix(text, "@@"):
			color = cyan
		case strings.HasPrefix(text, "+"):
			color = green
		case strings.HasPrefix(text, "-"):
			color = red
		}
		parts := []string{text}
		if width > 0 {
			parts = strings.Split(ansi.Hardwrap(text, width, true), "\n")
		}
		for _, p := range parts {
			if color != "" {
				p = fg(color).Render(p)
			}
			lines = append(lines, p)
		}
	}
	return lines
}

// behindText tells how many commits the source branch is behind dst.
func behindText(n int, dst string) string {
	if n <= 0 {
		return dimStyle.Render("up to date with " + dst)
	}
	unit := "commits"
	if n == 1 {
		unit = "commit"
	}
	return fg(magenta).Render(fmt.Sprintf("%d %s behind %s", n, unit, dst)) + dimStyle.Render(" · s syncs it")
}

// field returns the lines of one row of a field table: the name in a dim
// column of lw, then the value. If width is not 0, the value wraps at width,
// and the next lines start under the value.
func field(name, value string, lw, width int) []string {
	room := -1
	if width > 0 {
		room = width - lw
	}
	parts := wrapStyled(value, room)
	lead := dimStyle.Render(fit(name, lw))
	for i, p := range parts {
		if i > 0 {
			lead = strings.Repeat(" ", lw)
		}
		parts[i] = lead + p
	}
	return parts
}

// divider returns the line "── <name> ───…" that fills width columns.
func divider(name string, width int) string {
	head := "── " + name + " "
	return fg(gray).Render(head + strings.Repeat("─", max(0, width-ansi.StringWidth(head))))
}

// renderStatus returns the lines of the Status view: a table of the fields,
// a divider, and the description. A closed PR has no Merge row, and its State
// row tells who closed it. The Behind row shows only for an open PR with
// behindOK. With wrap on, the values and the description wrap at width.
func renderStatus(d bb.Details, behind int, behindOK, isOpen bool, width int, wrap bool) []string {
	ww := wrapAt(width, wrap)
	pr := boldStyle.Render(fmt.Sprintf("#%d", d.ID))
	if d.Draft {
		pr += "  " + dimStyle.Render("[draft]")
	}
	state := stateWord(d.State)
	if !isOpen {
		who := clean(d.ClosedBy)
		if who == "" {
			who = "?"
		}
		state += "  " + dimStyle.Render("by") + " " + who
	}
	approved, approvedStyle := names(d.ApprovedBy, fg(green), "nobody")
	reviewers, reviewersStyle := names(d.Reviewers, plainStyle, "none")

	fields := [][2]string{
		{"PR", pr},
		{"Title", boldStyle.Render(clean(d.Title))},
		{"Author", fg(yellow).Render(clean(d.Author))},
		{"Branches", fg(magenta).Render(clean(d.Src)) + " " + dimStyle.Render("→") + " " + fg(magenta).Render(clean(d.Dst))},
		{"State", state},
		{"Updated", clean(d.Updated)},
		{"Comments", fmt.Sprint(d.Comments)},
		{"Tasks", fmt.Sprint(d.Tasks)},
		{"Approved", approvedStyle.Render(approved)},
		{"Reviewers", reviewersStyle.Render(reviewers)},
	}
	if isOpen {
		fields = append(fields, [2]string{"Merge", mergeState(d)})
		if behindOK {
			fields = append(fields, [2]string{"Behind", behindText(behind, clean(d.Dst))})
		}
	}
	lw := 0
	for _, f := range fields {
		lw = max(lw, ansi.StringWidth(f[0]))
	}
	lw += 2

	var lines []string
	for _, f := range fields {
		lines = append(lines, field(f[0], f[1], lw, ww)...)
	}
	lines = append(lines, divider("Description", width))
	if desc := markdown(d.Description, ww); len(desc) > 0 {
		return append(lines, desc...)
	}
	return append(lines, dimStyle.Render("No description."))
}

// shortTime turns "2006-01-02 15:04" into "01-02 15:04". It returns another
// text as it is.
func shortTime(s string) string {
	s = clean(s)
	if len(s) == len("2006-01-02 15:04") && s[4] == '-' {
		return s[5:]
	}
	return s
}

// renderActivity returns one line for each event, oldest first: the time, the
// person, and what happened. If width is not 0, a long event wraps under its
// text.
func renderActivity(events []bb.Event, width int) []string {
	if len(events) == 0 {
		return []string{dimStyle.Render("No activity.")}
	}
	var lines []string
	for _, e := range events {
		what := clean(e.What)
		st := dimStyle
		switch {
		case what == "approved":
			st = fg(green)
		case what == "requested changes":
			st = fg(red)
		case strings.HasPrefix(what, "commented"):
			st = plainStyle
		}
		prefix := dimStyle.Render(shortTime(e.Time)) + "  " + fg(yellow).Render(fit(abbr(e.Who), labelWidth)) + " "
		lines = append(lines, wrap(prefix, what, st, width)...)
	}
	return lines
}

// shortDay turns "2006-01-02 15:04" into "01-02". It returns another text as
// it is.
func shortDay(s string) string {
	s = clean(s)
	if len(s) >= len("2006-01-02") && s[4] == '-' && s[7] == '-' {
		return s[5:10]
	}
	return s
}

// countFiles returns "1 file" or "<n> files".
func countFiles(n int) string {
	if n == 1 {
		return "1 file"
	}
	return fmt.Sprintf("%d files", n)
}

// fileStats returns the number of files, and the counts of the added and the
// removed lines of all of them: "+N" in green and "-N" in red.
func fileStats(files []bb.FileDiff) string {
	var added, removed int
	for _, f := range files {
		added += f.Added
		removed += f.Removed
	}
	return countFiles(len(files)) + "  " + fg(green).Render(fmt.Sprintf("+%d", added)) + " " + fg(red).Render(fmt.Sprintf("-%d", removed))
}

// allRow returns the first row of the commit list in width columns: All
// changes, and the number of files when the diff of the PR loaded.
func allRow(diff viewData, loaded bool, width int) string {
	row := boldStyle.Render("All changes")
	if loaded && diff.err == nil {
		row += "  " + dimStyle.Render(countFiles(len(diff.files)))
	}
	return fit(row, width)
}

// commitRow returns the row of one commit in a commit list of width columns.
// The row has the short hash, the day, the author in a column of aw columns,
// and the first line of the message.
func commitRow(c bb.Commit, aw, width int) string {
	return fit(fg(yellow).Render(clean(c.Hash))+"  "+dimStyle.Render(shortDay(c.Date))+"  "+
		fg(cyan).Render(fit(abbr(c.Who), aw))+"  "+clean(c.Subject()), width)
}

// previewHead returns the first lines of the preview of a row of the commit
// list. For All changes (c is nil), it is the title of pr. For a commit, it
// is the full hash, the author, the date, and the whole message. If width is
// not 0, the lines wrap at width.
func previewHead(pr bb.PR, c *bb.Commit, width int) []string {
	if c == nil {
		return wrap("", clean(pr.Title), boldStyle, width)
	}
	const lw = len("Commit  ")
	var lines []string
	for _, f := range [][2]string{
		{"Commit", fg(yellow).Render(clean(c.Full))},
		{"Author", fg(cyan).Render(clean(c.Who))},
		{"Date", clean(c.Date)},
	} {
		lines = append(lines, field(f[0], f[1], lw, width)...)
	}
	lines = append(lines, "")
	for i, l := range strings.Split(cleanText(c.Message), "\n") {
		st := plainStyle
		if i == 0 {
			st = boldStyle
		}
		lines = append(lines, wrap("", l, st, width)...)
	}
	return lines
}

// checkoutHint tells that the files of a commit of pr need the checkout of
// the repo of pr.
func checkoutHint(pr bb.PR) string {
	return fmt.Sprintf("The files of a commit need the checkout of %s. Press o to open it in the browser.", clean(pr.Repo))
}

// fetchHint tells that the checkout does not have the commit c, and names the
// fetch that gets it.
func fetchHint(c bb.Commit) string {
	return fmt.Sprintf("The checkout does not have commit %s. Run git fetch origin, then press enter to load it again. Press o to open it in the browser.", clean(c.Hash))
}

// overview is the data of the main panel when [1] Status has focus.
type overview struct {
	Repo      string // "<workspace>/<repo>", or empty outside a Bitbucket repo
	Workspace string
	Dir       string // the directory of the pane
	// The number of PRs in the open and the closed list, and of actions in
	// the log.
	Open, Closed, Logged int
	// The number of open PRs that wait for your review, of your own open
	// PRs, and of open PRs that are behind their destination.
	Review, Mine, Behind int
}

// renderOverview returns the lines of the overview.
func renderOverview(o overview, width int) []string {
	head := boldStyle.Render(clean(shortRepo(o.Repo))) + "  " + dimStyle.Render("("+clean(o.Repo)+")")
	if o.Repo == "" {
		head = boldStyle.Render("No repo") + "  " + dimStyle.Render("(not in a Bitbucket repo)")
	}
	ws := fg(cyan).Render(clean(o.Workspace))
	if o.Workspace == "" {
		ws = dimStyle.Render("none")
	}
	count := func(c lipgloss.Color, n int, text string) string {
		return fg(c).Render(fmt.Sprintf("%3d", n)) + "  " + text
	}
	lines := []string{
		head,
		label("Workspace") + ws,
		label("Directory") + clean(tildeHome(o.Dir)),
		label("Lists") + fmt.Sprintf("%d open · %d closed · %d actions", o.Open, o.Closed, o.Logged),
		"",
		count(yellow, o.Review, "wait for your review"),
		count(cyan, o.Mine, "are your own open PRs"),
		count(magenta, o.Behind, "are behind their destination"),
		"",
	}
	return append(lines, wrap("", "The list opens from the cache. A refresh runs when the list is older than 3 minutes, or when you press r.", dimStyle, width)...)
}

// tildeHome writes the home directory at the start of dir as "~".
func tildeHome(dir string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return dir
	}
	if dir == home {
		return "~"
	}
	if rest, ok := strings.CutPrefix(dir, home+"/"); ok {
		return "~/" + rest
	}
	return dir
}

// markdownStyle is the dark style of Glamour with ANSI colors 0 to 15 in
// place of its other colors. It has no margin and no empty line around the
// document, and the headings have no empty line after them.
func markdownStyle() gansi.StyleConfig {
	str := func(s string) *string { return &s }
	yes := func() *bool { b := true; return &b }
	num := func(n uint) *uint { return &n }

	// The copy shares the pointers of the built-in style. Set new pointers,
	// and do not write through the old ones.
	s := styles.DarkStyleConfig
	s.Document = gansi.StyleBlock{}
	s.BlockQuote.StylePrimitive = gansi.StylePrimitive{Color: str("8")}
	s.Heading = gansi.StyleBlock{StylePrimitive: gansi.StylePrimitive{Color: str("5"), Bold: yes()}}
	s.H1 = gansi.StyleBlock{StylePrimitive: gansi.StylePrimitive{Prefix: "# "}}
	s.H6 = gansi.StyleBlock{StylePrimitive: gansi.StylePrimitive{Prefix: "###### "}}
	s.HorizontalRule = gansi.StylePrimitive{Color: str("8"), Format: "\n--------\n"}
	s.List.Indent = num(2)
	s.Item = gansi.StylePrimitive{Prefix: "• ", Color: str("5")}
	s.Link = gansi.StylePrimitive{Color: str("4"), Underline: yes()}
	s.LinkText = gansi.StylePrimitive{Color: str("6"), Bold: yes()}
	s.Image = gansi.StylePrimitive{Color: str("5"), Underline: yes()}
	s.ImageText = gansi.StylePrimitive{Color: str("8"), Format: "Image: {{.text}} →"}
	s.Code = gansi.StyleBlock{StylePrimitive: gansi.StylePrimitive{Color: str("3")}}
	// No Chroma: its themes use 256 and RGB colors.
	s.CodeBlock = gansi.StyleCodeBlock{StyleBlock: gansi.StyleBlock{
		StylePrimitive: gansi.StylePrimitive{Color: str("3")},
		Margin:         num(2),
	}}
	s.DefinitionDescription = gansi.StylePrimitive{BlockPrefix: "\n→ "}
	return s
}

// md keeps one Glamour renderer for each width. A renderer is not safe for
// use by two goroutines at the same time, so the mutex guards each call. The
// model keeps the rendered lines of each view (viewData.lines), so Glamour
// does not run for each frame.
var md struct {
	sync.Mutex
	renderers map[int]*glamour.TermRenderer
}

// md keeps at most this number of renderers. When the map is full, markdown
// empties it.
const maxRenderers = 8

// markdown renders the description of a PR as Markdown. If width is not 0,
// the lines wrap at width. Width 0 gives no wrap. An empty description gives
// no lines. If Glamour fails, the plain text shows.
func markdown(text string, width int) []string {
	text = strings.TrimSpace(cleanText(text))
	if text == "" {
		return nil
	}
	if width > 0 {
		width = max(width, minWrap)
	}

	md.Lock()
	defer md.Unlock()
	r, ok := md.renderers[width]
	if !ok {
		var err error
		r, err = glamour.NewTermRenderer(
			glamour.WithStyles(markdownStyle()),
			glamour.WithWordWrap(width),
			glamour.WithColorProfile(lipgloss.ColorProfile()),
		)
		if err != nil {
			return plainText(text, width)
		}
		if md.renderers == nil || len(md.renderers) >= maxRenderers {
			md.renderers = map[int]*glamour.TermRenderer{}
		}
		md.renderers[width] = r
	}
	out, err := r.Render(text)
	if err != nil {
		return plainText(text, width)
	}

	lines := strings.Split(out, "\n")
	if width > 0 {
		var wrapped []string
		for _, l := range lines {
			// Glamour does not break a long word, for example a URL.
			wrapped = append(wrapped, strings.Split(ansi.Hardwrap(l, width, true), "\n")...)
		}
		lines = wrapped
	}
	blank := func(l string) bool { return strings.TrimSpace(ansi.Strip(l)) == "" }
	for len(lines) > 0 && blank(lines[0]) {
		lines = lines[1:]
	}
	for len(lines) > 0 && blank(lines[len(lines)-1]) {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// plainText breaks text into its lines, without Markdown. If width is not 0,
// each line wraps at width.
func plainText(text string, width int) []string {
	var lines []string
	for _, l := range strings.Split(text, "\n") {
		lines = append(lines, wrap("", l, plainStyle, width)...)
	}
	return lines
}
