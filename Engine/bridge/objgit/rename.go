package objgit

import (
	"path"
	"sort"

	"github.com/go-git/go-git/v5/plumbing/filemode"
)

// Rename and copy detection, ported from git's diffcore-rename.c and
// diffcore-delta.c so that a commit pairs the same files git pairs. Every
// number here is git's: the score scale, the 50 % default threshold, the 75 %
// bar for a same-basename match, four candidates kept per destination, and
// the chunk hash similarity is estimated with.

const (
	maxScore                  = 60000
	defaultRenameScore        = 30000 // 50 %
	candidatesPerDest         = 4
	defaultRenameLimit        = 1000
	spanHashBase       uint32 = 107927
)

// renameOptions select between the two ways git runs the detection here.
type renameOptions struct {
	// copies looks for copies as well as renames, from every file in the
	// old tree (`--find-copies-harder`). --follow's search does this.
	copies bool
	// sources, with copies, are the old tree's files that are not already in
	// the queue: an unchanged file can be a copy's source.
	sources []side
	// onlyDest restricts the destinations to one path (--follow's
	// single_follow).
	onlyDest string
}

// renameSrc is one candidate source: a deletion, or with copies any file of
// the old tree.
type renameSrc struct {
	side side
	// used counts the renames and copies taken from it. A source that still
	// exists starts at one, which is what turns a later pairing into a copy.
	used    int
	deleted bool
	spans   []span
	size    int // -1 until read
}

type renameDst struct {
	pair  *pair
	spans []span
	size  int // -1 until read
	// found is the source paired with this destination, -1 for none.
	found int
	score int
}

