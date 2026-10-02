package objgit

import (
	"bytes"
	"fmt"
	"io"
	"strings"

	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"
)

// side is one end of a file pair: a path, its mode and its object. A zero
// mode means the file does not exist on that side.
type side struct {
	path string
	mode filemode.FileMode
	hash plumbing.Hash
}

func (s side) valid() bool { return s.mode != 0 }

// pair is one entry of git's diff queue (diffcore.h's diff_filepair).
type pair struct {
	one, two side
	// status is git's letter: A, D, M, T, R or C.
	status byte
	// score is the rename or copy similarity, 0..maxScore.
	score int
}

// diffTrees compares two trees, either possibly nil, and returns the
// changed files selected by ps, in git's queue order: tree order, which for
// full paths is byte order.
func (r *repo) diffTrees(a, b *object.Tree, ps *pathspec) ([]*pair, error) {
	var out []*pair
	if err := r.diffTree(a, b, "", ps, &out); err != nil {
		return nil, err
	}
	return out, nil
}

// treeKey is the name git sorts a tree entry by: a directory's name with a
// slash appended, so "a.txt" sorts before the directory "a".
func treeKey(e object.TreeEntry) string {
	if e.Mode == filemode.Dir {
		return e.Name + "/"
	}
	return e.Name
}

func (r *repo) diffTree(a, b *object.Tree, base string, ps *pathspec, out *[]*pair) error {
	var ea, eb []object.TreeEntry
	if a != nil {
		ea = a.Entries
	}
	if b != nil {
		eb = b.Entries
	}
	i, j := 0, 0
	for i < len(ea) || j < len(eb) {
		var cmp int
		switch {
		case i >= len(ea):
			cmp = 1
		case j >= len(eb):
			cmp = -1
		default:
			cmp = strings.Compare(treeKey(ea[i]), treeKey(eb[j]))
		}
		switch {
		case cmp < 0:
			if err := r.emit(&ea[i], nil, base, ps, out); err != nil {
				return err
			}
			i++
		case cmp > 0:
			if err := r.emit(nil, &eb[j], base, ps, out); err != nil {
				return err
			}
			j++
		default:
			if ea[i].Hash != eb[j].Hash || ea[i].Mode != eb[j].Mode {
				if err := r.emit(&ea[i], &eb[j], base, ps, out); err != nil {
					return err
				}
			}
			i++
			j++
		}
	}
	return nil
}

// emit records the change between two entries of the same name (either nil),
// recursing into directories.
func (r *repo) emit(ea, eb *object.TreeEntry, base string, ps *pathspec, out *[]*pair) error {
	var name string
	if ea != nil {
		name = ea.Name
	} else {
		name = eb.Name
	}
	full := name
	if base != "" {
		full = base + "/" + name
	}

	isDir := func(e *object.TreeEntry) bool { return e != nil && e.Mode == filemode.Dir }
	if isDir(ea) || isDir(eb) {
		if !ps.descend(full) {
			return nil
		}
		var ta, tb *object.Tree
		var err error
		if isDir(ea) {
			if ta, err = r.git.TreeObject(ea.Hash); err != nil {
				return err
			}
		}
		if isDir(eb) {
			if tb, err = r.git.TreeObject(eb.Hash); err != nil {
				return err
			}
		}
		return r.diffTree(ta, tb, full, ps, out)
	}
	if !ps.matches(full) {
		return nil
	}

	p := &pair{}
	if ea != nil {
		p.one = side{path: full, mode: ea.Mode, hash: ea.Hash}
	}
	if eb != nil {
		p.two = side{path: full, mode: eb.Mode, hash: eb.Hash}
	}
	switch {
	case ea == nil:
		p.status = 'A'
	case eb == nil:
		p.status = 'D'
	case objectType(ea.Mode) != objectType(eb.Mode):
		p.status = 'T'
	default:
		p.status = 'M'
	}
	*out = append(*out, p)
	return nil
}

// objectType groups modes the way git's S_IFMT does: a mode change within a
// group (644 to 755) is a modification, across groups a type change.
func objectType(m filemode.FileMode) int {
	switch m {
	case filemode.Symlink:
		return 1
	case filemode.Submodule:
		return 2
	default:
		return 0
	}
}

// blob reads an object's content. A submodule has none in this repository;
// git diffs it as the one line "Subproject commit <sha>".
func (r *repo) blob(s side) ([]byte, error) {
	if !s.valid() {
		return nil, nil
	}
	if s.mode == filemode.Submodule {
		return []byte(fmt.Sprintf("Subproject commit %s\n", s.hash)), nil
	}
	b, err := r.git.BlobObject(s.hash)
	if err != nil {
		return nil, err
	}
	rd, err := b.Reader()
	if err != nil {
		return nil, err
	}
	defer rd.Close()
	return io.ReadAll(rd)
}

// blobSize is an object's size without reading its content.
func (r *repo) blobSize(s side) (int, error) {
	if s.mode == filemode.Submodule {
		return len(fmt.Sprintf("Subproject commit %s\n", s.hash)), nil
	}
	b, err := r.git.BlobObject(s.hash)
	if err != nil {
		return 0, err
	}
	return int(b.Size), nil
}

// isBinary is git's buffer_is_binary: a NUL in the first 8000 bytes.
func isBinary(data []byte) bool {
	if len(data) > 8000 {
		data = data[:8000]
	}
	return bytes.IndexByte(data, 0) >= 0
}

