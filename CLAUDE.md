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
| [project_notes/DECISIONS.md](docs/project_notes/DECISIONS.md) | ADR-001…016 | Architectural decisions and their trade-offs | Living |
| [project_notes/KEY_FACTS.md](docs/project_notes/KEY_FACTS.md) | — | Toolchain, commands, layout, gotchas | Living |
| [project_notes/WORK_LOG.md](docs/project_notes/WORK_LOG.md) | — | Dated work log | Living |

`docs/html/` is generated from `docs/*.md` by `scripts/build-docs.py`; never
edit it by hand.

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
- **Decoding never drops a record.** Status, type and dependency-type enums are
  open. A dropped issue silently changes every downstream metric.
- **An empty dependency type blocks**, matching bv's rule for rows written
  before the typed system. Only `""` and `blocks` block — not `parent-child`,
  not `waits-for`.
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
  either side of it. Same trap for any later overlay. See BUGS.md, 2026-08-23.
- **Hosted cell content is aligned leading by `HostedCell`, not by each
  column.** The hosting view is pinned to both edges, so content handed the full
  column width centres itself — which is what put every hosted column in the
  middle of its cell after the move to `NSTableView`. A new column cannot forget
  it, because it is applied once where the cell hosts the view.
- **"Uncommitted" is defined against git, not tracked by vbx.** A bead is dirty
  when its record differs from the same record at `HEAD`, read through the
  engine's `snapshot_at` — the object store directly, as ADR-006 requires. No
  side file to fall out of step with an external `br` run or a checkout. See
  ADR-015. Note `HEAD` moving is invisible to the bead-file watch, so `.git` is
  watched too.
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
  every real write against the fixture had always failed.
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
  parallel, and two writing to the shared fixture interfere.
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
- **Triage includes a bounded git-history walk**, because bv's does and it
  moves the scores. It is capped at 200 commits with a 10 s timeout, and
  reports `history_status` so an absent staleness signal is distinguishable
  from a low one.

## Verify before committing

```bash
./scripts/build-engine.sh --check   # Go archive + C ABI smoke test
./scripts/build-icon.sh --check     # committed .icns + README PNG are intact
python3 scripts/build-notices.py --check  # every dependency is acknowledged
python3 scripts/test-packaging.py   # signing, redaction, universal, version, cask
python3 scripts/release-notes.py --check  # docs/RELEASES.md matches the tags
swift test                          # Swift suite
cd Engine/bridge && go test ./...   # Go suite
gofmt -l Engine/bridge              # must print nothing
python3 scripts/parity-check.py     # vbx-cli vs bv, command by command
```

The parity check needs `bv` on the PATH. Without it every comparison is
reported as *skipped* rather than passing, so a missing `bv` cannot look like
agreement. It exits non-zero when any comparable command differs, or when a
command it declares is not implemented.

Biome is not configured here (no `package.json`, and Biome does not format
Markdown). Go is formatted with `gofmt`.
