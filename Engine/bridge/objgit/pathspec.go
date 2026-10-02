package objgit

import (
	"path"
	"strings"
)

// pathspec is the subset of git's pathspec language bv's correlation package
// uses: literal paths (a file, or a directory and everything under it), and
// `:(exclude,glob)<dir>/**` to leave a top-level directory out. Paths are
// relative to the command's directory, as git's are, and stored relative to
// the worktree root.
type pathspec struct {
	include []string // root-relative; "" matches everything
	exclude []string // root-relative directory prefixes, each ending in "/"
}

// parsePathspec reads the arguments after `--`.
func (r *repo) parsePathspec(args []string) (*pathspec, error) {
	if len(args) == 0 {
		return nil, nil
	}
	ps := &pathspec{}
	for _, arg := range args {
		if strings.HasPrefix(arg, ":(exclude,glob)") {
			pattern := strings.TrimPrefix(arg, ":(exclude,glob)")
			dir, ok := strings.CutSuffix(pattern, "/**")
			if !ok || dir == "" || strings.ContainsAny(dir, "*?[\\") {
				return nil, unsupported("pathspec %q", arg)
			}
			// Glob magic anchors at the top of the repository's working
			// directory — the command's directory, for a relative pattern.
			ps.exclude = append(ps.exclude, r.rooted(dir)+"/")
			continue
		}
		if strings.HasPrefix(arg, ":") || strings.ContainsAny(arg, "*?[\\") {
			return nil, unsupported("pathspec %q", arg)
		}
		ps.include = append(ps.include, r.rooted(arg))
	}
	if len(ps.include) == 0 {
		// Only exclusions: git matches them against everything.
		ps.include = []string{r.rooted(".")}
	}
	return ps, nil
}

// rooted turns a path relative to the command's directory into one relative
// to the worktree root, "" meaning the root itself.
func (r *repo) rooted(p string) string {
	joined := path.Clean(path.Join(r.prefix, p))
	if joined == "." {
		return ""
	}
	return joined
}

// matches reports whether a file path is selected.
func (ps *pathspec) matches(p string) bool {
	if ps == nil {
		return true
	}
	for _, ex := range ps.exclude {
		if strings.HasPrefix(p, ex) {
			return false
		}
	}
	for _, in := range ps.include {
		if in == "" || p == in || strings.HasPrefix(p, in+"/") {
			return true
		}
	}
	return false
}

// descend reports whether a directory can hold a selected path, so the tree
// diff need not open the ones that cannot.
func (ps *pathspec) descend(dir string) bool {
	if ps == nil {
		return true
	}
	for _, ex := range ps.exclude {
		if dir+"/" == ex || strings.HasPrefix(dir+"/", ex) {
			return false
		}
	}
	for _, in := range ps.include {
		if in == "" || dir == in || strings.HasPrefix(dir, in+"/") ||
			strings.HasPrefix(in, dir+"/") {
			return true
		}
	}
	return false
}
