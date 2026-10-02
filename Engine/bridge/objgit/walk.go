package objgit

import (
	"context"
	"time"

	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
)

// walkOptions are the revision-walk flags git log takes here.
type walkOptions struct {
	starts      []plumbing.Hash
	noWalk      bool // --no-walk=unsorted: exactly the given commits, in order
	firstParent bool
	noMerges    bool
	since       *time.Time // --since: stop descending past an older commit
	until       *time.Time // --until: skip newer commits, keep descending
}

// walk visits commits in git log's default order and calls visit for each
// one the walk returns. visit reports whether the commit was shown, which is
// what -n counts, and false from more stops the walk.
//
// The order is revision.c's for an unlimited walk: a list kept sorted by
// committer date, newest first, a newly queued commit going after every
// queued commit at least as new — so commits with equal dates leave in the
// order they arrived. A commit is queued once, when first reached.
//
// --since compares committer dates, as git's does, and a commit older than it
// is dropped *with its parents never queued*: git stops descending there,
// which is why `--since` is not a filter (git has --since-as-filter for that).
// --until and --no-merges skip a commit but keep walking past it.
func (r *repo) walk(ctx context.Context, opts walkOptions, visit func(*object.Commit) (more bool, err error)) error {
	if opts.noWalk {
		seen := map[plumbing.Hash]bool{}
		for _, h := range opts.starts {
			if seen[h] {
				continue
			}
			seen[h] = true
			c, err := r.git.CommitObject(h)
			if err != nil {
				return fatal("bad object %s", h)
			}
			if more, err := visit(c); err != nil || !more {
				return err
			}
		}
		return nil
	}

	var queue []*object.Commit
	seen := map[plumbing.Hash]bool{}
	insert := func(c *object.Commit) {
		at := len(queue)
		for i, q := range queue {
			if q.Committer.When.Unix() < c.Committer.When.Unix() {
				at = i
				break
			}
		}
		queue = append(queue, nil)
		copy(queue[at+1:], queue[at:])
		queue[at] = c
	}
	for _, h := range opts.starts {
		if seen[h] {
			continue
		}
		seen[h] = true
		c, err := r.git.CommitObject(h)
		if err != nil {
			return fatal("bad object %s", h)
		}
		insert(c)
	}

	for len(queue) > 0 {
		if err := ctx.Err(); err != nil {
			return err
		}
		c := queue[0]
		queue = queue[1:]

		if opts.since != nil && c.Committer.When.Unix() < opts.since.Unix() {
			continue
		}
		for i, h := range c.ParentHashes {
			if opts.firstParent && i > 0 {
				break
			}
			if seen[h] {
				continue
			}
			seen[h] = true
			parent, err := r.git.CommitObject(h)
			if err != nil {
				// A shallow clone's boundary: git walks no further either.
				continue
			}
			insert(parent)
		}

		if opts.noMerges && len(c.ParentHashes) > 1 {
			continue
		}
		if opts.until != nil && c.Committer.When.Unix() > opts.until.Unix() {
			continue
		}
		more, err := visit(c)
		if err != nil || !more {
			return err
		}
	}
	return nil
}
