// Package cmdlog keeps the lines of the command log. The UI shows them in the
// log panel. Many goroutines can add lines at the same time.
//
// Each head line starts an entry. An entry keeps its own lines, so that two
// actions that run at the same time do not mix their lines.
package cmdlog

import "sync"

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
	lines []string
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
func (e *Entry) Add(line string) {
	if e == nil {
		return
	}
	e.log.mu.Lock()
	defer e.log.mu.Unlock()
	e.lines = append(e.lines, line)
}

// Add adds a line under the last head. Use Entry.Add for the lines of an
// action that can run at the same time as another action.
func (l *Log) Add(line string) {
	l.mu.Lock()
	if len(l.entries) == 0 {
		l.entries = append(l.entries, &Entry{log: l})
	}
	e := l.entries[len(l.entries)-1]
	l.mu.Unlock()
	e.Add(line)
}

// Lines returns the last n lines, oldest first. The lines of each entry come
// after its head, in the order of the heads.
func (l *Log) Lines(n int) []Line {
	l.mu.Lock()
	defer l.mu.Unlock()
	var rev []Line
	for i := len(l.entries) - 1; i >= 0 && len(rev) < n; i-- {
		e := l.entries[i]
		for j := len(e.lines) - 1; j >= 0 && len(rev) < n; j-- {
			rev = append(rev, Line{Text: e.lines[j]})
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
