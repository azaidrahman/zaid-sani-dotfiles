package cmdlog

import (
	"reflect"
	"testing"
	"time"
)

// The lines of an entry stay under its head, also when a later head exists.
// Lines(n) gives the last n lines.
func TestEntriesKeepTheirLines(t *testing.T) {
	var l Log
	view := l.Begin("Load the details of #11")
	approve := l.Begin("Approve #12")
	view.Add("twg get 11")
	approve.Add("twg approve 12")
	view.Add("twg diffstat 11")

	want := []Line{
		{Text: "twg get 11"},
		{Text: "twg diffstat 11"},
		{Head: true, Text: "Approve #12"},
		{Text: "twg approve 12"},
	}
	if got := l.Lines(4); !reflect.DeepEqual(got, want) {
		t.Errorf("Lines(4) = %+v, want %+v", got, want)
	}
}

// An end line adds no line. It puts the time on the line of its command, in
// the entry of the end line or in an older entry.
func TestEndLines(t *testing.T) {
	var l Log
	view := l.Begin("Load the details of #11")
	view.Add("twg get 11")
	view.Add("twg diffstat 11")
	approve := l.Begin("Approve #12")
	approve.Add("twg approve 12")
	approve.Add(Ended("twg approve 12", 200*time.Millisecond))
	// A runner with the Record func Log.Add: the last entry is not the entry
	// of the command.
	l.Add(Ended("twg get 11", 1300*time.Millisecond))
	// A NUL without a time after it is not an end line.
	approve.Add("twg approve 12\x00not a time")

	want := []Line{
		{Head: true, Text: "Load the details of #11"},
		{Text: "twg get 11  1.3 s"},
		{Text: "twg diffstat 11"},
		{Head: true, Text: "Approve #12"},
		{Text: "twg approve 12  0.2 s"},
		{Text: "twg approve 12\x00not a time"},
	}
	if got := l.Lines(10); !reflect.DeepEqual(got, want) {
		t.Errorf("Lines = %+v, want %+v", got, want)
	}
}
