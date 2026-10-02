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
| Go | 1.26.6 and 1.27.1 (`darwin/arm64`) — 1.27 needs `-ldflags=-macos=`, which `build-engine.sh` passes only to a linker that offers it |
| Minimum macOS | 14.0 |
| Upstream `bv` | `github.com/Dicklesworthstone/beads_viewer v0.25.2` — its `go 1.26.0` directive is why the engine needs Go 1.26+ |
| `bv` binary for parity | Must report the same version (`bv --version` → `bv v0.25.2`); `parity-check.py` fails on a mismatch unless `--allow-bv-mismatch`. Homebrew's lags (0.20.0 on 2026-10-01): `brew upgrade bv`, or the release binary for the go.mod tag first on PATH / `--bv <path>` |

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
python3 scripts/vendor-correlation.py          # regenerate Engine/bridge/correlation
python3 scripts/vendor-correlation.py --check  # prove it is bv's, as go.mod pins it
```

Distribution:

```bash
./scripts/package-app.sh --check              # what is configured, what is ready
./scripts/build-app.sh --release --dmg        # Developer ID, notarized, stapled
./scripts/build-app.sh --release --app-store  # sandboxed .pkg for App Store Connect
./scripts/build-app.sh --universal            # arm64 + x86_64; implied by the above
VBX_DEVELOPER_ID_APP=- ./scripts/build-app.sh --dmg --no-notarize   # ad-hoc, local only
```

Signing prerequisites:

```bash
./scripts/signing-setup.sh --check    # what is missing, and how to get it
./scripts/signing-setup.sh --dry-run  # the plan, no credentials needed
./scripts/signing-setup.sh            # create the Developer ID cert via asc
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
| `Engine/bridge/correlation` | bv's `pkg/correlation`, **generated** by `scripts/vendor-correlation.py` — never edit it. `vbx_*.go` and `internal/env` are vbx's own: the in-process `gitCommand`, the artifact split, the env shim (ADR-027) |
| `Engine/bridge/objgit` | Answers the git command lines the correlator runs from the object store, byte for byte as git prints them: log, show, rev-parse, cat-file, with git's rename detection and xdiff's line counts ported (ADR-027) |
| `Engine/bridge/cbridge` | C ABI (`vbx_open` / `vbx_call` / `vbx_close` / `vbx_free` / `vbx_probe`) |
| `Engine/smoke` | C ABI smoke test |
| `Engine/build` | Generated archive — **gitignored**, rebuild with the script |
| `Sources/VBXCore` | Value types, filtering, fuzzy search, graph layout |
| `Sources/VBXEngine` | async/await facade over the C ABI |
| `Sources/VBXAppCore` | `ProjectStore`, `FileWatchService` |
| `Sources/VBXUI` | SwiftUI views |
| `Sources/vbx`, `Sources/vbx-cli` | App shell and CLI |
| `Fixtures/demo` | 18-bead workspace used by tests and demos |
| `Fixtures/readiness` | 21 beads covering bv 0.25's readiness and blocking cases; tests and parity only |
| `Fixtures/sprints` | 15 beads and 3 sprints: each at-risk signal, a stale `closed_at`, a tombstone; tests and parity only |
| `Fixtures/search` | 9 beads: six whose text is all "tax 7" bury `tax-7` below a query for its own id, plus `Case-1`/`case-1`. Search tests and parity only — the harness runs nothing else over it |
| `Fixtures/dropped` | 4 valid beads, a line cut off mid-record and one whose `updated_at` precedes its `created_at`: what bv's `load_stats` counts. Deliberately unwritable by `br`. Tests and parity only, as JSONL and as a `beads.db` |
| `Fixtures/dropped-workspace` | Two repositories (`api`, `web`) under one `.bv/workspace.yaml`; `web` holds a line cut off mid-record. Parity's workspace claim gate (vbx-koc) and, with the demo's `.beads` added at the root, its discovery comparisons (vbx-1y5). Parity copies it out of this repository first: from inside, discovery reaches the repository's own `.beads` and never the workspace (ADR-026) |
| `Fixtures/feedback`, `Fixtures/feedback-few` | The same 8 beads with a triage `feedback.json` of 4 verdicts (applied: fb-5 outranks the hub fb-1) and of 2 (reported, not applied); fb-6 carries the not-ready label `needs-design`. Tests and parity only |
| parity's `history` fixture (no directory) | A git repository `parity-check.py` builds at run time (`build_history_workspace`): 8 beads over 13 commits with fixed authors and dates, so the SHAs never change, a tombstone and a late dependency cycle, plus a drift baseline bv saves from the day-4 beads. `--workspace history` runs it alone. Diff and drift parity (vbx-9gl), and the nine history commands' (vbx-k7j). Its JSONL is written by Python, `"id": "x"` with a space, which bv's `--bead-history` cannot find on macOS (ADR-027) |
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
- **`vbx-cli --export` runs the repository's `.bv/hooks.yaml`**, as
  `bv --export` does: each hook is `sh -c <command>` with your user's rights,
  read from the *working directory* (bv's choice, not `--path`). So exporting
  in a checkout you do not trust runs its commands — pass `--no-hooks` there.
  bv's executor strips credential-looking variables (`*TOKEN*`, `*SECRET*`,
  `SSH_AUTH_SOCK`, …) from a hook's environment unless the hook's own `env:`
  re-grants them. Only a session opened with `export_hooks` runs a hook, and
  the app never opens one: the sandbox forbids the subprocess (vbx-uos).
