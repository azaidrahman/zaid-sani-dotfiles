package termtab

import (
	"context"
	"errors"
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

// Jump goes to a tab that is open. If there is none, OpenWith opens it and
// runs the command argv, one entry for each argument.
func TestJumpOrOpen(t *testing.T) {
	argv := []string{"claude", "--resume", "s-1"}
	const label, window = "review repo#7", "review-repo-7"
	rexEnv := map[string]string{"REX_SESSION": "s1", "TMUX": "/tmp/tmux,1,0"}
	tmuxEnv := map[string]string{"TMUX": "/tmp/tmux,1,0"}
	rexFocus := []string{"rex", "focus", "-s", "s1", label}
	rexRun := []string{"rex", "run", "-s", "s1", "-c", "/work", "--label", label, "--", "claude", "--resume", "s-1"}
	tmuxSelect := []string{"tmux", "select-window", "-t", "=" + window}
	tmuxNew := []string{"tmux", "new-window", "-c", "/work", "-n", window, "claude", "--resume", "s-1"}
	tests := []struct {
		name       string
		env        map[string]string
		failFocus  bool // the command that selects the tab fails
		wantJumped string
		wantOpened string
		wantCmds   [][]string
	}{
		{"rex jump ok", rexEnv, false, "a Rex tab", "", [][]string{rexFocus}},
		{"rex jump fails, run with the resume argv", rexEnv, true, "", "a Rex tab", [][]string{rexFocus, rexRun}},
		{"tmux select ok", tmuxEnv, false, "a tmux window", "", [][]string{tmuxSelect}},
		{"tmux select fails, new-window", tmuxEnv, true, "", "a tmux window", [][]string{tmuxSelect, tmuxNew}},
		{"neither", nil, false, "", "", nil},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var calls [][]string
			o := Opener{
				Env: func(k string) string { return tc.env[k] },
				Run: func(_ context.Context, name string, args ...string) error {
					calls = append(calls, append([]string{name}, args...))
					if tc.failFocus && (args[0] == "focus" || args[0] == "select-window") {
						return errors.New("no such tab")
					}
					return nil
				},
			}
			where, ok, err := o.Jump(context.Background(), label, window)
			if err != nil || ok != (tc.wantJumped != "") || where != tc.wantJumped {
				t.Fatalf("Jump = %q, %v, %v; want %q", where, ok, err, tc.wantJumped)
			}
			if !ok {
				if where, err = o.OpenWith(context.Background(), "/work", label, window, argv); err != nil || where != tc.wantOpened {
					t.Fatalf("OpenWith = %q, %v; want %q", where, err, tc.wantOpened)
				}
			}
			if !reflect.DeepEqual(calls, tc.wantCmds) {
				t.Errorf("commands = %q, want %q", calls, tc.wantCmds)
			}
		})
	}
}
