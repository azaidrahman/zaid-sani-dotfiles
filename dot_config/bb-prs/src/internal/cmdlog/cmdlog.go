// Package cmdlog keeps the lines of the command log. The UI shows them in the
// log panel. Many goroutines can add lines at the same time.
//
// Each head line starts an entry. An entry keeps its own lines, so that two
// actions that run at the same time do not mix their lines.
//
// A runner adds the command line when the command starts, so that a command
// that hangs shows. When the command ends, the runner adds the end line of
// the command (see Ended). The end line puts the time of the command at the
// end of the line of the command, for example "twg … get 7  1.3 s".
package cmdlog

import (
	"fmt"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Line is one line of the log. A head line starts a new action.
type Line struct {
	Head bool
	Text string
}

// Log holds the entries. The zero value is ready to use.
type Log struct {
	mu      sync.Mutex
	entries []*Entry
}

// Entry is a head line and the lines under it.
type Entry struct {
	log   *Log
	head  string
	lines []line
}

// line is one line of an entry. took is the time of the command, or "" while
// the command runs.
type line struct {
	text, took string
}

// endMark separates the command line from the time in an end line. A
// command line cannot hold a NUL byte, so an end line is never a command line.
const endMark = "\x00"

// tookRe is the form of the time in an end line, as Ended writes it. A text
// with a NUL and another text after it is not an end line.
var tookRe = regexp.MustCompile(`^\d+\.\d s$`)

// Ended returns the end line of the command line cmd that ran for took. Give
// it to the same Record func that got cmd.
func Ended(cmd string, took time.Duration) string {
	return cmd + endMark + fmt.Sprintf("%.1f s", took.Seconds())
}

// Begin adds a head line, and returns the entry for its lines. On a nil Log,
// it returns nil.
func (l *Log) Begin(head string) *Entry {
	if l == nil {
		return nil
	}
	e := &Entry{log: l, head: head}
	l.mu.Lock()
	defer l.mu.Unlock()
	l.entries = append(l.entries, e)
	return e
}

// Add adds a line under the head of e. On a nil Entry, it does nothing.
func (e *Entry) Add(text string) {
	if e == nil {
		return
	}
	e.log.mu.Lock()
	defer e.log.mu.Unlock()
	e.log.add(e, text)
}

// Add adds a line under the last head. Use Entry.Add for the lines of an
// action that can run at the same time as another action.
func (l *Log) Add(text string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.entries) == 0 {
		l.entries = append(l.entries, &Entry{log: l})
	}
	l.add(l.entries[len(l.entries)-1], text)
}

// add adds text under e. An end line adds no line. It puts the time on the
// newest line of its command that has no time: in e, or else in the newest
// other entry that has such a line. If there is no such line, the command
// line with its time goes under e. The caller holds mu.
func (l *Log) add(e *Entry, text string) {
	cmd, took, end := strings.Cut(text, endMark)
	if !end || !tookRe.MatchString(took) {
		e.lines = append(e.lines, line{text: text})
		return
	}
	if e.finish(cmd, took) {
		return
	}
	for i := len(l.entries) - 1; i >= 0; i-- {
		if l.entries[i] != e && l.entries[i].finish(cmd, took) {
			return
		}
	}
	e.lines = append(e.lines, line{text: cmd, took: took})
}

// finish puts took on the newest line of e that is cmd and has no time. It is
// false if e has no such line.
func (e *Entry) finish(cmd, took string) bool {
	for i := len(e.lines) - 1; i >= 0; i-- {
		if e.lines[i].text == cmd && e.lines[i].took == "" {
			e.lines[i].took = took
			return true
		}
	}
	return false
}

// Lines returns the last n lines, oldest first. The lines of each entry come
// after its head, in the order of the heads. A command that ended has its
// time at the end of its line.
func (l *Log) Lines(n int) []Line {
	l.mu.Lock()
	defer l.mu.Unlock()
	var rev []Line
	for i := len(l.entries) - 1; i >= 0 && len(rev) < n; i-- {
		e := l.entries[i]
		for j := len(e.lines) - 1; j >= 0 && len(rev) < n; j-- {
			text := e.lines[j].text
			if took := e.lines[j].took; took != "" {
				text += "  " + took
			}
			rev = append(rev, Line{Text: text})
		}
		if e.head != "" && len(rev) < n {
			rev = append(rev, Line{Head: true, Text: e.head})
		}
	}
	out := make([]Line, len(rev))
	for i, line := range rev {
		out[len(rev)-1-i] = line
	}
	return out
}
