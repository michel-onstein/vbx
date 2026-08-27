# Work Log

Entries are dated, newest first, and cite their bead where one exists. The
store was empty until 2026-08-21, so earlier entries carry no id.

---

## 2026-08-24 — The table's leading margin, measured rather than nudged

"Too much spacing between the status character and the left side of the table",
with the gap to the ID column reported as good. Those constrain each other: the
mark's distance from the id was already right, so the mark could not move — the
row had to.

How far in a row starts is `NSTableView.style`, and the three candidates were
measured on the real table rather than guessed at: 16pt for `.inset`, 8pt for
`.plain`, 6pt for `.fullWidth`, with `intercellSpacing` a constant 17pt across
all three. So the change moves the outer margin and nothing else, and the 4pt
between the mark and the id survives untouched. `.fullWidth` for a table that
fills its window.

The measurement also disproved a comment that had been sitting in two files
claiming the 17pt gap came from the inset style. It does not, and the comment
was confident enough to mislead someone changing exactly what was changed here.

Found on the way: `swift test` was **already red on `main`** — the gutter's
"draws a mark in the real table" test measures ink inside the gutter cell, and
the mark had been moved outside that cell on purpose. Repaired here, because
there is no green verify to ship against otherwise. See BUGS.md.
## 2026-08-24 — Pinch and two-finger scroll on the graph (vbx-vnl)

The graph zoomed only from its two buttons and panned only by holding the mouse
down. Asked for the trackpad gestures a canvas is expected to have.

SwiftUI supplies half. `MagnifyGesture` is a real pinch over a `Canvas`; there
is no scroll gesture at all, and `ScrollView` cannot be the answer because the
camera is a transform *inside* the canvas rather than a scrolled subview. So the
scroll half is an `NSEvent` local monitor behind a view that returns `nil` from
`hitTest(_:)` — the mouse stays entirely SwiftUI's, which after ADR-014 is worth
insisting on. ADR-019 records why a monitor rather than a view that takes the
event.

The camera became a value type in the same change, which is the part that made
any of this assertable: a pinch cannot be delivered headlessly, so the
arithmetic has to be reachable without one. Ten assertions came out of it,
including one that surprised me — a synthesised `CGEvent` scroll posted to the
process arrives with **no window**, so the monitor's own scoping rejects it. That
closed the door on testing delivery, and the honest thing was to write that down
in the ADR rather than assert something weaker and call it covered. What *is*
covered either side of the gap: the anchored zoom, the clamping, the pan, a
scroll event's deltas in both units, and — with the catcher hosted for real —
that its rectangle actually covers the graph, the failure mode being an overlay
that ends up zero-sized and looks exactly like a gesture macOS never sent.

Two things fell out of doing it properly. Hit-testing now goes through the same
camera as the drawing, where it had been a second copy of the transform. And the
buttons anchor on the middle of the pane: leaving the offset alone had slid the
graph off the pane, so zooming in twice needed a drag afterwards to find the
nodes again.

---

## 2026-08-23 — The check that let a development certificate through

Asked to publish the built binary as a GitHub release, back when there were
eight tags and no releases. The preflight said the notary profile was unusable
on a machine where notarization worked — the `--limit` bug, since fixed and
logged under *Two preflight checks that failed closed on their own bugs*.

What this adds is the bug underneath it, found by rehearsing the release rather
than trusting the fix: with the preflight unblocked the build ran to completion
and Apple refused it, because the app was signed with an **Apple Development**
certificate. `assert_identity` had been taking the certificate's kind as an
argument and using it only in the error text, so `"Developer ID Application"`
appeared in a message beside a check that never looked for one.

Worth keeping: the two preflight bugs failed closed and this one failed open,
and the open one was much more expensive — it is only caught after a universal
build and a round trip to Apple, by Apple. Running the whole path deliberately,
before it mattered, is what turned a silent failure into a caught one.

---

## 2026-08-26 — A Commits column, and a silent default it uncovered (vbx-cbw)

`histories[id].commits.count`, which is `.count` of what the engine attributed
and nothing more — which commits belong to a bead is the engine's judgement, and
re-deriving any of it here is the drift ADR-001 exists to prevent.

**Absent is not zero**, and the column is built around keeping them apart.
`commitCount(for:)` returns nil until the walk lands and zero for a bead the
walk attributed nothing to. The cell spells zero as `0` rather than taking the
house em dash `IssueRow.countLabel` gives a zero elsewhere: in this column the
dash has to mean *unknown*, and one glyph cannot mean both. The tooltip says
which kind of unknown — a walk still running, or a workspace with no repository.

Sorting is refused until the counts exist (`SortColumn.requiresHistory`,
mirroring `requiresPhase2`), because ordering by values nobody has read yet
sorts by zeros and leaves nothing on screen to explain the order.

**Deviation from the bead, deliberately.** It asked for the column to be
*hidden* where there is no repository, by analogy with History (`vbx-x8x`). Two
things argue the other way inside the table: the established rule here is that
an unavailable metric is shown as absent and says why — PageRank does exactly
that before Phase 2 — and `sanitize` prunes stored widths for columns it does
not know about, deliberately and with a test, so a column that came and went
would take the user's chosen width with it and never give it back.

**The silent default it uncovered.** `SortMode.ascending` had a `default: false`
catch-all. `commitsAscending` matched it, so the new ordering sorted descending
while claiming to ascend — caught only because the test asserted the actual
order rather than that sorting "worked". The switch is exhaustive now, so the
next case has to be classified or the build stops. That is the second silent
catch-all this area has produced (see `rowMenu`'s unread `specs[1]` parameter
in `vbx-dot`), and both were harmless-looking until they weren't.

Tests: `Commit count column` — the count is the report's, unloaded is nil,
loaded-with-nothing is zero, the cell draws zero and unknown differently
(rendered, against an opaque ground, after a layout pass — the first version
measured three blank images and "passed" every comparison), the column follows
the identifier contract, sorting is refused while unknown, and the ordering runs
both ways. 544 passing, green twice.

**Not visually confirmed in a running app.** The build launches, but the window
restores a different workspace and the column sits beyond the inspector's edge;
after two attempts I stopped rather than spend more on the screenshot. The
rendering assertion is what stands behind it.

---

## 2026-08-26 — The correlation report loads on open, and stays current (vbx-g3q)

`loadHistory()` had exactly two kinds of caller, both in `HistoryView`, so the
report existed only after someone visited that view — and `historyLoaded` was
never invalidated, so commits landing while the workspace was open left it
describing the repository as it was.

Now `startHistoryWalk()` runs on open and again whenever `HEAD` moves, in the
background: the walk is the expensive thing this app does, and an open that
waited for it would be an open that waits for git.

**The `HEAD` watch was fixed first, because everything else rests on it.**
`gitHeadPath` tested `<workspace>/.git/HEAD`, one level, so it missed a
workspace below the repository root *and* every git worktree — where `.git` is a
file holding a `gitdir:` pointer. It now resolves through `gitRepositoryRoot`
and follows the pointer. Until today that only made dirty marks slow to clear;
building "keep the report current" on the same watch would have shipped a
feature that silently did nothing in exactly the checkouts this project is
developed in. A `.git` file that is *not* a `gitdir:` pointer installs no watch
rather than guessing.

**Two bugs the tests found, not the design.**

- A walk that finishes after the workspace changed would publish into the store
  that had moved on. Every open bumps a generation; a walk carries the one it
  started under and publishes nothing if that is no longer current.
- Cancelling was not enough. A workspace with **no repository** starts no walk,
  so there was nothing to overwrite what the previous one published: opening a
  bare workspace left the last repository's commits on screen. `resetHistory()`
  now clears the report on a workspace change, for the same reason the filters
  and the navigation history are cleared.

**No repository is not an error.** The walk is skipped and `historyError` stays
nil. That distinction is what `vbx-cbw`'s column stands on: not-loaded,
loaded-with-nothing and no-repository have to be three different answers.

**A cost the suite made visible.** Every store the tests open would now start a
walk, and dozens at once is contention the harness pays for and learns nothing
from — so `loadsHistoryEagerly` exists, defaulting to true and turned off by the
fixtures, the same bargain `skipPhase2` already strikes. The dedicated suite
opts back in. The wait budget in those tests is deliberately generous: in a run
where the walk was still in flight at ten seconds, the test's own setup had
taken ~65 — a tight budget there measures the machine's load, not the feature.

Tests: `Eager history` — the report loads without the History view, a
repository-less workspace is neither loaded nor an error, the three states are
distinguishable, `HEAD` resolves to where git actually keeps it, a `gitdir:`
pointer is followed, an unreadable `.git` file installs no watch, and a stale
walk publishes nothing. 537 passing, green three runs in a row.

---

## 2026-08-24 — Labels are editable from the list (vbx-dot)

Double-clicking the Labels cell now opens a menu of the workspace's labels, each
one toggling, with `New Label…` at the bottom. The write is `br label add` /
`br label remove`, one invocation for the whole selection — `br` takes several
issue ids, so there is no half-applied state to report.

