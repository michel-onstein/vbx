# Bug Log

Found-and-fixed issues, with the regression test that locks each fix in.

---

## 2026-08-22 — The cask, and the instructions for it, did not survive contact

**Symptom:** following `release.sh`'s own printed instructions produced

```
Error: Calling `brew audit [path ...]` is disabled! Use `brew audit [name ...]` instead.
```

and once that was worked around, `brew audit` rejected the cask three times
over.

**What was wrong, all of it found by running the real thing against a published
release rather than reasoning about the template:**

- **The printed instruction could not work.** It said
  `brew audit --cask --new Casks/vbx.rb`. `brew audit` refuses a path outright;
  it takes a cask *name*, which only resolves once the tap is installed — and
  tapping a directory *clones* it, so an uncommitted cask is invisible even
  then. Both halves had to be said.
- **`--new` is the wrong audit for a personal tap.** It is the strict check for
  submissions to homebrew/homebrew-cask and fails on "repository not notable
  enough (<30 forks, <30 watchers and <75 stars)" — true, and not something a
  new project can act on.
- **The URL read as unversioned.** It had the number written into it rather
  than `#{version}`, and the audit looks for the interpolation, not for digits.
  It then demanded `sha256 :no_check`, which would have switched the checksum
  off entirely — the opposite of the point.
- **`verified:` is deprecated.** It vouches for a URL whose host is not
  obviously the project's; a github.com release URL under the project's own
  repository is not that.
- **`>= :sonoma` fails style.** The bare symbol already means "that version or
  newer".

**Fix:** the template interpolates the version, drops `verified:` and uses the
bare symbol; `release.sh` prints instructions that run.

**Verified end to end, which had never been done:** `brew audit --cask` exits 0,
`brew style` reports no offences, and `brew install --cask michel-onstein/tap/vbx`
succeeds — `/Applications/vbx.app` and `vbx-cli` on the PATH, from a genuinely
notarized disk image.

**Prevention:** `test_release_instructions_are_runnable` asserts the printed
commands never pass a path to `brew audit`, never suggest `--new` for a personal
tap, and say the cask must be committed. The template assertions cover the
interpolated URL, the absent `verified:` and the bare macOS symbol.

---

## 2026-08-22 — Two preflight checks that failed closed on their own bugs

**Symptom:** `package-app.sh --check` reported a working release setup as
broken, twice, and each report sent someone to fix something that was never
wrong.

**`notarytool history --limit 1`.** `--limit` is not an option that subcommand
takes. The command failed for a reason entirely unrelated to the credential, so
a valid App Store Connect API key was reported as *"configured but not
usable"*. Found by disbelieving the check and running the command by hand:
without the flag it answers `Successfully received submission history.`

**`check-ignore` asked of the wrong repository.** The check ran
`git -C "$ROOT" check-ignore` against the config path — which, from a linked
worktree, is in a *different* checkout. Git answers "not ignored" for a path it
does not own, so the output read *"gitignored NO — this file carries account
identifiers"* about a file that is correctly ignored where it lives. Alarming,
and false. Introduced in the same change that taught `--check` to find the
config in the primary worktree at all.

**Why they matter more than a wrong line of output.** A check that fails closed
on its own bug is worse than no check. It does not merely fail to help — it
actively misdirects, and the thing it accuses is by definition the thing you
were relying on. Both of these cost an investigation into correctly configured
credentials.

**Fix:** the flag is gone; `check-ignore` is asked of the tree that owns the
file, via `git -C "$(dirname "$CONFIG_FILE")"`.

**Prevention:** `test_check_does_not_fail_closed_on_its_own_bugs` asserts that
no un-commented line passes `--limit` to `notarytool history`, and that
`check-ignore` is run against the config's own directory. Comment lines are
stripped first — the third time in this file that a naive substring search has
matched the comment explaining the fix rather than the code.

---

## 2026-08-22 — A test fixture deleted a directory the store was still watching

**Symptom:** `swift test` exited non-zero roughly one run in eight, with **no
failing expectation and no summary line** — the runner simply stopped. Every
re-run passed, and `--no-parallel` always passed.

**Cause:** `Fixture.committedStore()` hands back a store and a directory, and
the tests removed the directory in a `defer` while the store was still open and
still watching it. That had been survivable when only the bead file was watched;
`vbx-bct` added a second watch on `.git`, which is *inside* the directory being
deleted, and FSEvents delivering a change for a path that has just gone — into a
store whose engine session is still open — is what took the process down.

Parallel execution is why it was intermittent and why it looked like it had no
location: the crash kills the whole runner, so the output shows a couple of
hundred tests "started" and nothing finished, wherever the failure actually was.

**Fix:** the tests stop watching before removing the directory. The store is
told to let go of the path first, which is the ordering the helper should always
have had.

**Not claimed:** that the app is now safe against a workspace being deleted
underneath it. That is a real question and this is not evidence about it — only
the test-side ordering was proven wrong and corrected.

**Prevention:** no new test, deliberately — a one-in-eight crash is not
something an assertion catches, and a test that ran the suite repeatedly would
be slow and still probabilistic. What was done instead is eight consecutive
clean runs after the change, against two observed failures in roughly a dozen
before it.

---

## 2026-08-22 — Every hosted cell was centred in its column

**Symptom:** reported as "the label pills are not aligned to the left of the
column". Looking at the rendered list, it was **every hosted column** — ID, P,
the type glyph, Status, Blocks, Blocked by and PageRank all sat in the middle of
their cells. Only Title was correct, and only because it is the one column drawn
natively as an `NSTextField` rather than hosted.

