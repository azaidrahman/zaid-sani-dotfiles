package ui

import (
	"fmt"
	"regexp"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"bbprs/internal/actions"
	"bbprs/internal/bb"
)

// screen returns the lines of the view, without styles.
func screen(m Model) []string { return strings.Split(ansi.Strip(m.View()), "\n") }

// spot returns the column and the line of the first text on the screen.
func spot(t *testing.T, m Model, text string) (x, y int) {
	t.Helper()
	for y, l := range screen(m) {
		if i := strings.Index(l, text); i >= 0 {
			return ansi.StringWidth(l[:i]), y
		}
	}
	t.Fatalf("no %q on the screen:\n%s", text, strings.Join(screen(m), "\n"))
	return 0, 0
}

// press gives the model a press of the button b at the column x and the
// line y.
func press(m Model, b tea.MouseButton, x, y int) Model {
	return feed(m, tea.MouseMsg{X: x, Y: y, Action: tea.MouseActionPress, Button: b})
}

func click(m Model, x, y int) Model { return press(m, tea.MouseButtonLeft, x, y) }

// clickOn clicks on the first column of the first text on the screen.
func clickOn(t *testing.T, m Model, text string) Model {
	t.Helper()
	x, y := spot(t, m, text)
	return click(m, x, y)
}