**The editor is a menu, not a token field.** The common case is applying a label
the workspace already has, which is one click; creating one is rarer and gets an
item of its own. A token field is better at free text and is a second editing
mechanism to build and keep — an `NSTokenField` in a table cell is its own
project.

**Presence has three answers.** Across a selection a label may be on some beads
and not others, so the checkmark is on, off, or mixed. Clicking a mixed one
*applies* the label to the rest rather than clearing it: the click after a mixed
checkmark is far more often "make these the same" than "take it off the ones
that have it".

**The double-click conflict, resolved.** A pill's double-click used to toggle
that label as a *filter*, and the cell's double-click now edits — one gesture
cannot mean both. Filtering keeps two homes, both showing more than the gesture
did: the sidebar's Labels section with counts, and the Labels surface with all
of them rather than only those a visible row carries. The gesture was also the
least reliable of the three, being exactly what ADR-014 records as not working —
a SwiftUI gesture on hosted content inside a table.

Removing it left `toggleLabelFilter` with no caller in Sources. Deleting it
would have been the clean-break move and would have been wrong: it does
something the sidebar's rows did not, namely clear an active recipe, because a
recipe owns the filter wholesale and one the user has since edited by hand is no
longer the recipe's. The sidebar now routes through it, which removes an
inconsistency rather than the function.

**A latent bug found on the way.** `rowMenu` built its priority submenu with
`priorityMenu(Self.specs[1], ids)` — and `specs[1]` stopped being the priority
column when the uncommitted gutter was added in front of it. It was harmless
only because the parameter was never read. The parameter is gone, which is what
makes it stay harmless.

Tests: `Label editing` — the argument vectors are pinned (the ids are
positional and the label is an option, the reverse of `update`), a label round
trips through `br`, one invocation covers a selection, presence is three-way, a
closed bead refuses through ADR-017's gate, an empty label is not written, and
filtering keeps its homes. `Table columns` had its editable-column list updated,
deliberately. 528 passing.

---

## 2026-08-24 — History is only offered where there is a repository (vbx-x8x)

History correlates beads to commits. A workspace outside a git repository has
none, so the surface had nothing to show and was offered anyway.

`ProjectStore.availableSurfaces` is the list, and all *three* places that offer
a surface now read it — the toolbar picker, the sidebar's Views section, and the
View menu in `VBXCommands`. The bead named two; the menu was the third, and a
command that switches to a surface neither control offers would strand the user
on a view they cannot leave by the route they arrived.

**How "is there a repository" is answered.** The bead weighed `gitHeadPath`
against `store.revisions` and neither is right:

- `gitHeadPath` tests `<workspace>/.git/HEAD`, one level only, so it answers
  "no" for a `.beads` directory in a *subdirectory* of a repository — where
  History works. Hiding a surface that would have worked is the more annoying of
  the two mistakes.
- `revisions` is exact but lazily loaded, so "not loaded yet" and "no
  repository" would be the same answer: absent read as zero, the trap ADR-015
  exists to avoid.

So `gitRepositoryRoot` walks up from the workspace looking for `.git`, and
accepts it as a **file** as well as a directory — which is what it is inside a
worktree or a submodule. That is not an exotic case here: this repo's own
discipline puts every session in a worktree.

**The selected surface falls back.** Opening a repository-less workspace while
on History leaves `surface` naming a view nothing offers — hidden from every
control and still rendered, which is worse than what was being fixed. It moves
to `.list`, and only in that case: an open must not quietly move the user off
the view they chose.

**A limitation this uncovered but did not change.** `gitHeadPath` still tests
one level, so ADR-015's `HEAD` watch does not fire in a worktree, where `.git`
is a file — meaning dirty marks there do not clear on commit until something
else forces a reload. Pre-existing, out of scope for this bead, and worth fixing
where the watch lives rather than here.

Tests: `History needs a repository` — hidden without one, offered with one, a
workspace one level down still counts, a `.git` file counts as much as a
directory, the selected surface falls back, and a valid one is left alone. 521
passing.

---

## 2026-08-24 — The toolbar's filter menu is gone (vbx-bcj)

It was the *third* copy of one setting. The sidebar's Filters section shows all
four with a count each — strictly more than a menu showing one value behind a
disclosure — and the View menu already carried `Filter: Open/Ready/Closed/All`
as commands.

That last fact is what settled the bead's open question. It asked whether a
collapsed sidebar would be left with no filter control, and named that as the
real argument against removing this. The answer turned out to already exist in
`VBXCommands`: the menu bar is always present, collapsed sidebar or not. Nothing
had to be built, but the test now asserts those commands exist — without them
this change really would be removing the last reachable control for someone who
works with the sidebar hidden, and that should fail loudly rather than be
rediscovered.

`showsFilterAndSort` became `showsSort`, because it now gates one control and a
comment describing a picker that no longer exists is how the next person is
misled.

The new assertions read the *source*, which is unusual here and deliberate: a
toolbar is window chrome, an `NSHostingView` of `ContentView` never builds one,
and a render-based check would pass whether or not the picker was there. What
can be checked honestly is that the declaration is gone and the two replacements
are declared.

Tests: `Toolbar sort` — the control follows the ordered surfaces, the eight
payload views hide it, every surface stays classified, the toolbar declares no
filter picker, both remaining routes exist, and the sidebar's rows still drive
the query. 515 passing.

---

## 2026-08-24 — Beads now say which repository they came from (vbx-pjf)

`br` stamps `source_repo` with the basename of the directory it runs in, and
this repo's discipline is that every session works in a worktree. The two rules
fight, and the worktree rule is the right one — so 30 of 54 records carried a
throwaway topic name and 29 named a path that no longer existed, 19 of them the
pre-rename `bvx` checkout.

Nothing reads the field today, and the ADR says so rather than inflating the
problem: `RepoInfo.owns(_:)` matches by id prefix and `--robot-repos` reports
this workspace as single-repo. The cost is latent, in a field `br`'s own help
calls the canonical location "for cross-machine sync awareness".

Rewrote all 30 through `br update` — a per-record diff, 31 lines changed, not
the whole-file rewrite that would mean clobbering another session. The 19 `bvx`
records became `vbx`, which is a decision rather than a cleanup: they *were*
filed in a directory of that name, but the rename was a rename of this same
project, and two names for one repository is the phantom-repository problem in
miniature.

`scripts/beads-check.py` guards it from here, in the verify block. The canonical
name comes from git — the common git directory is shared by every worktree and
its parent is the primary checkout — so it is right from wherever it runs, which
matters because it will nearly always run from a worktree.

**A check rather than a convention, deliberately.** The value cannot be set
correctly at creation: `br create` has no `--source-repo` flag and
`.beads/config.yaml` holds only `issue_prefix`. That leaves "remember to run
`br update` after every `br create`" — the same class of rule that produced the
mess. A failing check makes forgetting a build failure with a one-line answer.
The real fix is upstream in `beads_rust`.

Tests: `test_beads_source_repo_check` — the export is clean, the canonical name
comes from git rather than a constant, and a scratch repo carrying a foreign
stamp is caught with the offending repository named.

---

## 2026-08-24 — Closed beads stopped accepting edits (vbx-78c)

The bead's open question first, because it decided the shape of everything else:
**does `br` already refuse a write to a closed issue?** No. Against a scratch
workspace, `br update --title` and `br update --priority` both rewrote a closed
bead and exited 0. So this is vbx's own rule, not vbx agreeing with the engine,
and ADR-017 says so out loud — a terminal `br update` still rewrites a closed
bead, and pretending otherwise would be worse than the gap.

`IssueStatus.isImmutable` is the whole rule: `closed` and `tombstone`. The
affordances consult it before opening — the field editor does not open, the
priority menu shows its reason instead of values — and `setTitle`/`setPriority`
check it again, because a gate is not a rule if the thing behind it still says
yes.

**Mixed selection: refuse as a whole**, naming the count. Applying to the open
beads and skipping the closed ones is a partial success that surfaces a week
later, when the beads that did not change look like beads nobody got to.

**An unknown status stays editable.** The status enum is open on purpose, and
refusing an edit is the more surprising of the two failures — nobody would
report it, they would assume the bead was closed.

The write-path test was nearly a test of nothing: CLAUDE.md warns that writes
against the fixture used to fail for unrelated reasons, so a refusal test could
pass while proving only that the fixture is unwritable. Removing the guard and
re-running settled it — `br` wrote the closed bead and its priority went 0 → 3,
which is both the discrimination check and the direct evidence for the ADR's
central claim.

Tests: `Immutable statuses` in core (closed and tombstone, nothing else, unknown
stays editable) and `Immutable closed beads` in the UI suite — the refusal names
Reopen, an open bead is untouched, a mixed selection counts what stopped it, a
stale id does not refuse for the others, the write itself refuses through `br`,
and the tooltip precedence. 512 passing.

---

## 2026-08-24 — The mark moves into the gap, not just closer to it (vbx-be4)

