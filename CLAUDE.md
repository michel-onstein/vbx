# vbx — project instructions

**Visual Beads for macOS.** A native app for beads issue graphs: a SwiftUI
front end over the Go analysis engine of
[`bv`](https://github.com/Dicklesworthstone/beads_viewer).

`vbx` is the short form and is what appears in code, paths, the bundle
identifier and the URL scheme. **Visual Beads** is the display name, and the
only place the long form belongs is user-facing text — the menu bar, the About
box, the README title.

## Document index

| Document | ADR | Description | State |
|---|---|---|---|
| [VBX_DESIGN.md](docs/VBX_DESIGN.md) | ADR-001 | Architecture: engine reuse, C ABI bridge, data model, UI, distribution | Built |
| [FEATURE_PARITY.md](docs/FEATURE_PARITY.md) | — | Every bv capability mapped to a vbx surface and delivery phase | Living |
| [RELEASES.md](docs/RELEASES.md) | ADR-013 | User-facing changes per release — generated from the git tags, never edited | Generated |
| [project_notes/BUGS.md](docs/project_notes/BUGS.md) | — | Bug log with the regression test locking each fix in | Living |
| [project_notes/DECISIONS.md](docs/project_notes/DECISIONS.md) | ADR-001…027 | Architectural decisions and their trade-offs | Living |
| [project_notes/KEY_FACTS.md](docs/project_notes/KEY_FACTS.md) | — | Toolchain, commands, layout, gotchas | Living |
| [project_notes/WORK_LOG.md](docs/project_notes/WORK_LOG.md) | — | Dated work log | Living |

`docs/html/` is generated from `docs/*.md` by `scripts/build-docs.py`; never
edit it by hand. `--check` proves it still matches its Markdown, and
`version-bump.sh` regenerates it as part of recording a release — the release
rewrites `RELEASES.md`, so without that the one page listing releases is the
page guaranteed to go stale.

## Rules specific to this repo

These are not in `bv --help` or the global conventions, and nothing else records
them.

- **No metric is ever computed in Swift.** The engine owns every number; Swift
  does layout and formatting only. Graph *layout* is Swift because it is
  presentation, not analysis. Reimplementing a metric "just to avoid a round
  trip" reintroduces exactly the drift ADR-001 exists to prevent.
- **An unavailable metric is absent, never zero.** Phase-2 dictionaries are
  omitted rather than zero-filled, and the UI shows the metric's status. Note
  `phase2Ready` and `hasPhase2Values` are different: everything-skipped is
  "ready" with nothing in it.
- **A report the engine failed to build is unavailable, never empty.** Never
  read a displayed report with `(try? …) ?? .empty`: every panel once did, and
  drew "No alerts", "No labels" or a zero for a call that failed. Read it
  through `ProjectStore.fetch(.report) { … }`, which records the failure in
  `unavailable`; the view checks `unavailableReason(_:)` and draws
  `UnavailableReportView` / `UnavailableReportLabel`, or a dash for a count.
  A new report is a new `EngineReport` case — `UnavailableReportTests` runs
  every case, so one that bypasses `fetch` fails it. A normal empty state the
  engine *throws* for (revisions outside git) is guarded before the call, not
  swallowed. See BUGS.md, 2026-10-02 (vbx-twy).
- **Decoding never drops a record.** Status, type and dependency-type enums are
  open. A dropped issue silently changes every downstream metric. **Analysis is
  a different set:** like bv 0.25, the engine analyses every record *except
  tombstones*, while bv's readiness index sees the tombstones too, so a deleted
  blocker counts as resolved. The session's `records` (the `issues` payload)
  keep the tombstone; its `issues` (the analysis set) do not. Pick the one you
  mean. See ADR-021.
- **An empty dependency type blocks**, matching bv's rule for rows written
  before the typed system. Since bv v0.25.0, `""`, `blocks`,
  `conditional-blocks` and `waits-for` block — not `parent-child`, `related`,
  `discovered-from` or a custom type. The rule is bv's `IsBlocking()`, and
  it has moved once already: check the engine's bv version, not this line, and
  `blockingAgreesWithEngine` fails when Swift's copy drifts from it.
- **The engine archive is not committed.** Run `./scripts/build-engine.sh`
  before `swift build` in a fresh clone. The generated header *is* committed,
  because the Swift C target needs it to compile.
- **The app icon *is* committed, and never hand-edited.**
  `Resources/vbx-icon.svg` is output from `scripts/make-icon.py` — edit the
  script's control points, not the SVG. `Resources/vbx.icns` and the README's
  `docs/images/vbx-icon.png` are committed too (unlike the engine archive)
  because rasterising them needs `rsvg-convert`, which is not part of the
  toolchain, and `build-app.sh` has to be able to bundle an icon on a bare
  clone. `./scripts/build-icon.sh` rebuilds both from the SVG, so the README
  image cannot drift from the icon. See ADR-008.
- **Snapshot tests must not use `ImageRenderer`** — it does not lay out
  `ScrollView` content, so scrolling views render blank and pass a naive
  file-exists check. Use `NSHostingView`, and assert on ink coverage.
- **`.task` and `.onAppear` do not run in a snapshot.** Prefer data the store
  already holds; that constraint is why the unblocks cache exists.
- **The bead list is `NSTableView`, not SwiftUI's `Table`.** See ``BeadTable``
  and ADR-014. The reason is per-cell editing: `Table`'s only double-click hook
  is `primaryAction:`, which reports the selected rows and not the column, and a
  gesture on cell content is not a route to rely on — priority editing shipped
  that way and did nothing in a real build.
  **Cell appearance is still SwiftUI**, hosted in the cell, so there is one
  description of how a bead looks. Only columns that accept an edit are drawn
  natively, because an `NSTextField` is what a field editor edits.
- **A column is declared once**, in `IssueListView.specs`. Its identifier is a
  storage contract — stored layouts are keyed by it — and for a sortable column
  it must equal its `SortColumn` raw value, or the header chevron and the order
  come apart. An *unsortable* column has no `SortColumn` to take one from and
  supplies its own (`type`, `blockedRatio`). Asserted in `Table columns`.
- **A row's appearance that comes from outside the `Issue` record must be in
  `BeadTable`'s fingerprint**, or it goes stale on screen. The table reloads
  only when the fingerprint changes — it has to, because `updateNSView` runs on
  every unrelated state change and an unconditional reload cancels an
  in-progress edit on every keystroke elsewhere. The uncommitted mark is drawn
  from git rather than from the bead, and a commit changes no bead: `HEAD`
  moves, every mark clears, and a fingerprint of the record alone is identical
  either side of it. Same trap for any later overlay — the engine's deferral
  verdict (`IssueRow.isDeferred`) is one: the clock passing a `defer_until`
  changes no field either. See BUGS.md, 2026-08-23.
- **Hosted cell content is aligned by `HostedCell`, not by each column.** The
  hosting view is pinned to both edges, so content handed the full column width
  centres itself — which is what put every hosted column in the middle of its
  cell after the move to `NSTableView`. A new column cannot forget it, because
  it is applied once where the cell hosts the view. Leading is the default; a
  column wanting the other edge sets `contentAlignment` **on its spec**, which
  `HostedCell` reads. Wrapping a column's own content in an alignment instead
  puts the decision back where this exists to take it out of. The same goes for
  `contentInset`: the gutter is 10pt wide, and 4pt each side would leave 2pt and
  clip the glyph — asserted by rendering, since at that size "tight" and
  "clipped" are two points apart.
- **What separates two columns is the table's `intercellSpacing`, not their
  widths.** An inset-style table sets it to 17pt, so the uncommitted gutter's
  cell ends at x=26 while the ID cell starts at 43. Narrowing a column moves its
  content by the width you removed and no further; the gap is a property of the
  table and cannot be set for one column. `contentTrailingInset` may go
  **negative** so a column's content overhangs into that gap, which is safe
  because the gap belongs to no column — but an overhang as long as the spacing
  reaches the next column's content, and the test asserts it stays shorter.
- **"Uncommitted" is defined against git, not tracked by vbx.** A bead is dirty
  when its record differs from the same record at `HEAD`, read through the
  engine's `snapshot_at` — the object store directly, as ADR-006 requires. No
  side file to fall out of step with an external `br` run or a checkout. See
  ADR-015. Note `HEAD` moving is invisible to the bead-file watch, so `.git` is
  watched too. **In a multi-repository workspace every member has its own
  `HEAD`**: `snapshot_at` for `HEAD` reads each member's own object store, and
  the engine's `git_watch_paths` names each member's `.git` — a separate list
  from `watch_paths`, because a commit needs the marks recomputed, which the
  hash-gated reload would skip. See BUGS.md, 2026-10-01 (vbx-d1c).
- **The graph's camera is ``GraphCamera``, and nothing recomputes its
  arithmetic.** Drawing, hit-testing, the zoom buttons and both trackpad
  gestures go through the one value — a click that lands on the node that *was*
  under the cursor is what a second copy of the transform looks like. Zoom is
  clamped in one place, so the percentage readout means the same thing whichever
  input produced it. See ADR-019.
- **SwiftUI has no scroll gesture, and a view that hit-tests to get one takes
  every click with it.** Two-finger scrolling over the graph arrives through an
  `NSEvent` local monitor scoped to the catcher's window and bounds, behind a
  view that returns `nil` from `hitTest(_:)`; the mouse stays SwiftUI's. Also:
  **a synthesised scroll event carries no window**, so delivery cannot be
  asserted — test the deltas and the catcher's rectangle instead.
- **A synthetic click cannot activate anything inside a table.** It presses a
  plain SwiftUI `Button` in a hosting view, but inside a table it neither
  focuses a known-editable `NSTextField` nor fires a double-click action. So a
  headless "the click did nothing" result is a fact about the harness, not the
  app — a test asserting it passes either way. One was written and deleted for
  exactly that; assert what sits either side of the click instead.
- **Never conform a type to both `Codable` and `RawRepresentable`** when the raw
  value is `Codable` and `rawValue` encodes `self`. The standard library's
  `RawRepresentable` coding defaults encode the *raw value*, so `rawValue`
  re-enters itself and the stack overflows — SIGSEGV, no message, dead test
  runner. `BeadTableLayout` codes a private nested type for this reason.
- **One `Text` holding a large string is seconds of layout.** SwiftUI lays a
  `Text` out in full before drawing any of it: the 227 KB acknowledgements took
  **7.1 s**, with a spinning cursor throughout. Split across a `LazyVStack` it
  is 0.01 s. Text selection is not the factor — disabling it changed nothing.
- **The demo fixture must stay writable by `br`.** Its preflight validates every
  dependency row and requires `created_at` on each, and it rejects the *whole*
  workspace when one is missing. That is why no test caught the priority bug:
  every real write against the fixture had always failed. The same holds for
  `Fixtures/readiness`, and br's import also rejects a dependency naming a bead
  that does not exist — so that fixture's missing blocker is an `external:`
  reference, which br accepts and bv still reads as unknown.
- **bv 0.25's readiness cases live in `Fixtures/readiness`, not the demo.**
  Custom status, `waits-for`, `conditional-blocks`, `defer_until`, a missing
  blocker, parent-child gating, a tombstoned blocker — none of which the demo
  reaches, which is how numbers moved under the engine bump with every test
  green. Add a new edge case there, so the demo's numbers stay stable.
  `parity-check.py` compares it as JSONL and as a `beads.db` built at run time,
  because vbx reads SQLite through its own loader. Its deferral is in 2099, so
  the ready set does not depend on the clock. Sprint data likewise lives in
  `Fixtures/sprints`; adding a sprint file to the demo would move its numbers.
- **`Bundle.main` in a test process is SwiftPM's helper binary**, not the app —
  so `CFBundleShortVersionString`, `CFBundleVersion` and the bundle identifier
  are all absent. Anything reading them renders empty in every snapshot. Take
  the info dictionary as a parameter and default it to `Bundle.main`, or the
  code is untestable and quietly stays that way.
- **Ink coverage is whole-image unless you scope it.** `inkCoverage(in:)` takes
  a region in points; use it whenever a scrolling pane dominates the frame,
  because the pane's own text clears any threshold on its own and a header that
  vanished would still pass.
- **Swift Testing exports its own `Issue` type.** Test files alias the model:
  `private typealias Bead = VBXCore.Issue`.
- **Tests that write into a workspace use `Fixture.writableStore()`**, which
  copies the fixture to a temporary directory. Swift Testing runs tests in
  parallel, and two writing to the shared fixture interfere. **A copy must be
  what was committed, not what is on disk**: `Fixture.copy` drops `br`'s and
  bv's gitignored local state, because a stray `.bv/semantic` index in one
  checkout's `Fixtures/demo` once made a test pass there and fail everywhere
  else. New local state a tool writes into a workspace belongs in that list.
- **The version is the git tag, never a literal, and the tag carries no `v`.**
  `scripts/version.sh` is the only source: the tag `0.2.0` *is*
  `CFBundleShortVersionString`, and the commit count becomes `CFBundleVersion`.
  Three things have to agree — the app, the `.dmg` filename and a Homebrew
  cask's `version` — and a cask that disagrees with what the app reports cannot
  be upgraded. A `v` prefix is three more places to forget the strip, so
  `release.sh` refuses `--tag v0.2.0` rather than accepting and stripping it.
- **The bump level comes from a `semver:*` PR label, not the commit subject.**
  Subjects here are prose, so a Conventional Commits parser reads every one of
  them as "no bump". `scripts/version-bump.sh` reads the label once, records it
  in the annotated tag, and everything downstream reads git alone — which is why
  `release-notes.py --check` is offline enough for the verify block. A missing
  label defaults to patch **and says which rule fired**; a silent default is how
  a feature ships as a patch. Before 1.0.0, a breaking change bumps MINOR. See
  ADR-013.
- **A commit that touches only `.beads/` bumps nothing.** Beads land as ordinary
  squash-merged PRs, so without the rule every `br create` that reached `main`
  would cut a patch — a release whose notes describe an issue somebody wrote
  down rather than anything a user can install. The test is the *diff*, not the
  subject: a PR that changes code and a bead is a real change and bumps as
  usual. When a run finds nothing but bookkeeping it says so and exits, and each
  skipped commit is named `beads-only` on the way past — a commit that silently
  did not count is indistinguishable from one the script never saw. See ADR-013.
- **Every distribution build is universal**, implied by `--dmg`, `--app-store`
  and `--sign` just as they already imply `--release`. Check the *artefact*, not
  the flag: `lipo -archs` on both binaries in the bundle, the same distinction
  `assert_archive_target` draws for the deployment target. `lipo` strips the
  linker's ad-hoc signature, which is why nested code is signed before the
  bundle. See ADR-012.
- **Launch discovery probes; it never opens to find out.** `loadError` means the
  user pointed at something and it did not work. A candidate found by discovery
  — the recents list, the current directory, a restored window's path — is
  skipped when it does not probe openable, so a launch with nothing to open
  lands in the neutral empty state. Only an explicit choice reports a failure.
- **A `br` write run from a worktree lands in the main checkout, and looks like
  a silent no-op.** `br` resolves its workspace through git's common dir, so
  from `.claude/worktrees/<topic>` it writes the *primary* checkout's
  `beads.db` and `.beads/issues.jsonl`: it prints the updated issue and exits
  0, your worktree's export is unchanged, and the shared tree is left holding an
  uncommitted edit. This was once recorded here as "`br update
  --description-file` is a silent no-op" (`vbx-g3q`); it is not — the flag
  writes on br 0.6.0 and 0.7.4 alike, and `-d` from a worktree misses in exactly
  the same way. **Pin every `br` call to the worktree** with
  `--db "$PWD/.beads/beads.db"` or `BEADS_DB`, and run `br where` if in doubt.
  Separately, `br update` **refuses** — exit 4, a `VALIDATION_FAILED` envelope
  on stdout — a description under half the old length unless `--force` is
  given, so a shrink is loud rather than lost. See BUGS.md, 2026-10-01.
- **A single-bead `br update` is guarded by `Issue.updatedAtStamp`, never by
  `updatedAt`.** `br update --if-unchanged` (0.7.0+) compares to the
  microsecond; a `Date` keeps milliseconds, so a stamp rebuilt from one is a
  conflict on every edit. Pass the stamp of the record the user *saw* — reading
  it fresh with `br show` just before writing guards nothing. A new single-bead
  edit goes through the same path; a multi-id command (`br label`) cannot. See
  ADR-022.
- **`br` stamps `source_repo` with the directory it runs in, so every bead
  created in a worktree is stamped wrong.** That rule and this repo's worktree
  discipline are in direct conflict, and the worktree rule is the right one — 30
  of 54 records named a topic directory that had since been deleted, and 29
  named a path that no longer existed. Nothing reads the field today
  (`RepoInfo.owns(_:)` matches by id prefix), so the cost is latent: `br`'s help
  calls `source_repo_path` the canonical location "for cross-machine sync
  awareness". It cannot be set at creation — `br create` has no
  `--source-repo` flag and `.beads/config.yaml` holds only `issue_prefix` — but
  `br update` has `--source-repo` and `--source-repo-path`, which is what the
  fix uses. So **after `br create`, run `python3 scripts/beads-check.py
  --fix`**, from wherever the bead was created. `--fix` pins every `br` call to
  the `beads.db` beside the export it checked (an explicit `BEADS_DB` wins and is
  named) and re-reads that export afterwards, failing if the stamps did not land
  there — so from a worktree it no longer rewrites the main checkout. The check
  is in the verify block, which is what makes forgetting a build failure instead
  of silent drift. The real fix is upstream in `beads_rust`. See ADR-018.
- **Never call bv's `workspace.LoadAllFromConfig` or `AggregateLoader`.** In
  v0.25.2 they run `br update --help` and `bd export` unconditionally, which the
  App Sandbox forbids. Workspaces load through `workspace_loader.go`, a port
  whose tracker access is the session's choice, and `TestWorkspaceLoaderMatchesBV`
  holds it to bv's. See ADR-020 and BUGS.md, 2026-10-01.
- **Workspace discovery is bv's precedence, in the app as in `vbx-cli`.** A
  reachable `.beads` wins over a `.bv/workspace.yaml` found upward, and an
  explicit configuration (`--workspace`, or the YAML file chosen in the app)
  wins over both. `discoverWorkspaceConfig` is the only copy of the rule, and
  `Probe` and `load` both ask it. Parity over a workspace must run outside
  this checkout, because from inside it discovery reaches this repository's
  own `.beads`. See ADR-026.
- **`Engine/bridge/correlation` is bv's `pkg/correlation`, generated — never
  edit it.** `scripts/vendor-correlation.py` copies it from the module cache at
  the version `go.mod` pins, with seven asserted substitutions, and `--check`
  in the verify block fails on any hand edit. vbx's own files there are
  `vbx_*.go` and `internal/env`. Its one way to git, `gitCommand`, runs
  `objgit` in-process, which answers each command line from the object store
  with the bytes git prints and **refuses** any it does not know — so a bv
  upgrade that adds a git call fails the differential tests instead of
  approximating, **but only a call some test history reaches**. A fallback
  path runs only on the histories that take it: the orphan detector's
  per-commit `show --name-status` reached no fixture and shipped refused
  (vbx-lh0). `TestThisRepositoryMatchesBV` walks this repository's whole
  history and fails on any command line outside `supportedShapes`; a new
  fallback needs a fixture that takes it. Never make `objgit` guess at an
  invocation. Port git's
  behaviour, and prove it against real git in a test. See ADR-027.
- **bv's custom id patterns are a package global, and the engine holds a
  lock whenever it sets them.** `correlation.SetCustomIDPatterns` is how
  `--id-pattern` reaches the explicit matcher and the orphan detector. One
  process serves a session per window, each with its own patterns. So
  `withIDPatterns` sets them, runs the reader and restores them. A new caller
  of `NewCorrelator` or the orphan detector goes through
  `Session.newCorrelator` / `withIDPatterns`, or it runs with whichever
  window's patterns happen to be registered. The app registers `br`'s id
  shape for the workspace's prefix; `vbx-cli` registers only `--id-pattern`,
  as bv does. See ADR-027.
- **Where a vbx-cli modifier applies is declared once, in `ModifierRules`**
  (VBXCore) — bv's `modifierRules`, in bv's order, with bv's message and
  **exit 1** (bv's status for these, not the 2 of an unparseable value).
  Adding a modifier flag to vbx-cli means adding its rule there; `--help` is
  printed from the table, and `test-parity-check.py` fails when a bv modifier
  vbx-cli parses has no rule, a rule differs from bv's source, or a rule has
  no refused parity comparison. Never check a modifier by hand in
  `parseArguments` or a request builder. See BUGS.md, 2026-10-02 (vbx-uao).
- **Triage includes a bounded git-history walk**, because bv's does and it
  moves the scores. It is capped at 200 commits with a 10 s timeout, and
  reports `history_status` so an absent staleness signal is distinguishable
  from a low one. **It runs only where bv's does:** not under
  SOURCE_DATE_EPOCH (`skipped`), and not unless the workspace directory itself
  holds `.git` — bv never looks further up, though vbx's object store would
  (`error`). Either way the history is nil and staleness is absent; an empty
  report instead makes `ComputeStaleness` fall back to `updated_at`. See
  BUGS.md, 2026-10-01 (vbx-8u3).
- **Only vbx-cli resolves the live tracker.** Claim and show commands come from
  bv's `loader.AttachIssueOrigins`, which runs `br update --help` — a
  subprocess the App Sandbox forbids. The session's `live_tracker_actions`
  open option turns it on; `vbx-cli` passes it and the app never does, so in
  the app every bead's `actions` carry an `unavailable_reason` instead of a
  command. Never sniff the sandbox, and never assemble a claim string in vbx:
  the claim is bv's atomic `br update --claim`, taken from the bead's actions.
  Multi-repository workspaces are the exception still open — bv's workspace
  loader binds origins itself. See ADR-020.
- **Only vbx-cli runs export hooks.** `.bv/hooks.yaml` commands run through
  bv's `pkg/hooks` inside `export_report`, and only for a session opened with
  `export_hooks` — which vbx-cli sets unless `--no-hooks` is given, and the app
  never does, because a hook is a subprocess the sandbox forbids. The hook
  text bv prints comes back in the payload for the CLI to print; the engine
  has no stdout. Same pattern as live tracker actions (ADR-020).
- **Analysis reads "now" from `robotNow()`, on every call.** It honours
  `SOURCE_DATE_EPOCH` everywhere bv 0.23+ does — label health, alerts, impact,
  ETA, readiness — which is what lets the parity check compare exactly. The
  session's analyzer is long-lived, so its clock is set per call through
  `Session.pinClock`, never once at load: a clock captured at load freezes
  every staleness figure in the app at the moment the workspace was opened.
  Only non-analysis timestamps (load time, a deploy commit) use `time.Now()`.

## Verify before committing

```bash
./scripts/build-engine.sh --check   # Go archive + C ABI smoke test
./scripts/build-icon.sh --check     # committed .icns + README PNG are intact
python3 scripts/build-notices.py --check  # every dependency is acknowledged
python3 scripts/test-packaging.py   # signing, redaction, universal, version, cask
python3 scripts/release-notes.py --check  # docs/RELEASES.md matches the tags
python3 scripts/build-docs.py --check     # docs/html matches docs/*.md
python3 scripts/beads-check.py            # every bead is stamped with this repo
python3 scripts/vendor-correlation.py --check  # Engine/bridge/correlation is bv's
swift test                          # Swift suite
cd Engine/bridge && go test ./...   # Go suite
gofmt -l Engine/bridge              # must print nothing
python3 scripts/test-parity-check.py  # the parity harness itself (no binaries)
python3 scripts/parity-check.py     # vbx-cli vs bv, command by command, every fixture
```

The parity check needs `bv` on the PATH, **at the engine's beads_viewer version**
— the one in `Engine/bridge/go.mod`, compared against `bv --version`. Without
`bv` every comparison is reported as *skipped* rather than passing, so a missing
`bv` cannot look like agreement. A `bv` of another version (Homebrew's lags
behind) is worse than none — every upstream change between the two reads as a
vbx bug — so the check names both versions and the binary's path in a banner,
compares nothing, and **fails**; `--allow-bv-mismatch` compares anyway, under
the same banner. Get the matching `bv` with `brew upgrade bv`, or put the
release binary for the go.mod tag first on the PATH (or pass `--bv <path>`). It exits non-zero when any comparable command differs, or when a
command it declares is not implemented. It covers every workspace in its
`FIXTURES` (`--workspace` narrows it to one), and prints the first difference
per command with a count of the rest — `--verbose` lists them all.

Biome is not configured here (no `package.json`, and Biome does not format
Markdown). Go is formatted with `gofmt`.
