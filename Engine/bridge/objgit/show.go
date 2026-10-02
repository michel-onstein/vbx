package objgit

import (
	"bytes"
	"context"
	"io"
	"strings"

	"github.com/go-git/go-git/v5/plumbing/object"
)

// show answers the two forms of `git show` bv's correlation package runs:
//
//   - `show -s --format=<fmt> <rev>`: one commit's header, without its diff;
//   - `show --name-status|--numstat --format= <rev> [-- <pathspec>...]`: one
//     commit's diff and nothing else — the co-commit extractor's per-commit
//     fallback, which the orphan detector reaches for a commit the walk
//     listed no files for (vbx-lh0).
//
// The diff form takes only the empty format, because that is the only one bv
// passes: with a header, git separates it from the diff, and how depends on
// the format.
func (r *repo) show(ctx context.Context, args []string, stdout io.Writer) error {
	var format, rev, diffFormat string
	hasFormat, quiet := false, false
	var pathArgs []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--":
			pathArgs = args[i+1:]
			i = len(args)
		case arg == "-s":
			quiet = true
		case arg == "--name-status", arg == "--numstat":
			// As in git, the last of these wins.
			diffFormat = strings.TrimPrefix(arg, "--")
		case strings.HasPrefix(arg, "--format="):
			format = strings.TrimPrefix(arg, "--format=")
			hasFormat = true
		case strings.HasPrefix(arg, "-"):
			return unsupported("show %s", arg)
		case rev == "":
			rev = arg
		default:
			return unsupported("show with more than one revision")
		}
	}
	if rev == "" || !hasFormat {
		return unsupported("show %s", strings.Join(args, " "))
	}

	if quiet {
		if diffFormat != "" || pathArgs != nil || format == "" {
			return unsupported("show %s", strings.Join(args, " "))
		}
		if err := validateFormat(format); err != nil {
			return err
		}
		c, err := r.showCommit(rev)
		if err != nil {
			return err
		}
		header, err := expand(format, c)
		if err != nil {
			return err
		}
		_, err = io.WriteString(stdout, header+"\n")
		return err
	}

	if diffFormat == "" || format != "" {
		return unsupported("show %s", strings.Join(args, " "))
	}
	ps, err := r.parsePathspec(pathArgs)
	if err != nil {
		return err
	}
	c, err := r.showCommit(rev)
	if err != nil {
		return err
	}
	var buf bytes.Buffer
	if err := r.showDiff(ctx, &buf, c, diffFormat, ps); err != nil {
		return err
	}
	_, err = stdout.Write(buf.Bytes())
	return err
}

// showCommit resolves show's one revision to a commit.
func (r *repo) showCommit(rev string) (*object.Commit, error) {
	h, err := r.resolveCommit(rev)
	if err != nil {
		return nil, err
	}
	c, err := r.git.CommitObject(h)
	if err != nil {
		return nil, fatal("bad object %s", h)
	}
	return c, nil
}

// showDiff writes the diff `git show` prints for a commit under an empty
// format: nothing else, and nothing at all when the diff is empty.
//
// A root commit is diffed against the empty tree (log.showRoot is on by
// default) and any other non-merge against its parent, renames detected as
// diff.renames says — the same diff git log prints. A merge is where show
// differs from log: it shows the combined diff (--diff-merges=cc), which for
// --name-status is combine-diff.c's raw form, and for --numstat is the diff
// against the first parent, because git shows every stat format that way
// even in a combined diff.
func (r *repo) showDiff(ctx context.Context, w *bytes.Buffer, c *object.Commit, diffFormat string, ps *pathspec) error {
	if len(c.ParentHashes) > 1 && diffFormat == "name-status" {
		return r.combinedNameStatus(w, c, ps)
	}
	parent, err := r.firstParent(c)
	if err != nil {
		return err
	}
	pairs, err := r.parentDiff(parent, c, ps)
	if err != nil {
		return err
	}
	return r.formatPairs(w, pairs, diffFormat)
}

// parentDiff is the diff queue from parent (nil for the empty tree) to c
// under ps, with renames detected when diff.renames is on.
func (r *repo) parentDiff(parent, c *object.Commit, ps *pathspec) ([]*pair, error) {
	oldTree, err := treeOf(parent)
	if err != nil {
		return nil, err
	}
	newTree, err := c.Tree()
	if err != nil {
		return nil, err
	}
	pairs, err := r.diffTrees(oldTree, newTree, ps)
	if err != nil {
		return nil, err
	}
	if r.renames {
		return r.detectRenames(pairs, renameOptions{})
	}
	return pairs, nil
}

// combinedNameStatus is combine-diff.c's --name-status for a merge: the
// paths the merge changed relative to every one of its parents — those it
// did not simply take from one side — in the order of the diff against the
// first parent, each printed as one status letter per parent (no rename
// score), a tab and the path.
//
// Each parent's diff is run in full, renames included, and a path is kept
// when it is a destination in all of them (find_paths_generic and
// intersect_paths: rename detection is what forces git onto that generic
// scan).
func (r *repo) combinedNameStatus(w *bytes.Buffer, c *object.Commit, ps *pathspec) error {
	type combined struct {
		path     string
		statuses []byte
	}
	var paths []*combined
	for i, h := range c.ParentHashes {
		parent, err := r.git.CommitObject(h)
		if err != nil {
			return fatal("bad object %s", h)
		}
		pairs, err := r.parentDiff(parent, c, ps)
		if err != nil {
			return err
		}
		if i == 0 {
			for _, p := range pairs {
				paths = append(paths, &combined{path: destPath(p), statuses: []byte{p.status}})
			}
			continue
		}
		status := map[string]byte{}
		for _, p := range pairs {
			status[destPath(p)] = p.status
		}
		kept := paths[:0]
		for _, p := range paths {
			if s, ok := status[p.path]; ok {
				p.statuses = append(p.statuses, s)
				kept = append(kept, p)
			}
		}
		paths = kept
	}
	for _, p := range paths {
		w.Write(p.statuses)
		w.WriteByte('\t')
		w.WriteString(r.quotePathName(p.path))
		w.WriteByte('\n')
	}
	return nil
}

// destPath is the path a diff pair is filed under in a combined diff: its
// new side's (diff_filepair's two->path), which for a deletion is the
// deleted path itself.
func destPath(p *pair) string {
	if p.two.valid() {
		return p.two.path
	}
	return p.one.path
}