Halving the gutter to 10pt moved the mark 10pt and stopped, which still read as
far from the id. Measuring the real table said why: the gutter's cell is
x=16…26, the id cell starts at 43, and the 17pt between them is the table's own
`intercellSpacing` — an inset-style `NSTableView` sets it, it applies between
every pair of columns, and it is not settable per column. Narrowing a column can
only ever move its content by the width removed.

So the glyph overhangs into the gap instead. `BeadColumnSpec` grew
`contentTrailingInset`, defaulting to `contentInset` and allowed to go negative;
`HostedCell` holds leading and trailing separately. The gutter asks for -13,
which puts the mark about 4pt short of the id cell.

Overhanging is only safe in this direction: the gap belongs to no column, so
drawing in it covers nothing. An overhang as long as the spacing would reach the
next column's *content*, which is why the test asserts it stays shorter than
`intercellSpacing` rather than just asserting the mark looks right.

**The test took three attempts, and the failures are the interesting part.**
First version measured how far across a strip the first ink appeared: it passed
alone and failed in the parallel suite, because the strip started outside the
row and the step from the window's background to the row's counted as ink.
Confining it to the row left 0.8% ink in the far zone — antialiasing at a zone
boundary — so demanding exactly zero failed on that rather than on the mark's
position. It now compares the ink in the 14pt before the id against the ink
before that, which is the actual claim: the mark is *there*, not *here*.
Confirmed to fail with the overhang removed, and the full suite ran green twice.

---

## 2026-08-24 — A deleted bead gets a name, not a row (vbx-iyy)

The open question left by the gutter: `+` and `*` shipped, `-` did not, because
a deleted bead is gone from disk and nothing in `visibleIssues` represents it.
This decides it rather than deferring it again.

**No synthesised rows.** The records are available — `compare` already reads the
committed set through `snapshot_at` — so injecting the removed ones is the easy
half. The hard half is what such a row *is*: no metrics (absent, not zero, since
`GraphMetrics` covers the beads on disk), every edit refused because `br` has
nothing to write to, and the same question again for the board, graph, tree and
detail pane, which read the same beads. Filtering, sorting, recipes and hybrid
search would all run over it, and the engine that ranks those ids does not know
the bead exists.

That is every feature that reads the workspace learning about a bead the
workspace does not contain, to show a row nobody can act on. Spread the cost
across the app, and the benefit is one glyph.

**What a deletion gets instead is a name.** The status bar already counted
removals; it now names them. `BeadDirtyState.summary()` lists the removed ids —
sorted, bounded, and saying how many it left out — so "which bead went?" has an
answer. Ids rather than titles, because the record is gone and the id is the
handle that still resolves against the commit.

The formatting moved from `ContentView` into `BeadDirtyState`, next to
`Mark.reason`: it is a description of the state, the state already owns the
words for its other cases, and a private computed property in a view is not
testable.

Tests: naming (present, sorted), bounding (`+7 more` rather than silent
truncation), clean and unknown reading differently — absent is not zero — and
that `mark(for:)` still answers nil for a removed bead while `total` still
counts it. That last one is the test to reconsider first if a `-` is ever
wanted.

---

## 2026-08-24 — A release regenerates the HTML it invalidates (vbx-uq4)

`docs/html/` is generated from `docs/*.md` and committed, and nothing
regenerated it when a release rewrote `docs/RELEASES.md`. So the one page whose
whole purpose is listing releases was the page guaranteed to go stale: it was
missing 0.1.2 and 0.1.3 when this was noticed, and went stale again for 0.1.4
and 0.1.5 while the bead sat open.

Both halves, because either alone leaves a hole:

- **`build-docs.py --check`** renders to a temporary directory and compares,
  naming any page that differs — and any committed page whose source is gone,
  which is drift in the other direction. In the verify block beside the other
  four checks.
- **`version-bump.sh` regenerates** after writing the notes, and commits the
  HTML in the same commit. In the *script*, not in `release.yml`, for the reason
  the workflow holds no logic of its own: a bump run by hand has to leave the
  same tree as one run by the workflow, or the next person's verify block fails
  on someone else's release. The workflow gained a `pip install markdown` step,
  since the bump now needs what `build-docs.py` imports.

A missing `build-docs.py` is tolerated — the versioning tests run against a
scratch repository holding only the scripts under test — but a *failing* one
stops the release rather than committing notes whose HTML disagrees with them.

**The check was not offline when first written.** It called `build()`, which
vendors mermaid from a CDN when the bundle is absent. In a checkout the bundle
is committed so it never fired, which is exactly the kind of thing that works
until it does not: a check that reaches the network passes at a desk and fails
on a plane. `build(vendor:)` now exists so the check can decline, and the test
asserts it on the source rather than on a run that happened to succeed.

Tests: `test_docs_html_check` (matches, does not fetch, catches drift, names the
page) and `test_bump_regenerates_the_html` (the bump renders the notes, the tree
is clean afterwards, the HTML is committed rather than left dirty). The bump's
scratch repository now carries `build-docs.py`, a page to render and a stubbed
mermaid asset, so the regeneration is exercised rather than skipped. 242 passing.

---

## 2026-08-24 — The gutter is half as wide, and its mark sits against the ID (vbx-tkx)

20pt to 10pt, and the glyph moved from the leading edge to the trailing one, so
it reads as attached to the bead whose id is immediately to its right instead of
floating at the left of the window.

Two things made this more than two numbers, both of them the same constraint
seen from different sides: `HostedCell` pins its hosting view to both cell edges
and aligns content leading, in *one* place, precisely so a column cannot forget
to do it. So:

- **The alignment is declared on the spec.** `BeadColumnSpec.contentAlignment`
  defaults to `.leading` and `HostedCell` reads it. Wrapping the gutter's own
  content in a trailing frame would have worked and would have put the decision
  back in the place the rule exists to take it out of.
- **The inset is declared on the spec too.** 4pt each side of a 10pt column
  leaves 2pt, and the glyph clips. The gutter asks for 1pt; everything else
  keeps 4.

`HostedCell` now keeps its edge constraints so the inset can change, rebuilt
only when a spec asks for a different one — a cell is reused across the rows of
one column, so this is not per-row work.

Checked by rendering rather than by reasoning, because at 10pt "tight" and
"clipped" are two points apart: the mark drew complete in a real list, and the
clipping guard was confirmed to fail at a 4pt inset, where 2pt of content leaves
a sliver that would still have satisfied "there is ink here".

Tests: `The glyph still fits once the gutter is halved` renders the same mark in
the real content width and in a generous one and requires the same ink;
`The gutter is the one column on the other edge` asserts the trailing alignment
*and* that every other column kept the default, which is the half that says the
rule still holds. 499 passing.

---

## 2026-08-23 — The uncommitted state is a gutter mark, not a row tint (vbx-r0m)

The row background was tinted `controlAccentColor` at 12% when a bead was ahead
of `HEAD`. Two things were wrong with it, and neither is cosmetic: the tint
could say only *something here is uncommitted*, collapsing the three cases
`BeadDirtyState` keeps apart; and it was suppressed while a row was selected, so
selecting a dirty row hid the fact it was dirty.

A fixed 20pt column before the ID now draws `+` for added and `*` for changed.
`BeadRowView` existed only to paint the tint and is gone with it.

**`-` is deliberately absent.** A deleted bead has no row — it is gone from
disk, and nothing in `visibleIssues` represents it. Surfacing removed beads as
rows synthesised from the `HEAD` snapshot was considered and deferred: such a
row carries no metrics, must refuse every edit and every `br` write, and has to
mean something on the board, graph and tree as well. That decision is its own
bead; until it lands a deletion shows up only in the toolbar count, which has
always included it.

Details worth keeping:

- **The mark and its explanation are one thing.** `Mark.reason` sits on the enum
  in `VBXCore`, so the glyph and the tooltip cannot drift, and the tooltip
  answers for the *whole row* — asking someone to find a one-character gutter
  before they can learn what it means would repeat the mistake the tint made.
- **Both marks take the same accent.** A second colour would imply a severity
  ordering between "new" and "edited" that does not exist.
- **The column is protected.** It is now the only surface a row has for this
  state, so hiding it would leave the state with nowhere to appear. Its
  identifier is hand-written (`dirtyMark`) because it is unsortable, which is
  the position the type glyph is already in.

**A bug found on the way**, and the reason this is not a pure rendering change:
the table reloads only when its row fingerprint changes, and the fingerprint was
built from the bead record alone. A commit touches no bead, so every mark
cleared while the fingerprint stayed identical and the gutter kept drawing marks
for committed changes. Logged in BUGS.md with a regression test confirmed to
fail on the unfixed code.

Tests: `Uncommitted beads` grew to 11 — the three glyphs, an unknown state
marking nothing, a reason for every case over `allCases`, ink on the rendered
cell, the column's position and protection, the fingerprint regression, and an
end-to-end one that writes through `br` and requires ink in that bead's gutter
cell of an actually-rendered `IssueListView`, with a clean row in the same table
as the control. That last one exists because this repo has shipped a table
feature every unit test agreed with and that did nothing in a real build; it was
confirmed to fail with the glyphs blanked.

