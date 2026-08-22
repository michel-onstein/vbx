# Architectural Decision Records

---

## ADR-001 — Reuse bv's Go engine rather than reimplement it in Swift

**Date:** 2026-08-19 · **Status:** Accepted, implemented

**Context.** bv is ~85k lines of Go: roughly 34k of Bubble Tea terminal UI and
~50k of platform-neutral engine — tolerant loading, a two-phase analyser
computing nine graph metrics with per-metric deadlines, git correlation, search
and export. vbx needs the same numbers with a native UI.

**Decision.** Compile bv's non-UI packages with `go build -buildmode=c-archive`,
expose them through a small C ABI, and replace only the UI with Swift.

**Alternatives.**

- *Full Swift rewrite.* Rejected: ~50k lines whose behaviour is subtle
  (approximation thresholds, timeout semantics, confidence blending). Its bugs
  would surface as plausible-but-wrong numbers, the worst failure mode for a
  decision-support tool, and upstream tracking becomes manual forever.
- *Sidecar `bv` binary over robot JSON.* Kept only as the Phase-0 scaffold. No
  shared warm state, a process spawn per query, and an embedded binary to
  notarize.

**Consequences.**

- Metrics match upstream by construction; tracking a bv release is a version
  bump. Verified end-to-end: `vbx-cli` reports PageRank 0.2013 for the bead that
  blocks seven others, computed by bv's own code.
- cgo is required, and the archive is ~29 MB (24 MB before `pkg/export`).
- `internal/datasource` is not importable across modules, so vbx carries its own
  SQLite reader — the one piece deliberately duplicated.

**Rule this imposes:** *no metric is ever computed in Swift.* Layout and
formatting only. Graph layout is Swift because it is presentation, not analysis.

---

## ADR-002 — An unavailable metric is absent, never zero

**Date:** 2026-08-19 · **Status:** Accepted, implemented

**Context.** bv's Phase-2 metrics can be `computed`, `approx`, `timeout` or
`skipped`. A timed-out betweenness rendered as `0.000` reads as "this is not a
bottleneck" — a confident falsehood.

**Decision.** Phase-2 dictionaries are omitted from the wire format rather than
zero-filled. The UI renders the metric's status instead of a value, and
disables sorting by a metric that has not been computed.

**Consequences.** `phase2Ready` and `hasPhase2Values` are distinct and both
needed — everything-skipped is "ready" with nothing in it. Conflating them
produced the dead "compute metrics" button (see BUGS.md).

---

## ADR-003 — Decoding must never drop a record

**Date:** 2026-08-19 · **Status:** Accepted, implemented

**Context.** beads is an evolving ecosystem; bv accepts Gastown statuses
(`role`, `agent`, `molecule`) it does not enumerate, three spellings of a
dependency target, and comment ids as UUID or integer.

**Decision.** `IssueStatus`, `IssueType` and `DependencyType` are open enums
with a catch-all case. Unknown values render; they never throw.

**Consequences.** A dropped issue silently changes every downstream metric, so
this is a correctness rule rather than a robustness nicety. Each tolerance has
a test pinning it.

---

## ADR-004 — Views live in a library, not the executable

**Date:** 2026-08-19 · **Status:** Accepted, implemented

**Context.** A Swift test target cannot import an executable target, so neither
`ProjectStore` nor any view was testable while they lived in `Sources/vbx`.

**Decision.** `VBXAppCore` holds application state, `VBXUI` holds views. The
executable is a thin `@main` shell.

**Consequences.** The state layer and every view are verifiable headlessly.
This mattered more than expected: GUI verification via screenshot, the
accessibility API and `CGWindowList` are all permission-gated, and offscreen
rendering was the only route available.

---

## ADR-005 — Snapshot rendering uses NSHostingView, not ImageRenderer

**Date:** 2026-08-19 · **Status:** Accepted, implemented

**Context.** `ImageRenderer` is the obvious choice and needs no permissions, but
it does not lay out `ScrollView` content — four views rendered entirely blank
through it.

