package objgit

import (
	"bytes"
	"context"
	"io"
	"strconv"
	"strings"

	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"
)

// logRequest is a parsed `git log` command line.
type logRequest struct {
	walk         walkOptions
	format       string
	diffFormat   string // "", name-only, name-status, numstat, raw
	diffMerges   bool   // --diff-merges=first-parent: diff a merge against its first parent
	follow       bool
	limit        int // -n; -1 for none
	paths        *pathspec
	followedPath string
}

func (r *repo) parseLog(args []string) (*logRequest, error) {
	req := &logRequest{limit: -1}
	var revisions []string
	var pathArgs []string
	noAbbrev := false
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--":
			pathArgs = args[i+1:]
			i = len(args)
		case arg == "--no-merges":
			req.walk.noMerges = true
		case arg == "--first-parent":
			req.walk.firstParent = true
		case arg == "--diff-merges=first-parent":
			req.diffMerges = true
		case arg == "--name-only", arg == "--name-status", arg == "--numstat", arg == "--raw":
			// As in git, the last of these wins.
			req.diffFormat = strings.TrimPrefix(arg, "--")
		case arg == "--no-abbrev":
			noAbbrev = true
		case arg == "--follow":
			req.follow = true
		case arg == "--no-walk=unsorted":
			req.walk.noWalk = true
		case strings.HasPrefix(arg, "--format="):
			req.format = strings.TrimPrefix(arg, "--format=")
		case strings.HasPrefix(arg, "--since="):
			t, err := parseTime(strings.TrimPrefix(arg, "--since="))
			if err != nil {
				return nil, err
			}
			req.walk.since = &t
		case strings.HasPrefix(arg, "--until="):
			t, err := parseTime(strings.TrimPrefix(arg, "--until="))
			if err != nil {
				return nil, err
			}
			req.walk.until = &t
		case strings.HasPrefix(arg, "-n") && len(arg) > 2:
			n, err := strconv.Atoi(arg[2:])
			if err != nil || n < 0 {
				return nil, unsupported("log %s", arg)
			}
			req.limit = n
		case strings.HasPrefix(arg, "-"):
			return nil, unsupported("log %s", arg)
		default:
			revisions = append(revisions, arg)
		}
	}
	if req.format == "" {
		return nil, unsupported("log without --format")
	}
	if err := validateFormat(req.format); err != nil {
		return nil, err
	}
	if req.diffFormat == "raw" && !noAbbrev {
		return nil, unsupported("log --raw without --no-abbrev")
	}

	ps, err := r.parsePathspec(pathArgs)
	if err != nil {
		return nil, err
	}
	req.paths = ps
	if req.follow {
		if ps == nil || len(ps.include) != 1 || len(ps.exclude) != 0 || ps.include[0] == "" {
			return nil, fatal("--follow requires exactly one pathspec")
		}
		req.followedPath = ps.include[0]
	} else if ps != nil && !req.walk.noWalk {
		// A walk limited by a path simplifies history around merges; bv
		// never asks for one, so it is not emulated.
		return nil, unsupported("log with a pathspec but neither --follow nor --no-walk")
	}

	if len(revisions) == 0 {
		if req.walk.noWalk {
			return nil, unsupported("log --no-walk without revisions")
		}
		revisions = []string{"HEAD"}
	}
	for _, rev := range revisions {
		h, err := r.resolveCommit(rev)
		if err != nil {
			return nil, err
		}
		req.walk.starts = append(req.walk.starts, h)
	}
	return req, nil
}

// resolveCommit turns a revision into a commit hash, failing as git log
// does on one it cannot resolve.
func (r *repo) resolveCommit(rev string) (plumbing.Hash, error) {
	h, err := r.git.ResolveRevision(plumbing.Revision(rev))
	if err != nil {
		if rev == "HEAD" {
			return plumbing.ZeroHash, fatal("your current branch does not have any commits yet")
		}
		return plumbing.ZeroHash, fatal("bad revision '%s'", rev)
	}
	if _, err := r.git.CommitObject(*h); err != nil {
		return plumbing.ZeroHash, fatal("bad revision '%s'", rev)
	}
	return *h, nil
}

func (r *repo) log(ctx context.Context, args []string, stdout io.Writer) error {
	req, err := r.parseLog(args)
	if err != nil {
		return err
	}
	if req.limit == 0 {
		return nil
	}

	var buf bytes.Buffer
	shown := 0
	err = r.walk(ctx, req.walk, func(c *object.Commit) (bool, error) {
		pairs, err := r.commitDiff(ctx, req, c)
		if err != nil {
			return false, err
		}
		if req.paths != nil && !req.follow && len(c.ParentHashes) > 1 {
			// A merge under a pathspec is shown unless, on those paths, it
			// is the same as one of its parents (TREESAME) — and then
			// without a diff, as for any merge.
			same, err := r.treesameToAParent(c, req.paths)
			if err != nil {
				return false, err
			}
			if same {
				return true, nil
			}
		} else if req.paths != nil && len(pairs) == 0 {
			// Limited to paths it does not touch: not shown at all.
			return true, nil
		}

		header, err := expand(req.format, c)
		if err != nil {
			return false, err
		}
		buf.Reset()
		buf.WriteString(header)
		buf.WriteByte('\n')
		if len(pairs) > 0 {
			buf.WriteByte('\n')
			if err := r.formatPairs(&buf, pairs, req.diffFormat); err != nil {
				return false, err
			}
		}
		if _, err := stdout.Write(buf.Bytes()); err != nil {
			return false, err
		}
		shown++
		return req.limit < 0 || shown < req.limit, nil
	})
	return err
}