The two tint tests are gone, and `Table columns` had both of its enumerated sets
updated — deliberately, since both exist to make a change here a conscious act.

One unrelated test moved: `Cell alignment` renders the list at a fixed width and
measures where ink starts in a given column. Twenty more points of columns put
Labels at x=1114 in an 1100pt host, off the right edge, where it drew nothing —
which reads as an alignment failure rather than as a viewport too narrow. It had
about 6pt of itself visible before, so the harness was lucky rather than roomy.
Widened to 1400; the assertion is untouched.

Two follow-ups filed: `vbx-iyy` carries the deleted-row decision above, and
`vbx-uq4` records that nothing regenerates `docs/html/` when a release rewrites
`RELEASES.md` — found because regenerating for this change also pulled in 0.1.2
and 0.1.3, which had been missing from the committed HTML.

---

## 2026-08-23 — A bead-only commit no longer cuts a release (vbx-r0m)

`vbx-r0m` was written down and pushed as PR #52, and shipping it would have
released 0.1.3. `release.yml` advances the version on every merge, and
`version-bump.sh` had no level below patch: a missing `semver:*` label defaults
to patch, so a commit whose whole diff was one added line of
`.beads/issues.jsonl` was about to become a version, a tag and an entry in
`RELEASES.md` describing an issue nobody can install.

The rule now is that a commit touching nothing outside `.beads/` contributes no
level, and a run finding only those exits without tagging. Two details are the
whole of it:

- **The test is the diff, not the subject.** A PR that changes code *and* a bead
  is a real change. The condition is "no file outside `.beads/`", not "any file
  inside it", and there is a test for exactly that shape.
- **Skipped commits are named.** They print as `beads-only`, because a commit
  that silently did not count is indistinguishable from one the script never
  saw — the same argument ADR-013 already makes for announcing the default
  label.

`git show --pretty=format: --name-only` rather than `git diff-tree`, so a root
commit lists its files instead of nothing; a commit with no files at all is
deliberately *not* bead-only, which keeps an unknown case on the path where it
is at least reported.

Checked against real history as well as the synthetic repos: a dry run on this
branch reports `Only bead bookkeeping has landed since 0.1.2`.

Tests: `test_beads_only_does_not_release` in `scripts/test-packaging.py` — eight
assertions covering the bookkeeping-only run, the mixed run where the notes
carry the change and not the bead, and the code-plus-bead commit that still
bumps.

---

## 2026-08-22 — The API cannot issue a Developer ID certificate; the portal can

`signing-setup.sh` was run for real and Apple refused:

    This request is forbidden for security reasons:
    This operation can only be performed by the Account Holder.

Which is what `--check` had warned about, but the warning implied the problem
was the *key's* role and therefore fixable. It is not: Account Holder is not
among the roles a **Team** key can be given, so no team key will ever create a
Developer ID certificate. An *Individual* key made by the Account Holder carries
that person's role and might; worth one attempt, not a plan.

So the script gained the route that always works. `--csr` generates the request
locally — reusing the key and CSR a failed `asc` run already left behind, which
matters because a fresh key would not match a certificate issued for the old
request — and `--import` installs what the portal returns.

`--import` refuses a certificate with no matching private key, and says why. A
`.cer` imported alone is not a signing identity: it appears in the keychain,
`security find-identity` does not list it, and `codesign` cannot use it. That
failure would otherwise surface much later, during a release.

Notarization is unaffected: it has no role restriction, so the Team key already
configured is enough for that half.

---

## 2026-08-22 — Working towards a signed build

Asked whether a signed release was possible yet. It is not, and the reason was
worse than the one on record: `package-app.sh --check` reported "Developer ID
cert in the keychain" while `VBX_DEVELOPER_ID_APP` pointed at an **Apple
Development** certificate. The check grepped for the configured string rather
than the certificate's kind, so it confirmed the string was present, not that it
was usable. There is no Developer ID Application certificate on this machine at
all. (Another session found the same thing and has PR #40 open fixing the check
— left alone rather than duplicated.)

Two blockers, then, both needing the Apple account. What could be done here was
to collapse them into one credential and make the path to it short.

Notarization now accepts an App Store Connect API key as well as a `notarytool`
keychain profile, and prefers it. A profile lives in one login keychain: it
cannot go to CI, cannot be shared, and needs an app-specific password that
exists for no other purpose. An API key is the same credential that issues the
Developer ID certificate, so there is one thing to obtain rather than two.
ADR-017.

`scripts/signing-setup.sh` turns getting the certificate into one command
against `asc`, with a `--check` that names what is missing and a `--dry-run`
that works before any credential exists — which is when reading the plan is
most useful. The key and certificate go to `~/.vbx-signing`, outside the
checkout, because this repository is public.

Proved the rest of the pipeline is not the problem: an ad-hoc
`--dmg --no-notarize` build produced a 50 MB universal disk image, both slices,
signed and verified. The certificate really is the only missing piece.

---

## 2026-08-22 — History loses the filter and sort it never read

`vbx-ec6`, the decision left open when the other seven engine-payload surfaces
had the controls hidden. History was held back because it sits beside the
revision scrubber, and there was a real question about whether it should gain a
filter and sort meaning something in its own terms — narrowing the commit walk,
ordering the correlated beads.

Answered by looking at what it reads: `store.history`, and neither `query` nor
`visibleIssues`. Both controls were as inert there as on Attention or Plan.

Dropped rather than given a meaning. Inventing a feature to justify a control
already on screen is the wrong way round, and nobody has asked what filtering a
history should do. If that need appears it arrives as its own request, with its
own idea of the answer.

`ToolbarControlsTests`' `deferred` set is now empty and stays as a named empty
set, so the next deferral has somewhere to go rather than hiding as a quiet
`true` in the switch.

---

## 2026-08-22 — The three list beads

`vbx-00c`, `vbx-06t`, `vbx-bct`, filed from using the 0.0.5 build and
implemented together because they all touch the same table.

**Alignment** was the interesting one. Reported for the label pills; it was
every hosted column, and a regression from the `NSTableView` move earlier the
same day. One line at the cell rather than ten at the columns. The test measures
leftmost ink, because ink coverage cannot distinguish centred from leading — and
there is a second test asserting the measurement itself discriminates, which is
the guard the vacuous double-click test taught us to write.

**The combined `Blocked/by` column** ships unsortable. A sortable column's
identifier must equal its `SortColumn` raw value, so sorting would have needed a
new enum case *and* a definition of what the order is — by blocks, by
blocked-by, or the sum. None is obviously right and the two single-value columns
already sort, so nothing was invented. Zero renders as `—`, matching those
columns, because "Blocks: —" beside "Blocked/by: 0 / 2" would read as two
different facts about the same number.

**Uncommitted beads** are defined against git rather than tracked by vbx: a
record differing from the same record at `HEAD`, read through the engine's
`snapshot_at`. Nothing stored, so nothing to invalidate when someone runs `br`
in a terminal or checks out a branch. `.git` is watched alongside the bead file,
because a commit moves `HEAD` without touching the export and the existing watch
would never fire. ADR-015 has the rest.

That one needed a fixture that is a real git repository with a commit —
`Fixture.committedStore()` — since `writableStore()` has no history and would
have made the state permanently "unknown". It was the largest single piece, as
the bead predicted.

An existing test earned its keep: it asserted that `type` was the only
identifier not derived from `SortColumn`, and the new column broke it. Rewritten
to state the actual rule — *sortable* columns take their identifier from their
`SortColumn` — so the next unsortable column will not mean editing a test to
keep it passing.

---

## 2026-08-22 — The bead list moved to NSTableView, and titles are editable

Asked whether we were using the wrong widget, given that double-click-to-edit is
ordinary macOS behaviour. The honest answer was no — SwiftUI's `Table` renders
editable cells fine — but it cannot say *which cell* was double-clicked, and
that is the thing more editing needs. So the list is `NSTableView` behind an
`NSViewRepresentable` now, with `clickedRow` and `clickedColumn` doing the work.

Cell appearance stayed SwiftUI, hosted in the cell. That kept the whole visual
layer — chips, pills, badges, metric placeholders — unchanged, and is why the
diff is much smaller than replacing a table usually is.

Title editing is the first thing it buys: double-click a title, the field editor
opens in place, Return commits through `br update --title`. A title full of
quotes, `$` and backticks survives, because the argument vector goes to
`Process` and never through a shell — asserted, since that is the kind of thing
that is fine until someone adds a shell.

Two things fell out of the move. A column is declared once now, so the tests
that used to *parse `IssueListView.swift` as text* to pin column order and
identifiers became ordinary assertions — those parsers had silently matched
nothing the moment the table changed shape, which is how they were noticed. And
`PriorityCell` is deleted; its popover was the mechanism that never worked.

