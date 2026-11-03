// Package gitops runs the git commands of the PR picker: fetch, count how far
// a branch is behind, and update a branch with a rebase or a merge.
package gitops

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Git runs git commands in the checkout Dir. Record, if set, gets each
// command as "git <args>" before the command runs.
type Git struct {
	Dir    string
	Record func(string)
}

// SyncResult is the outcome of Sync and SyncMerge.
type SyncResult int

const (
	// Synced means the updated branch is pushed.
	Synced SyncResult = iota
	// Conflict means the rebase or the merge stopped on a conflict. The
	// branch is unchanged.
	Conflict
	// Failed means the rebase, the merge, or the push failed for another
	// reason.
	Failed
)

// command makes a git command for dir. It puts git in its own process group.
// When ctx ends, the kill then reaches the children of git, for example ssh.
// WaitDelay stops the wait for a child that keeps the output pipe open.
// GIT_TERMINAL_PROMPT=0 makes git fail, not ask for a password. The screen
// owns the terminal, so a prompt stops git until the kill.
func command(ctx context.Context, dir string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 500 * time.Millisecond
	return cmd
}

// Toplevel returns the root directory of the checkout that holds dir.
func Toplevel(dir string) (string, error) {
	out, err := command(context.Background(), dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// OriginURL returns the URL of the origin remote. It returns an empty string
// if there is no origin.
func OriginURL(dir string) string {
	out, err := command(context.Background(), dir, "remote", "get-url", "origin").Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// run records and runs one git command in dir. It returns the combined output.
func (g Git) run(ctx context.Context, dir string, args ...string) (string, error) {
	if g.Record != nil {
		g.Record("git " + strings.Join(args, " "))
	}
	out, err := command(ctx, dir, args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// Run records and runs "git <args>" in Dir. It returns the combined output.
// Use it for a command that has no method of its own.
func (g Git) Run(ctx context.Context, args ...string) (string, error) {
	return g.run(ctx, g.Dir, args...)
}

// Fetch updates the remote branches from origin. It stops after 60 seconds,
// for example if git waits for a password or the network is down.
func (g Git) Fetch(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	_, err := g.run(ctx, g.Dir, "fetch", "-q", "origin")
	return err
}

// Behind counts the commits that origin/dst has and origin/src does not have.
// If one of the two branches is missing, ok is false. It does not record the
// command, because the list load calls it for each pull request.
func (g Git) Behind(src, dst string) (n int, ok bool) {
	rng := "refs/remotes/origin/" + src + "..refs/remotes/origin/" + dst
	out, err := command(context.Background(), g.Dir, "rev-list", "--count", rng).Output()
	if err != nil {
		return 0, false
	}
	n, err = strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil {
		return 0, false
	}
	return n, true
}

// ErrNoCommit means that the checkout does not have the commit. For example,
// the last fetch was before the push of the commit.
var ErrNoCommit = errors.New("the checkout does not have this commit")

// errBadHash means that a text is not a full commit hash.
var errBadHash = errors.New("not a full commit hash")

// Show returns the patch of the commit hash: the output of "git show" in Dir.
// A merge commit shows the changes that it brought to its first parent. The
// options keep the patch in the format of bb.ParseDiff, also when the git
// config of the user sets an external diff, a textconv filter, or other
// prefixes. The hash must be a full hash (IsFullHash), so that it cannot be
// an option of git or a ref. Else Show runs nothing. If the checkout does not
// have the commit, the error is ErrNoCommit. Then Show also records the check.
func (g Git) Show(ctx context.Context, hash string) ([]byte, error) {
	if !IsFullHash(hash) {
		return nil, fmt.Errorf("%w: %q", errBadHash, hash)
	}
	args := []string{"show", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
		"--format=", "--patch", "--diff-merges=first-parent", hash}
	if g.Record != nil {
		g.Record("git " + strings.Join(args, " "))
	}
	out, err := command(ctx, g.Dir, args...).Output()
	if err == nil {
		return out, nil
	}
	var stderr string
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		stderr = strings.TrimSpace(string(exit.Stderr))
	}
	// The text of the error of git depends on the language. Thus ask git if
	// the commit is there.
	if ctx.Err() == nil {
		if _, cerr := g.run(ctx, g.Dir, "cat-file", "-e", hash+"^{commit}"); cerr != nil {
			return nil, ErrNoCommit
		}
	}
	return nil, fmt.Errorf("git show failed: %s", firstLines(stderr, err))
}

// IsFullHash reports whether s is a full commit hash: 40 hexadecimal digits
// (SHA-1), or 64 (SHA-256).
func IsFullHash(s string) bool {
	if len(s) != 40 && len(s) != 64 {
		return false
	}
	for _, r := range s {
		if !strings.ContainsRune("0123456789abcdefABCDEF", r) {
			return false
		}
	}
	return true
}

// Conflicts lists the files that conflict when origin/src merges into
// origin/dst. If the merge is clean, the list is empty. It uses merge-tree,
// which merges in memory. It does not change the index, HEAD, or the working
// tree. Run Fetch first, so that the two branches are current.
func (g Git) Conflicts(ctx context.Context, src, dst string) ([]string, error) {
	args := []string{"merge-tree", "-z", "--write-tree", "--name-only", "--no-messages",
		"refs/remotes/origin/" + dst, "refs/remotes/origin/" + src}
	if g.Record != nil {
		g.Record("git " + strings.Join(args, " "))
	}
	out, err := command(ctx, g.Dir, args...).Output()
	if err == nil {
		return nil, nil
	}
	// Exit 1 means conflicts. With -z, a NUL ends each name. The first name
	// is the id of the merged tree. The names after it are the conflicted
	// files, and git does not quote them.
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 1 {
		var stderr []byte
		if exit != nil {
			stderr = exit.Stderr
		}
		return nil, fmt.Errorf("git merge-tree failed: %s", firstLines(strings.TrimSpace(string(stderr)), err))
	}
	var files []string
	for i, name := range strings.Split(string(out), "\x00") {
		if i > 0 && name != "" {
			files = append(files, name)
		}
	}
	if len(files) == 0 {
		return nil, errors.New("git merge-tree reported conflicts, but named no file")
	}
	return files, nil
}

// inWorktree runs fn in a temporary detached worktree at origin/src. It gives
// fn the directory of the worktree and the commit of origin/src. It always
// removes the worktree, also if ctx is cancelled.
func (g Git) inWorktree(ctx context.Context, src string, fn func(wt, old string) (SyncResult, string)) (SyncResult, string) {
	old, err := g.run(ctx, g.Dir, "rev-parse", "--verify", "-q", "refs/remotes/origin/"+src+"^{commit}")
	if err != nil {
		return Failed, "origin/" + src + " not found"
	}
	tmp, err := os.MkdirTemp("", "bb-prs-sync")
	if err != nil {
		return Failed, err.Error()
	}
	defer os.RemoveAll(tmp)
	wt := filepath.Join(tmp, "wt")
	if out, err := g.run(ctx, g.Dir, "worktree", "add", "-q", "--detach", wt, old); err != nil {
		return Failed, firstLines(out, err)
	}
	// Remove the worktree also if ctx is cancelled.
	defer g.run(context.Background(), g.Dir, "worktree", "remove", "--force", wt)
	return fn(wt, old)
}

// Sync rebases origin/src onto origin/dst in a temporary worktree, then force
// pushes the result to src. The lease is the commit that the last fetch saw.
// Thus a push to src after the fetch makes Sync fail and loses nothing. On a
// conflict, the branch does not change. On Failed, the string holds the first
// lines of the error.
func (g Git) Sync(ctx context.Context, src, dst string) (SyncResult, string) {
	return g.inWorktree(ctx, src, func(wt, old string) (SyncResult, string) {
		if out, err := g.run(ctx, wt, "rebase", "-q", "refs/remotes/origin/"+dst); err != nil {
			// A rebase can fail for a reason that is not a conflict, for
			// example the signing of a commit. Then show the error.
			files, _ := g.run(ctx, wt, "diff", "--name-only", "--diff-filter=U")
			g.run(context.Background(), wt, "rebase", "--abort")
			if files != "" {
				return Conflict, ""
			}
			return Failed, firstLines(out, err)
		}
		lease := "--force-with-lease=refs/heads/" + src + ":" + old
		if out, err := g.run(ctx, wt, "push", "-q", lease, "origin", "HEAD:refs/heads/"+src); err != nil {
			return Failed, firstLines(out, err)
		}
		return Synced, ""
	})
}

// SyncMerge merges origin/dst into origin/src in a temporary worktree, then
// pushes the merge commit to src. The old head of src is the first parent of
// the merge commit, so the push rewrites nothing. The push has no force. Thus
// a push to src after the fetch makes the push fail, and src keeps the commit
// of the other person. On a conflict, the branch does not change. On Failed,
// the string holds the first lines of the error.
func (g Git) SyncMerge(ctx context.Context, src, dst string) (SyncResult, string) {
	return g.inWorktree(ctx, src, func(wt, _ string) (SyncResult, string) {
		text := "Merge " + dst + " into " + src
		if out, err := g.run(ctx, wt, "merge", "--no-ff", "--no-edit", "-m", text, "refs/remotes/origin/"+dst); err != nil {
			// A merge can fail for a reason that is not a conflict, for
			// example the signing of the commit. Then show the error.
			files, _ := g.run(ctx, wt, "diff", "--name-only", "--diff-filter=U")
			g.run(context.Background(), wt, "merge", "--abort")
			if files != "" {
				return Conflict, ""
			}
			return Failed, firstLines(out, err)
		}
		if out, err := g.run(ctx, wt, "push", "-q", "origin", "HEAD:refs/heads/"+src); err != nil {
			return Failed, firstLines(out, err)
		}
		return Synced, ""
	})
}

// firstLines returns the first 5 lines of out. If out is empty, it returns
// the text of err.
func firstLines(out string, err error) string {
	if out == "" {
		return err.Error()
	}
	lines := strings.Split(out, "\n")
	if len(lines) > 5 {
		lines = lines[:5]
	}
	return strings.Join(lines, "\n")
}