**Decision.** Render through `NSHostingView` in an offscreen window, and assert
on ink coverage and colour variety rather than file size.

**Consequences.** `.task` and `.onAppear` still do not run, so views should
prefer data the store already holds — which is what motivated the unblocks
cache. Snapshots are closer to what the app actually draws.

---

## ADR-006 — Correlation reads the git object store directly, not `git`

**Date:** 2026-08-20 · **Status:** Accepted, implemented

**Context.** bv's `pkg/correlation` reaches git through exactly one choke
point — a hardcoded `exec.Command("git")` in `gitcmd.go`. It exposes no
interface, no func-typed field and no settable runner to supply that data
another way; the only levers from outside are `WithContext`, the repo path, and
`PATH`. The App Sandbox forbids spawning that binary, so `Correlator` and
everything built on it is unreachable from the app.

What *is* reachable is everything downstream of the report. `FileLookup`,
`BuildFileIndex`, `NetworkBuilder`, `HistoryReport.BuildCausalityChain` and
`HistoryReport.FindRelatedWork` are pure functions over a `*HistoryReport`
whose fields are all exported, and none of them touches git.

**Decision.** Build the `*HistoryReport` ourselves by walking the object store
with `go-git`, then hand it to bv's own analyses. Scoring stays bv's:
confidences come from `correlation.CalculateConfidence` and
`correlation.MethodRanges`, milestones from `correlation.GetBeadMilestones`,
cycle times from `correlation.CalculateCycleTime`, and the beads file at each
commit is parsed with `loader.ParseIssues`. This is not a second opinion about
the numbers — it is the same code, fed different input.

**Consequences.**

- One code path serves the app and the CLI, so there is no pair of correlation
  engines to keep in agreement.
- `go-git` joins the dependency set. It is pure Go, so the archive still links
  as a `c-archive` with no new system requirements; it costs about 6 MB.
- **Temporal-author correlation is not implemented.** It needs a repo-wide
  author/time query that only pays for itself as a `git log` subprocess, and bv
  rates it lowest of the three methods (0.20–0.85). Explicit-ID and co-commit
  attribution, which bv rates 0.70–0.99 and 0.85–0.99, are both present.
- **Explicit matching is membership-driven, not pattern-driven.** bv's built-in
  patterns require a numeric suffix (`[A-Za-z]+-\d+`) and would miss every id
  `br` mints — `vbx-8ou`, `whois-q1rfj`. Ids are matched against the loaded
  workspace first, so no id format is assumed and an id the workspace does not
  hold is never linked. bv's patterns still run, for the classic
  `PROJECT-123` style.
- **Orphan detection is ours.** bv's `OrphanDetector` re-queries git whatever
  report it is handed, so it cannot run sandboxed. The replacement scores the
  same four signals — files, timing, message, author — with weights summing to
  100 so each contribution stays legible beside the total.
- The walk computes a patch per commit for line counts, so it is capped at
  bv's own `DefaultHistoryLimit` of 500 and cached until the bead set changes.
  An unchanged reload deliberately keeps the cache; only a changed one drops it.

---

## ADR-007 — TOON is encoded in Go, not delegated to `tru`

**Date:** 2026-08-20 · **Status:** Accepted, implemented

**Context.** bv contains no TOON encoder. It imports a Go wrapper that shells
out to the Rust `tru` binary, and when that binary is absent it prints a
warning to stderr and emits JSON instead. bv's own TOON tests skip when `tru`
is missing, and beads_viewer ships no TOON goldens — the only normative data is
toon_rust's fixture corpus.

That is a poor contract to inherit. `--format toon` would produce a different
format depending on what happened to be installed, the App Sandbox forbids
spawning the binary anyway, and a format that silently degrades is worse than
one that is unavailable.

**Decision.** A pure-Go implementation of TOON spec v3.0 in the engine. No
subprocess, no external dependency, identical output on every machine.

**Consequences.**