Also fixed on the way: a `Codable` + `RawRepresentable` layout type that
recursed into itself and took the whole test runner down with SIGSEGV. See
BUGS.md — `--no-parallel` is what found it. ADR-014 has the decision.

---

## 2026-08-22 — Two bugs found by running the app, and a third underneath

Both reported from a real build: priority editing missing, and the About window
taking 5+ seconds to open.

Priority editing was present and unreachable. `br` was found and `canEditBeads`
was true, so the gate was not the problem — the double-click was. A gesture on a
`Table` cell never fires, because macOS hands the click to `NSTableView` for row
selection. Moved to the row context menu, which is `Table`'s own mechanism, and
which is where a macOS user looks anyway; the double-click had no affordance at
all on a 30pt column.

The About window was 227 KB of licence text in a single `Text`. Measured at
7.1 s of layout; chunked into a `LazyVStack`, 0.01 s. Text selection was not the
cause, which was worth checking before rewriting anything.

The third bug is the one that explains the first. No test had ever exercised a
real write, and none could have: `br update` against the demo fixture fails
because 13 of its records carry dependency rows without `created_at`, which
`br`'s preflight requires — and it rejects the whole workspace over it. The
fixture's rows now have it, which is what made the end-to-end priority test
possible.

Both fixes were confirmed to fail before they passed: the timing assertion by
forcing the notices back to one chunk, the double-click test by the fact that it
passes at all. See BUGS.md.

---

## 2026-08-22 — The About box's version, actually verified

Asked whether the build version shows in the About window. It does in the real
app — a built bundle carries `0.0.1 (42)`, stamped from the tag — but the
offscreen render showed a blank row where it belongs, and probing confirmed why:
in a test process `Bundle.main` is SwiftPM's helper binary and has no version
keys at all.

The gap that mattered was not the blank row. The version had just become
dynamic, travelling five hops from the git tag to the About box, and nothing
tested the last two. The test whose name promised it did asserted something
else entirely.

`versionLine(from:)` now takes the info dictionary so the formatting is
testable, the header omits the row when there is nothing to show, and the
stamping hop is asserted in the packaging suite against a real bundle. Both new
checks were made to fail first. `inkCoverage(in:)` gained a region so the header
could be measured without the notices pane below it clearing the threshold on
its own. See BUGS.md.

---

## 2026-08-22 — Versions advance from a PR label, and the notes generate themselves

`vbx-xi1`. Picked up after the session that filed it left no worktree and no
branch. It overlaps the version work above deliberately: `scripts/version.sh`
had already made the tag the single source, so what was left was deciding the
next tag and turning the tags into something a user can read.

The decision that shaped it: the bump level cannot come from the commit
subject. Subjects here are prose by house style, and a Conventional Commits
parser reads all 38 of them as no bump. So the level is a `semver:*` label on
the PR — set during review, when the person setting it knows what the change is
— read once by `scripts/version-bump.sh` and written into the annotated tag.
Everything after that reads git alone, which is what lets
`release-notes.py --check` sit in the verify block without reaching the network.

A missing label is a patch *and a printed line saying so*; a silent default is
how a feature ships as a patch. Before 1.0.0 a breaking change bumps MINOR.

`docs/RELEASES.md` is generated, user-facing, and deliberately not a fourth copy
of BUGS.md and WORK_LOG.md. `.github/workflows/release.yml` — this repository's
first workflow — runs the bump on merge and nothing else; it is idempotent
because pushing its own release-notes commit re-triggers it. The `semver:*`
labels still need creating on GitHub. See ADR-013.

---

## 2026-08-22 — Universal builds, a version from the tag, and a cask to paste

`vbx-ttx`, `vbx-j3o`. Two beads that turned out to be one piece of work: a
Homebrew cask cannot be written until the artefact it points at is both
installable everywhere and versioned by something other than a literal.

`lipo -archs` on the built app reported `arm64` and nothing else, so the `.dmg`
would not have launched on an Intel Mac at all. Half the fix already existed and
had never been wired up — `build-engine.sh --universal` was written, and nothing
passed it. Now `--universal` reaches SwiftPM as `--arch arm64 --arch x86_64` for
both products, distribution builds imply it, and both binaries in the bundle are
checked with `lipo -archs` rather than trusted to the flag. That check earned
itself immediately: `lipo` strips the linker's ad-hoc signature when it fuses
the slices, so the local signing step had been failing silently and the bundle's
nested CLI now gets signed first.

`CFBundleShortVersionString` was the literal `0.1.0`. `scripts/version.sh` reads
the git tag instead, with the commit count as the build number, and refuses a
release from a dirty tree or a HEAD that has moved past its tag.

`scripts/release.sh` runs the whole path — tag, universal build, notarize,
verify the ticket stapled, checksum, render the cask — and prints the stanza
ready to paste. Nothing has been published: there is no tagged release and no
tap repository, so `brew install --cask vbx` does not work yet. That is
deliberate and it is written down in the design doc's status rather than implied
by the presence of the script. See ADR-012.

Chased the remaining blockers afterwards rather than leaving them as a list.
`--lint-cask` runs `brew style` on the rendered cask without a build, and found
four real offences the first time: a missing frozen-string comment, "macOS" in a
cask description, mis-grouped stanzas, an unsorted `zap` array. `brew audit`
deliberately is not run — it takes a cask name, which needs an installed tap.

And the reason `package-app.sh --check` reported nothing configured turned out
not to be a missing certificate: `scripts/signing.env` still used the pre-rename
`BVX_` prefix and had been inert since #13. Repaired, with a check that names
the stale prefix instead of falling through to "unconfigured". The Developer ID
certificate was in the keychain all along. What is genuinely still missing is
the notary profile — `xcrun notarytool store-credentials` needs an Apple ID —
and the tap repository.

---

## 2026-08-22 — Launch stopped opening onto an error

`vbx-jo9`. Launching from the Dock always showed "Could not open workspace",
because discovery ended at the current directory and a GUI app's is `/`.
Candidates are probed now rather than opened, the recents list joined the order,
and a launch with nothing to discover lands in the neutral empty state. The
error state is unchanged for anything the user actually chose. See BUGS.md.

---

## 2026-08-22 — The bead list crashed when scrolled

Reported as "vbx crashes when opening workspace of1". It was not about that
workspace, and not about opening: of1 has 327 beads where vbx's own has 38, so
of1 was simply the first list long enough to scroll. `PriorityCell` read its
store with `@EnvironmentObject`, and macOS `Table` builds a cell's subgraph when
the row scrolls into view — a subgraph that does not carry the
`environmentObject` injected around `ContentView`. Every row created after the
first layout pass trapped.

Reproduced in a hosting-view harness before touching anything, which is what
turned an intermittent user-visible crash into a two-line fix: the store is now
handed in, matching what the other nine columns already do.

Swept every other surface for the same shape and found none —
`LazyVStack`/`LazyVGrid` inherit the environment, `Table` is the one container
that does not. See BUGS.md for the sweep and the two regression tests.

---

## 2026-08-22 — An About window carrying the licence notices

`vbx-x18`. The default About panel showed a name and a version while the engine
linked 66 third-party modules, several of which require their notices to travel
with the binary — and one of which requires its rider carried unmodified, with
breach terminating the licence to the engine vbx is built on. None of it
reached a user.

`scripts/build-notices.py` generates `Resources/ACKNOWLEDGEMENTS.md` from
`go.mod` and the module cache; the result is committed and `--check` is in the
verify block. Committed for the same reason as the icon: regenerating needs a
populated module cache, and `build-app.sh` has to bundle a shippable app on a
bare clone. `--check` deliberately validates against `go.mod` rather than
regenerating, so it works on a clone with no cache — which is most of the point.

Three dependencies cannot be handled by reading one licence file, and each is a
real case here rather than a hypothetical:

- **`golang/freetype`** is dual-licensed, FreeType *or* GPLv2. The notices state
  which arm vbx takes, because a reader who is not told assumes the GPL one.
- **`cyphar/filepath-securejoin`** carries three licence files (a summary, BSD-3
  and MPL-2.0). MPL is per-file copyleft, so the notice points at upstream for
  the source of the covered files.
- **`mattn/go-localereader`** ships *no* licence file; its README is the only
  statement of terms, so the README is what is reproduced.

A generator that took the first licence file it found would be wrong about two
of the three, so they are declared rather than discovered.

`build-app.sh` now **fails** rather than warns when the notices are missing: an
icon-less bundle still runs, but a bundle without these is not distributable.

The About window is a `Window` scene, not something a `WorkspaceWindow` owns —
it names the app, and with per-window stores anything a workspace window owned
would multiply. Name and version come from the bundle rather than literals,
which would drift against `build-app.sh` where the real ones are written.

---

## 2026-08-22 — Per-segment tooltips, and one window per workspace

`vbx-2wp`, `vbx-zlu`.