// detectRenames rewrites a diff queue with renames (and copies) found, git's
// diffcore_rename followed by diff_resolve_rename_copy.
func (r *repo) detectRenames(queue []*pair, opts renameOptions) ([]*pair, error) {
	var srcs []*renameSrc
	var dsts []*renameDst
	dstOf := map[*pair]*renameDst{}

	for _, p := range queue {
		switch {
		case !p.one.valid() && p.two.valid():
			if opts.onlyDest != "" && p.two.path != opts.onlyDest {
				continue
			}
			d := &renameDst{pair: p, found: -1, size: -1}
			dsts = append(dsts, d)
			dstOf[p] = d
		case p.one.valid() && !p.two.valid():
			srcs = append(srcs, &renameSrc{side: p.one, deleted: true, size: -1})
		case opts.copies:
			srcs = append(srcs, &renameSrc{side: p.one, used: 1, size: -1})
		}
	}
	if opts.copies {
		for _, s := range opts.sources {
			srcs = append(srcs, &renameSrc{side: s, used: 1, size: -1})
		}
		// Sources are registered in path order whatever their origin.
		sort.SliceStable(srcs, func(i, j int) bool { return srcs[i].side.path < srcs[j].side.path })
	}
	if len(dsts) == 0 || len(srcs) == 0 {
		return finishRenames(queue, srcs, dstOf), nil
	}

	// Exact renames: the same object. Prefer a source not yet used, then
	// one with the same basename; among equals, the first in path order.
	for _, d := range dsts {
		best, bestScore := -1, -1
		for i, s := range srcs {
			if s.side.hash != d.pair.two.hash {
				continue
			}
			if !isRegular(s.side.mode) || !isRegular(d.pair.two.mode) {
				if s.side.mode != d.pair.two.mode {
					continue
				}
			}
			if s.used > 0 && !opts.copies {
				continue
			}
			score := 0
			if s.used == 0 {
				score = 1
			}
			if path.Base(s.side.path) == path.Base(d.pair.two.path) {
				score++
			}
			if score > bestScore {
				best, bestScore = i, score
				if score == 2 {
					break
				}
			}
		}
		if best >= 0 {
			d.found, d.score = best, maxScore
			srcs[best].used++
		}
	}

	remaining := 0
	for _, d := range dsts {
		if d.found < 0 {
			remaining++
		}
	}
	if remaining == 0 {
		return finishRenames(queue, srcs, dstOf), nil
	}

	// A source an exact rename consumed takes no further part, unless copies
	// are wanted (remove_unneeded_paths_from_src).
	live := make([]int, 0, len(srcs))
	for i, s := range srcs {
		if !opts.copies && s.used > 0 {
			continue
		}
		live = append(live, i)
	}

	if !opts.copies {
		// Same-basename pairs first, when the basename is unique on both
		// sides and the content clears a higher bar.
		minBasename := defaultRenameScore + (maxScore-defaultRenameScore)/2
		srcByBase := map[string]int{}
		for _, i := range live {
			base := path.Base(srcs[i].side.path)
			if _, dup := srcByBase[base]; dup {
				srcByBase[base] = -1
			} else {
				srcByBase[base] = i
			}
		}
		dstByBase := map[string]int{}
		for i, d := range dsts {
			if d.found >= 0 {
				continue
			}
			base := path.Base(d.pair.two.path)
			if _, dup := dstByBase[base]; dup {
				dstByBase[base] = -1
			} else {
				dstByBase[base] = i
			}
		}
		for base, si := range srcByBase {
			if si < 0 {
				continue
			}
			di, ok := dstByBase[base]
			if !ok || di < 0 {
				continue
			}
			score, err := r.similarity(srcs[si], dsts[di], minBasename)
			if err != nil {
				return nil, err
			}
			if score < minBasename {
				continue
			}
			dsts[di].found, dsts[di].score = si, score
			srcs[si].used++
		}
		kept := live[:0]
		for _, i := range live {
			if srcs[i].used == 0 {
				kept = append(kept, i)
			}
		}
		live = kept
	}

	var unmatched []int
	for i, d := range dsts {
		if d.found < 0 {
			unmatched = append(unmatched, i)
		}
	}
	if len(unmatched) == 0 || len(live) == 0 {
		return finishRenames(queue, srcs, dstOf), nil
	}
	if len(unmatched)*len(live) > defaultRenameLimit*defaultRenameLimit {
		// Too many candidates: git gives up on inexact detection.
		return finishRenames(queue, srcs, dstOf), nil
	}

	// The candidate matrix: the best four sources for each destination.
	type candidate struct {
		dst, src  int
		score     int
		nameScore int
	}
	compare := func(a, b candidate) int { // diffcore-rename.c's score_compare
		if a.dst < 0 {
			if b.dst >= 0 {
				return 1
			}
			return 0
		}
		if b.dst < 0 {
			return -1
		}
		if a.score == b.score {
			return b.nameScore - a.nameScore
		}
		return b.score - a.score
	}
	var matrix []candidate
	for _, di := range unmatched {
		row := make([]candidate, candidatesPerDest)
		for k := range row {
			row[k].dst = -1
		}
		for _, si := range live {
			score, err := r.similarity(srcs[si], dsts[di], defaultRenameScore)
			if err != nil {
				return nil, err
			}
			c := candidate{dst: di, src: si, score: score}
			if path.Base(srcs[si].side.path) == path.Base(dsts[di].pair.two.path) {
				c.nameScore = 1
			}
			worst := 0
			for k := 1; k < candidatesPerDest; k++ {
				if compare(row[k], row[worst]) > 0 {
					worst = k
				}
			}
			if compare(row[worst], c) > 0 {
				row[worst] = c
			}
		}
		matrix = append(matrix, row...)
	}
	sort.SliceStable(matrix, func(i, j int) bool { return compare(matrix[i], matrix[j]) < 0 })

	pass := func(copies bool) {
		for _, c := range matrix {
			if c.dst < 0 || c.score < defaultRenameScore {
				break
			}
			d := dsts[c.dst]
			if d.found >= 0 {
				continue
			}
			if !copies && srcs[c.src].used > 0 {
				continue
			}
			d.found, d.score = c.src, c.score
			srcs[c.src].used++
		}
	}
	pass(false)
	if opts.copies {
		pass(true)
	}
	return finishRenames(queue, srcs, dstOf), nil
}

// finishRenames builds the output queue: each paired destination becomes a
// rename or copy in its creation's place, a deletion a rename consumed
// disappears, and the rest stays as it was. A pair whose source is used again
// later is a copy; the last use of a deleted source is the rename.
func finishRenames(queue []*pair, srcs []*renameSrc, dstOf map[*pair]*renameDst) []*pair {
	consumed := map[string]bool{}
	for _, d := range dstOf {
		if d.found >= 0 && srcs[d.found].deleted {
			consumed[srcs[d.found].side.path] = true
		}
	}
	var out []*pair
	for _, p := range queue {
		if d, ok := dstOf[p]; ok && d.found >= 0 {
			s := srcs[d.found]
			out = append(out, &pair{one: s.side, two: p.two, score: d.score, status: 'R'})
			continue
		}
		if p.one.valid() && !p.two.valid() && consumed[p.one.path] {
			continue
		}
		out = append(out, p)
	}
	// diff_resolve_rename_copy, in queue order.
	used := map[string]int{}
	for _, s := range srcs {
		used[s.side.path] = s.used
	}
	for _, p := range out {
		if p.status != 'R' {
			continue
		}
		used[p.one.path]--
		if used[p.one.path] > 0 {
			p.status = 'C'
		}
	}
	return out
}