// TestMouse finds each place in the text of the screen, so the test checks
// that the hit test follows what the view draws.
func TestMouse(t *testing.T) {
	// 40 PRs, so that the list scrolls at both sizes.
	var prs []bb.PR
	for i := range 40 {
		p := fixturePRs()[0]
		p.ID += i
		prs = append(prs, p)
	}
	id := regexp.MustCompile(`#\d+`)
	const merge = "pull-requests merge --pull-request 11"
	// The cases with side true run also at 250×40, where the list of the
	// Changes view is at the left of the right side.
	cases := []struct {
		name  string
		side  bool
		check func(t *testing.T, f fixture)
	}{
		{"click on [0] focuses it", false, func(t *testing.T, f fixture) {
			x, y := spot(t, f.m, "[0]")
			if f.m = click(f.m, x, y+1); f.m.focus != focusMain {
				t.Errorf("focus = %q, want main", f.m.focus)
			}
		}},
		{"click on the header of [2], then on the third PR row, also after the list scrolled", false, func(t *testing.T, f fixture) {
			f.m = send(f.m, "0")
			if f.m = clickOn(t, f.m, "PR#"); f.m.focus != focusPRs || f.m.cursor["open"] != 0 {
				t.Errorf("focus = %q, cursor = %d after a click on the header, want prs and 0", f.m.focus, f.m.cursor["open"])
			}
			for _, scrolled := range []bool{false, true} {
				if scrolled {
					f.m = send(f.m, strings.Repeat("j", 35))
					if f.m.offset["open"] == 0 {
						t.Fatal("the list did not scroll")
					}
				}
				_, y := spot(t, f.m, "PR#")
				line := screen(f.m)[y+3] // the header, then the rows
				loc := id.FindStringIndex(line)
				f.m = click(f.m, ansi.StringWidth(line[:loc[0]]), y+3)
				if got, want := f.m.currentKey(), "ws/cur"+line[loc[0]:loc[1]]; got != want {
					t.Errorf("scrolled %t: cursor on %q, want %q", scrolled, got, want)
				}
			}
		}},
		{"click on Closed", false, func(t *testing.T, f fixture) {
			if f.m = clickOn(t, f.m, "Closed"); f.m.list != "closed" {
				t.Errorf("list = %q, want closed", f.m.list)
			}
		}},
		{"click on Changes", false, func(t *testing.T, f fixture) {
			if f.m = clickOn(t, f.m, "Changes"); f.m.view != "changes" || f.m.focus != focusMain {
				t.Errorf("view = %q, focus = %q, want changes and main", f.m.view, f.m.focus)
			}
		}},
		{"click on a commit row, then again, then on the scope line", true, func(t *testing.T, f fixture) {
			fakeGit(t, 0)
			f.m.d.Env.Dir = t.TempDir()
			f.m = send(f.m, "}")
			x, y := spot(t, f.m, "a1b2c3d4")
			if f.m = click(f.m, x, y); f.m.row != 1 || f.m.level != levelCommits {
				t.Errorf("row = %d, level = %d, want row 1 on the commit list", f.m.row, f.m.level)
			}
			if f.m = click(f.m, x, y); f.m.level != levelFiles || !strings.Contains(f.mainText(), "api/budget.go") {
				t.Errorf("level = %d, panel =\n%s\nwant the files of the commit", f.m.level, f.mainText())
			}
			if f.m = clickOn(t, f.m, "← a1b2c3d4 (esc)"); f.m.level != levelCommits || f.m.row != 1 {
				t.Errorf("level = %d, row = %d after a click on the scope line, want the commit list on row 1", f.m.level, f.m.row)
			}
		}},
		{"click on a file, then again", true, func(t *testing.T, f fixture) {
			f.m = send(f.m, "}", "0", "enter")
			x, y := spot(t, f.m, "docs/retry.md")
			if f.m = click(f.m, x, y); f.m.file != 1 || f.m.level != levelFiles {
				t.Errorf("file = %d, level = %d, want file 1 on the files level", f.m.file, f.m.level)
			}
			if f.m = click(f.m, x, y); f.m.file != 1 || f.m.level != levelZoom {
				t.Errorf("file = %d, level = %d after the second click, want the zoom of file 1", f.m.file, f.m.level)
			}
		}},
		{"click on the header of a file list that scrolled", true, func(t *testing.T, f fixture) {
			// 60 files: more than the rows of the file list at each size.
			var diff strings.Builder
			for i := range 60 {
				fmt.Fprintf(&diff, "diff --git a/f%[1]d.go b/f%[1]d.go\n--- a/f%[1]d.go\n+++ b/f%[1]d.go\n@@ -1 +1 @@\n-a\n+b\n", i)
			}
			pr, _ := f.m.current()
			f.writePreview(pr, "diff", diff.String())
			f.m = send(f.m, "}", "0", "enter", strings.Repeat("j", 59))
			if f.m.fileOff == 0 {
				t.Fatal("the file list did not scroll")
			}
			if f.m = clickOn(t, f.m, "ST  +/-"); f.m.file != 59 || f.m.level != levelFiles {
				t.Errorf("file = %d, level = %d after a click on the header, want file 59 on the files level", f.m.file, f.m.level)
			}
		}},
		{"click on Merge: m in the bar", false, func(t *testing.T, f fixture) {
			f.m = clickOn(t, f.m, "Merge: m")
			if f.m.popup == nil || f.m.popup.kind != confirmKind || f.m.popup.title != "Approve and merge" {
				t.Errorf("popup = %+v, want the merge confirm", f.m.popup)
			}
			if log := f.twg(); strings.Contains(log, "pull-requests merge") {
				t.Errorf("twg log = %q, want no merge", log)
			}
		}},
		{"the wheel acts on the panel under the pointer", false, func(t *testing.T, f fixture) {
			// The second PR has a long description, so that [0] can scroll.
			f.writeDetails(f.m.prRows()[1], strings.Repeat("A line of the description.\n\n", 30))
			f.m = send(f.m, "0")
			x, y := spot(t, f.m, "PR#")
			if f.m = press(f.m, tea.MouseButtonWheelDown, x, y+1); f.m.cursor["open"] != 1 || f.m.focus != focusMain {
				t.Errorf("cursor = %d, focus = %q after the wheel over [2], want 1 and main", f.m.cursor["open"], f.m.focus)
			}
			x, y = spot(t, f.m, "[0]")
			if f.m = press(f.m, tea.MouseButtonWheelDown, x, y+1); f.m.cursor["open"] != 1 || f.m.scroll != wheelStep {
				t.Errorf("cursor = %d, scroll = %d after the wheel over [0], want 1 and %d", f.m.cursor["open"], f.m.scroll, wheelStep)
			}
		}},
		{"click on a sync method", false, func(t *testing.T, f fixture) {
			f.m.busy = "Fetching origin…" // as after s
			plan := actions.SyncPlan{Todo: []actions.Behind{{PR: prs[0], Commits: 2}}}
			f.m = send(feed(f.m, syncPlanMsg{plan: plan}), "wait")
			spot(t, f.m, "Sync: ⏎ or y") // the popup draws the item that confirms
			f.m = clickOn(t, f.m, "Merge main into feat/x")
			if p := f.m.popup; p == nil || p.title != "Sync" || p.idx != 1 || f.m.busy != "" {
				t.Errorf("popup = %+v, busy = %q, want the sync popup with Merge chosen, and nothing runs", p, f.m.busy)
			}
		}},
		{"clicks with a popup open: only the popup gets them", false, func(t *testing.T, f fixture) {
			f.m = send(f.m, "m")
			_, y := spot(t, f.m, "PR#")
			line := screen(f.m)[y+2] // the second PR row, above the popup
			f.m = click(f.m, ansi.StringWidth(line[:id.FindStringIndex(line)[0]]), y+2)
			f.m = clickOn(t, f.m, "Approve: a")
			f.m = clickOn(t, f.m, "Merge: ⏎ or y") // in the guard time
			if f.m.popup == nil || f.m.popup.kind != confirmKind || f.m.cursor["open"] != 0 {
				t.Errorf("popup = %+v, cursor = %d, want the merge confirm and the cursor on 0", f.m.popup, f.m.cursor["open"])
			}
			if log := f.twg(); strings.Contains(log, " approve ") || strings.Contains(log, merge) {
				t.Errorf("twg log = %q, want no approve and no merge", log)
			}
			f.m = clickOn(t, send(f.m, "wait"), "Cancel: esc or n")
			if log := f.twg(); f.m.popup != nil || strings.Contains(log, merge) || !strings.Contains(f.bar(), "Cancelled") {
				t.Errorf("popup = %+v, twg log = %q, bar = %q, want a cancel", f.m.popup, log, f.bar())
			}
			f.m = clickOn(t, send(f.m, "m", "wait"), "Merge: ⏎ or y")
			if log := f.twg(); !strings.Contains(log, merge) || f.m.popup == nil || f.m.popup.kind != resultKind {
				t.Errorf("popup = %+v, twg log = %q, want the merge and its result", f.m.popup, log)
			}
			if f.m = clickOn(t, send(f.m, "wait"), "Merge results"); f.m.popup != nil {
				t.Errorf("popup = %+v after a click on the result, want none", f.m.popup)
			}
		}},
		{"click on an item of the ? menu", false, func(t *testing.T, f fixture) {
			f.m = clickOn(t, send(f.m, "?"), "Next list: Open, Closed, Log")
			if f.m.popup != nil || f.m.list != "closed" {
				t.Errorf("popup = %+v, list = %q, want no popup and the closed list", f.m.popup, f.m.list)
			}
		}},
	}
	for _, size := range [][2]int{{120, 40}, {80, 24}, {250, 40}} {
		for _, c := range cases {
			if size[0] == 250 && !c.side {
				continue
			}
			t.Run(fmt.Sprintf("%dx%d %s", size[0], size[1], c.name), func(t *testing.T) {
				f := newFixture(t.TempDir(), prs, nil)
				f.m = feed(f.m, tea.WindowSizeMsg{Width: size[0], Height: size[1]})
				c.check(t, f)
			})
		}
	}
}
