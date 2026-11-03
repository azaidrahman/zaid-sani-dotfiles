// Package gitopstest builds the git repositories that the tests of bb-prs
// use. Only test code imports it.
package gitopstest

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// IsolateConfig gives git a clean configuration. The user configuration signs
// commits and runs hooks, so the tests must not read it. Call it in TestMain
// before m.Run, and call the returned function after m.Run.
func IsolateConfig() (cleanup func()) {
	dir, err := os.MkdirTemp("", "gitops-config")
	if err != nil {
		panic(err)
	}
	cfg := filepath.Join(dir, "gitconfig")
	content := "[user]\n\tname = Test\n\temail = test@example.com\n"
	if err := os.WriteFile(cfg, []byte(content), 0o600); err != nil {
		panic(err)
	}
	os.Setenv("GIT_CONFIG_GLOBAL", cfg)
	os.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	return func() { os.RemoveAll(dir) }
}

// Git runs one git command in dir and fails the test if it fails.
func Git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	out, err := exec.Command("git", append([]string{"-C", dir}, args...)...).CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

// Commit writes a file in dir and commits it.
func Commit(t *testing.T, dir, file, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, file), []byte(text+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	Git(t, dir, "add", file)
	Git(t, dir, "commit", "-qm", text)
}

// Repos builds a bare origin and a clone that fetched it. Origin has main,
// feat and feat2 (one clean commit each), and clash. The branch clash changes
// the same line as main does after the branches fork.
func Repos(t *testing.T) (origin, work string) {
	t.Helper()
	root := t.TempDir()
	origin = filepath.Join(root, "origin.git")
	work = filepath.Join(root, "work")
	Git(t, root, "init", "-q", "--bare", "-b", "main", origin)
	Git(t, root, "clone", "-q", origin, work)
	Commit(t, work, "a.txt", "base")
	Git(t, work, "push", "-q", "origin", "HEAD:main")
	Git(t, work, "checkout", "-q", "-b", "feat")
	Commit(t, work, "b.txt", "feat")
	Git(t, work, "push", "-q", "origin", "feat")
	Git(t, work, "checkout", "-q", "-b", "feat2", "main")
	Commit(t, work, "c.txt", "feat2")
	Git(t, work, "push", "-q", "origin", "feat2")
	Git(t, work, "checkout", "-q", "-b", "clash", "main")
	Commit(t, work, "a.txt", "clash")
	Git(t, work, "push", "-q", "origin", "clash")
	Git(t, work, "checkout", "-q", "main")
	Commit(t, work, "a.txt", "main2")
	Git(t, work, "push", "-q", "origin", "main")
	Git(t, work, "fetch", "-q", "origin")
	return origin, work
}
