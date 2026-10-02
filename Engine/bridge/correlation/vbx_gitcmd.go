// vbx's replacement for bv's gitcmd.go — the only file of this package not
// copied from bv (scripts/vendor-correlation.py, ADR-027).
//
// bv's gitCommand returns an exec.Cmd that runs the git binary. This one
// returns a gitCmd with the same surface the package uses — Dir, Output,
// StdoutPipe, StdinPipe, Start, Wait and Process.Kill — that answers the
// command line in-process from the object store (package objgit). No process
// is ever started, which is what lets the App Sandbox run bv's correlator.

package correlation

import (
	"bytes"
	"context"
	"errors"
	"io"
	"sync"

	"github.com/qjam/vbx/engine/objgit"
)

// GitRunner answers one git command line: objgit.Run's signature.
type GitRunner func(ctx context.Context, dir string, args []string, stdin io.Reader, stdout io.Writer) error

// gitRunner is what every gitCmd runs. Tests swap it to compare each
// invocation against real git; nothing else should.
var gitRunner GitRunner = objgit.Run

// SetGitRunner replaces the runner and returns a function restoring the
// previous one. For tests only: the package's history is answered by
// objgit everywhere else.
func SetGitRunner(r GitRunner) (restore func()) {
	previous := gitRunner
	gitRunner = r
	return func() { gitRunner = previous }
}

// errKilled is what a killed command's Wait reports.
var errKilled = errors.New("git command killed")

// gitCmd is one git invocation, run in-process.
type gitCmd struct {
	ctx  context.Context
	args []string
	// Dir is the directory the command runs in, as exec.Cmd's.
	Dir string
	// Process is non-nil from creation, so the package's Kill calls work at
	// any point.
	Process *gitProcess

	cancel  context.CancelFunc
	stdin   *io.PipeReader
	stdout  *io.PipeWriter
	reader  *io.PipeReader
	done    chan error
	once    sync.Once
	waitErr error
}

// gitProcess stands in for os.Process: Kill is all the package calls.
type gitProcess struct {
	cmd *gitCmd
}

// Kill stops the command: its context is cancelled and its pipes closed, so
// a runner blocked reading stdin or writing stdout returns.
func (p *gitProcess) Kill() error {
	c := p.cmd
	if c.cancel != nil {
		c.cancel()
	}
	if c.reader != nil {
		_ = c.reader.CloseWithError(errKilled)
	}
	if c.stdin != nil {
		_ = c.stdin.CloseWithError(errKilled)
	}
	return nil
}

// gitCommand is bv's constructor, kept by name: a nil ctx means
// context.Background(), as in bv.
func gitCommand(ctx context.Context, args ...string) *gitCmd {
	if ctx == nil {
		ctx = context.Background()
	}
	c := &gitCmd{ctx: ctx, args: args}
	c.Process = &gitProcess{cmd: c}
	return c
}

// Output runs the command and returns what it printed.
func (c *gitCmd) Output() ([]byte, error) {
	var out bytes.Buffer
	err := gitRunner(c.ctx, c.Dir, c.args, nil, &out)
	return out.Bytes(), err
}

// StdinPipe returns the writer the command reads as its stdin.
func (c *gitCmd) StdinPipe() (io.WriteCloser, error) {
	r, w := io.Pipe()
	c.stdin = r
	return w, nil
}

// StdoutPipe returns the reader the command's output arrives on. As with
// exec.Cmd, it reaches EOF when the command finishes.
func (c *gitCmd) StdoutPipe() (io.ReadCloser, error) {
	r, w := io.Pipe()
	c.stdout, c.reader = w, r
	return r, nil
}

// Start runs the command in the background.
func (c *gitCmd) Start() error {
	ctx, cancel := context.WithCancel(c.ctx)
	c.cancel = cancel
	c.done = make(chan error, 1)
	var stdin io.Reader
	if c.stdin != nil {
		stdin = c.stdin
	}
	var stdout io.Writer = io.Discard
	if c.stdout != nil {
		stdout = c.stdout
	}
	go func() {
		err := gitRunner(ctx, c.Dir, c.args, stdin, stdout)
		if c.stdout != nil {
			// EOF either way, as a process's pipe gives; the error is
			// Wait's to report.
			_ = c.stdout.Close()
		}
		if c.stdin != nil {
			// Unblock a writer feeding a command that has stopped reading.
			_ = c.stdin.CloseWithError(io.ErrClosedPipe)
		}
		c.done <- err
	}()
	return nil
}

// Wait waits for a started command and returns its error.
func (c *gitCmd) Wait() error {
	c.once.Do(func() {
		if c.done == nil {
			c.waitErr = errors.New("git command not started")
			return
		}
		c.waitErr = <-c.done
		if c.cancel != nil {
			c.cancel()
		}
	})
	return c.waitErr
}
