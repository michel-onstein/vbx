// Package objgit answers a fixed set of git command lines from the object
// store, through go-git, with the bytes git itself would print.
//
// It exists for one caller. bv's correlation package reads history by running
// `git` — log, cat-file, rev-parse, show — and parsing what comes back. The
// App Sandbox cannot spawn that binary (ADR-006), so vbx's copy of the
// package (Engine/bridge/correlation, ADR-027) hands each command line here
// instead, and bv's own parsers read the result exactly as they would read
// git's. Matching git byte for byte is the whole contract: the parsers were
// written against git's output, and a difference in a separator, an ordering
// or a rename decision changes a report without failing anything.
//
// Only the invocations that package makes are understood. Anything else is
// refused with an error naming the argument, never approximated — an
// unsupported flag silently ignored would be a wrong answer that looks like a
// right one. The tests run every supported form against real git on the same
// repository and compare the bytes.
package objgit

import (
	"context"
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"github.com/go-git/go-git/v5"
)

// ExitError is a failed invocation: git's exit status and what it would have
// written to stderr.
type ExitError struct {
	Code   int
	Stderr string
}

func (e *ExitError) Error() string {
	return fmt.Sprintf("exit status %d: %s", e.Code, strings.TrimSpace(e.Stderr))
}

// fatal is git's own failure: status 128 with a "fatal:" line.
func fatal(format string, args ...any) error {
	return &ExitError{Code: 128, Stderr: "fatal: " + fmt.Sprintf(format, args...) + "\n"}
}

// unsupported refuses an invocation this package does not emulate. Status 129
// is git's for a usage error, and the message says it is vbx's refusal rather
// than git's, so nobody goes looking for a git bug.
func unsupported(format string, args ...any) error {
	return &ExitError{Code: 129, Stderr: "vbx objgit: unsupported git invocation: " +
		fmt.Sprintf(format, args...) + "\n"}
}

// Run executes one git command line, as `git <args>` would run in dir,
// reading stdin and writing stdout.
func Run(ctx context.Context, dir string, args []string, stdin io.Reader, stdout io.Writer) error {
	if ctx == nil {
		ctx = context.Background()
	}
	args, err := stripConfig(args)
	if err != nil {
		return err
	}
	if len(args) == 0 {
		return unsupported("no command")
	}
	r, err := open(dir)
	if err != nil {
		return err
	}
	switch args[0] {
	case "log":
		return r.log(ctx, args[1:], stdout)
	case "show":
		return r.show(ctx, args[1:], stdout)
	case "rev-parse":
		return r.revParse(args[1:], stdout)
	case "cat-file":
		return r.catFile(ctx, args[1:], stdin, stdout)
	default:
		return unsupported("git %s", args[0])
	}
}

// stripConfig removes leading `-c key=value` pairs. Only the one bv passes —
// color.ui=false, which keeps colour codes out of output vbx never colours —
// is accepted.
func stripConfig(args []string) ([]string, error) {
	for len(args) >= 2 && args[0] == "-c" {
		if args[1] != "color.ui=false" {
			return nil, unsupported("-c %s", args[1])
		}
		args = args[2:]
	}
	return args, nil
}

// repo is one opened repository and the directory the command runs in.
type repo struct {
	git *git.Repository
	// prefix is the working directory relative to the worktree root,
	// slash-separated, "" at the root. Pathspecs are relative to it, as git's
	// are relative to the process's directory.
	prefix string
	// quotePath is core.quotePath: whether bytes above 0x7f are escaped in
	// printed paths. On by default, as in git.
	quotePath bool
	// renames is diff.renames: rename detection in log's diffs. On by
	// default since git 2.9.
	renames bool
}

func open(dir string) (*repo, error) {
	// EnableDotGitCommonDir makes a linked worktree work: its refs, HEAD's
	// target included, live in the common directory.
	g, err := git.PlainOpenWithOptions(dir, &git.PlainOpenOptions{
		DetectDotGit:          true,
		EnableDotGitCommonDir: true,
	})
	if err != nil {
		return nil, fatal("not a git repository (or any of the parent directories): .git")
	}
	r := &repo{git: g, quotePath: true, renames: true}

	if wt, err := g.Worktree(); err == nil {
		root := resolve(wt.Filesystem.Root())
		if rel, err := filepath.Rel(root, resolve(dir)); err == nil && rel != "." &&
			!strings.HasPrefix(rel, "..") {
			r.prefix = filepath.ToSlash(rel)
		}
	}

	if cfg, err := g.Config(); err == nil && cfg.Raw != nil {
		core := cfg.Raw.Section("core")
		if v := core.Option("quotepath"); v != "" {
			r.quotePath = gitBool(v, true)
		}
		diff := cfg.Raw.Section("diff")
		if v := diff.Option("renames"); v != "" {
			r.renames = gitBool(v, true)
		}
	}
	return r, nil
}

// resolve follows symlinks — /tmp and every temporary directory on macOS is
// one — falling back to the path itself.
func resolve(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	return path
}

// gitBool reads a git boolean. Anything that is not a recognised false is
// true, as `diff.renames = copies` is a true value for rename detection.
func gitBool(v string, fallback bool) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "false", "no", "off", "0":
		return false
	case "true", "yes", "on", "1", "copy", "copies":
		return true
	}
	return fallback
}
