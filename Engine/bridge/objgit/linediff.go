package objgit

// lineCounts returns how many lines a change adds and deletes, the numbers
// --numstat prints.
//
// It is git's own line diff, ported from xdiff (xprepare.c and xdiffi.c) with
// git's default options, because a minimal diff is not what git computes.
// xdiff discards a line with no counterpart in the other file before it
// searches, may discard a line that recurs many times when it sits among
// such lines, and once a search grows expensive it settles for a heuristic
// split. Each of those can mark a line changed that a minimal diff would
// keep, and on real files the counts differ — 278 against git's 361 on one
// commit of this repository. The counts are the number of lines xdiff marks
// changed on each side, which is what its diffstat consumer counts.
func lineCounts(oldData, newData []byte) (added, deleted int) {
	x := newXdiff(oldData, newData)
	x.diff()
	for _, c := range x.f1.rchg {
		if c {
			deleted++
		}
	}
	for _, c := range x.f2.rchg {
		if c {
			added++
		}
	}
	return added, deleted
}

// xdiff's constants (xdiff/xdiffi.c, xprepare.c).
const (
	xdlMaxCostMin    = 256
	xdlHeurMinCost   = 256
	xdlSnakeCnt      = 20
	xdlKHeur         = 4
	xdlMaxEqLimit    = 1024
	xdlSimscanWindow = 100
	xdlKpdisRun      = 4
	xdlLineMax       = int(^uint(0) >> 1)
)

// xdfile is one side: every record's class, which records the search sees
// (rindex, ha) and which are marked changed (rchg).
type xdfile struct {
	class      []int  // per record: equal content, equal class
	rchg       []bool // per record
	rindex     []int  // the records left after cleanup, by record index
	ha         []int  // their classes
	dstart     int
	dend       int
	otherCount map[int]int // occurrences of each class in the other file
}

type xdiff struct {
	f1, f2 xdfile
}

func newXdiff(a, b []byte) *xdiff {
	classes := map[string]int{}
	count1, count2 := map[int]int{}, map[int]int{}
	classify := func(data []byte, counts map[int]int) []int {
		var out []int
		for len(data) > 0 {
			end := len(data)
			for i, c := range data {
				if c == '\n' {
					end = i + 1
					break
				}
			}
			line := string(data[:end])
			id, ok := classes[line]
			if !ok {
				id = len(classes)
				classes[line] = id
			}
			counts[id]++
			out = append(out, id)
			data = data[end:]
		}
		return out
	}
	x := &xdiff{}
	x.f1.class = classify(a, count1)
	x.f2.class = classify(b, count2)
	x.f1.rchg = make([]bool, len(x.f1.class))
	x.f2.rchg = make([]bool, len(x.f2.class))
	x.f1.otherCount, x.f2.otherCount = count2, count1
	return x
}

// bogosqrt is xdl_bogosqrt: a power of two near the square root.
func bogosqrt(n int) int {
	i := 1
	for ; n > 0; n >>= 2 {
		i <<= 1
	}
	return i
}

func (x *xdiff) diff() {
	x.trimEnds()
	x.cleanupRecords()

	n1, n2 := len(x.f1.ha), len(x.f2.ha)
	ndiags := n1 + n2 + 3
	kvdf := make([]int, ndiags)
	kvdb := make([]int, ndiags)
	env := xdalgoenv{
		mxcost:   bogosqrt(ndiags),
		snakeCnt: xdlSnakeCnt,
		heurMin:  xdlHeurMinCost,
		off:      n2 + 1,
	}
	if env.mxcost < xdlMaxCostMin {
		env.mxcost = xdlMaxCostMin
	}
	x.recsCmp(0, n1, 0, n2, kvdf, kvdb, false, &env)
}

// trimEnds is xdl_trim_ends: the common first and last records.
func (x *xdiff) trimEnds() {
	c1, c2 := x.f1.class, x.f2.class
	lim := len(c1)
	if len(c2) < lim {
		lim = len(c2)
	}
	i := 0
	for ; i < lim; i++ {
		if c1[i] != c2[i] {
			break
		}
	}
	x.f1.dstart, x.f2.dstart = i, i
	lim -= i
	j := 0
	for ; j < lim; j++ {
		if c1[len(c1)-1-j] != c2[len(c2)-1-j] {
			break
		}
	}
	x.f1.dend = len(c1) - j - 1
	x.f2.dend = len(c2) - j - 1
}