**Cause:** introduced the same day, by the move to `NSTableView`
([ADR-014](DECISIONS.md)). `HostedCell` pins its `NSHostingView` to both the
leading *and* trailing edges, so the SwiftUI content is handed the full column
width — and a view given more width than it needs centres itself in it.
SwiftUI's `Table` left-aligned cell content by default, which is why this was
right before and wrong after.

**Fix:** one line where the cell hosts the view —
`.frame(maxWidth: .infinity, alignment: .leading)` — rather than ten changes at
the columns. A new column cannot forget it.

Numeric columns were left leading rather than right-aligned. macOS often
right-aligns counts so digits line up, and that is arguably better, but it is a
change to how the list has always looked rather than a restoration of it. Worth
deciding separately; `BeadColumnSpec` is where a per-column alignment would go.

**Prevention:** `CellAlignmentTests` measures the leftmost ink in a cell as a
fraction of the cell's width, because ink coverage cannot see this — centred
content and leading content produce identical coverage. Confirmed to fail before
the fix, at 27% across the column.

The suite also contains a test that the *measurement* separates centred from
leading. Without it, a `firstInkFraction` that returned something small for
everything would let the real assertions pass on a broken build — which is
exactly how the vacuous double-click test got shipped a day earlier.

---

## 2026-08-22 — A Codable + RawRepresentable layout killed the test runner

**Symptom:** `swift test` exited with **signal 11**. No failing expectation, no
message, no stack — the runner simply died, and because Swift Testing runs in
parallel the output showed two hundred tests "started" and nothing finished, so
the crash appeared to be everywhere and nowhere.

**Cause:** `BeadTableLayout` conformed to both `Codable` and `RawRepresentable`,
the second so `@AppStorage` could hold it. The standard library supplies default
`Codable` implementations for *every* `RawRepresentable` whose raw value is
itself `Codable`, and those implementations encode the **raw value**. So:

```
rawValue → JSONEncoder().encode(self) → encode(to:) → rawValue → …
```

until the stack ran out. The type looked entirely ordinary; the recursion is
between two conformances neither of which is visible at the call site.

**Finding it:** `--no-parallel` was what made it tractable. Serially, the last
line printed is the test that dies, and it named
`hiddenColumnPersists` — the one test that round-trips the layout through
`rawValue`, which is exactly the path that recursed.

**Fix:** the type no longer conforms to `Codable` at all. `rawValue` encodes a
private nested `Storage` struct instead, so there is no conformance for the
`RawRepresentable` defaults to attach to. The encoding also sorts the hidden set,
because a `Set`'s iteration order is not fixed and an unsorted encoding would
rewrite preferences when nothing had changed.

**Prevention:** `ColumnVisibilityTests` round-trips a layout through `rawValue`
— the trip `@AppStorage` actually makes — with a hidden set, an explicit order
and a stored width. That test is what crashed; it passes now, and it would crash
again the moment someone adds `Codable` back.

---

## 2026-08-22 — Priority editing was in the build and could not be reached

**Symptom:** reported from a real build — "the editing of Priority is not in
this build". It was in the build. Double-clicking the priority cell did nothing.

**Cause:** `PriorityCell` offers editing through `onTapGesture(count: 2)` on
cell content, and in the running app that does nothing.

**Correction, recorded because the first write-up of this entry over-claimed:**
the mechanism is *not* established. The original text said the gesture "never
arrives" because `NSTableView` consumes the click, and cited a test that
synthesised a double-click and saw no popover. That test was vacuous and has
been deleted — the same harness cannot activate anything inside a `Table`, so it
would have passed either way. Measured afterwards: a synthetic click does press
a plain SwiftUI `Button` in a hosting view, and a `TextField` in a `Table` cell
*is* a real editable `NSTextField`, yet neither that field's focus nor the
table's `primaryAction` can be triggered headlessly.

So what is known is narrower, and enough: with `br` present and
`canEditBeads == true` the write path was open, and the double-click still did
nothing in a real build. The widget is not the limit — `Table` supports
interactive cell content — but a gesture layered over a `Text` in a cell is not
a route to rely on.

The obvious explanation was ruled out first: `br` **was** found, at
`~/.cargo/bin/br`, and the store reported `canEditBeads == true` with
`editingUnavailableReason == nil`. The gate was open; the door was painted on.

Two things made it invisible. The only affordance was a double-click on an
unmarked 30pt column — nothing on screen said the cell was editable. And the row
context menu, the place a macOS user looks for a row action, offered only Copy ID
and Show History.

**Why no test caught it — a second bug underneath.** Nothing had ever exercised a
real write. `BeadWriterTests` injects a fake runner and asserts the *command
vbx sends*, which is the right test for that layer but proves nothing about the
UI reaching it. And an end-to-end write was impossible anyway: `br update`
against the demo fixture fails with

```
Preflight checks failed:
  - json_valid: Found 13 invalid issue record(s): line 2: missing field `created_at`
```

Exactly 13 of the fixture's 18 records carry `dependencies`, and `br` validates
every dependency row and requires `created_at` on each. Real `br` exports have
it; the hand-written fixture's rows had only `issue_id`, `depends_on_id` and
`type`. So the fixture rejected every write, and the one test that would have
caught the UI bug could not have been written.

