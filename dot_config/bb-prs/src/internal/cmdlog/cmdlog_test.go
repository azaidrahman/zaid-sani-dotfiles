package cmdlog

import (
	"reflect"
	"testing"
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