- **A bv upgrade regenerates the correlation copy.** Bump `go.mod`, run
  `python3 scripts/vendor-correlation.py`, then `go test ./...`: a git command
  line the new correlator runs that `objgit` does not know is refused, and the
  differential tests (`objgit_test.go`, `correlation/vbx_differential_test.go`)
  fail on it — when a test history reaches it. `TestThisRepositoryMatchesBV`
  runs the correlator over this repository's whole history for that reason
  (vbx-lh0). They compare against real git and real bv, so they need `git` on
  PATH; the package itself never runs it.
- **This repo's own `.beads` store is empty** (0 issues). Point vbx at
  `Fixtures/demo` for anything with a real dependency graph.
- **bv's `--feedback-*` flags are not pinned by `SOURCE_DATE_EPOCH`.** The
  verdict's score is computed at the wall clock and every stamp in
  `feedback.json` is `time.Now`, so vbx does the same (vbx-rt3), and a test
  that wants a fixed score sets `feedbackScoreClock`. `--feedback-show`'s
  `effective_weights` also differ in the last bit between two runs of bv
  itself — normalised by summing a Go map — so compare them parsed, with a
  tolerance, never as text.
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
- **`BeadDirtyState` says which beads are ahead of the last commit**, computed
  by comparing the working bead set with `snapshot_at "HEAD"`. `unknown` — no
  repository, or no commits — is deliberately not `clean`. `ProjectStore`
  refreshes it on open, on every reload (so every write), and when `.git`
  changes, because a commit moves `HEAD` without touching the export.
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
- **`br` 0.7.4's first write after a stock SQLite reader fails once.** After
  `bv` or `sqlite3` has opened `beads.db`, the next write retries for ~17 s and
  exits 2 with `database is busy (recovery in progress)` — the error JSON on
  stdout, 24 pager log lines on stderr — and the write after it succeeds. 0.6.0
  is unaffected, and vbx's own `mode=ro&immutable=1` reader does not trigger
  it. `BeadWriter` re-sends that one failure once (vbx-1sw), so an edit can
  take ~17 s rather than failing.
- **A failed `br … --json` puts its error on stdout, not stderr.** Both 0.6.0
  and 0.7.4 print `{"error":{"code","message","hint","retryable","context"}}`
  (`hint` may be `null`) with an empty stderr for an unknown id, an invalid
  priority or an empty title; 0.7.4 can add pager log lines on stderr.
  `BeadWriter.failureMessage` shows the JSON's message and hint first (vbx-jmu).
