// Package twg runs the twg command line tool and reads its output.
//
// A read command prints the JSON or the text, or prints an envelope. The
// envelope is a short YAML text. Its output_files.stdout line names a file
// that holds the output. A failed command prints an envelope with an error
// message.
package twg

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

// Error is a failure that twg reported.
type Error struct {
	Args    []string
	Message string
}

func (e *Error) Error() string { return e.Message }

// Runner runs twg. Set Bin to use another program, for example in a test.
type Runner struct {
	Bin     string
	Timeout time.Duration
	// Record gets the command line before each call. A caller can also give
	// it a line about a failed call. It can be nil.
	Record func(line string)
}

// New makes a Runner for the twg program. Each call times out after 60 seconds.
func New(record func(string)) *Runner {
	return &Runner{Bin: "twg", Timeout: 60 * time.Second, Record: record}
}

// JSON runs twg with args and "-o json". It returns the JSON from the bare
// output, or from the file that the envelope names.
func (r *Runner) JSON(ctx context.Context, args ...string) ([]byte, error) {
	full := append(append([]string{}, args...), "-o", "json")
	stdout, stderr, err := r.run(ctx, full)
	if err != nil {
		return nil, failure(full, err, stdout, stderr)
	}
	trimmed := bytes.TrimLeft(stdout, " \t\r\n")
	if len(trimmed) > 0 && (trimmed[0] == '{' || trimmed[0] == '[') {
		return stdout, nil
	}
	return outputFile(full, stdout, "no JSON in the output of twg")
}

// Text runs twg with args, without "-o json", and returns the output, for
// example the text of a diff. If the output is an envelope, Text returns the
// file that the envelope names, as JSON does.
func (r *Runner) Text(ctx context.Context, args ...string) ([]byte, error) {
	stdout, stderr, err := r.run(ctx, args)
	if err != nil {
		return nil, failure(args, err, stdout, stderr)
	}
	// An envelope starts with its "ok:" line. A diff starts with "diff".
	if !bytes.HasPrefix(bytes.TrimLeft(stdout, " \t\r\n"), []byte("ok:")) {
		return stdout, nil
	}
	return outputFile(args, stdout, "no output file in the envelope of twg")
}

// outputFile returns the file that the output_files.stdout line of the
// envelope names. If the envelope names no file, the error has the text
// missing.
func outputFile(args []string, envelope []byte, missing string) ([]byte, error) {
	path := envelopeValue(string(envelope), "  stdout: ")
	if path == "" {
		return nil, &Error{Args: args, Message: missing}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, &Error{Args: args, Message: "cannot read the output file of twg: " + err.Error()}
	}
	return data, nil
}

// Do runs twg with args for a write. The output is not used.
func (r *Runner) Do(ctx context.Context, args ...string) error {
	stdout, stderr, err := r.run(ctx, args)
	if err != nil {
		return failure(args, err, stdout, stderr)
	}
	return nil
}

// run starts the program and waits for it. When the timeout passes, it kills
// the program and its children, and returns an error with the text "timed out".
func (r *Runner) run(ctx context.Context, args []string) (stdout, stderr []byte, err error) {
	if r.Record != nil {
		r.Record("twg " + strings.Join(args, " "))
	}
	ctx, cancel := context.WithTimeout(ctx, r.Timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, r.Bin, args...)
	// Put the program in its own process group. A kill then reaches the
	// children too, and they cannot keep the output pipes open.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 500 * time.Millisecond
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut

	err = cmd.Run()
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		err = fmt.Errorf("twg %s: timed out after %s", strings.Join(args, " "), r.Timeout)
	case ctx.Err() != nil:
		err = fmt.Errorf("twg %s: %w", strings.Join(args, " "), ctx.Err())
	}
	return out.Bytes(), errOut.Bytes(), err
}

// failure makes the error for a failed run. A timeout or a start failure
// passes through. A failure that twg reported becomes an *Error.
func failure(args []string, err error, stdout, stderr []byte) error {
	var exit *exec.ExitError
	if !errors.As(err, &exit) {
		return err
	}
	out := string(stdout) + string(stderr)
	msg := envelopeValue(out, "  message: ")
	if msg == "" {
		msg = firstLine(out)
	}
	if msg == "" {
		msg = err.Error()
	}
	return &Error{Args: args, Message: msg}
}

// envelopeValue returns the text after prefix on the first line that starts
// with prefix. It removes one pair of quotes.
func envelopeValue(text, prefix string) string {
	for _, line := range strings.Split(text, "\n") {
		if v, ok := strings.CutPrefix(strings.TrimRight(line, "\r"), prefix); ok {
			v = strings.TrimSpace(v)
			if len(v) >= 2 && v[0] == '"' && v[len(v)-1] == '"' {
				v = v[1 : len(v)-1]
			}
			return v
		}
	}
	return ""
}

func firstLine(text string) string {
	for _, line := range strings.Split(text, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			return line
		}
	}
	return ""
}