**Fix:** priority moved to the row context menu, through
`contextMenu(forSelectionType:)` — `Table`'s own mechanism rather than a gesture
layered over it. It handles a multi-bead selection, ticks the current value only
when the whole selection agrees, and explains itself when editing is
unavailable rather than being silently disabled. `ProjectStore.setPriority(_:for:)`
gained a set-taking form that writes sequentially — `br` owns the database, and
concurrent writers are how a lock error becomes a half-applied change — reloads
once at the end, and returns the ids it could not write.

The fixture's dependency rows gained `created_at`, which is what makes a real
write testable at all.

**Prevention:** four tests. That `br` is found and nothing blocks a write, so a
future failure points at the UI rather than the environment. That a synthesised
double-click still opens nothing — pinned deliberately, so removing the context
menu in favour of "the double-click already does this" fails here instead of in
someone's hands. That setting a priority across a two-bead selection really
writes both, read back through `br`. And that a refused edit reports the ids it
did not apply rather than failing silently.

---

## 2026-08-22 — Opening About froze the app for seven seconds

**Symptom:** the About window took 5+ seconds to appear, with the spinning
cursor for all of it.

**Cause:** the notices pane rendered all 227 KB of `ACKNOWLEDGEMENTS.md` as a
single `Text`. SwiftUI lays a `Text` out in full before it can draw any of it,
and at that size it takes **7.1 s** — measured, not estimated.

Text selection was the obvious suspect and is not the cause: with
`.textSelection(.disabled)` it was 7.14 s. Size alone is the factor — the same
pane with the first 4 KB laid out in 0.01 s.

**Fix:** the notices are split on line boundaries and rendered in a
`LazyVStack`, so only the chunks on screen are laid out. Same content, **0.01 s**
— 700× faster. An `NSTextView` was the other candidate at 0.17 s; chunking is
faster and keeps the pane in SwiftUI.

**The constraint on the chunker:** these are licence notices that several
dependencies require be carried verbatim, and beads_viewer's rider must travel
unmodified. A chunker that dropped or duplicated a line would be a licence
problem, not a display bug.

**Prevention:** a byte-for-byte round-trip assertion — the chunks rejoined must
equal the source exactly — plus edge cases (shorter than one chunk, an exact
multiple, a trailing newline). And a timing assertion, the only one in the repo,
because the bug *was* the timing and nothing else distinguishes the fixed code
from the broken code. Its bound is 3 s against measurements of 7.1 s and 0.01 s,
so it cannot flake yet still catches a return to one `Text`; it was confirmed to
fail when forced back to a single chunk.

---

## 2026-08-22 — The About window's version line was untested, and drew a blank row

**Symptom:** rendering `AboutView` offscreen produced a header with the app name,
then an empty row, then the licence line. The version was simply missing. In the
real app it is correct — a built bundle reports `Version 0.0.1 (42)` — so this
was only ever visible in a snapshot.

**Cause:** `versionLine` read `Bundle.main.infoDictionary` directly, and in a
test process `Bundle.main` is SwiftPM's helper binary:

```
bundlePath  = …/XcodeDefault.xctoolchain/usr/libexec/swift/pm
short       = nil
build       = nil
versionLine = []
```

`applicationName` survived the same conditions because it ends in
`?? "Visual Beads"`; `versionLine` had no fallback. And because the string was
empty rather than absent, `Text("")` still occupied a row — hence the gap.

**Why it mattered more than a cosmetic gap:** the version had just stopped being
a literal. It now travels git tag → `scripts/version.sh` → `PlistBuddy` → the
plist → `Bundle.main` → the About box, and **nothing verified the last two
hops**. The test that sounded like it did — *"The version line comes from the
bundle rather than a literal"* — asserted only that `applicationName` was
non-empty and never touched `versionLine`. A broken stamp would have shipped a
blank About box with every check green.

**Fix:** `versionLine(from:)` takes the info dictionary, with
`versionLine` defaulting it to `Bundle.main`, which is what makes the formatting
testable at all. The header omits the row entirely when the string is empty,
rather than reserving a blank one. The misleading test was renamed for what it
actually asserts.

**Prevention:** four cases on the formatting — both keys, marketing version
alone, nothing, and a build number with no marketing version (which shows
nothing, since it says nothing a user can use). Plus the hop Swift cannot reach:
`test-packaging.py` compares a built bundle's plist against `scripts/version.sh`,
and skips loudly when no bundle has been built rather than passing on a missing
artefact. Both were confirmed to fail before passing — the plist check by
setting the plist back to the old hardcoded `0.1.0`, and the header check by
aiming its region at a band known to be blank.

---

## 2026-08-22 — The signing config had been dead since the rename, and said nothing

**Symptom:** `./scripts/package-app.sh --check` reported *"no distribution
channel is configured. Copy scripts/signing.env.example to scripts/signing.env,
or export the settings."* — with a complete, filled-in `scripts/signing.env`
sitting right there, all seven keys set.

**Cause:** the project was renamed from bvx to vbx in #13. The scripts were
renamed with it; the local config file was not. Every key in it was still
`BVX_TEAM_ID`, `BVX_DEVELOPER_ID_APP` and so on, and nothing reads those. The
file is `source`d, so the assignments succeeded — they just landed on variables
no one looks at.

What made it survive so long is the *wording of the failure*. "No distribution
channel is configured" reads as "you have not set this up yet", so the natural
response is to go and set it up, find the file already correct, and conclude the
check is about something else. A message can be accurate and still point away
from the cause.

