# Key Facts

Project configuration and references. Never secrets.

## What this is

`vbx` — a native macOS app for beads issue graphs, implementing
[`bv`](https://github.com/Dicklesworthstone/beads_viewer) with a SwiftUI front
end over bv's own Go analysis engine.

## Document inventory

| Document | Purpose |
|---|---|
| `README.md` | Build, run, test; what works today |
| `LICENSE` | MIT plus an AI-training rider; reserved-rights terms |
| `docs/README.md` | Docs index and reading order |
| `docs/VBX_DESIGN.md` | Architecture and design specification |
| `docs/FEATURE_PARITY.md` | Every bv capability mapped to a vbx surface |
| `docs/project_notes/BUGS.md` | Bug log with regression tests |
| `docs/project_notes/DECISIONS.md` | ADRs |
| `docs/project_notes/KEY_FACTS.md` | This file |
| `docs/project_notes/WORK_LOG.md` | Work log |
| `docs/html/` | Generated static HTML of `docs/*.md` |

## Toolchain

| Tool | Version verified |
|---|---|
| Swift | 6.3.3 (Xcode 26.6), package builds in language mode 5 |
| Go | 1.26.6 (`darwin/arm64`) |
| Minimum macOS | 14.0 |
| Upstream `bv` | `github.com/Dicklesworthstone/beads_viewer v0.20.0` |

Biome is referenced by the global conventions but is **not configured in this
repo** — there is no `package.json`, and Biome does not format Markdown. Go is
formatted with `gofmt`.

## Build and test commands

```bash
./scripts/build-engine.sh --check   # Go archive + C ABI smoke test
./scripts/build-icon.sh --check     # committed .icns + README PNG are intact
./scripts/build-icon.sh             # regenerate the icon (needs rsvg-convert)
./scripts/build-app.sh --run        # vbx.app, opened on the demo fixture
swift test                          # Swift suite
cd Engine/bridge && go test ./...   # Go suite
python3 scripts/test-packaging.py   # signing config, redaction, leak guard
python3 scripts/build-docs.py       # regenerate docs/html
```

Distribution:

```bash
./scripts/package-app.sh --check              # what is configured, what is ready
./scripts/build-app.sh --release --dmg        # Developer ID, notarized, stapled
./scripts/build-app.sh --release --app-store  # sandboxed .pkg for App Store Connect
./scripts/build-app.sh --universal            # arm64 + x86_64; implied by the above
VBX_DEVELOPER_ID_APP=- ./scripts/build-app.sh --dmg --no-notarize   # ad-hoc, local only
```

Release:

```bash
./scripts/version-bump.sh --dry-run # what the next version would be, and why
./scripts/version-bump.sh           # tag from the PR's semver:* label, record it
python3 scripts/release-notes.py    # regenerate docs/RELEASES.md from the tags
./scripts/version.sh                # the version, from the git tag
./scripts/release.sh --lint-cask    # brew style the rendered cask, build nothing
./scripts/release.sh --dry-run      # rehearse: preflight, build, render the cask
./scripts/release.sh --tag 0.2.0    # tag, build universal, notarize, print the cask
./scripts/release.sh --publish      # ...and push the tag + create the GitHub release
```

`VBX_SNAPSHOT_DIR=/tmp/vbx-snaps swift test --filter VBXUITests` keeps rendered
view snapshots for inspection.

## Layout

| Path | Contents |
|---|---|
| `Engine/bridge/engine` | Go session wrapper over bv's `pkg/*`, plus a SQLite reader |
| `Engine/bridge/cbridge` | C ABI (`vbx_open` / `vbx_call` / `vbx_close` / `vbx_free` / `vbx_probe`) |
| `Engine/smoke` | C ABI smoke test |
| `Engine/build` | Generated archive — **gitignored**, rebuild with the script |
| `Sources/VBXCore` | Value types, filtering, fuzzy search, graph layout |
| `Sources/VBXEngine` | async/await facade over the C ABI |
| `Sources/VBXAppCore` | `ProjectStore`, `FileWatchService` |
| `Sources/VBXUI` | SwiftUI views |
| `Sources/vbx`, `Sources/vbx-cli` | App shell and CLI |
| `Fixtures/demo` | 18-bead workspace used by tests and demos |
| `Resources` | App icon: generated `vbx-icon.svg` and the committed `vbx.icns` |
| `Resources/entitlements` | Developer ID entitlements, plus the App Store *template* |
| `docs/images` | `vbx-icon.png`, the same artwork at 512px for the README |
| `scripts/signing.env` | Signing configuration — **gitignored**, from `signing.env.example` |

## Gotchas

- **The engine archive is not committed.** ~29 MB and reproducible; a fresh
  clone must run `./scripts/build-engine.sh` before `swift build`. The generated
  *header* is committed, because the Swift C target needs it to compile.
- **The app icon is generated, and the `.icns` is committed.** Edit the
  control points in `scripts/make-icon.py`, never `Resources/vbx-icon.svg`.
  Unlike the engine archive the `.icns` *is* committed, because rasterising it
  needs `rsvg-convert` (`brew install librsvg`) and `build-app.sh` must be able
  to bundle an icon without it. The same run also emits
  `docs/images/vbx-icon.png` for the README, so the two cannot drift — a test
  asserts they are pixel-identical. `scripts/make-icon.py <dir> --variants`
  re-renders the palettes that were considered. See ADR-008.
- **This repo's own `.beads` store is empty** (0 issues). Point vbx at
  `Fixtures/demo` for anything with a real dependency graph.
- **Swift Testing exports its own `Issue` type**, which collides with the model.
  Test files alias it: `private typealias Bead = VBXCore.Issue`.
- **The remote is `origin` (github.com/michel-onstein/vbx)**; work lands on a
  branch and is integrated by PR, never pushed to `main` directly.
- **GUI rendering of the live window is unverified** — `screencapture`, the
  accessibility API and `CGWindowList` are permission-gated for background
  sessions. Offscreen view snapshots are the substitute.
- **App Intents are not discoverable from a `swift build`.** Shortcuts finds
  intents through a metadata bundle produced by Xcode's
  `appintentsmetadataprocessor`. SwiftPM does not run it, so the intents in
  `Sources/vbx/Intents.swift` compile and execute correctly but are only *listed*
  in Shortcuts when the app is built through Xcode, or when that step is added
  to `scripts/build-app.sh`.
- **The bead list is `NSTableView`** (`Sources/VBXUI/BeadTable.swift`), because
  per-cell editing needs to know which cell was hit and SwiftUI's `Table` cannot
  say. Cell *appearance* is still SwiftUI, hosted in the cell. See ADR-014.
- **Columns are declared once, in `IssueListView.specs`.** A sortable column's
  identifier must equal its `SortColumn` raw value — the sort descriptor's key
  is the raw value while the chevron is drawn on the matching identifier.
- **The stored layout key is `issueListLayout`**, holding a `BeadTableLayout` as
  JSON. The old `issueListColumnCustomization` held a SwiftUI type and is dead;
  a layout saved before the move is ignored and the columns reset once.
- **Hidden columns stay in the table with `isHidden`**, never removed —
  `HiddenColumnMarkers` finds where a column *was* by walking the table's
  columns, and a column that is gone has no position.
- **Synthetic clicks do not reach table content headlessly.** Measured: a
  synthetic click presses a plain SwiftUI `Button`, but inside a table it
  neither focuses an editable `NSTextField` nor fires a double-click action. Any
  headless test concluding "the click did nothing" is testing the harness.
- **The demo fixture's dependency rows need `created_at`.** `br`'s preflight
  requires it and refuses the entire workspace without it — `br update` on the
  fixture reported "Found 13 invalid issue record(s)", which was exactly the 13
  records carrying dependencies. Real `br` exports include it (along with
  `created_by`, `metadata`, `thread_id`); the hand-written fixture did not.
- **`Bundle.main` in the test process is SwiftPM's helper binary** —
  `…/XcodeDefault.xctoolchain/usr/libexec/swift/pm`, measured, not assumed. It
  has no `CFBundleShortVersionString` and no `CFBundleVersion`, so the About
  window's version line renders empty in every snapshot. `AboutView` takes the
  info dictionary as a parameter for exactly this reason; the stamped values are
  asserted against a real bundle in `test-packaging.py` instead.
- **`CSSearchableIndex.default()` and `UNUserNotificationCenter.current()` both
  raise in a process with no bundle identifier** — which is how the test suite
  and the CLI run. Availability is checked before the call, never around it,
  and both subsystems degrade to doing nothing.
- **The engine writes into `<project>/.bv/`**: the semantic search index, a
  saved baseline, drift configuration and project recipes. The first two are
  gitignored (a rebuildable cache and a local reference point); `recipes.yaml`
  is deliberately not, because it is shared configuration that `bv --recipe`
  reads too.
- **No signing identifier is in this repository, and none may be.** It is
  public. Configuration lives in the gitignored `scripts/signing.env` or the
  environment; the App Store entitlements are a template expanded into
  `.build/dist/`; and everything `package-app.sh` prints is masked, because
  `codesign -dvvv` and `security find-identity` echo the Team ID and build logs
  get pasted into issues. `scripts/test-packaging.py` asserts all three, and
  scans tracked files for the values configured locally. See ADR-009.
- **Every distribution build is universal**, implied by `--dmg`, `--app-store`
  and `--sign` exactly as they already imply `--release`. `--universal` on its
  own is for a deliberate local check; it roughly doubles the build, so
  development stays host-only. The slices are asserted with `lipo -archs` on
  both binaries in the bundle rather than inferred from the flag. One
  consequence worth knowing: `lipo` strips the linker's ad-hoc signature when it
  fuses slices, which is why `build-app.sh` signs the nested `vbx-cli` before
  the bundle. See ADR-012.
- **The version is the git tag, never a literal.** `scripts/version.sh` maps
  the tag straight into `CFBundleShortVersionString` and the commit count to
  `CFBundleVersion`. An untagged checkout reports `0.0.0`, which sorts below
  every real tag; `--check` refuses a dirty tree or a HEAD past its tag.
- **The tag carries no `v`** — it is `0.2.0`, not `v0.2.0`. A prefix only has to
  be stripped again at the plist, the `.dmg` name and the cask, so
  `release.sh --tag v0.2.0` is refused rather than silently stripped. See
  ADR-013.
- **The bump level is a `semver:*` PR label, not the commit subject.** Prose
  subjects are the house style, so a Conventional Commits parser reads every
  commit here as no bump. `version-bump.sh` reads the label once and writes it
  into the annotated tag, so `release-notes.py` and its `--check` read git alone
  and work offline. A missing label is patch, announced. Before 1.0.0 a breaking
  change bumps MINOR. See ADR-013.
- **The `semver:major` / `semver:minor` / `semver:patch` labels do not exist
  yet** on the GitHub repository. Until someone creates them every release is a
  patch, and the script says so on every run.
- **`.github/workflows/release.yml` is the repository's only workflow.** It tags
  and records; it builds, signs and publishes nothing, because no runner holds
  the signing identity. It is idempotent because pushing its own release-notes
  commit re-triggers it.
- **A signing config written before the bvx → vbx rename is dead, silently.**
  Every `BVX_*` key is unrecognised, so `package-app.sh --check` reported "no
  distribution channel is configured" — which reads as "not set up yet" while a
  complete config sat in the file. The real `scripts/signing.env` had been dead
  that way since #13. `--check` now names the stale prefix and prints the
  one-line `sed` that fixes it.
- **`brew style` is the local gate for the cask; `brew audit` is not.** Audit
  takes a cask *name*, which only resolves for an installed tap, and installing
  one is more than a linter should do — it belongs to the tap repository's CI.
  `./scripts/release.sh --lint-cask` renders the template with a placeholder
  checksum and styles it; it caught four real offences the first time it ran.
- **Nothing has been released.** `scripts/release.sh` and
  `packaging/homebrew/vbx.rb.template` produce a cask ready to paste, but there
  is no tagged release, no published `.dmg` and no `homebrew-tap` repository, so
  `brew install --cask vbx` does not work yet. The cask goes to a personal tap,
  not `homebrew/homebrew-cask`, which requires a track record a new app does not
  have. See ADR-012.
- **The two channels ship different apps.** `--dmg` is unsandboxed and keeps
  `vbx-cli`; `--app-store` is sandboxed and removes it, because a sandboxed app
  cannot symlink it into `/usr/local/bin`. See ADR-010.
- **`VBX_DEVELOPER_ID_APP=-` signs ad-hoc**, which makes the whole packaging
  path runnable with no certificates. It produces nothing distributable and
  says so; notarizing it is refused rather than attempted.
- **Discovery does not walk upwards.** bv's `GetBeadsDir` checks `<path>/.beads`
  and, for a linked checkout, the main repository's — nothing else. A folder
  *below* a project root is therefore not openable, which is why the Open
  panel's guard asks `vbx_probe` rather than testing for `.beads` itself: the
  set of openable paths is wider in one direction (a workspace root holds
  `.bv/workspace.yaml` and no `.beads`) and narrower in another.
- **Tests that write into a workspace must use `Fixture.writableStore()`**,
  which copies the fixture to a temporary directory. Swift Testing runs tests
  in parallel, and two of them writing to the shared fixture interfered — see
  BUGS.md.