// treeOf returns a commit's tree, or nil for no commit.
func treeOf(c *object.Commit) (*object.Tree, error) {
	if c == nil {
		return nil, nil
	}
	return c.Tree()
}

// parentForDiff returns the commit a log diff compares against: the first
// parent, or nil for a root commit.
func (r *repo) firstParent(c *object.Commit) (*object.Commit, error) {
	if len(c.ParentHashes) == 0 {
		return nil, nil
	}
	return r.git.CommitObject(c.ParentHashes[0])
}

// formatPairs writes the diff queue in one of git log's diff formats.
func (r *repo) formatPairs(w *bytes.Buffer, pairs []*pair, format string) error {
	for _, p := range pairs {
		switch format {
		case "name-only":
			name := p.two.path
			if !p.two.valid() {
				name = p.one.path
			}
			w.WriteString(r.quotePathName(name))
			w.WriteByte('\n')
		case "name-status":
			w.WriteString(statusString(p))
			for _, name := range pairNames(p) {
				w.WriteByte('\t')
				w.WriteString(r.quotePathName(name))
			}
			w.WriteByte('\n')
		case "raw":
			oneMode, twoMode := 0, 0
			oneHash, twoHash := plumbing.ZeroHash, plumbing.ZeroHash
			if p.one.valid() {
				oneMode, oneHash = int(p.one.mode), p.one.hash
			}
			if p.two.valid() {
				twoMode, twoHash = int(p.two.mode), p.two.hash
			}
			fmt.Fprintf(w, ":%06o %06o %s %s %s", oneMode, twoMode, oneHash, twoHash, statusString(p))
			for _, name := range pairNames(p) {
				w.WriteByte('\t')
				w.WriteString(r.quotePathName(name))
			}
			w.WriteByte('\n')
		case "numstat":
			if err := r.numstat(w, p); err != nil {
				return err
			}
		default:
			return unsupported("diff format %s", format)
		}
	}
	return nil
}

// statusString is the status column: the letter, with the similarity for a
// rename or copy (diff.c's similarity_index).
func statusString(p *pair) string {
	if p.status == 'R' || p.status == 'C' {
		return fmt.Sprintf("%c%03d", p.status, p.score*100/maxScore)
	}
	return string(p.status)
}

// pairNames is what --name-status and --raw print after the status: both
// paths for a rename or copy, otherwise the one that exists.
func pairNames(p *pair) []string {
	switch {
	case p.status == 'R' || p.status == 'C':
		return []string{p.one.path, p.two.path}
	case !p.two.valid():
		return []string{p.one.path}
	default:
		return []string{p.two.path}
	}
}

// numstat writes one --numstat line: added and deleted line counts, "-" for
// a binary side, and the path — a rename compressed as git's pprint_rename
// does.
func (r *repo) numstat(w *bytes.Buffer, p *pair) error {
	oldData, err := r.blob(p.one)
	if err != nil {
		return err
	}
	newData, err := r.blob(p.two)
	if err != nil {
		return err
	}
	var name string
	if p.status == 'R' || p.status == 'C' {
		name = r.pprintRename(p.one.path, p.two.path)
	} else if p.two.valid() {
		name = r.quotePathName(p.two.path)
	} else {
		name = r.quotePathName(p.one.path)
	}
	if isBinary(oldData) || isBinary(newData) {
		fmt.Fprintf(w, "-\t-\t%s\n", name)
		return nil
	}
	added, deleted := lineCounts(oldData, newData)
	fmt.Fprintf(w, "%d\t%d\t%s\n", added, deleted, name)
	return nil
}

// pprintRename is diff.c's pprint_rename: "a => b", or with a common
// directory prefix and suffix factored out, "dir/{a => b}/rest".
func (r *repo) pprintRename(a, b string) string {
	qa, qb := r.quotePathName(a), r.quotePathName(b)
	if qa != a || qb != b {
		return qa + " => " + qb
	}
	lenA, lenB := len(a), len(b)

	pfx := 0
	for i := 0; i < lenA && i < lenB && a[i] == b[i]; i++ {
		if a[i] == '/' {
			pfx = i + 1
		}
	}

	// The suffix scan starts at the strings' terminators, which are equal,
	// and may run one byte into the prefix to see its slash.
	at := func(s string, i int) byte {
		if i >= len(s) {
			return 0
		}
		return s[i]
	}
	adjust := 0
	if pfx > 0 {
		adjust = 1
	}
	sfx := 0
	oa, ob := lenA, lenB
	for pfx-adjust <= oa && pfx-adjust <= ob && at(a, oa) == at(b, ob) {
		if at(a, oa) == '/' {
			sfx = lenA - oa
		}
		oa--
		ob--
	}

	midA := lenA - pfx - sfx
	midB := lenB - pfx - sfx
	if midA < 0 {
		midA = 0
	}
	if midB < 0 {
		midB = 0
	}
	var s strings.Builder
	if pfx+sfx > 0 {
		s.WriteString(a[:pfx])
		s.WriteByte('{')
	}
	s.WriteString(a[pfx : pfx+midA])
	s.WriteString(" => ")
	s.WriteString(b[pfx : pfx+midB])
	if pfx+sfx > 0 {
		s.WriteByte('}')
		s.WriteString(a[lenA-sfx:])
	}
	return s.String()
}