func isRegular(m filemode.FileMode) bool {
	return m == filemode.Regular || m == filemode.Executable || m == filemode.Deprecated
}

// similarity is diffcore-rename.c's estimate_similarity: how much of the
// larger file's material the source supplies, on a 0..maxScore scale. Only
// regular files are compared; anything else renames only when identical.
func (r *repo) similarity(s *renameSrc, d *renameDst, minimum int) (int, error) {
	if !isRegular(s.side.mode) || !isRegular(d.pair.two.mode) {
		return 0, nil
	}
	// Sizes first: the size test below rejects most pairs without reading
	// either blob, which matters when every file of a tree is a candidate.
	if s.size < 0 {
		size, err := r.blobSize(s.side)
		if err != nil {
			return 0, err
		}
		s.size = size
	}
	if d.size < 0 {
		size, err := r.blobSize(d.pair.two)
		if err != nil {
			return 0, err
		}
		d.size = size
	}
	maxSize, baseSize := s.size, d.size
	if baseSize > maxSize {
		maxSize, baseSize = baseSize, maxSize
	}
	delta := maxSize - baseSize
	// Edits that change the size this much are never a rename.
	if int64(maxSize)*int64(maxScore-minimum) < int64(delta)*int64(maxScore) {
		return 0, nil
	}
	if s.spans == nil {
		data, err := r.blob(s.side)
		if err != nil {
			return 0, err
		}
		s.spans = hashChars(data)
	}
	if d.spans == nil {
		data, err := r.blob(d.pair.two)
		if err != nil {
			return 0, err
		}
		d.spans = hashChars(data)
	}
	copied := countCopied(s.spans, d.spans)
	if d.size == 0 {
		return 0, nil
	}
	return int(int64(copied) * maxScore / int64(maxSize)), nil
}

// span is one entry of diffcore-delta.c's spanhash table: a chunk hash and
// how many bytes hashed to it.
type span struct {
	hash uint32
	cnt  int
}

// hashChars splits content into chunks — a line, or 64 bytes of one — and
// totals the bytes per chunk hash. In text, the CR of a CRLF is skipped.
func hashChars(data []byte) []span {
	counts := map[uint32]int{}
	text := !isBinary(data)
	var accum1, accum2 uint32
	n := 0
	for i := 0; i < len(data); i++ {
		c := uint32(data[i])
		old1 := accum1
		if text && c == '\r' && i+1 < len(data) && data[i+1] == '\n' {
			continue
		}
		accum1 = (accum1 << 7) ^ (accum2 >> 25)
		accum2 = (accum2 << 7) ^ (old1 >> 25)
		accum1 += c
		n++
		if n < 64 && c != '\n' {
			continue
		}
		counts[(accum1+accum2*0x61)%spanHashBase] += n
		n, accum1, accum2 = 0, 0, 0
	}
	if n > 0 {
		counts[(accum1+accum2*0x61)%spanHashBase] += n
	}
	spans := make([]span, 0, len(counts))
	for h, c := range counts {
		spans = append(spans, span{hash: h, cnt: c})
	}
	sort.Slice(spans, func(i, j int) bool { return spans[i].hash < spans[j].hash })
	return spans
}

// countCopied is diffcore_count_changes' src_copied: for each chunk hash,
// the bytes the source and destination have in common.
func countCopied(src, dst []span) int {
	copied := 0
	j := 0
	for _, s := range src {
		for j < len(dst) && dst[j].hash < s.hash {
			j++
		}
		dstCnt := 0
		if j < len(dst) && dst[j].hash == s.hash {
			dstCnt = dst[j].cnt
			j++
		}
		if s.cnt < dstCnt {
			copied += s.cnt
		} else {
			copied += dstCnt
		}
	}
	return copied
}