// cleanupRecords is xdl_cleanup_records: a record with no counterpart in
// the other file is changed outright, and one with many counterparts is too
// when it sits among such records; the rest go to the search.
func (x *xdiff) cleanupRecords() {
	mark := func(f *xdfile) []byte {
		dis := make([]byte, len(f.class)+1)
		mlim := bogosqrt(len(f.class))
		if mlim > xdlMaxEqLimit {
			mlim = xdlMaxEqLimit
		}
		for i := f.dstart; i <= f.dend; i++ {
			nm := f.otherCount[f.class[i]]
			switch {
			case nm == 0:
				dis[i] = 0
			case nm >= mlim:
				dis[i] = 2
			default:
				dis[i] = 1
			}
		}
		return dis
	}
	dis1, dis2 := mark(&x.f1), mark(&x.f2)
	keep := func(f *xdfile, dis []byte) {
		for i := f.dstart; i <= f.dend; i++ {
			if dis[i] == 1 || (dis[i] == 2 && !cleanMmatch(dis, i, f.dstart, f.dend)) {
				f.rindex = append(f.rindex, i)
				f.ha = append(f.ha, f.class[i])
			} else {
				f.rchg[i] = true
			}
		}
	}
	keep(&x.f1, dis1)
	keep(&x.f2, dis2)
}

// cleanMmatch is xdl_clean_mmatch: whether a recurring record sits in a run
// dominated by records with no counterpart, and so is discarded with them.
func cleanMmatch(dis []byte, i, s, e int) bool {
	if i-s > xdlSimscanWindow {
		s = i - xdlSimscanWindow
	}
	if e-i > xdlSimscanWindow {
		e = i + xdlSimscanWindow
	}
	rdis0, rpdis0 := 0, 1
	for r := 1; i-r >= s; r++ {
		if dis[i-r] == 0 {
			rdis0++
		} else if dis[i-r] == 2 {
			rpdis0++
		} else {
			break
		}
	}
	if rdis0 == 0 {
		return false
	}
	rdis1, rpdis1 := 0, 1
	for r := 1; i+r <= e; r++ {
		if dis[i+r] == 0 {
			rdis1++
		} else if dis[i+r] == 2 {
			rpdis1++
		} else {
			break
		}
	}
	if rdis1 == 0 {
		return false
	}
	rdis1 += rdis0
	rpdis1 += rpdis0
	return rpdis1*xdlKpdisRun < rpdis1+rdis1
}

type xdalgoenv struct {
	mxcost   int
	snakeCnt int
	heurMin  int
	// off maps a diagonal to its index in the K vectors, which C offsets by
	// pointer arithmetic.
	off int
}

type xdpsplit struct {
	i1, i2       int
	minLo, minHi bool
}

// recsCmp is xdl_recs_cmp: shrink the box by its common ends, mark a side
// changed when the other is empty, else split and recurse.
func (x *xdiff) recsCmp(off1, lim1, off2, lim2 int, kvdf, kvdb []int, needMin bool, env *xdalgoenv) {
	ha1, ha2 := x.f1.ha, x.f2.ha
	for off1 < lim1 && off2 < lim2 && ha1[off1] == ha2[off2] {
		off1++
		off2++
	}
	for off1 < lim1 && off2 < lim2 && ha1[lim1-1] == ha2[lim2-1] {
		lim1--
		lim2--
	}
	switch {
	case off1 == lim1:
		for ; off2 < lim2; off2++ {
			x.f2.rchg[x.f2.rindex[off2]] = true
		}
	case off2 == lim2:
		for ; off1 < lim1; off1++ {
			x.f1.rchg[x.f1.rindex[off1]] = true
		}
	default:
		var spl xdpsplit
		x.split(off1, lim1, off2, lim2, kvdf, kvdb, needMin, &spl, env)
		x.recsCmp(off1, spl.i1, off2, spl.i2, kvdf, kvdb, spl.minLo, env)
		x.recsCmp(spl.i1, lim1, spl.i2, lim2, kvdf, kvdb, spl.minHi, env)
	}
}

