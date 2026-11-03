package browser

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
)

const (
	prURL     = "https://bitbucket.org/ws/repo/pull-requests/12"
	unsafeURL = "https://bitbucket.org/ws/r'; rm -rf ~"
)

func TestOpen(t *testing.T) {
	sshOpts := "-n -o BatchMode=yes -o ConnectTimeout=4 -a -x -T"
	tests := []struct {
		name      string
		host      string
		force     string
		localIdle int // seconds
		peerIdle  string
		sshFails  bool
		wantHost  string
		wantLast  string
		wantNote  bool
		noSSH     bool
		noIoreg   bool
		url       string // default: prURL
		wantErr   bool   // an unsafe URL: an error, and no command runs
	}{
		{name: "peer is busier", host: "onyx", localIdle: 300, peerIdle: "3",
			wantHost: "aqua", wantLast: "ssh " + sshOpts + " aqua open '" + prURL + "'"},
		{name: "here is busier", host: "onyx", localIdle: 2, peerIdle: "900",
			wantHost: "onyx", wantLast: "open " + prURL},
		{name: "peer unreachable", host: "onyx", localIdle: 300, sshFails: true,
			wantHost: "onyx", wantLast: "open " + prURL, wantNote: true},
		{name: "forced local", host: "onyx", force: "local",
			wantHost: "onyx", wantLast: "open " + prURL, noSSH: true, noIoreg: true},
		{name: "forced peer", host: "aqua", force: "onyx",
			wantHost: "onyx", wantLast: "ssh " + sshOpts + " onyx open '" + prURL + "'", noIoreg: true},
		{name: "no peer", host: "studio",
			wantHost: "studio", wantLast: "open " + prURL, noSSH: true, noIoreg: true},
		{name: "unsafe URL", host: "onyx", url: unsafeURL, wantErr: true},
		{name: "unsafe URL, forced peer", host: "onyx", force: "aqua", url: unsafeURL, wantErr: true},
		{name: "unsafe URL, forced local", host: "onyx", force: "local", url: unsafeURL, wantErr: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var calls []string
			run := func(_ context.Context, name string, args ...string) ([]byte, error) {
				line := name + " " + strings.Join(args, " ")
				calls = append(calls, line)
				switch {
				case name == "ioreg":
					return []byte(fmt.Sprintf("    | \"HIDIdleTime\" = %d\n", tc.localIdle*1_000_000_000)), nil
				case name == "ssh" && tc.sshFails:
					return nil, errors.New("exit status 255")
				case name == "ssh" && strings.Contains(line, "HIDIdleTime"):
					return []byte(tc.peerIdle + "\n"), nil
				}
				return nil, nil
			}
			var recorded []string
			o := Opener{Host: tc.host, Force: tc.force, Run: run,
				Record: func(s string) { recorded = append(recorded, s) }}
			url := tc.url
			if url == "" {
				url = prURL
			}
			host, note, err := o.Open(context.Background(), url)
			if tc.wantErr {
				if err == nil || len(calls) != 0 || len(recorded) != 0 {
					t.Errorf("err = %v, commands = %q, recorded = %q; want an error and no command", err, calls, recorded)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if host != tc.wantHost {
				t.Errorf("host = %q, want %q", host, tc.wantHost)
			}
			if (note != "") != tc.wantNote {
				t.Errorf("note = %q, want a note: %v", note, tc.wantNote)
			}
			if last := calls[len(calls)-1]; last != tc.wantLast {
				t.Errorf("last command = %q, want %q", last, tc.wantLast)
			}
			if got := recorded[len(recorded)-1]; got != tc.wantLast {
				t.Errorf("last recorded line = %q, want %q", got, tc.wantLast)
			}
			for _, c := range calls {
				if tc.noIoreg && strings.HasPrefix(c, "ioreg") {
					t.Errorf("unexpected ioreg call: %q", c)
				}
				if tc.noSSH && strings.HasPrefix(c, "ssh") {
					t.Errorf("unexpected ssh call: %q", c)
				}
			}
		})
	}
}

func TestSafeURL(t *testing.T) {
	tests := []struct {
		url  string
		want bool
	}{
		{prURL, true},
		{"https://bitbucket.org/ws/repo/pull-requests/12#comment-3?a=b&c=d+e%20f", true},
		{"https://bitbucket.org/ws/repo'; rm -rf ~", false},
		{"http://bitbucket.org/ws/r", false},
		{"https://evil.example/ws/r", false},
		{"https://bitbucket.org/ws/r\nid", false},
		{"https://bitbucket.org/ws/r$(id)", false},
		{"https://bitbucket.org/", false},
	}
	for _, tc := range tests {
		if got := SafeURL(tc.url); got != tc.want {
			t.Errorf("SafeURL(%q) = %v, want %v", tc.url, got, tc.want)
		}
	}
}
