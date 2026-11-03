package twg

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeTwg writes a shell script that runs body, and returns its path.
func fakeTwg(t *testing.T, dir, body string) string {
	t.Helper()
	path := filepath.Join(dir, "twg")
	script := "#!/bin/sh\n" + body + "\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestJSON(t *testing.T) {
	tests := []struct {
		name    string
		script  func(dir string) string
		timeout time.Duration
		want    string
		wantMsg string
		wantErr string
	}{
		{
			name:   "bare object",
			script: func(string) string { return `printf '%s' '{"items":[]}'` },
			want:   `{"items":[]}`,
		},
		{
			name:   "bare array",
			script: func(string) string { return `printf '%s' '[1]'` },
			want:   `[1]`,
		},
		{
			name: "envelope",
			script: func(dir string) string {
				out := filepath.Join(dir, "out.json")
				if err := os.WriteFile(out, []byte("[2]"), 0o644); err != nil {
					t.Fatal(err)
				}
				return `printf 'ok: true\noutput_files:\n  stdout: "` + out + `"\n'`
			},
			want: `[2]`,
		},
		{
			name: "failure",
			script: func(string) string {
				return `printf 'ok: false\nerror:\n  message: "Bitbucket API error: 429"\n'; exit 1`
			},
			wantMsg: "Bitbucket API error: 429",
		},
		{
			name:    "hang",
			script:  func(string) string { return `sleep 5` },
			timeout: 200 * time.Millisecond,
			wantErr: "timed out",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			var recorded []string
			r := New(func(line string) { recorded = append(recorded, line) })
			r.Bin = fakeTwg(t, dir, tt.script(dir))
			if tt.timeout > 0 {
				r.Timeout = tt.timeout
			}

			start := time.Now()
			got, err := r.JSON(context.Background(), "a", "b")

			if len(recorded) != 1 || recorded[0] != "twg a b -o json" {
				t.Errorf("Record got %q, want [twg a b -o json]", recorded)
			}
			switch {
			case tt.wantErr != "":
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("error = %v, want text %q", err, tt.wantErr)
				}
				if d := time.Since(start); d > time.Second {
					t.Errorf("took %v, want under 1s", d)
				}
			case tt.wantMsg != "":
				var te *Error
				if !errors.As(err, &te) || te.Message != tt.wantMsg {
					t.Fatalf("error = %v, want *Error with message %q", err, tt.wantMsg)
				}
			default:
				if err != nil {
					t.Fatal(err)
				}
				if string(got) != tt.want {
					t.Errorf("got %q, want %q", got, tt.want)
				}
			}
		})
	}
}

func TestText(t *testing.T) {
	tests := []struct {
		name    string
		script  func(dir string) string
		want    string
		wantMsg string
	}{
		{
			name:   "bare diff",
			script: func(string) string { return `printf 'diff --git a/x b/x\n'` },
			want:   "diff --git a/x b/x\n",
		},
		{
			name: "envelope",
			script: func(dir string) string {
				out := filepath.Join(dir, "out.diff")
				if err := os.WriteFile(out, []byte("diff --git a/y b/y\n"), 0o644); err != nil {
					t.Fatal(err)
				}
				return `printf 'ok: true\noutput_files:\n  stdout: "` + out + `"\n'`
			},
			want: "diff --git a/y b/y\n",
		},
		{
			name:    "envelope without a file",
			script:  func(string) string { return `printf 'ok: true\n'` },
			wantMsg: "no output file in the envelope of twg",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			var recorded []string
			r := New(func(line string) { recorded = append(recorded, line) })
			r.Bin = fakeTwg(t, dir, tt.script(dir))

			got, err := r.Text(context.Background(), "a", "b")

			if len(recorded) != 1 || recorded[0] != "twg a b" {
				t.Errorf("Record got %q, want [twg a b]", recorded)
			}
			if tt.wantMsg != "" {
				var te *Error
				if !errors.As(err, &te) || te.Message != tt.wantMsg {
					t.Fatalf("error = %v, want *Error with message %q", err, tt.wantMsg)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if string(got) != tt.want {
				t.Errorf("got %q, want %q", got, tt.want)
			}
		})
	}
}