- `vbx-cli --format toon` always emits TOON, and works under the sandbox.
- Key order had to be preserved through the JSON parse. Go randomises map
  iteration, and TOON's whole point is a stable compact rendering, so the
  decoder builds an ordered value rather than a `map[string]any`.
- The spec's twelve encode fixtures are the test suite, copied verbatim. The
  quoting rules are where a naive implementation goes wrong in both
  directions: `05` and `-dash` must be quoted, `café` and `你好` must not.
- **Version drift is a live risk.** toon_rust implements v3.0, where an empty
  array is `key[0]:`. The published spec is now v4.1, which mandates `key: []`
  and only accepts the older form as legacy. v3.0 is implemented here because
  that is what today's `tru` — and therefore bv — produces.

## ADR-008 — The app icon is generated from a script, and the .icns is committed

**Date:** 2026-08-20 · **Status:** Accepted, implemented

**Context.** vbx shipped with no `CFBundleIconFile` and no `.icns`, so the app
took the generic macOS placeholder in the Dock. Nothing upstream was worth
inheriting: `bv` has no mark at all (its only image is GitHub's auto-generated
social card), `br` has an AI-drawn robot illustration that cannot survive
scaling to 32px, and beads itself has only the teal "bd" tile Docusaurus
scaffolds as a default favicon. The one reusable idea in the family is the
beaded chain from `br`'s illustration.

**Decision.** The artwork is a committed SVG generated by
`scripts/make-icon.py`, and `Resources/vbx.icns` is committed alongside it.

**Consequences.**

- **Geometry is code, so it is reviewable.** Bead centres are sampled at equal
  arc length along one quadratic Bézier rather than hand-placed, so spacing
  stays even as the curve flattens; nudging the composition is a diff in three
  control points, not an opaque binary. `--variants` re-renders the palettes
  that were considered, so the choice can be revisited without redrawing.
- **The .icns is committed even though the engine archive is not.** The
  archive is rebuilt because it is 51 MB and reproducible from a pinned Go
  module; the icon is 436 KB and needs `rsvg-convert`, which is not part of the
  toolchain. Committing it is the same call as committing the generated C
  header — `build-app.sh` must be able to bundle an icon on a bare clone.
- **The README image comes off the same pass.** Markdown cannot display an
  `.icns`, and a hand-exported PNG is exactly the kind of asset that gets left
  behind when the artwork changes. `build-icon.sh` emits
  `docs/images/vbx-icon.png` from the same SVG, and a test asserts it is
  pixel-identical to the icon's 512px representation.
- **`--check` verifies shape, not bytes.** Two librsvg versions produce
  different antialiasing, so a byte comparison would report an intact icon as
  stale. The check expands the committed `.icns` and measures each
  representation instead.
- **Legibility is asserted, not assumed.** `Tests/VBXUITests/AppIconTests.swift`
  measures edge density inside the icon body per representation. Colour
  diversity would not work — the background is a gradient, so an empty tile
  shows hundreds of shades — and the transparent squircle margin has to be
  excluded or it registers as one enormous edge and hides the artwork's
  absence.

---

## ADR-009 — Signing identifiers never enter the repository, and output is masked

**Date:** 2026-08-20 · **Status:** Accepted, implemented

**Context.** Producing a distributable build needs an Apple developer account,
and everything that identifies one is account-specific: the 10-character Team
ID, the certificate common names that embed it, the notary credential, the
provisioning profile. This repository is public.

Two properties make that harder than "add it to `.gitignore`".

The first is that a leak is not undoable. A Team ID committed and then deleted
in a later commit is still in the history, and in every fork and clone taken
meanwhile. So the design has to make the leak *not happen*, not make it fixable.

The second is that these values are printed by the tools themselves, not only
written into files. `codesign -dvvv` prints `TeamIdentifier=`, `security
find-identity` prints full certificate names, and `notarytool` echoes both. A
build log is a public artifact more often than not — it gets pasted into
issues and uploaded by CI.

App Store entitlements make it worse: `com.apple.application-identifier` must
contain the Team ID *verbatim*, so the file that gets signed cannot be a file
that is committed.