- **`br update --if-unchanged <updated_at>` (0.7.0+) compares at full
  precision.** Measured on 0.7.4: `.000Z` matches a stored `Z`, so it compares
  instants rather than text, but `.885Z` against a stored `.885481Z` is refused.
  A refusal exits 6 with `"code": "UPDATE_PRECONDITION_FAILED"` on stdout and
  writes nothing; an unparseable value exits 4 (`VALIDATION_FAILED`). 0.6.0
  rejects the flag outright. So the token is `Issue.updatedAtStamp`, never a
  `Date`, and `BeadWriter` sends it only after `br update --help` lists the flag
  (vbx-7fh, ADR-022).
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
  reads too. A recipe defined by its own `.beads/recipes/<name>.yaml` — bv's
  `project-file` source, which outranks `.bv/recipes.yaml` — is saved and
  deleted in that file instead (vbx-7d5).
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
- **A bead-only commit is not a release.** `version-bump.sh` skips any commit
  whose diff touches nothing outside `.beads/`, and exits without tagging when
  that is all that landed. Tracker bookkeeping arrives here as squash-merged
  PRs like everything else, so otherwise each one would cut a patch. Verified by
  `test_beads_only_does_not_release` in `test-packaging.py`. See ADR-013.
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
- **There is no Developer ID Application certificate on this machine**, and
  that is what blocks a signed release. `VBX_DEVELOPER_ID_APP` pointed at an
  *Apple Development* certificate, which cannot sign for distribution outside
  the App Store — Gatekeeper rejects it. `--check` reported it as present
  because it grepped for the string rather than the certificate's kind.
- **Notarization takes an App Store Connect API key**, `VBX_NOTARY_KEY` /
  `_KEY_ID` / `_ISSUER`, in preference to a `notarytool` keychain profile. One
  credential covers the certificate and the notarization, and it is the only
  form that works in CI — a keychain profile cannot travel. See ADR-017.
- **A Developer ID certificate cannot be created with a Team API key.**
  Apple: *"This operation can only be performed by the Account Holder."* Account
  Holder is not a role a Team key can be given, so this is not a configuration
  problem. Use `./scripts/signing-setup.sh --csr`, issue the certificate in the
  web portal as the Account Holder, then `--import` it. An *Individual* key made
  by the Account Holder inherits that role and may work through `asc`.
  Notarization has no such restriction.
- **Keep `~/.vbx-signing/developer-id.key`.** The certificate is useless without
  the private key that produced its request — a `.cer` imported alone is not a
  signing identity, and `security find-identity` will not list it.
- **The packaging pipeline itself is proven.** An ad-hoc `--dmg --no-notarize`
  build produces a 50 MB universal disk image with both slices, signed and
  verified, so the certificate is the only missing piece rather than one of
  several unknowns.
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
- **`.beads` discovery does not walk upwards; workspace discovery does.**
  bv's `GetBeadsDir` checks `<path>/.beads` and then the root of the checkout
  (the main repository's, for a linked one), and nothing else. A plain folder
  *below* a project root is therefore not openable. A `.bv/workspace.yaml` is
  found in any parent, but only when no `.beads` is reachable: bv's
  precedence, which the engine follows for the app too (ADR-026). This is why
  the Open panel's guard asks `vbx_probe` rather than testing for `.beads`
  itself. The set of openable paths is wider in one direction (a workspace
  root holds `.bv/workspace.yaml` and no `.beads`) and narrower in another.
- **Tests that write into a workspace must use `Fixture.writableStore()`**,
  which copies the fixture to a temporary directory. Swift Testing runs tests
  in parallel, and two of them writing to the shared fixture interfered — see
  BUGS.md.
- **A timing test asserts against what it measured, not what it asked for.**
  Under a loaded full suite a 20 ms `Task.sleep` can overshoot a 150 ms window.
  Pin timing logic on an injected scheduler (`Debouncer` and `DebouncerTests`'
  virtual clock), and bound a real-clock test by the gaps it recorded. CPU
  burners and SIGSTOP freezes did not reproduce the watcher flake. Forcing the
  overshoot in the test itself did — see BUGS.md, vbx-7a2.