**The view switcher's segments each name their view now** (`vbx-2wp`). The
bead asked whether `.help` on the labels inside the picker reaches the
segments. It does not: with a `.help` on all twelve labels,
`toolTip(forSegment:)` is nil for every one, and the control's own tooltip is
nil too. A segmented picker is one `NSSegmentedControl` and per-segment
tooltips have no SwiftUI surface at all.

Rather than the bead's fallback — replacing the picker with buttons, which
costs its keyboard handling and system styling — the tooltips are written onto
the control through the same AppKit-introspection pattern the column markers
and link cursors already use. The search starts at the nearest ancestor
holding a segmented control rather than at the window, because the toolbar has
three of them and starting at the top would label the wrong one.

**One window per workspace** (`vbx-zlu`). The store moved from the `App` to a
per-window `WorkspaceWindow`. That is the whole change: `WindowGroup` always
made several windows, they simply all rendered one store.

Decisions the bead asked to be resolved, and how:

- **The scene is keyed on the workspace path.** Free state restoration, and
  `openWindow(value:)` raises the window already showing a path instead of
  opening a second one — so a recents entry or a `vbx://` link goes to the
  window that already has it.
- **Commands act on the key window** through `@FocusedValue`, not a captured
  store, and disable themselves when there is no focused window. A menu item
  that silently acted on the wrong window would be worse than a disabled one.
  The export sheet is focused the same way, so ⌘⇧E opens it on the window
  being looked at.
- **`RecentWorkspaces` became app-wide** (`.shared`). Where you have been
  belongs to the person, not to one window, and every window writes the same
  preferences key — without sharing, a workspace opened in one window would be
  missing from the other's menu.
- **The tutorial gets its own store.** It reads `surface` to highlight the
  matching section, and following whichever window was last focused would make
  it jump around while being read.

**Left unresolved, deliberately:** the two Settings toggles — terminal keys and
skip-Phase-2 — are still per-workspace, so Settings binds to the focused
window and says so when there is none. They read like app preferences rather
than workspace state and probably should become exactly that, but changing
where they live is a separate decision from where the store lives.

Multi-window behaviour itself is not assertable headlessly; what the tests pin
is the property the change rests on — two stores share nothing: workspace,
surface, filters, selection and navigation history are all per-store.

---

## 2026-08-22 — Six beads: columns, label filters, and the first write path

`vbx-zu2`, `vbx-lmj`, `vbx-ce2`, `vbx-s0k`, `vbx-jg8`, `vbx-z8a`.

**A Created column** (`vbx-zu2`). Only Created was missing — `Updated` had been
there since the list was built, and `IssueRow.createdKey` plus
`SortColumn.created` already existed, so this was the header nobody had added.

Adding it broke the build in a way worth recording: `@TableColumnBuilder`
accepts **at most ten columns**, and this was the eleventh. The columns are now
split across three builder properties, which also fixed a type-check that had
grown past what the compiler would solve in reasonable time.

**`disabledCustomizationBehavior` does not enforce anything** (`vbx-lmj`). It
governs the menu affordance only. A stored layout marking `id` hidden really
did hide the identifier — measured, not theorised — so the customization is now
sanitised on the way in and out, forcing the protected columns visible. The
menu entry and the enforcement are separate problems and needed separate fixes.

**Filtered label pills are shaded, and double-clicking a pill toggles the
filter** (`vbx-ce2`, `vbx-s0k`). Toggling clears an active recipe: a recipe
writes `query` wholesale, so a filter edited by hand is no longer the recipe's,
and leaving it active would keep the sidebar claiming a recipe that no longer
describes the screen.

**Bead links get a pointer and a tooltip** (`vbx-jg8`). The attributes set in
`vbx-tdk` never arrived: `.link`, colour and underline cross into the backing
`SelectionTextField`, while `appKit.cursor` and `appKit.toolTip` are dropped —
so the tooltip had been silently broken since it was written. `BeadLinkCursors`
adds real cursor and tooltip rects, deriving the ranges from the field's own
`.link` attribute rather than re-deriving them alongside the renderer. A test
asserts the cursor attribute is still absent, so if SwiftUI ever starts
honouring it the overlay can be deleted.

**Priority editing — vbx's first write to bead data** (`vbx-z8a`). It goes
through `br update <id> --priority <n> --json`, run in the workspace directory,
followed by a reload; nothing here touches the JSONL, for the whole-file-export
reason in `BeadWriter`'s header. Editing refuses in two states, each explained
rather than silently inert: `br` not installed, and time travel, where an edit
would write today's data from a view of last week's.

Two findings from validating it against the real binary:

- **`br` cannot operate on the bundled demo fixture at all.** Its records have
  no `created_at`, and `br`'s preflight rejects them — so editing works against
  real workspaces and not against `Fixtures/demo`. The same gap is why the new
  Created column shows an em dash for every fixture bead, which at least
  exercises the missing-date path.
- **The command must run in the workspace root**, not `<workspace>/.beads`:
  `br` discovers `.beads` from its working directory.

`br` is now a runtime dependency for editing, and `BeadWriter.locateBR` checks
the usual install locations as well as `PATH`, because a GUI app launched from
Finder inherits a minimal `PATH` that holds none of them — without which
editing would work from a terminal launch and mysteriously not from the Dock.

---

## 2026-08-21 — Rule confined to the header, and a recents menu

**The hidden-column rule now marks the header only.** Run the full height of
the table it read as a division of the *content* — a coloured wall through the
rows, competing with the data for attention — rather than a note about the
columns. Below the header the boundary is an ordinary hairline, like every
other column edge. The header height is measured from the table's own
`headerView` rather than assumed, because it follows the system's control size.

That change fixed a bug that had shipped with the original: the overlay's hit
region ran the full height too, so a click on a row lying under the boundary
was swallowed and the row simply would not select. Hit-testing now stops at the
header, where the rule actually is.

**A Recent Workspaces submenu** in File, holding the last five, with the
conventional Clear Menu at the bottom. Deliberately not
`NSDocumentController`'s recent-documents list: vbx is not document-based and
what it reopens is a workspace *directory*, so the system list would both
mis-describe the entries and fight the app over which is current.

Three decisions worth keeping:

- **Recorded only after a successful open.** A path that failed to load is not
  somewhere the user has been, and offering it again would reproduce the error.
- **Entries that no longer exist are hidden but not forgotten.** Listing a moved
  folder and letting the click fail is worse than omitting it; deleting it from
  storage would mean an unmounted drive costs the user their history.
- **Re-opening moves an entry up rather than adding it twice**, which is what
  makes the list read as "where I have been" rather than "what I have clicked".

`RecentWorkspaces` takes its `UserDefaults` by injection so the tests never
touch the real preferences — and so two of them cannot see each other's entries
under parallel execution.

---

## 2026-08-21 — The hidden-column marker, after all

Follow-up to `vbx-gsd`, which shipped hiding without the accent rule and
recorded that the rule "cannot be layered on" because SwiftUI's `Table` exposes
no divider API and no column geometry.

**That conclusion was wrong, and the reason is worth keeping.** It was drawn
from SwiftUI's public API alone. On macOS the `Table` is built on a real
`NSTableView` — `SwiftUIOutlineTableView` inside a `ListCoreScrollView` — and
probing it settled three things the public API hides:

- the backing table is reachable by walking the view hierarchy;
- a column hidden through the customization menu **stays** in `tableColumns`
  marked `isHidden`, so a run of hidden columns is detectable and its visible
  neighbours report exact rects;
- `@AppStorage` persists the customization as JSON `Data`, which is what makes
  a hidden layout seedable in a test rather than only reachable by clicking.

So the rule is drawn by an overlay that reads those rects, and a double-click
on it restores exactly the run behind it. Adjacent hidden columns collapse into
one marker, which is what makes "unhide the group" a single action.

The mapping between the two worlds is the header title: SwiftUI assigns the
`NSTableColumn` identifiers UUIDs, not the customization IDs, so the title is
the only stable shared key. A test asserts every declared title has an entry —
without it, a new column could be hidden and never brought back.

**The cost is a dependency on an implementation detail, not a contract.** It is
handled two ways: the overlay fails soft, drawing nothing when no table is
found rather than breaking the list, and a test asserts the hierarchy is still
reachable, so a macOS release that changes it fails loudly instead of the
markers quietly never appearing. The overlay also hit-tests to the rule alone —
without that it would swallow row selection, the header and the context menu,
which is a far worse bug than the one it fixes.

---

## 2026-08-21 — Hideable list columns

`vbx-gsd`. Columns can be hidden and shown from the header's own right-click
menu, and the layout — visibility, order and widths — survives a relaunch.

Almost none of this is hand-written. `TableColumnCustomization` is macOS 14 and
this package targets 14, so one `@AppStorage` binding plus a `customizationID`
per column delivers the menu, the persistence and column reordering together.
Worth recording because the bead was filed asking for a hand-built context
menu: the platform already had it, and checking took one type-check against the
SDK.

Two columns opt out of visibility. **ID** because every context menu, bead link
and URL is keyed by it, and **the type glyph** because it is headerless and
would list as a blank row in the menu.

