// Package browser opens a pull request URL in the browser of the Mac where
// the user sits. That Mac is this Mac or its peer, reached over Tailscale SSH.
// The method is the same as in the op wrapper (dot_local/shims/executable_op).
package browser

import (
	"context"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// Exec runs one command and returns its standard output.
type Exec func(ctx context.Context, name string, args ...string) ([]byte, error)

// Default is the Exec that runs a real command.
func Default(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).Output()
}

// Opener opens a URL on the right Mac.
type Opener struct {
	// Host is the short name of this Mac, in lower case.
	Host string
	// Force is the value of $BB_PRS_OPEN_HOST: "local", "aqua", "onyx", or "".
	Force string
	// Run runs each command.
	Run Exec
	// Record gets each command line before the command runs. It can be nil.
	Record func(string)
}

// sshOpts are the options for each SSH call to the peer.
var sshOpts = []string{"-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4", "-a", "-x", "-T"}

// idleCmd prints the idle time of the keyboard and mouse, in seconds.
const idleCmd = `ioreg -c IOHIDSystem -d 4 | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'`

// Peer returns the other Mac, or "" if this host has no peer.
func Peer(host string) string {
	switch host {
	case "aqua":
		return "onyx"
	case "onyx":
		return "aqua"
	}
	return ""
}

// SafeURL reports whether u is safe to send to the shell of the peer. The URL
// must start with https://bitbucket.org/ and have only safe characters after it.
func SafeURL(u string) bool {
	const prefix = "https://bitbucket.org/"
	rest, ok := strings.CutPrefix(u, prefix)
	if !ok || rest == "" {
		return false
	}
	for _, r := range rest {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
		case strings.ContainsRune("._~/%#?=&+-", r):
		default:
			return false
		}
	}
	return true
}

// Open opens url. It returns the Mac that opened it. The note is not empty
// when the peer failed and the URL opened here.
func (o Opener) Open(ctx context.Context, url string) (host, note string, err error) {
	if !SafeURL(url) {
		return "", "", fmt.Errorf("refusing to open an unsafe URL: %q", url)
	}
	switch o.Force {
	case "local":
		return o.openLocal(ctx, url, "")
	case "aqua", "onyx":
		if o.Force == o.Host {
			return o.openLocal(ctx, url, "")
		}
		return o.openOn(ctx, o.Force, url)
	}
	peer := Peer(o.Host)
	if peer == "" {
		return o.openLocal(ctx, url, "")
	}
	localIdle, ok := o.localIdle(ctx)
	if !ok {
		return o.openLocal(ctx, url, "")
	}
	peerIdle, ok := o.peerIdle(ctx, peer)
	if !ok {
		return o.openLocal(ctx, url, unreachable(peer))
	}
	if peerIdle < localIdle {
		return o.openOn(ctx, peer, url)
	}
	return o.openLocal(ctx, url, "")
}

func unreachable(peer string) string {
	return "could not reach " + peer + ", opened here"
}

func (o Opener) run(ctx context.Context, name string, args ...string) ([]byte, error) {
	if o.Record != nil {
		o.Record(strings.TrimSpace(name + " " + strings.Join(args, " ")))
	}
	return o.Run(ctx, name, args...)
}

func (o Opener) openLocal(ctx context.Context, url, note string) (string, string, error) {
	if _, err := o.run(ctx, "open", url); err != nil {
		return "", "", fmt.Errorf("open: %w", err)
	}
	return o.Host, note, nil
}

// openOn opens url on the peer. If SSH fails, it opens url here.
func (o Opener) openOn(ctx context.Context, peer, url string) (string, string, error) {
	// SafeURL ran before, so the single quotes are enough for the peer shell.
	args := append(append([]string{}, sshOpts...), peer, "open '"+url+"'")
	if _, err := o.run(ctx, "ssh", args...); err != nil {
		return o.openLocal(ctx, url, unreachable(peer))
	}
	return peer, "", nil
}

// localIdle returns the idle time of this Mac, in seconds.
func (o Opener) localIdle(ctx context.Context) (int64, bool) { return LocalIdle(ctx, o.run) }

// LocalIdle returns the time since the last key or mouse event on this Mac,
// in seconds. It reads HIDIdleTime from ioreg, with run. It is false if ioreg
// fails or does not tell the time.
func LocalIdle(ctx context.Context, run Exec) (int64, bool) {
	out, err := run(ctx, "ioreg", "-c", "IOHIDSystem", "-d", "4")
	if err != nil {
		return 0, false
	}
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.Contains(line, "HIDIdleTime") {
			continue
		}
		f := strings.Fields(line)
		ns, err := strconv.ParseInt(f[len(f)-1], 10, 64)
		if err != nil {
			return 0, false
		}
		return ns / 1_000_000_000, true
	}
	return 0, false
}

// peerIdle returns the idle time of the peer, in seconds.
func (o Opener) peerIdle(ctx context.Context, peer string) (int64, bool) {
	args := append(append([]string{}, sshOpts...), peer, idleCmd)
	out, err := o.run(ctx, "ssh", args...)
	if err != nil {
		return 0, false
	}
	secs, err := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	return secs, err == nil
}