// split is xdl_split: Myers' middle snake, searched from both ends, with
// xdiff's two ways out of an expensive search — a long enough snake past
// the heuristic cost, or the furthest-reaching path past the maximum cost.
func (x *xdiff) split(off1, lim1, off2, lim2 int, kvdf, kvdb []int, needMin bool, spl *xdpsplit, env *xdalgoenv) {
	ha1, ha2 := x.f1.ha, x.f2.ha
	o := env.off
	dmin, dmax := off1-lim2, lim1-off2
	fmid, bmid := off1-off2, lim1-lim2
	odd := (fmid-bmid)&1 != 0
	fmin, fmax := fmid, fmid
	bmin, bmax := bmid, bmid

	kvdf[o+fmid] = off1
	kvdb[o+bmid] = lim1

	for ec := 1; ; ec++ {
		gotSnake := false

		if fmin > dmin {
			fmin--
			kvdf[o+fmin-1] = -1
		} else {
			fmin++
		}
		if fmax < dmax {
			fmax++
			kvdf[o+fmax+1] = -1
		} else {
			fmax--
		}
		for d := fmax; d >= fmin; d -= 2 {
			var i1 int
			if kvdf[o+d-1] >= kvdf[o+d+1] {
				i1 = kvdf[o+d-1] + 1
			} else {
				i1 = kvdf[o+d+1]
			}
			prev1 := i1
			i2 := i1 - d
			for i1 < lim1 && i2 < lim2 && ha1[i1] == ha2[i2] {
				i1++
				i2++
			}
			if i1-prev1 > env.snakeCnt {
				gotSnake = true
			}
			kvdf[o+d] = i1
			if odd && bmin <= d && d <= bmax && kvdb[o+d] <= i1 {
				spl.i1, spl.i2 = i1, i2
				spl.minLo, spl.minHi = true, true
				return
			}
		}

		if bmin > dmin {
			bmin--
			kvdb[o+bmin-1] = xdlLineMax
		} else {
			bmin++
		}
		if bmax < dmax {
			bmax++
			kvdb[o+bmax+1] = xdlLineMax
		} else {
			bmax--
		}
		for d := bmax; d >= bmin; d -= 2 {
			var i1 int
			if kvdb[o+d-1] < kvdb[o+d+1] {
				i1 = kvdb[o+d-1]
			} else {
				i1 = kvdb[o+d+1] - 1
			}
			prev1 := i1
			i2 := i1 - d
			for i1 > off1 && i2 > off2 && ha1[i1-1] == ha2[i2-1] {
				i1--
				i2--
			}
			if prev1-i1 > env.snakeCnt {
				gotSnake = true
			}
			kvdb[o+d] = i1
			if !odd && fmin <= d && d <= fmax && i1 <= kvdf[o+d] {
				spl.i1, spl.i2 = i1, i2
				spl.minLo, spl.minHi = true, true
				return
			}
		}

		if needMin {
			continue
		}

		if gotSnake && ec > env.heurMin {
			best := 0
			for d := fmax; d >= fmin; d -= 2 {
				dd := d - fmid
				if dd < 0 {
					dd = -dd
				}
				i1 := kvdf[o+d]
				i2 := i1 - d
				v := (i1 - off1) + (i2 - off2) - dd
				if v > xdlKHeur*ec && v > best &&
					off1+env.snakeCnt <= i1 && i1 < lim1 &&
					off2+env.snakeCnt <= i2 && i2 < lim2 {
					for k := 1; ha1[i1-k] == ha2[i2-k]; k++ {
						if k == env.snakeCnt {
							best = v
							spl.i1, spl.i2 = i1, i2
							break
						}
					}
				}
			}
			if best > 0 {
				spl.minLo, spl.minHi = true, false
				return
			}

			best = 0
			for d := bmax; d >= bmin; d -= 2 {
				dd := d - bmid
				if dd < 0 {
					dd = -dd
				}
				i1 := kvdb[o+d]
				i2 := i1 - d
				v := (lim1 - i1) + (lim2 - i2) - dd
				if v > xdlKHeur*ec && v > best &&
					off1 < i1 && i1 <= lim1-env.snakeCnt &&
					off2 < i2 && i2 <= lim2-env.snakeCnt {
					for k := 0; ha1[i1+k] == ha2[i2+k]; k++ {
						if k == env.snakeCnt-1 {
							best = v
							spl.i1, spl.i2 = i1, i2
							break
						}
					}
				}
			}
			if best > 0 {
				spl.minLo, spl.minHi = false, true
				return
			}
		}

		if ec >= env.mxcost {
			fbest, fbest1 := -1, -1
			for d := fmax; d >= fmin; d -= 2 {
				i1 := kvdf[o+d]
				if i1 > lim1 {
					i1 = lim1
				}
				i2 := i1 - d
				if lim2 < i2 {
					i1 = lim2 + d
					i2 = lim2
				}
				if fbest < i1+i2 {
					fbest = i1 + i2
					fbest1 = i1
				}
			}
			bbest, bbest1 := xdlLineMax, xdlLineMax
			for d := bmax; d >= bmin; d -= 2 {
				i1 := kvdb[o+d]
				if i1 < off1 {
					i1 = off1
				}
				i2 := i1 - d
				if i2 < off2 {
					i1 = off2 + d
					i2 = off2
				}
				if i1+i2 < bbest {
					bbest = i1 + i2
					bbest1 = i1
				}
			}
			if (lim1+lim2)-bbest < fbest-(off1+off2) {
				spl.i1, spl.i2 = fbest1, fbest-fbest1
				spl.minLo, spl.minHi = true, false
			} else {
				spl.i1, spl.i2 = bbest1, bbest-bbest1
				spl.minLo, spl.minHi = false, true
			}
			return
		}
	}
}
