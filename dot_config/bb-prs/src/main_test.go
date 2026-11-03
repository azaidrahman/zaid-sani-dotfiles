package main

import (
	"os"
	"path/filepath"
	"testing"

	"bbprs/internal/gitops/gitopstest"
	"bbprs/internal/store"
)

func TestMain(m *testing.M) {
	cleanup := gitopstest.IsolateConfig()
	code := m.Run()
	cleanup()
	os.Exit(code)
}

func TestSetup(t *testing.T) {
	tests := []struct {
		name     string
		origin   string // the origin remote. Empty makes a plain directory.
		env      map[string]string
		wantRepo string
		wantWS   string
		wantErr  string
		wantFile string // the content of the workspace file
	}{
		{
			name: "Bitbucket repo", origin: "git@bitbucket.org:ws/cur.git",
			wantRepo: "ws/cur", wantWS: "ws", wantFile: "ws\n",
		},
		{
			name: "plain directory with BB_WORKSPACE", env: map[string]string{"BB_WORKSPACE": "ws2"},
			wantWS: "ws2",
		},
		{
			name:    "plain directory, no workspace",
			wantErr: "no workspace. Run bb-prs in a Bitbucket repo one time, or set BB_WORKSPACE.",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			if tt.origin != "" {
				gitopstest.Git(t, dir, "init", "-q")
				gitopstest.Git(t, dir, "remote", "add", "origin", tt.origin)
			}
			paths := store.Paths{Cache: t.TempDir(), State: t.TempDir()}
			env, err := setup(dir, paths, func(k string) string { return tt.env[k] })
			if tt.wantErr != "" {
				if err == nil || err.Error() != tt.wantErr {
					t.Fatalf("error = %v, want %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if env.Repo != tt.wantRepo || env.WS != tt.wantWS {
				t.Errorf("Repo, WS = %q, %q, want %q, %q", env.Repo, env.WS, tt.wantRepo, tt.wantWS)
			}
			wantPrompt := tt.wantRepo
			if wantPrompt == "" {
				wantPrompt = tt.wantWS
			}
			if env.Prompt != wantPrompt {
				t.Errorf("Prompt = %q, want %q", env.Prompt, wantPrompt)
			}
			if (env.Dir != "") != (tt.wantRepo != "") {
				t.Errorf("Dir = %q for repo %q", env.Dir, tt.wantRepo)
			}
			got, _ := os.ReadFile(filepath.Join(paths.State, "workspace"))
			if string(got) != tt.wantFile {
				t.Errorf("workspace file = %q, want %q", got, tt.wantFile)
			}
		})
	}
}