Hiding the column being sorted by falls back to `.default`, decided in
`SortMode.whenColumnsHidden(_:)` so the rule is testable without a view. The
alternative — leaving the sort pointed at an invisible column — leaves the rows
looking shuffled with nothing on screen to explain it.

The identifiers are a storage contract: they sit in users' preferences once
shipped, so they are derived from `SortColumn` rather than written out twice,
and three source-level tests hold that line — every column has one, none is
duplicated, and only the glyph uses a literal. That is not theoretical
tidiness: the first implementation gave PageRank the `blocks` identifier
through a mis-aimed edit, and the uniqueness test is what caught it.

**Not implemented here: the accent-coloured divider marking hidden groups.**
The reasoning at the time was that SwiftUI's `Table` exposes no divider API and
no column geometry, so it could not be layered on. **Superseded the same day** —
that only held for the public API, and the entry above records what probing the
backing `NSTableView` actually found. Kept as written because the mistake is
the useful part: "the framework has no API for this" was a conclusion about
documentation, not about the framework.

---

## 2026-08-21 — Open panel navigation, and bead selection as navigation

`vbx-kjh`, `vbx-8ea`.

The panel fix is in BUGS.md. Worth repeating here: the guard's own doc comment
stated the AppKit behaviour it depended on, and that statement was wrong. Both
halves of the new rule are now asserted in pairs — enabled *and* refused on OK,
files greyed *and* bead data still offered — because each half alone reads as a
sensible thing to "simplify" later.

**Selecting a bead now records a position** (`vbx-8ea`), reversing the choice
made in `vbx-8lk` a few hours earlier. That choice — refresh the current
position in place, because `j`/`k` browsing is not navigation — left back
unable to return to the bead just read, which is the commonest thing to want
back for.

The objection behind it was still real: with a twenty-position cap, key repeat
would evict every surface position within a screenful. So a *run* of selections
inside `navigationCoalesceWindow` (0.5 s) collapses into the position it ends
on, and back leaves the whole run in one step. Both behaviours are tested, and
the clock is injectable so the run test is deterministic rather than racing a
real interval.

One robustness point found by that test: the window is a half-open range, not a
bare `<`. A negative interval means the clock moved backwards — an NTP step, or
a test installing its own clock — and treating that as "the same run" silently
merges positions. Recording is the harmless reading.

---

## 2026-08-21 — Filters reset on a workspace switch

`vbx-ozd`. See BUGS.md. Opening a second workspace inherited the first one's
filters, and because labels, assignees, repo names and a recipe's ids are
workspace-specific strings, the new workspace typically came up empty with
nothing on screen explaining why.

The reset is gated on the resolved source changing rather than run on every
`open`, and it sits before `refreshAll()` so the first render is already
unfiltered. `surface` is left alone on purpose — it is not a filter — and there
is a test pinning that, so the exclusion reads as a decision rather than an
oversight.

---

## 2026-08-21 — Five open beads: list columns, link affordances, view history

`bvx-iyc`, `bvx-4xw`, `vbx-tdk`, `vbx-8lk`, `bvx-hsv`. Four UI changes and one
parity bug, landed together.

**Priority column moved after ID** (`bvx-iyc`) and **labels drawn as pills**
(`bvx-4xw`). The pill fill is 0.18 rather than the 0.12 `StatusChip` uses,
because that chip's tint is *coloured* while a label's is grey: measured
against the window background, a neutral capsule at 0.12 scores the same ink as
bare text (0.049 vs 0.043) — it renders, it just cannot be seen. The test
compares pill against bare text instead of a fixed threshold, which is the only
form that catches this.

SwiftUI's `Table` exposes no list of its columns, so the column order is pinned
by reading `IssueListView.swift` in the test. Unusual, but the order is exactly
what an unrelated edit reshuffles unnoticed.

**Bead-link affordances** (`vbx-tdk`). Linked ids already drew in the accent
colour — SwiftUI does that for any `.link` — so the visible gap was narrower
than the bead assumed. Added an explicit tint (so the styling does not depend
on the rendering context), an underline, and a pointing-hand cursor.
`.pointerStyle(.link)` is macOS 15 and this package targets 14, so the cursor
rides as an `appKit.cursor` attribute on the linked range — precise, unlike an
`onHover` over the whole `Text`. Whether AppKit honours that attribute inside a
SwiftUI `Text` is not assertable headlessly; the tests pin that the attribute is
set on exactly the linked run, and the runtime behaviour wants a look in the
running app.

**Navigation history** (`vbx-8lk`). Twenty positions, back/forward at the
leading end of the toolbar. A position is surface *plus* focused bead: following
a bead link changes selection without changing surface, and that is the move
back exists to undo. Row browsing (`j`/`k`, a table click) updates the current
position in place instead of pushing one — pushing per row would evict all
twenty within a screenful — while `select(id:)`, the deliberate jump, pushes.
The cursor rules are what make forward work: back moves a cursor rather than
popping, a new move mid-history truncates the forward branch, and restoring
never re-records.

**Triage staleness parity** (`bvx-hsv`) — see BUGS.md. The bead carried only a
title, so the divergence was found by running vbx and bv side by side over
purpose-built repositories until they disagreed.

---

## 2026-08-21 — Licence: MIT with an AI training rider

The repo had no `LICENSE` at all, which defaults to all rights reserved and
leaves anyone reading the public source unsure whether they may build it. It now
carries the unmodified MIT grant plus a rider that reserves one use: feeding the
source to model training, fine-tuning, distillation, RAG indexing or corpus
construction. The rider is written as a narrowing condition on the MIT grant and
says so in its own text, so nobody mistakes the result for OSI-approved MIT —
the file's title is "MIT License with AI Training Rider" rather than "MIT
License".

Two carve-outs keep it from over-reaching: using an AI assistant while working
on or with vbx is explicitly permitted, as is a model reading the source
transiently at inference time without retaining it. The restriction is about
corpora, not tools.

A closing section states what the licence does *not* cover — the Go modules in
`Engine/bridge/go.mod`, and beads_viewer, whose engine vbx links unmodified.
Those keep their own terms. Copyright is held by Michel Onstein.

---

## 2026-08-20 — App icon

vbx had no `CFBundleIconFile` and no `.icns`, so it took the generic macOS
placeholder in the Dock. Nothing upstream was reusable: `bv` has no mark at all,
`br` has an AI-drawn robot illustration that will not scale to 32px, and beads
itself has only the teal "bd" tile Docusaurus scaffolds as a default favicon.
The beaded chain from `br`'s illustration was the one idea worth keeping.

The mark is four white beads on a curved strand with a teal X tucked into the
bottom-right corner, on a near-black slate body. Artwork is generated by
`scripts/make-icon.py` — bead centres are sampled at equal arc length along one
quadratic Bézier, so spacing stays even as the curve flattens — and
`scripts/build-icon.sh` rasterises the ten representations into
`Resources/vbx.icns`. Three palettes were rendered at 512/128/64/32/16px before
graphite was chosen; `--variants` regenerates them. ADR-008 records why the
`.icns` is committed when the engine archive is not.

The same run also emits `docs/images/vbx-icon.png`, the README's hero image, so
it cannot be left behind when the artwork changes — a test asserts it is
pixel-identical to the icon's 512px representation.

`AppIconTests.swift` measures edge density inside the icon body per
representation. Both failure modes were confirmed to fail the suite before the
thresholds were fixed: a gradient tile with no artwork on it, and artwork
bleeding into the transparent squircle margin that macOS clips. The first pass
missed the flat tile entirely — colour-diversity ink coverage counted the
transparent margin as ink — which is why the measure is local contrast instead.

Tests: 336 → 341 Swift.

---

## 2026-08-20 — Signed distribution: a notarized .dmg and an App Store .pkg

`scripts/package-app.sh` signs and packages the app for both channels;
`build-app.sh --release --dmg` and `--app-store` build the bundle and hand off
to it. `--check` reports what is configured and which channel is ready,
`--dry-run` prints the plan without running anything.

**The channels ship different apps** (ADR-010). Developer ID is unsandboxed,
hardened-runtime, keeps `vbx-cli` and the shell hooks. The App Store build is
sandboxed, embeds the provisioning profile, and *removes* `vbx-cli` — a
sandboxed app cannot symlink it into `/usr/local/bin`, so shipping it would put
an unusable binary in the bundle. Packaging always works on a staged copy, so an
`--app-store` run cannot quietly delete the CLI from the developer's own build.

**Nothing account-specific is in the repository** (ADR-009), which is the part
that needed care rather than typing. Configuration is a gitignored
`scripts/signing.env` or the environment; the App Store entitlements are a
template expanded into `.build/dist/` at mode 600, because
`com.apple.application-identifier` must contain the Team ID verbatim; and every
line the script prints goes through `redact`, since `codesign -dvvv` and
`security find-identity` echo the Team ID and build logs get pasted into public
issues.

`scripts/test-packaging.py` — 65 checks — drives the real script with fabricated
credentials and asserts they do not come back out. It found two bugs that
review would not have:

