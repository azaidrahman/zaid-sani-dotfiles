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
// Open opens a tab, where names it.
func (o Opener) Open(ctx context.Context, dir, label, window string) (where string, err error) {
	// An opener without Env or Run cannot open a tab. This is not an error.
	if o.Env == nil || o.Run == nil {
		return "", nil
	}
	var name string
	var args []string
	switch session := o.Env("REX_SESSION"); {
	case session != "":
		// Rex needs a command. A login shell gives the tab a normal prompt.
		shell := o.Env("SHELL")
		if shell == "" {
			shell = "/bin/zsh"
		}
		name, args, where = "rex", []string{"run", "-s", session, "-c", dir, "--label", label, "--", shell, "-l"}, "a Rex tab"
	case o.Env("TMUX") != "":
		name, args, where = "tmux", []string{"new-window", "-c", dir, "-n", window}, "a tmux window"
	default:
		return "", nil
	}
	if o.Record != nil {
		o.Record(name + " " + strings.Join(args, " "))
	}
	if err := o.Run(ctx, name, args...); err != nil {
		return "", err
	}
	return where, nil
}