It also made a real capability look absent: with the prefix fixed, `--check`
reports **"Developer ID cert — in the keychain"**. The certificate had been
there the whole time.

**Fix:** the config loader greps for `^BVX_` and refuses with the actual
diagnosis and the one-line `sed` that repairs it, rather than falling through to
the generic "unconfigured" path. The local `signing.env` was repaired with that
exact command (original kept as `signing.env.bvx-backup`).

**Prevention:** `test-packaging.py` drives `--check` with a fabricated `BVX_`
config and asserts it is rejected *by name* — and with a `VBX_` one, asserting
it is not flagged, so the guard cannot start firing on a correct file.

---

## 2026-08-22 — The first host build after a universal one refused to run

**Symptom:** `./scripts/build-engine.sh` failed with

```
build output ".../Engine/build/libvbxengine.a" already exists and is not an object file
```

Found while running the verify block immediately after a `--universal` build,
which is exactly when a person would hit it: the flag is new, so the state it
leaves behind is new too.

**Cause:** `go build -o` will overwrite an object file it produced, and refuses
anything else. A universal archive is a *fat* file rather than an object file,
so once `--universal` had written one, every subsequent host-only build stopped
on it. The error names the archive, not the flag that produced it, so the
obvious reading — a corrupt build directory — is wrong.

Latent before today in that `--universal` existed; unreachable in practice
because nothing called it. Wiring it into every distribution build is what made
it a normal thing to hit.

**Fix:** `build_slice` removes its target first. The universal path already
overwrote through `lipo -create`, which has no such restriction, so only the
host path needed it — but it is done in `build_slice` so both are covered.

**Prevention:** `test-packaging.py` asserts the archive is cleared before the
slice is built.

---

## 2026-08-22 — Every launch from the Dock opened onto an error

**Symptom:** launching vbx from the Dock or Finder showed **"Could not open
workspace"** with an error triangle, every time, before the user had asked for
anything. Launching it from a terminal that happened to be sitting in a
workspace worked, which is how it had been tested and why it was not caught.

**Cause:** `openInitialWorkspace()` tried a path argument, then `VBX_WORKSPACE`,
then `FileManager.default.currentDirectoryPath` — and *opened* each rather than
asking whether it could be opened. A GUI app launched from Finder or the Dock
has a current directory of `/`, which holds no `.beads`, so the third candidate
always failed, set `loadError`, and the error state won over the neutral "No
workspace open" state sitting a few lines below it in `ContentView`. It also
never consulted the recents list, although `RecentWorkspaces.shared` already
held exactly "the last workspace opened".

The distinction that had been lost: **"nothing to open yet" is not "what you
asked for failed."** `loadError` should mean the user pointed at something and
it did not work.

**Fix:** candidates are *probed* — `BeadsEngine.probe`, the same discovery code
the Open panel greys rows with — rather than opened, so a dead candidate is
skipped instead of producing an error. The order gained the recents list: a path
argument, `VBX_WORKSPACE`, the recent workspaces, then the current directory.
When none probes openable, nothing opens and `loadError` stays nil, so the
existing empty state appears on its own with its Choose Workspace… button. No
new UI was needed.

Two neighbours moved with it. A restored window goes through
`openRestoredWorkspace(path:)`, which probes for the same reason — being told a
folder you did not choose this session has vanished is the same unhelpful error,
one launch later. And a path the user *named* on the command line or in
`VBX_WORKSPACE` still reports why it failed, provided it exists: a stray launch
argument (`YES`, left behind by `-NSDocumentRevisionsDebugMode`) names nothing
and must stay silent.

**Prevention:** `LaunchDiscoveryTests` — ten cases, including the guard against
over-correcting: `open(path:)` on a folder holding no beads must still set
`loadError`, or a fix here could quietly make every failure silent.

---

## 2026-08-22 — Scrolling the bead list crashed the app

**Symptom:** open a workspace with more beads than fit in the window, scroll the
list, and vbx dies with `EXC_BREAKPOINT` on the main thread. The crash report
names `PriorityCell.body` and
`SwiftUICore/EnvironmentObject.swift:93: Fatal error: No ObservableObject of
type ProjectStore found`. It reproduced on a 327-bead workspace and never on
vbx's own 38, which made it look workspace-specific — a bad data row, or the
engine — rather than a property of how many rows were on screen.

**Cause:** `PriorityCell` read the store with `@EnvironmentObject`. It is the
only table cell that is its own `View`; every other column's cell closure
captures `IssueListView`'s store directly, so only this one depended on what the
cell's environment contains. macOS `Table` bridges to `NSTableView` and builds a
cell's subgraph when its row scrolls into view, and that subgraph does not carry
the `environmentObject` injected around `ContentView` in `WorkspaceWindow`. So
the lookup resolved for the rows laid out on the first pass and trapped on the
first row created after it. A workspace small enough to fit on screen never
creates one, which is exactly why the repo's own beads never showed it.

The `SearchContentKey` frames in the report are incidental — that was merely the
preference being combined during the layout pass that built the new cell. The
search field is not involved.

**Fix:** the store is handed in — `@ObservedObject var store` and
`PriorityCell(store: store, issue:)` — which is what the other nine columns
already do, made explicit because this cell is a separate type. Observation is
unchanged; only the lookup is.