- **Masking order.** A certificate name contains the Team ID, so masking the
  Team ID first left a string that no longer matched the full name, and the
  developer's *name* survived into the log. Longest first.
- **Short values.** The ad-hoc identity is a single `-`; masking it replaced
  every hyphen in the output, turning flags and paths into
  `<DEVELOPER_ID_APP>`. Only values of six characters or more are masked.

It also scans every tracked file for the values configured locally, and says so
when there is no configuration to check against rather than passing silently.

Verified end to end with an ad-hoc signature (`VBX_DEVELOPER_ID_APP=-`): a real
26 MB `.dmg` that mounts, carries a valid signature inside and out, and an App
Store bundle that signs with the expanded entitlements and drops the CLI. Both
scripts were checked under `/bin/bash` 3.2, not just the Homebrew bash 5.

Still not built, and now said so in §17: the universal binary, the Sparkle
appcast, and the Homebrew cask.

---

## 2026-08-20 — List multi-selection, a row context menu, and an Open-panel guard

Three beads (`vbx-jpn`, `vbx-tlv`, `vbx-roq`).

**Multi-selection.** `ProjectStore.selectedID` became `selection: Set<Issue.ID>`
plus a derived `focusedID`. Everything that follows the cursor — the inspector,
the graph, history — binds to `focusedID`, so a multi-row selection does not
leave those surfaces guessing which of several beads they are describing. The
focus rule is "the row just added, or the first survivor when the focused one
leaves the selection", which keeps a filter change or a recipe from blanking the
inspector.

**Context menu.** Attached with `.contextMenu(forSelectionType:)`, which is what
makes "the selected beads, or the one right-clicked when it is not selected"
fall out of AppKit rather than being reconstructed from mouse position. The menu
is structured around none / one / several from the start. First item is Copy ID;
several ids join with `", "` **in screen order**, since a `Set` iterates in hash
order and the same action could otherwise put two different strings on the
clipboard.

**Open-panel guard.** `vbx_probe` — a new, session-less C entry point — answers
"could this path be opened?" without loading it, and `OpenPanelGuard` is an
`NSOpenSavePanelDelegate` over it. The answer comes from the same discovery code
`open` runs, so the panel and the loader cannot disagree.

The literal rule (a folder containing `.beads`) is not the rule implemented,
because it is wrong in both directions: it would refuse a multi-repository
workspace root, which holds `.bv/workspace.yaml` while its `.beads` directories
live in the repositories below it, and it would accept a folder below a project
root — discovery does *not* walk upwards, so opening that fails. Greying is
advisory; `panel(_:validate:)` is the actual gate, because a path typed into
Go-to-folder never passes through `shouldEnable`.

336 Swift tests, Go suite green, parity 9 matched / 0 differed.

---

## 2026-08-19 — Markdown in the bead detail view

The inspector renders a bead's description as Markdown when it contains any:
headings, paragraphs, bullet and numbered lists, fenced code with a language
label, blockquotes, rules, and inline emphasis / code / links.

Detection is deliberately conservative — bead prose is full of identifiers like
`data_hash`, so single underscores are not treated as emphasis and plain prose
renders verbatim. Parsing lives in `VBXCore` (pure, 24 tests); rendering is
`MarkdownText` in `VBXUI`.

Two bugs found by looking at the snapshots: a greedy blockquote rule, and
soft line breaks rendered as hard ones. Both logged in BUGS.md.

---

## 2026-08-19 — Conventions compliance pass

Brought the repo in line with the global conventions after re-reading them.

- Renamed `docs/vbx-design.md` → `docs/VBX_DESIGN.md` and
  `docs/feature-parity.md` → `docs/FEATURE_PARITY.md`, updating every reference
  (both docs' cross-links, `README.md`, `docs/README.md`,
  `scripts/build-docs.py` nav order) and regenerating `docs/html`.
- Converted the two remaining ASCII diagrams to Mermaid: the window-anatomy
  wireframe in the design doc, and the architecture chain in `README.md`. The
  directory listings stay as plain code blocks, which the rule allows.
- Added the project `CLAUDE.md` document index.
- Added `docs/project_notes/` (BUGS, DECISIONS, KEY_FACTS, WORK_LOG).
- Added the missing regression test for the inspector unblocks bug
  (`UnblocksCacheTests`, 5 tests).
- Updated `Status:` lines and the parity matrix to match what is actually built.

---

## 2026-08-19 — Offscreen view snapshot tests

12 tests rendering every view to PNG. Caught three real defects: scrolling views
rendering blank under `ImageRenderer`, dead gaps in the Insights grid from
`LazyVGrid` row alignment, and the inspector reporting Unblocks 0 for a bead
that unblocks six. Views moved to a `VBXUI` library so tests can import them.

## 2026-08-19 — Triage recommendations

Scored recommendations with the engine's reasoning, quick wins, and blockers to
clear, in the Insights dashboard. Gated on `hasPhase2Values`, since the score
derives from PageRank and betweenness.

## 2026-08-19 — Markdown report export

bv's `pkg/export` wired through the bridge, so the report is byte-identical to
`bv --export-md`. Available from the File menu, `vbx-cli export-md`, and the
engine's `export_markdown`. Archive grew 24 MB → 29 MB.

## 2026-08-19 — Live reload and label analytics

FSEvents watching the containing directory (atomic renames defeat a
descriptor-level watch), debounced at 200 ms, with a content-hash gate so an
incidental touch costs one parse and no analysis. Labels dashboard over the
engine's `label_health`.

## 2026-08-19 — vbx implemented

Native macOS app over bv's Go engine via `c-archive` and a C ABI. Seven views,
inspector, filters, sorting, fuzzy search, bv's single-key bindings alongside
native menu shortcuts, and a CLI with a `doctor` self-check. ~6,200 lines of
implementation.

## 2026-08-19 — Design document

`docs/VBX_DESIGN.md` and `docs/FEATURE_PARITY.md`, derived from a study of
upstream bv, plus a static HTML build with vendored Mermaid.

## 2026-08-20 — The remainder of vbx

Closed all sixteen open beads. Highlights, in the order they landed:

- **vbx-ee7** Markdown tables — parsed and rendered; the bug was that
  `joinSoftWrapped` collapsed rows onto one line.
- **vbx-8y4** Bead ids in prose link to their bead, membership-driven so no id
  format is hardcoded and a stale id stays plain text.
- **vbx-6qy** Column-header sorting, sharing one sort value with the toolbar
  and bv's `s` cycle so they cannot disagree.
- **vbx-8ou** Git correlation without a `git` subprocess (ADR-006), reading the
  object store with go-git and feeding bv's own pure analyses.
- **vbx-dpz** Flow matrix and attention views.
- **vbx-v49** History view: commits, timeline, causality, files, hotspots,
  orphans, and confirm/reject feedback.
- **vbx-hai** Time travel with per-bead diff badges.
- **vbx-k1s** Alerts, baselines and drift.
- **vbx-k51** Recipes, written to bv's own `.bv/recipes.yaml`.
- **vbx-k06** Sprint dashboard with burndown and capacity.
- **vbx-6w3** Hybrid search with live weights and score breakdowns.
- **vbx-e3y** Multi-repository workspaces.
- **vbx-1gn** App Intents, `vbx://`, Spotlight, CLI installer.
- **vbx-pk8** Static site export with in-process GitHub Pages deployment.
- **vbx-erx** Interactive tutorial.
- **vbx-fl1** Robot-protocol parity: a pure-Go TOON encoder (ADR-007) and a
  parity harness diffing `vbx-cli` against `bv`.

The parity harness earned its place immediately: it caught that vbx's triage
scores disagreed with bv's, because bv feeds a bounded git-history report into
the scorer and vbx did not. That is now fixed, and nine commands compare byte
for byte.

Tests: 104 → 304 Swift, plus a substantially expanded Go suite.

## 2026-08-24 — The recipe editor opened empty

Clicking **New recipe…** opened a dialog that stayed blank for about twenty
seconds. The sheet was presented by a flag written beside the recipe it edits,
and SwiftUI built its content from a body that had not yet seen the recipe — so
it opened at 100×80 with an `EmptyView` inside and waited for an unrelated
redraw. Now `sheet(item:)`, here and for `HistoryView`'s patch sheet, which had
the same shape. `RecipeEditorPresentationTests` clicks the real row and asserts
the sheet's size. See BUGS.md, 2026-08-24.

## 2026-08-26 — The packaging test cut a real release

`test-packaging.py` ended its release-script section by running `release.sh
--tag 99.0.0` and assuming the environment would refuse it. On a configured
machine with a clean tree it did not: every verify run built, signed, notarized
and tagged a fake 99.0.0. The check now points at a signing config that does not
exist, so the refusal is a property of the run, and asserts no tag is left
behind. `release.sh` also takes back a tag it created when the release does not
finish, so a failed or interrupted release no longer spends the version. See
BUGS.md, 2026-08-26.