**Decision.** Three mechanisms, none of which relies on remembering:

1. **Configuration lives outside the tree.** `scripts/signing.env` is
   gitignored; `scripts/signing.env.example` is the committed template, with
   placeholders. The environment overrides the file, so CI supplies everything
   from a secret store and writes nothing into the checkout.
2. **The App Store entitlements are a template.** `package-app.sh` expands
   `__TEAM_ID__` and `__BUNDLE_ID__` into `.build/dist/`, which is ignored, and
   at mode 600. The real file exists only on the machine that built it.
3. **Everything printed passes through `redact`.** Configured values are masked
   by name, and anything shaped like a certificate name — `Developer ID
   Application: Name (TEAMID)` — is masked by pattern, which covers identities
   the build never configured but `security find-identity` lists anyway.

**Consequences.** A fresh clone cannot produce a distributable build without
configuration, which is correct: it should not be able to.

Two things were only found because `scripts/test-packaging.py` drives the real
script with fabricated credentials and asserts they do not come back out.

- **Masking order is load-bearing.** A certificate name *contains* the Team ID,
  so masking the Team ID first left a string that no longer matched the full
  name — and the developer's name survived into the log. Longest first.
- **Short values must not be masked at all.** The ad-hoc identity is a single
  `-`, and masking it replaced every hyphen in the output: flags, paths and
  prose all became `<DEVELOPER_ID_APP>`. Only values of six characters or more
  are masked.

The test suite also scans every *tracked* file for the values configured on the
machine running it. That is the check that would actually catch a leak, since a
placeholder looks nothing like the real thing — and it reports when no
configuration is present rather than passing silently.

**Alternatives rejected.** Committing entitlements with the Team ID and relying
on the repository staying private: it is not private, and "we will remember to
scrub it" is not a mechanism. Keeping a `signing.env` in the tree and hoping
`.gitignore` covers it: the check is now asserted by a test rather than assumed.

---

## ADR-010 — The two distribution channels ship different apps

**Date:** 2026-08-20 · **Status:** Accepted, implemented

