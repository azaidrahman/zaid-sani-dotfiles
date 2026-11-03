// Package termtab opens a new tab of the terminal in a directory. It uses Rex
// or tmux, and the picker stays open.
package termtab

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// openTimeout is the time for the command that opens the tab.
const openTimeout = 15 * time.Second

// Opener opens a terminal tab. Env reads an environment variable. Run runs a
// command, and tests replace it. Record, if set, gets each command as
// "<name> <args>" before the command runs.
type Opener struct {
	Env    func(string) string
	Run    func(ctx context.Context, name string, args ...string) error
	Record func(string)
}

// Default runs the command and waits for it. It stops the command when ctx
// ends or after openTimeout. If the command fails, the error holds its output.
func Default(ctx context.Context, name string, args ...string) error {
	ctx, cancel := context.WithTimeout(ctx, openTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, name, args...).CombinedOutput()
	if text := strings.TrimSpace(string(out)); err != nil && text != "" {
		return fmt.Errorf("%w: %s", err, text)
	}
	return err
}

// Open opens a tab in dir. If REX_SESSION is set, the tab is a Rex tab in
// that session, with the label. Else, if TMUX is set, it is a tmux window
// with the name window. Else Open runs no command, and where is empty. When
// Open opens a tab, where names it. The tab runs a shell.
func (o Opener) Open(ctx context.Context, dir, label, window string) (where string, err error) {
	if o.Env == nil {
		return "", nil
	}
	// Rex needs a command. A login shell gives the tab a normal prompt. A
	// tmux window runs the default shell of tmux.
	var argv []string
	if o.Env("REX_SESSION") != "" {
		shell := o.Env("SHELL")
		if shell == "" {
			shell = "/bin/zsh"
		}
		argv = []string{shell, "-l"}
	}
	return o.OpenWith(ctx, dir, label, window, argv)
}

// OpenWith opens a tab in dir that runs the command argv, as Open does. Each
// entry of argv is one argument. No shell reads them.
func (o Opener) OpenWith(ctx context.Context, dir, label, window string, argv []string) (where string, err error) {
	// An opener without Env or Run cannot open a tab. This is not an error.
	if o.Env == nil || o.Run == nil {
		return "", nil
	}
	var name string
	var args []string
	switch session := o.Env("REX_SESSION"); {
	case session != "":
		name, args, where = "rex", append([]string{"run", "-s", session, "-c", dir, "--label", label, "--"}, argv...), "a Rex tab"
	case o.Env("TMUX") != "":
		name, args, where = "tmux", append([]string{"new-window", "-c", dir, "-n", window}, argv...), "a tmux window"
	default:
		return "", nil
	}
	if err := o.run(ctx, name, args); err != nil {
		return "", err
	}
	return where, nil
}

// Jump goes to the tab that is open already: the Rex tab with the label, or
// the tmux window with the name window. If the tab does not exist, ok is
// false, and the caller can open it. If there is no Rex or tmux, Jump runs no
// command, and ok is false. When ok is true, where names the tab.
func (o Opener) Jump(ctx context.Context, label, window string) (where string, ok bool, err error) {
	if o.Env == nil || o.Run == nil {
		return "", false, nil
	}
	var name string
	var args []string
	switch session := o.Env("REX_SESSION"); {
	case session != "":
		name, args, where = "rex", []string{"focus", "-s", session, label}, "a Rex tab"
	case o.Env("TMUX") != "":
		// The "=" makes tmux match the whole name, not the start of it.
		name, args, where = "tmux", []string{"select-window", "-t", "=" + window}, "a tmux window"
	default:
		return "", false, nil
	}
	// A failure means that there is no such tab. This is not an error.
	if o.run(ctx, name, args) != nil {
		return "", false, nil
	}
	return where, true, nil
}

// run records the command, then runs it.
func (o Opener) run(ctx context.Context, name string, args []string) error {
	if o.Record != nil {
		o.Record(name + " " + strings.Join(args, " "))
	}
	return o.Run(ctx, name, args...)
}