**Checked, not assumed:** every other surface was swept for the same shape — a
standalone `View` with `@EnvironmentObject` inside a container that builds
children lazily. Board, Plan, Labels, Tree, Insights, Attention, Sprint, Alerts,
History, Flow, Sidebar and Inspector were each hosted in a short window and
scrolled past their content; all survived. `LazyVStack` and `LazyVGrid` stay in
the same view graph and do inherit the environment. `Table` was the only
container that loses it, and `PriorityCell` was its only environment-reading
cell.

**Prevention:** `PriorityCellTests` does both halves.
`scrollingTheListCreatesCellsThatKeepTheirStore` hosts the real `IssueListView`
in a 220pt window — short on purpose, so the fixture's rows cannot all lay out
on the first pass — and scrolls past the content; it traps on the fixture's 18
beads if the `@EnvironmentObject` returns, verified by reverting the fix.
`rendersWithoutAnEnvironmentObjectAncestor` states the invariant directly by
rendering the cell with no `environmentObject` anywhere above it. Both fail by
trapping rather than by reporting, because `EnvironmentObject.error()` is a
`fatalError` — the regression takes the process down, which is itself the
signal.

The general lesson is the one the sweep encodes: a view that renders correctly
at full size proves nothing about the children a container builds later. The
existing snapshot tests all render at a size where everything fits, which is the
blind spot this slipped through.

---

## 2026-08-22 — Recipes never loaded, so the feature looked inert

**Symptom:** the sidebar's Recipes section offered "New recipe…" and nothing
else, in every workspace. The feature appeared to do nothing, and was reported
that way.

**Cause:** `loadRecipes()` guards on `isLoaded` and was called from exactly
three places — the sidebar section's `.task`, `saveRecipe` and `deleteRecipe`.
**Nothing called it when a workspace opened.** The sidebar renders immediately
at launch, before any workspace has loaded, so its `.task` fired while
`isLoaded` was still false, returned early, and never ran again: `.task` does
not re-run when the value it depended on changes. The one call that would have
populated the list ran at the only moment it could not work.

Measured by driving the store directly — after `open`, `recipes` was empty; an
explicit `loadRecipes()` immediately returned eleven. `vbx-cli --robot-recipes`
listed all eleven for the same workspace throughout, so nothing below the store
was ever wrong.

**Fix:** load them in `open(path:)` after `refreshAll()`, and in
`reload(force:)` on the changed path — recipes live in the workspace, so an edit
on disk can add or remove one. The `.task` is gone: two mechanisms for one job,
and the view-driven one was the half that could not be relied on.

**Prevention:** `openingLoadsRecipes` asserts the list is populated after
`open`, and reports `recipes → []` against the unfixed store.
`loadedRecipesAreUsable` guards the shape of the fix — loading a list that
cannot be applied would satisfy the first test while leaving the feature just as
inert. `noWorkspaceMeansNoRecipes` pins the legitimately-empty case, which is
what made this bug easy to mistake for "recipes do nothing".

---

## 2026-08-21 — The Open panel could not be navigated to a workspace

**Symptom:** folders without `.beads` could not be double-clicked to enter
them, so a workspace below one was unreachable — the panel was only usable if
it happened to open inside a workspace already. Meanwhile *every* file was
selectable, greyed out or not.

**Cause, part one:** `OpenPanelGuard.panel(_:shouldEnable:)` returned
`canOpen(url.path)` for directories as well as files, and the type's own
documentation asserted that was safe: *"AppKit still lets the user navigate
into a disabled directory, which is essential."* It does not. A disabled
directory cannot be entered, and since every folder on the way to a repository
is itself unopenable, each was a dead end.

**Cause, part two:** `resolveSource`'s non-directory branch returned
`(path, "jsonl")` for anything that was not `.db`/`.sqlite`/`.sqlite3`, without
checking extension or content. Measured: `README.md`, `Package.swift` and a
binary `vbx.icns` all probed `can_open=true`. So `shouldEnable` said yes to
every file and the failure arrived later, in the loader — the panel/loader
disagreement `Probe`'s header says it exists to design out.

**Fix:** directories are always enabled and `panel(_:validate:)` — which
already existed for exactly this, and refuses with a reason — is the gate.
Greying now applies to files only, and the engine accepts a file by extension
(`.jsonl`, `.db`, `.sqlite`, `.sqlite3`). Content is deliberately not sniffed:
an empty or mid-write `issues.jsonl` is still the file the user means, and
refusing it here would break the documented fallback to `beads.db`.

**Also corrected:** `Probe`'s header claimed discovery "does *not* walk
upwards". A folder inside a git checkout does resolve to the repository root's
`.beads` — `Sources/deep` is openable — while the same layout *outside* git is
refused. Git is what decides it, and the two cases look identical on disk, so
both are now asserted: `TestProbeAcceptsAFolderInsideAGitRepository` alongside
the existing `TestProbeRefusesAFolderBelowOneWithBeads`.

**Prevention:** `unopenableFolderStaysNavigable` asserts an unopenable folder
stays *enabled*, paired with `unopenableFolderIsRefusedOnValidate` so a fix for
one cannot silently undo the other. `nonBeadFileIsDisabled` and
`beadDataFileStaysEnabled` pin both directions of the file rule — refusing
every file would "fix" the greying by switching the panel's file support off.
The existing `refusesEmptyFolder` was rewritten rather than deleted: it no
longer asserts the row is greyed, and says why.

---

## 2026-08-21 — A second workspace opened behind the first one's filters

**Symptom:** open one workspace, filter it, open another — and the list comes up
empty with no visible cause. The sidebar shows a filter nobody chose for this
workspace, and an empty table reads as "this workspace has no beads".

