package termtab

import (
	"context"
	"reflect"
	"strings"
	"testing"
)

func TestOpen(t *testing.T) {
	tests := []struct {
		name      string
		env       map[string]string
		wantWhere string
		wantCmd   []string // nil: no command runs
	}{
		{"rex", map[string]string{"REX_SESSION": "s1", "TMUX": "/tmp/tmux,1,0", "SHELL": "/bin/fish"}, "a Rex tab",
			[]string{"rex", "run", "-s", "s1", "-c", "/work", "--label", "PR #7 conflicts", "--", "/bin/fish", "-l"}},
		{"tmux", map[string]string{"TMUX": "/tmp/tmux,1,0"}, "a tmux window",
			[]string{"tmux", "new-window", "-c", "/work", "-n", "pr7"}},
		{"no terminal", nil, "", nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Each call is the name and the arguments, as separate strings.
			var calls [][]string
			var recorded []string
			o := Opener{
				Env: func(k string) string { return tc.env[k] },
				Run: func(_ context.Context, name string, args ...string) error {
					calls = append(calls, append([]string{name}, args...))
					return nil
				},
				Record: func(s string) { recorded = append(recorded, s) },
			}
			where, err := o.Open(context.Background(), "/work", "PR #7 conflicts", "pr7")
			if err != nil {
				t.Fatalf("Open: %v", err)
			}
			if where != tc.wantWhere {
				t.Errorf("where = %q, want %q", where, tc.wantWhere)
			}
			var wantCalls [][]string
			var wantRecorded []string
			if tc.wantCmd != nil {
				wantCalls = [][]string{tc.wantCmd}
				wantRecorded = []string{strings.Join(tc.wantCmd, " ")}
			}
			if !reflect.DeepEqual(calls, wantCalls) {
				t.Errorf("commands = %q, want %q", calls, wantCalls)
			}
			if !reflect.DeepEqual(recorded, wantRecorded) {
				t.Errorf("recorded = %q, want %q", recorded, wantRecorded)
			}
		})
	}
}