**Context.** [§8.3](../VBX_DESIGN.md#83-sandboxing) plans for a sandboxed app;
[§17](../VBX_DESIGN.md#17-build-packaging-and-distribution) plans for Developer
ID as the primary channel with the App Store optional. Those two pull in
opposite directions, and the packaging script has to pick.

The bundle carries `vbx-cli` so that "Install Command Line Tool" can symlink it
into `/usr/local/bin` later — which a sandboxed app cannot do. Shipping the
binary anyway would put an executable in the bundle that cannot be reached by
the mechanism it exists for, and App Review would reasonably ask why it is
there.

**Decision.** `--dmg` builds an unsandboxed Developer ID app with the hardened
runtime, keeping the CLI, shell hooks and unrestricted repository access.
`--app-store` builds a sandboxed app with `user-selected.read-only`, app-scope
bookmarks and network-client, and **removes `vbx-cli` from the bundle**.

Both are built from one staged copy of the same `vbx.app`, so the difference is
signing and contents rather than a separate build.

**Consequences.** The App Store build is a genuinely smaller product, and that
is a decision to state rather than a detail to discover after submission. It
also means a feature gated on the CLI has to degrade rather than assume, which
matches §17's "gate the affected features behind a capability check rather than
forking the codebase".

Packaging never mutates its input bundle — it copies to `.build/dist/stage`
first. Otherwise an `--app-store` run would silently delete `vbx-cli` from the
developer's own build, and the next `build-app.sh --run` would launch a bundle
that had quietly lost a binary.

---

## ADR-011 — One edition, with every feature; no paid tier

**Date:** 2026-08-22 · **Status:** Accepted

**Context.** A closed-source paid edition — Visual Beads Pro, differentiated by
editing — was investigated on 2026-08-21 and written up in a plan outside this
repository. Around the same time, priority editing landed in the open app
(`vbx-z8a`), which would have been that edition's differentiator. The two could
not both stand: either editing came out of the open app, or Pro needed a
different pitch.

**Decision.** There is one vbx. Every feature ships in it, under the licence
this repository already carries. No paid tier, no closed fork, no feature gates
held back for one.

**Consequences.**

- **Nothing to un-build.** Editing shipped ungated, so the code already matches
  this. Had it been gated behind a flag "just in case", that flag would now be
  dead weight nobody dared delete.
- **No open-core seam is needed.** The plan called for extracting an
  action-provider protocol so a closed module could inject edit affordances
  into open views. That work is not needed, and the seam should not be built
  speculatively — an abstraction with one implementation is a cost with no
  payer.
- **`br` stays a hard runtime dependency for editing.** With no paid edition to
  carry the burden of an in-process writer, delegating writes to `br` is simply
  the design, not a stepping stone.
- **The identifier collisions never happen.** Bundle id, the `vbx://` scheme,
  the `vbx-cli` symlink, the Spotlight domain and the preferences suite were all
  going to need splitting so two editions could coexist. One edition, one of
  each.

**What survives from the Pro investigation.** The licence diligence, which was
never about Pro:

- All 66 Go modules were classified — 33 MIT, 22 BSD-3, 7 Apache-2.0, plus
  freetype (FreeType *or* GPLv2, choose FTL), `filepath-securejoin` (BSD-3 +
  MPL-2.0) and `ajstarks/svgo` (CC-BY-4.0). Nothing is GPL-only. A third-party
  notices screen is still owed, and is still best generated from `go.mod` rather
  than maintained by hand.
- **bv's licence rider still applies**, and this decision neither triggers nor
  resolves it. It forbids making the software or any derivative available to
  OpenAI or Anthropic, and a public repository already does that — so the
  position is exactly what it was before Pro was considered, which is to say
  unchanged and still worth a written clarification from bv's author.

Not selling the software removes the sharpest version of that exposure — a
purchase we could not refuse — but not the question itself.

---

## ADR-012 — Distribution ships universal, and the cask lives in a personal tap

**Date:** 2026-08-22 · **Status:** Accepted

**Context.** vbx built for the host architecture only, so a `.dmg` cut on an
Apple-silicon machine produced an app that will not launch on an Intel Mac at
all — `lipo -archs` on the bundle reported `arm64` and nothing else. Rosetta
does not cover this: it translates x86_64 to arm64, not the reverse. Half of the
work already existed, in that `build-engine.sh --universal` had been written and
never wired up; the Swift build and the packaging path simply never asked for
it.

At the same time `brew install --cask vbx` was wanted, and a cask cannot be
written against a version that is a literal in a build script.

**Decision.**

- **Every distribution build is universal**, implied by `--dmg`, `--app-store`
  and `--sign` in the same way and for the same reason those already imply
  `--release`. `--universal` exists as a flag for a deliberate local check;
  development builds stay host-only because it roughly doubles the build.
- **The version comes from the git tag, and the tag is the version.**
  `scripts/version.sh` reads `0.2.0` — no `v` — straight into
  `CFBundleShortVersionString`, with the commit count as `CFBundleVersion`. The
  `v` is a widespread git convention, but it is a prefix that then has to be
  removed at every point of use: the plist, the `.dmg` filename and the cask's
  `version`, each a place the strip can be forgotten. Dropping it removes the
  class of mistake, so `release.sh` refuses `--tag v0.2.0` rather than quietly
  accepting and stripping it.
- **The cask goes to a personal tap**, `michel-onstein/homebrew-tap`, not to
  `homebrew/homebrew-cask`.

**Why a personal tap.** `homebrew-cask`'s acceptance criteria require a track
record — a notable user base, stable versioning, a maintained upstream. A newly
published app is normally rejected, so submitting now spends a review cycle on a
predictable no. A tap costs one repository and gives the same two commands:

```
brew tap michel-onstein/tap
brew install --cask vbx
```

**Consequences.**

- **Build time roughly doubles for a release**, and the engine archive is 51 MB
  per slice. Paid once per release, which is the right place to pay it.
- **The flag is not the artefact.** `lipo -archs` is asserted on both binaries
  in the bundle — `vbx` and `vbx-cli`, since the CLI is installed onto the
  user's PATH — rather than trusting that `--universal` took effect. This is the
  same distinction `assert_archive_target` already draws for the deployment
  target, and it caught a real failure: `lipo` strips the linker's ad-hoc
  signature when it fuses slices, so the bundle's own signing had to move to
  signing nested code first.
- **Notarization stops being optional on the release path.** A cask installing
  an un-notarized app gives every user a Gatekeeper block, so `release.sh`
  refuses `--no-notarize` and fails if the ticket did not staple.
- **`zap` cannot reach the Keychain.** A cask can trash preferences, saved
  state and caches, but the deploy credentials in `com.qjam.vbx` need
  `security delete-generic-password`. The cask's `caveats` say so rather than
  leaving an uninstall quietly incomplete.
- **The last check cannot be run here.** `brew install --cask` on a machine
  that has never seen the build, confirming it launches without a Gatekeeper
  prompt, needs a published release and a clean Mac.
- **`brew style` is what can be run, and it earns its place.**
  `./scripts/release.sh --lint-cask` renders the template with a placeholder
  checksum and styles it; on its first run it rejected four things: a missing
  frozen-string comment, the word "macOS" in a cask description (every cask is
  macOS), mis-grouped stanzas, and an unsorted `zap` array. None needed a build
  to find. `brew audit` is *not* run: it takes a cask name, which only resolves
  for an installed tap, and installing one inside a linter writes into the
  user's Homebrew prefix. It belongs to the tap repository's own CI.

---

## ADR-013 — The version bump comes from a PR label, and the notes from the tags

**Date:** 2026-08-22 · **Status:** Accepted

**Context.** Every build vbx had ever produced claimed to be version 0.1.0,
build 1: both were literals in `build-app.sh`'s plist heredoc, nothing bumped
them, and there were no git tags at all. So there was no way to answer "which
build is this?" — not from the About window, not from a `.dmg` filename, not
from git. [ADR-012](#adr-012--distribution-ships-universal-and-the-cask-lives-in-a-personal-tap)
made that urgent rather than untidy: a Homebrew cask cannot be written against a
version a script carries as a literal.

The obvious implementation reads Conventional Commits off the merge commit.
**That does not work here.** This repository's subjects are deliberately prose —
"Hand the priority cell its store, so scrolling the list cannot crash (#29)" —
and a `feat:`/`fix:` parser classifies every one of the 38 commits as no bump.
Adopting the prefixes would overwrite a house style the log has held from the
beginning, for the convenience of a script.

**Decision.**

- **The bump level is a `semver:major` / `semver:minor` / `semver:patch` label
  on the pull request.** Every change lands here squash-merged — every subject
  ends in `(#N)` — so the PR is a reliable handle, and the label is set during
  review, by someone who knows what the change is.
- **A missing label defaults to patch, and the script says which rule fired.**
- **Before 1.0.0 a breaking change bumps MINOR.** Promoting to 1.0.0 is a
  decision about the software being finished, not one a label should make.
- **The label is read once and written into the annotated tag.** Everything
  downstream reads git alone.
- **`docs/RELEASES.md` is generated** from those tags, newest first, grouped
  into Features and Fixes.

**Why the tag carries the label.** It is what makes `--check` offline. A check
that reached GitHub would fail on a plane and pass in CI, which is worse than
not having one — and every other script here (`build-engine.sh`,
`build-icon.sh`, `build-notices.py`) has a `--check` that belongs in the verify
block. Recording the decision at the moment it is made also means a later
relabelling cannot silently rewrite history.

**Considered and rejected.**

- **A commit trailer (`Semver: minor`).** Survives outside GitHub, but has to be
  remembered at commit time and cannot be corrected during review, which is
  exactly when the level is actually known.
- **Adopting Conventional Commits.** Cheapest to automate, and it costs the
  thing the log is for. CLAUDE.md's own guidance is that a subject should say
  what changed and why.

**Consequences.**

- **`RELEASES.md` must not become a fourth copy.** `BUGS.md` keeps a bug and its
  regression test; `WORK_LOG.md` keeps dated engineering work. `RELEASES.md` is
  the user-facing view and says nothing about implementation.
- **The bump has to be idempotent**, because pushing the release-notes commit
  re-triggers the workflow that made it. A commit that is already tagged is a
  no-op, which is the whole of the loop guard.
- **The labels do not exist yet.** `semver:major`, `semver:minor` and
  `semver:patch` need creating on the repository; until they do, every release
  is a patch and the script says so on every run.
- **This is the repository's first GitHub Actions workflow.** It only tags and
  records; nothing is built, signed or published on a runner, because no runner
  here holds the signing identity.

---

## ADR-014 — The bead list is an NSTableView, not SwiftUI's Table

**Date:** 2026-08-22 · **Status:** Accepted

**Context.** Priority editing shipped as a double-click on the priority cell and
did nothing in the running app. `br` was present and `canEditBeads` was true, so
the write path was open; the gesture was what failed.

Investigating produced a narrower answer than the first write-up claimed (see
the correction in [BUGS.md](BUGS.md)). SwiftUI's `Table` is **not** unable to
edit: a `TextField` in a cell is a real editable `NSTextField`, one per row. What
it cannot express is **which cell was double-clicked**. Its only double-click
hook is `contextMenu(forSelectionType:menu:primaryAction:)`, and `primaryAction`
reports the selected rows, not the column. A gesture layered over cell content is
the alternative, and that is what had just been shown not to work.

The immediate need was one column. The stated direction is more: editing is
going to spread across columns that each want their own editor.

**Decision.** The list is an `NSTableView` behind an `NSViewRepresentable`
(``BeadTable``). `clickedRow` and `clickedColumn` answer which cell was hit, so
each column can declare its own editor — a field editor for text, a menu for a
closed set of values.

**Cell appearance stays SwiftUI.** Content is hosted in the cell, so
`StatusChip`, `LabelPill`, `MetricCell`, the diff and repo badges and the rest
are unchanged and there is one description of how a bead looks. Only columns
that accept an edit are drawn natively, because an `NSTextField` is what a field
editor edits.

**What this bought beyond editing.** The header's show/hide menu,
drag-reordering, live column resize and the field editor are AppKit behaviour
that now works rather than being approximated. A column is also declared once —
`IssueListView.specs` — where before it was declared three times (the
`TableColumn`, its `customizationID`, and a title→id map the hidden-column
markers read) with a test whose only job was catching those drift apart.

**Consequences.**

- **Stored layouts reset, once.** `issueListColumnCustomization` held a
  `TableColumnCustomization`, a SwiftUI type that cannot describe this table.
  The new key is `issueListLayout`. Per the repo's not-in-production rule this
  is a clean break rather than a migration; it costs a user a few seconds.
- **Hidden columns stay in the table**, marked `isHidden`, never removed.
  `HiddenColumnMarkers` finds where a column *was* by walking the table's
  columns, and a column that is gone has no position.
- **A sortable column's identifier must equal its `SortColumn` raw value.** The
  sort descriptor's key is the raw value; the chevron is drawn on the column
  whose identifier matches the store's current column. If those disagreed, a
  header click would reorder the list and put the chevron somewhere else.
  Asserted, because it is invisible until it is wrong.
- **The tests that read source text are gone.** Column order and identifiers
  used to be checked by parsing `IssueListView.swift` for `TableColumn("…")`,
  because the built table exposed no list. They silently matched nothing the
  moment the table changed shape. `specs` is a value, so they are ordinary
  assertions now.
- **`PriorityCell` is deleted.** Its double-click popover was the mechanism that
  did not work.
- **Still not testable: the click itself.** Synthesised clicks do not reach
  content inside a table headlessly, with `NSTableView` no more than with
  `Table`. What is asserted is either side — which columns declare an editor,
  and what each editor writes.