// treesameToAParent reports whether a commit's tree, limited to ps, equals
// that of any of its parents.
func (r *repo) treesameToAParent(c *object.Commit, ps *pathspec) (bool, error) {
	tree, err := c.Tree()
	if err != nil {
		return false, err
	}
	for _, h := range c.ParentHashes {
		parent, err := r.git.CommitObject(h)
		if err != nil {
			return false, err
		}
		parentTree, err := parent.Tree()
		if err != nil {
			return false, err
		}
		pairs, err := r.diffTrees(parentTree, tree, ps)
		if err != nil {
			return false, err
		}
		if len(pairs) == 0 {
			return true, nil
		}
	}
	return false, nil
}

// commitDiff is the diff git log prints under a commit: against its first
// parent, nothing for a merge unless --diff-merges=first-parent asks, and
// with --follow, only the followed file — renamed or copied from elsewhere
// when that is how it came to exist.
func (r *repo) commitDiff(ctx context.Context, req *logRequest, c *object.Commit) ([]*pair, error) {
	if req.diffFormat == "" {
		return nil, nil
	}
	if len(c.ParentHashes) > 1 && !req.diffMerges {
		return nil, nil
	}
	parent, err := r.firstParent(c)
	if err != nil {
		return nil, err
	}
	oldTree, err := treeOf(parent)
	if err != nil {
		return nil, err
	}
	newTree, err := c.Tree()
	if err != nil {
		return nil, err
	}

	if req.follow {
		return r.followDiff(req, oldTree, newTree)
	}
	pairs, err := r.diffTrees(oldTree, newTree, req.paths)
	if err != nil {
		return nil, err
	}
	if r.renames {
		return r.detectRenames(pairs, renameOptions{})
	}
	return pairs, nil
}

// followDiff is tree-diff.c's --follow: the diff limited to the followed
// path, and when that path is created here, a search of the whole parent
// tree — copies included — for where it came from. A rename or copy found
// becomes the commit's one entry, and the search follows its source from
// then on.
func (r *repo) followDiff(req *logRequest, oldTree, newTree *object.Tree) ([]*pair, error) {
	only := &pathspec{include: []string{req.followedPath}}
	pairs, err := r.diffTrees(oldTree, newTree, only)
	if err != nil {
		return nil, err
	}
	created := false
	for _, p := range pairs {
		if !p.one.valid() && p.two.valid() {
			created = true
		}
	}
	if !created || oldTree == nil {
		return pairs, nil
	}

	whole, err := r.diffTrees(oldTree, newTree, nil)
	if err != nil {
		return nil, err
	}
	changed := map[string]bool{}
	for _, p := range whole {
		if p.one.valid() {
			changed[p.one.path] = true
		}
	}
	var unchanged []side
	files := oldTree.Files()
	err = files.ForEach(func(f *object.File) error {
		if !changed[f.Name] {
			unchanged = append(unchanged, side{path: f.Name, mode: f.Mode, hash: f.Hash})
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	// Submodules are tree entries Files() skips; they are copy sources too.
	unchanged = append(unchanged, r.gitlinks(oldTree, "", changed)...)

	found, err := r.detectRenames(whole, renameOptions{
		copies:   true,
		sources:  unchanged,
		onlyDest: req.followedPath,
	})
	if err != nil {
		return nil, err
	}
	for _, p := range found {
		if (p.status == 'R' || p.status == 'C') && p.two.path == req.followedPath {
			req.followedPath = p.one.path
			return []*pair{p}, nil
		}
	}
	return pairs, nil
}

// gitlinks lists the submodule entries of a tree, recursively, that are not
// in changed.
func (r *repo) gitlinks(t *object.Tree, base string, changed map[string]bool) []side {
	var out []side
	for _, e := range t.Entries {
		full := e.Name
		if base != "" {
			full = base + "/" + e.Name
		}
		switch e.Mode {
		case filemode.Submodule:
			if !changed[full] {
				out = append(out, side{path: full, mode: e.Mode, hash: e.Hash})
			}
		case filemode.Dir:
			if sub, err := r.git.TreeObject(e.Hash); err == nil {
				out = append(out, r.gitlinks(sub, full, changed)...)
			}
		}
	}
	return out
}