**Cause:** `open(path:)` swapped the workspace but left `query` (filter, search
text, labels, assignees, sort), `repoFilter`, the active recipe with its ids,
and the two alert filters exactly as the previous workspace left them. Labels,
assignees, repository names and a recipe's ids are all workspace-specific
strings, so after a switch they typically match nothing. Observed in the
failing test: `recipeIDs` still held `["vbx-12", "vbx-3", "vbx-14"]` — beads of
the workspace that had just been closed.

The rule was already stated twice in that same function and simply never
carried to filters: `resetNavigationHistory()` ("the previous workspace's beads
do not exist in this one"), and `refreshAll` keeping only selected ids the
fresh set still holds.

**Fix:** `resetWorkspaceFilters()` returns all of it to initialiser defaults,
called from `open(path:)` before `refreshAll()` so the first render is already
unfiltered. Gated on the resolved `info.source` actually changing, so reopening
the workspace already open leaves it alone. `surface` is deliberately *not*
reset: which view you are on is not a filter, it names nothing inside the
workspace, and someone comparing two workspaces in one view wants to stay in it.

**Prevention:** `openingAnotherWorkspaceResetsFilters` sets every listed filter,
opens a copy of the fixture at its own path, and asserts each default plus a
non-empty list; it fails nine assertions against the unfixed store.
`reloadPreservesFilters` is the half that matters just as much — resetting
inside `refreshAll` would satisfy the first test while wiping the filter on
every watcher tick, and `reload` exists precisely to keep the view stable while
the file changes underneath. `surfaceIsNotAFilter` pins the exclusion so it
cannot be "tidied up" later.

---

## 2026-08-21 — Triage staleness counted commits bv does not see

**Symptom:** `stale_count` disagreed with `bv --robot-triage` on the same
workspace. Reproduced against bv v0.20.0 in a repository holding three months-
old open beads plus one recent commit naming a bead in its message while
touching no bead record: bv reported 3 stale, vbx reported 2.

Invisible on the demo fixture — every bead there is recently active, so
staleness is `null` in both tools and the parity harness reported a match. It
takes a bead old enough to cross the 14-day threshold before the two disagree.

**Cause:** vbx correlates a commit to a bead two ways — the commit edited the
bead's record beside code (co-committed), or the commit *message* names the
bead (explicit). bv's triage path only ever has the first: it derives its
commits from the beads-file events, and its `ExplicitMatcher` is never
constructed anywhere in bv's own `pkg/` or `cmd/`. `ComputeStaleness` takes the
latest of a bead's events and commits, so an explicit-only commit made a bead
look freshly worked to vbx and stale to bv. Staleness is 10 % of the triage
score, so this moved the whole ranking, not one field.

**Fix:** `historyForTriage` hands triage a narrowed copy keeping only commits
whose SHA also appears among that bead's own events — exactly the set bv
derives. Narrowing by *method label* would have been wrong: a commit that both
names a bead and edits its record is recorded as explicit here but is a
co-commit to bv, so dropping it by label swaps one divergence for another.
Explicit correlation is untouched everywhere else — it is the History view's
whole point, and it is genuinely better, since bv's own patterns require a
numeric suffix and miss every `br`-minted id like `vbx-8ou`.

**Prevention:** `TestTriageStalenessIgnoresExplicitOnlyCommits` builds that
repository and asserts `stale_count`; it reports 1 against the unfixed engine.
`TestTriageNarrowingLeavesTheCachedReportIntact` guards the other direction —
the report is cached and shared with the History view, so narrowing a copy
rather than the original is load-bearing. `TestHistoryForTriageKeepsOnlyEvent`
`Commits` pins the SHA-based rule against a hand-built report.

---

## 2026-08-20 — The leak scan flagged nine files that held no secret

**Symptom:** the first run against a real `scripts/signing.env` reported
`FileWatchService.swift`, `Keychain.swift`, `build-app.sh`, `package-app.sh`,
`test-packaging.py` and the template itself as carrying "a configured signing
value". None of them did.

**Cause:** the scan took every value in the config file longer than eight
characters. `VBX_BUNDLE_ID=com.qjam.vbx` is one of them — and it is committed
in `Info.plist`, the scripts and the Swift sources, deliberately. A partly
filled config also still holds the template's placeholders, which by definition
match the template.

**Fix:** scan only the settings that are actually secret — Team ID, the three
certificate names, the provisioning profile path. The bundle identifier is
public by design, and the notary *profile name* is local rather than secret
(the credential it names stays in the keychain). Values still equal to a
placeholder are skipped.

**Prevention:** `test_the_leak_scan_still_detects` asserts both directions
against a planted config: a real Team ID and a real certificate name *are*
scanned for, the bundle id and notary profile are *not*, and an untouched
template yields nothing. Narrowing a detector risks switching it off, and a
detector that fires on everything gets ignored — which is the same outcome by a
longer route.

---

## 2026-08-20 — An editor's swap file beside `signing.env` was committable

**Symptom:** with `scripts/signing.env` created and correctly ignored,
`git status` showed `?? scripts/.signing.env.swp` — vim's swap file, holding
the same buffer contents, Team ID included, and stageable.

**Cause:** the `.gitignore` rule was the exact filename. It covered the file
being protected and nothing an editor leaves beside it: `.signing.env.swp`,
`signing.env~`, `signing.env.bak`. The one file everybody thinks of was
covered; the copies made automatically were not.

**Fix:** glob the family — `scripts/signing.env`, `scripts/signing.env.*`,
`scripts/signing.env~`, `scripts/.signing.env*` — with an explicit
`!scripts/signing.env.example` negation, because the broadened glob would
otherwise swallow the committed template.

**Prevention:** `scripts/test-packaging.py` asserts six editor leftovers are
ignored *and* that the example template is not, so the negation cannot be lost
while widening the glob later. Found by watching real `git status` output
rather than by reasoning about the rule — the original rule looked right.

---

## 2026-08-19 — Blockquote rule stretched down the whole pane

**Symptom:** a one-line quote in a bead description drew a grey vertical bar
hundreds of points tall, down the rest of the description.

**Cause:** the rule was a `RoundedRectangle` sibling in an `HStack`. A bare
shape is greedy and expanded to whatever vertical space the container had left.

**Fix:** the rule is an `.overlay(alignment: .leading)` on the quote text, so it
inherits the text's height.

**Prevention:** covered by the `markdown-blocks` snapshot — this was invisible
to every non-visual test and was found by looking at the rendered PNG.

---

## 2026-08-19 — Wrapped sentences broke mid-clause in rendered Markdown

**Symptom:** a description wrapped in the source rendered with a hard line
break where the author had simply wrapped, e.g. "…while the real" / newline /
"concurrency stays inside Go."

**Cause:** the parser joined paragraph lines with a literal newline, and the
renderer preserves whitespace. In Markdown a lone newline inside a paragraph is
a *soft* break and means a space.

**Fix:** `MarkdownParser.joinSoftWrapped` joins with a space, keeping genuine
hard breaks (two trailing spaces, or a trailing backslash).

**Prevention:** `MarkdownTests.lineBreaks` and `wrappedSentenceJoins`, the
latter using the exact sentence that exhibited the bug.

---

## 2026-08-19 — `parent-child` and `waits-for` wrongly treated as blocking

**Symptom:** none visible; every graph metric would have been subtly wrong.

**Cause:** the initial Swift `DependencyType` declared
`{blocks, parentChild, conditionalBlocks, waitsFor}` as blocking. bv's rule is
narrower: `IsBlocking()` is `type == "" || type == "blocks"`.

**Fix:** `DependencyType.isBlocking` now matches bv exactly, including the
legacy quirk that an *empty* type blocks.

**Prevention:** `ModelTests.blockingSemantics` asserts each type individually.
Any Swift-side notion of blocking must be checked against bv's source, not
inferred from the name — this is the failure mode the "no metric is computed in
Swift" rule exists to prevent.

---

## 2026-08-19 — Graph layout ranked dependents above their blockers

**Symptom:** the dependency graph drew upside down — the bead that depends on
everything sat at the top, its blockers beneath it.

**Cause:** `GraphLayoutEngine` computed longest-path rank correctly, then
inverted it with `maxRank - rank`.

**Fix:** use the computed rank directly, so rank 0 is unblocked and each row
below waits on the row above.

**Prevention:** `QueryAndLayoutTests.layoutRanking` pins the ranks of a
three-node chain. Confirmed visually in the `graph-canvas` snapshot.

---

## 2026-08-19 — Execution plan decoded to silently empty tracks

**Symptom:** the Plan view showed track headers with no cards.

**Cause:** the Swift model expected `{id, issues: [String]}`; bv emits
`{track_id, items: [PlanItem]}`. Lenient decoding turned the mismatch into
empty arrays rather than an error.

**Fix:** model the real shape, including `PlanItem` and the plan summary.

**Prevention:** `EngineTests.executionPlan` asserts every track is non-empty
*and* that the planned set equals the actionable set. Lenient decoding needs a
positive assertion on content, since it cannot fail loudly by design.

---

## 2026-08-19 — "Compute metrics" was a no-op after opening with Phase 2 skipped

**Symptom:** opening with metrics skipped left the UI permanently unable to
compute them; the button did nothing.

**Cause:** the session was analysed once with every Phase-2 metric disabled.
That leaves `phase2Ready == true` with no values, so `wait_phase2` returned the
same empty result forever.

**Fix:** added the engine's `compute_phase2`, which re-runs a full analysis. The
UI gates on `hasPhase2Values` rather than `phase2Ready`.

**Prevention:** `engine.TestComputePhase2AfterSkip` and
`ProjectStoreTests.storeComputesPhase2`. Note the distinction the two flags
carry: "ready" and "has values" are not the same thing, and conflating them is
what produced the dead button.

---

## 2026-08-19 — Scrolling views rendered completely blank in snapshots

**Symptom:** Board, Insights, Labels and Inspector snapshots were empty —
0 % ink, one colour — while Graph, Tree and Sidebar rendered fine.

**Cause:** `ImageRenderer` does not lay out `ScrollView` content.

**Fix:** snapshots render through `NSHostingView` in an offscreen window, which
performs a real AppKit layout pass.

**Prevention:** the snapshot suite asserts ink coverage and colour variety, not
file size — a view that lays out but paints nothing still produces a valid PNG,
so "a file appeared" would have passed throughout.

---

## 2026-08-19 — Inspector reported "Unblocks 0" for a bead that unblocks six

**Symptom:** `vbx-3` showed Blocks 7, Unblocks 0.

**Cause:** the count was fetched in a `.task`, which never runs in a static
render and flashes 0 in the live app before resolving.

**Fix:** the plan and triage payloads already carry unblocks lists, so they
populate a cache the inspector reads synchronously. Genuinely-unknown values
render "—", never 0.

**Prevention:** `UnblocksCacheTests`, including that nil and `[]` stay
distinguishable, and that unblocks (6) is not conflated with blocks (7) —
`vbx-6` also waits on `vbx-12`, so closing `vbx-3` alone would not free it.

---

## 2026-08-20 — Markdown tables were collapsed onto a single line

**Symptom:** a pipe table in a bead description rendered two different wrong
ways depending on what surrounded it. Alone, `looksLikeMarkdown` returned
`false` and the rows showed as literal pipes in body font. Beside any other
Markdown, detection fired, the rows fell through to the paragraph branch, and
every row was joined into one line.

**Cause:** `MarkdownParser` had no table block. The second symptom was a side
effect of the soft-break fix: `joinSoftWrapped` is correct for prose and
destructive for a table, and nothing stopped table rows reaching it.

**Fix:** `MarkdownBlock.table(headers:rows:alignments:)`, parsed from a header
row followed by a delimiter row and rendered with SwiftUI `Grid` inside a
horizontal `ScrollView`. Detection treats `|` as a signal only when a delimiter
row follows.

**Prevention:** parser tests for alignment, ragged rows, escaped pipes in cells
and table termination, a false-positive suite covering prose like
`use a | b to pipe`, and a render snapshot. The false-positive guard is the load
bearing one — the delimiter row must have exactly as many cells as the header,
which is what stops a `---` rule under a pipe-containing sentence from reading
as a one-column table.

---

## 2026-08-20 — History was empty in a git worktree

**Symptom:** the History view reported "no history available" and the engine
returned `resolving HEAD: reference not found`, in a checkout that plainly had
commits.

**Cause:** the checkout was a *linked worktree*. There `.git` is a file
pointing at `<main>/.git/worktrees/<name>`, and the refs — HEAD included — live
in the common directory rather than beside the worktree. go-git opens such a
repository happily with `DetectDotGit` alone and only fails later, at HEAD
resolution, which reads like an empty repository rather than a misconfigured
one.

**Fix:** `PlainOpenOptions.EnableDotGitCommonDir`, which is exactly the option
for this layout.

**Prevention:** `EngineTests.historyReachable` walks the fixture workspace,
which lives inside this repository — so it exercises whatever checkout layout
the tests are run from, worktree or not.

**A second bug hid the first.** The fix appeared not to work: the Go tests
passed and the Swift ones kept failing with the old message. SwiftPM does not
treat `libvbxengine.a` as a build input, so rebuilding the engine alone does
*not* trigger a relink — `swift test` kept running the previous archive.
`build-engine.sh` now touches `Sources/VBXEngine/BeadsEngine.swift` after a
successful build to force it. Worth remembering whenever a Go-side change seems
to have no effect on the Swift side.

---

## 2026-08-20 — Two tests fought over the fixture's `.bv` directory

**Symptom:** the recipe save/delete test failed with `no project recipe named
"vbx-test-recipe"` — but only sometimes, and only when the whole suite ran. The
recipe was demonstrably saved a moment earlier, and the listing still showed it.

**Cause:** Swift Testing runs tests in parallel. The alerts test wrote a
baseline to `<fixture>/.bv/baseline.json` and cleaned up by removing the file
*and its parent directory*. `removeItem` on a directory is recursive, so it took
`<fixture>/.bv/recipes.yaml` with it — a file a different test, running at the
same moment, had just written. Whichever test lost the race reported the
failure, which is why it looked like a bug in the recipe code.

**Fix:** `Fixture.writableStore()` copies the fixture to a private temporary
directory. Any test that writes into the workspace uses it, so no two tests
share a filesystem.

**Prevention:** the two tests that write — the baseline round trip and the
recipe round trip — both go through the helper, and both assert against a
directory they own. As a side effect the checkout is no longer mutated by a
test run at all, which is worth having on its own.

---

## 2026-08-20 — The engine archive ignored the declared deployment target

**Symptom:** every Swift link printed, once per object file:

```
ld: warning: object file (libvbxengine.a[...]) was built for newer 'macOS'
    version (26.0) than being linked (14.0)
```

**Cause:** `Package.swift` declares `platforms: [.macOS(.v14)]`, but
`build-engine.sh` built the Go archive with no deployment target at all, so
every object carried the host SDK's minimum — 26.0. Not cosmetic: the app
claimed to support macOS 14 while linking objects that require 26. It runs on
the build machine and fails on the machine the deployment target promised.

**Fix:** `-mmacosx-version-min` via `CGO_CFLAGS` and `CGO_LDFLAGS`.

**The part worth remembering:** `MACOSX_DEPLOYMENT_TARGET` alone does **not**
work with this toolchain. Setting it changed nothing — the Go-linked `go.o` and
the cgo-compiled objects alike stayed at 26.0. Only the explicit
`-mmacosx-version-min` flag reaches both. The variable is still set because it
is the conventional knob and costs nothing, but it is not what fixes this.

**Prevention:** two assertions in `build-engine.sh`, because setting a flag and
assuming it worked is how this went unnoticed for so long:

- `assert_package_target` reads the platform out of `Package.swift` and refuses
  to build when the script and the manifest disagree. Nothing else would notice
  them drifting apart.
- `assert_archive_target` runs `otool -l` on the built archive and requires
  *every* object to report the expected `minos`. Checking only the first would
  have passed while the rest were wrong — the archive holds objects from two
  different tools, and a flag reaching one need not reach the others.
