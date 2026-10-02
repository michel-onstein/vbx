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
- **A commit touching nothing outside `.beads/` contributes no level**, and a
  run that finds only those exits without tagging. Beads are tracker
  bookkeeping; they land squash-merged like everything else, so without the rule
  every `br create` reaching `main` cut a patch release. The test is the diff
  rather than the subject, so a PR that changes code *and* a bead still bumps —
  the rule is "no file outside `.beads/`", not "any file inside it". Skipped
  commits are named `beads-only` in the output, because a commit that silently
  did not count reads exactly like one the script failed to see.
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

- **A release always has something to describe.** The bead-only rule keeps
  `RELEASES.md` free of entries for issues nobody can install, which is the same
  boundary the next consequence draws for `BUGS.md` and `WORK_LOG.md`.
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


---

## ADR-015 — "Uncommitted" is a fact about git, not state vbx keeps

**Date:** 2026-08-22 · **Status:** Accepted

**Context.** vbx writes through `br`, which updates the database and re-exports
`.beads/issues.jsonl` immediately. Nothing commits it, so after a few edits
there is no way to see what a commit would contain without reading a diff.

The obvious implementation is to remember what the app changed. That state has
to live somewhere, and it is wrong the moment anything happens outside the app —
a `br` run in a terminal, a `git checkout`, a commit, a pull, another vbx
window. Each of those needs its own invalidation, and a missed one leaves the
app confidently marking rows that are already committed.

**Decision.** A bead is dirty when **its record differs from the same record at
`HEAD`**. Nothing is stored; the answer is recomputed from the checkout, and it
is correct however the file got into its current state.

The committed set comes from the engine's `snapshot_at`, which reads the git
object store directly — the same path time travel uses, and the reason this
works in a sandbox where shelling out to `git` would not
([ADR-006](#adr-006--correlation-reads-the-git-object-store-directly-not-git)).

**Consequences.**

- **Three cases, not one.** Changed, added and removed are different, and only
  the first two have a row to mark. A removed bead still counts towards what a
  commit would carry, so the count includes it and the gutter cannot.
- **Absent is not clean.** A workspace with no repository, or one with no
  commits, has nothing to compare against. That is `unknown`, and it renders as
  nothing at all rather than as "nothing outstanding" — the same rule the
  Phase-2 metrics follow.
- **Records, not bytes.** The export is whole-file and `br` rewrites all of it,
  so formatting and order move without any bead moving. A byte comparison would
  light up every row after an unrelated write.
- **`updated_at` counts.** `br` stamps it on every write, so a record differing
  only there is still a record that was written and is not committed. Excluding
  it would call a real pending change clean.
- **`.git` is watched as well as the bead file.** A commit does not touch the
  export: `HEAD` moves and every dirty bead becomes clean while the watched file
  sits unchanged. Without the second watch the list would keep marking rows that
  are no longer dirty.
- **In a multi-repository workspace, `HEAD` is each member's own** (amended
  2026-10-01, `vbx-d1c`). A member is normally a repository of its own, so the
  committed set is the union of each member's beads at its own `HEAD`,
  namespaced as the loader namespaces them, and each member's `.git` is watched.
  A member with no history is `unknown` for its beads alone, not for the
  workspace — and not "added", which leaving it out would make it.
- **A mark in a gutter, not a tint across the row** (amended 2026-08-23,
  `vbx-r0m`). The row was originally tinted with a low-alpha accent. That could
  say only *something here is uncommitted*: it collapsed the three cases above
  into one, and it was suppressed while a row was selected, so selecting a dirty
  row hid the very fact it was there to show. A fixed 20pt column before the ID
  now draws `+` for added and `*` for changed, and nothing at all for a clean
  bead. Both marks take the same accent deliberately — a second colour would
  imply a severity ordering between "new" and "edited" that does not exist.
- **Colour is not the only signal.** A character in a gutter explains itself no
  better than a tint did, so the whole row still carries a tooltip saying why —
  the whole row, not just the marker cell, since asking someone to find a
  one-character gutter before they can learn what it means repeats the mistake.
  The reason text lives on the mark itself, so the glyph and its explanation
  cannot drift. The status bar keeps the count broken down by kind. There is an
  accessibility audit bead open; colour alone would fail it.
- **Deleted beads get no row — decided, not deferred** (amended 2026-08-24,
  `vbx-iyy`). `-` is not among the marks and will not be: the bead is gone from
  disk, and nothing on screen represents it.

  The alternative was real and was rejected. `BeadDirtyState.compare` already
  reads the committed set through `snapshot_at`, so the records are in hand;
  injecting the removed ones back into the list is the easy half. The hard half
  is what such a row *is*. It has no metrics — `GraphMetrics` is computed over
  the beads on disk, so blocks, blocked-by and PageRank are absent rather than
  zero. It must refuse every edit, because `br` has nothing to write to. It is
  not only the list: the board, graph, tree and detail pane read the same beads,
  and a row that exists on one surface and not the others is its own kind of
  wrong. Filtering, sorting, recipes and hybrid search all run over it, and the
  engine — which ranks the ids — does not know the bead exists.

  That is every feature that reads the workspace learning about a bead the
  workspace does not contain, to display a row nobody can act on. The cost is
  spread across the whole app; the benefit is one glyph.

  **What a deletion gets instead: a name.** `BeadDirtyState.summary()` lists the
  removed ids in the status bar's tooltip — bounded, and saying how many it left
  out — so "which bead went?" has an answer without a ghost row to ask it of.
  Ids rather than titles, because the record is gone from disk and the id is the
  handle that still resolves against the commit.
- **Multi-repo is not solved.** A workspace can span repositories with a `HEAD`
  each. This compares against the one the engine resolves for the opened source;
  when that fails the state is `unknown`, which is honest but not complete.
- **Committing from vbx is out of scope**, deliberately. This is about seeing
  the state. What message, which files, whose identity — all separate questions.

## ADR-016 — `main` is protected, and the release bot pushes through a deploy key

**Date:** 2026-08-22 · **Status:** Accepted

**Context.** `main` had no protection of any kind: it could be force-pushed,
rewritten or deleted outright, and nothing required a change to arrive through
a pull request. Every change already *does* arrive that way by habit, but habit
is not a control — a single mistyped `git push --force` from any of the several
worktrees this repo runs in would have rewritten the branch every other one is
based on.

The obvious protection is a ruleset requiring a pull request. That collides
with [ADR-013](#adr-013--the-version-bump-comes-from-a-pr-label-and-the-notes-from-the-tags):
`release.yml` advances the version *on merge* and pushes the tag and the
release-notes commit straight to `main`. A pull-request rule applies to
`GITHUB_TOKEN` exactly as it does to a person, so turning it on without more
would have left every merge protected and every release broken.

The fix is a bypass actor, and the choice of actor is forced. GitHub will not
let the **GitHub Actions app** bypass a ruleset on a user-owned repository —
the API rejects it with *"Actor GitHub Actions integration must be part of the
ruleset source or owner organization"*, an organisation-only feature. That
leaves an admin PAT or a deploy key. A deploy key wins because it does not
expire, is scoped to this one repository, and is not tied to a human account
whose own access changing would silently break releases.

**Decision.** A ruleset on the default branch blocks deletion and non-fast-forward
pushes and requires a pull request, with a write **deploy key** as the only
bypass actor. `release.yml` checks out with that key (`ssh-key:` on
`actions/checkout`, which also rewrites `origin` to SSH) so its push to `main`
is the one thing allowed past the rule.

**Consequences.**

- **Deletion and force-push protection are absolute.** No bypass actor is
  granted for them in practice: the release push is an ordinary fast-forward,
  so the deploy key never needs to rewrite or delete anything.
- **The idempotence guard became load-bearing.** A push authenticated with
  `GITHUB_TOKEN` never triggers another workflow — GitHub suppresses it to
  break exactly this loop — so the re-run the workflow header describes did not
  actually happen. A deploy key carries no such suppression, so pushing the
  release-notes commit *does* start a second run now, and `version-bump.sh`
  exiting on `--exact-match` is the only thing stopping a version per version.
  The tag lands on the release-notes commit itself, which is what makes that
  exact match hold.
- **Required approvals are zero.** GitHub does not let anyone approve their own
  pull request, and this repository has one human. Requiring an approval would
  have meant nothing could ever merge. The rule still forces the pull request;
  it just does not demand a second person who does not exist.
- **The key is a credential to rotate, not configuration.** It lives as the
  `RELEASE_SSH_KEY` secret with its public half registered as a write deploy
  key. Losing it breaks releases and nothing else; replacing it is generating a
  new pair and updating both halves.
- **A workflow edit is now a privileged change.** Anything `release.yml` runs
  can push to `main` past the rule. That is the residual hole, and it is the
  reason the bypass is a deploy key scoped to this repository rather than a PAT
  carrying a person's whole account.

---

## ADR-017 — Notarize with an App Store Connect API key, not a keychain profile

**Date:** 2026-08-22 · **Status:** Accepted

**Context.** `package-app.sh` required `VBX_NOTARY_PROFILE`, a profile written
by `xcrun notarytool store-credentials` from an Apple ID and an app-specific
password. That is the form Apple's documentation leads with, and it has two
problems.

It lives in one login keychain. It cannot be put in CI, cannot be shared, and a
new machine means creating it again — so the release path only ever works from
one desk.

And it is a *second* credential. Getting a signed release also needs a Developer
ID Application certificate, which comes from the developer account; the
app-specific password is a separate thing to create, store and rotate for no
additional capability.

**Decision.** `VBX_NOTARY_KEY`, `VBX_NOTARY_KEY_ID` and `VBX_NOTARY_ISSUER` — an
App Store Connect API key — are accepted and preferred. The keychain profile
still works and is not deprecated; when both are configured the key wins,
because it is the form that behaves the same everywhere.

The same key creates the certificate: `scripts/signing-setup.sh` uses it through
`asc` to issue the Developer ID Application certificate and import it. One
credential, both halves.

**Consequences.**

- **A release becomes possible from CI**, which a keychain profile made
  impossible. Not wired up — the workflow tags and records and deliberately
  builds nothing (ADR-014's note) — but it is no longer blocked by the
  credential's shape.
- **The key's identifiers are masked** like every other account identifier. The
  `.p8` path can carry an account name and the issuer is an account-wide UUID;
  neither is secret alone, and both are what ends up pasted into an issue beside
  a build log.
- **`--check` asks whether the credential *works*,** by calling
  `notarytool history` with whichever form is configured, and reports which one
  is in play. Configured and usable are different claims, and only the second
  one ships.
- **The missing `.p8` is caught before building.** A path that does not exist
  otherwise fails inside `notarytool`, minutes into a release, after the
  universal build and the signing.
- **Creating the certificate through the API does not work for most accounts.**
  Measured, not predicted: `asc certificates create` returns *"This request is
  forbidden for security reasons: This operation can only be performed by the
  Account Holder."* A **Team** key cannot hold that role — it is not among the
  roles offered when generating one — so no configuration fixes it. An
  *Individual* key created by the Account Holder carries that person's role and
  may work; it is worth one attempt and nothing more.
  `signing-setup.sh --csr` is therefore the route that always works: the request
  is generated locally, the certificate is issued in the web portal signed in as
  the Account Holder, and `--import` installs it. Notarization has no such
  restriction — any Team key notarizes.
- **Neither credential exists here yet**, so this does not make a signed release
  possible on its own — it removes one of the two blockers and makes the other
  a single credential rather than two.

---

## ADR-017 — A closed bead is immutable in vbx, and vbx is the only thing enforcing it

**Date:** 2026-08-24 · **Status:** Accepted

**Context.** A closed bead is a record of what happened. Editing one rewrites
history rather than tracking work, and vbx offered both of its edits — the title
field editor and the priority menu — on closed beads exactly as on open ones.

The first question was whether `br` already refuses, because it changes what
this is. **It does not.** Measured against a scratch workspace before anything
was written:

    $ br close scr-985 --reason done
    $ br update scr-985 --title "Retitled after closing"
    [{"id":"scr-985","title":"Retitled after closing","status":"closed",...}]
    exit: 0

Priority behaves the same way. So this is not vbx aligning with the engine; it
is vbx's own rule.

**Decision.** A bead whose status is `closed` or `tombstone` is immutable in
vbx. `IssueStatus.isImmutable` is the single expression of it.

- **Not offered, rather than refused afterwards.** The double-click does not
  open the field editor and the priority menu shows its reason instead of
  values. By the time a title has been typed and Return pressed, an edit that
  vanishes into an error is worse than one that was never offered.
- **Refused at the write as well.** `setTitle` and `setPriority` check the same
  rule. A gate is not a rule if the thing behind it still says yes, and the
  thing behind it — `br` — does.
- **A mixed selection refuses as a whole**, naming how many beads stood in the
  way. The alternative, applying to the open beads and skipping the closed
  ones, is the kind of partial success noticed a week later, when the beads that
  did not change look like beads nobody got to.
- **The rule is a function of status and nothing else.** The escape hatch for a
  bead closed by mistake is to reopen it, after which it edits again because it
  is no longer closed. Nothing is stored, and there is no separate lock to fall
  out of step with the status — the same argument
  [ADR-015](#adr-015--uncommitted-is-defined-against-git-not-tracked-by-vbx)
  makes for defining "uncommitted" against git.
- **An unknown status stays editable.** `IssueStatus` is an open enum on
  purpose. A status this build has never heard of must not silently become
  read-only: refusing an edit is the more surprising of the two failures, and
  the one nobody would think to report — they would assume the bead was closed.

**Consequences.**

- **This does not make a closed bead immutable anywhere else.** A terminal
  `br update` still rewrites one, and vbx will show the result on the next
  reload. Stated here rather than implied, because a rule enforced in one
  surface is a rule people are surprised by in another.
- **Reopening is the escape hatch and is not yet built.** Until it is, a bead
  closed by mistake is edited from the terminal — which works, per the above.
- **Colour is not the affordance.** The refused cell carries the reason as its
  tooltip, and a refusal outranks the uncommitted mark's tooltip on a column
  that edits: it explains an affordance that just did nothing.

---

## ADR-018 — Beads are stamped with the repository, and a check keeps them that way

**Date:** 2026-08-24 · **Status:** Accepted

**Context.** `br` records where each bead was created, as `source_repo` and
`source_repo_path`. It takes the basename of the directory it runs in — and this
repository's discipline is that **every session works in
`.claude/worktrees/<topic>`**. The two rules are in direct conflict, and the
worktree rule is the correct one, so essentially every bead filed since it took
hold carried a throwaway topic name.

Measured on 54 records: **11 distinct `source_repo` values, 30 of them not this
repository**, and **29 records naming a `source_repo_path` that no longer
existed** — 19 pointing at the pre-rename `bvx` checkout, the rest at worktrees
deleted when their work landed.

**Nothing reads the field today.** `RepoInfo.owns(_:)` matches beads to a
repository by id prefix, `--robot-repos` reports this workspace as single-repo,
and the sidebar's repository section only renders for a workspace. Said plainly
so this is not over-prioritised: no bead is mis-grouped today. The cost is
latent — `br`'s own help calls `source_repo_path` "the canonical filesystem
location of the repo for cross-machine sync awareness", and any future surface
that groups by origin would inherit 11 apparent repositories, 9 of them phantom,
as plausible-looking strings rather than as something that reads as broken.

**Decision.**

- **Every record is stamped with this repository** — the primary checkout's name
  and path. The 30 offenders were rewritten through `br update`, in one commit,
  a per-record diff rather than a whole-file rewrite.
- **The 19 pre-rename `bvx` records became `vbx`.** A decision rather than an
  obvious cleanup: they *were* filed in a directory called `bvx`. But the rename
  was a rename of this same project, so the honest answer to "which repository
  is this bead from?" is the one it is from now, and keeping two names for one
  repository is precisely the phantom-repository problem in miniature.
- **`scripts/beads-check.py` guards it**, in the verify block beside the other
  checks. `--fix` rewrites; the default reports, grouped by the repository that
  stamped them.
- **The canonical name comes from git**, not a constant: the common git
  directory is shared by every worktree and its parent is the primary checkout,
  so the check is right from wherever it runs — which matters, because it will
  almost always run from a worktree.

**Why a check rather than a convention.** The value cannot be set correctly at
creation time: `br create` has no `--source-repo` flag, and `.beads/config.yaml`
holds only `issue_prefix`. That leaves "remember to run `br update` after every
`br create`" — a rule of exactly the kind that produced this mess. A failing
check turns it into something the build says out loud, with a one-line answer.

**Consequences.**

- **The real fix is upstream.** A `source_repo` key in `.beads/config.yaml`, or
  `--source-repo` on `br create`, would make this check redundant. Worth raising
  with `beads_rust` rather than worked around forever.
- **Creating a bead now has a second step.** `br create` then
  `scripts/beads-check.py --fix`. The check is what makes forgetting visible.
- **The rewrite bumped `updated_at` on 30 records**, so they all read as
  modified since their last real change. Accepted: the alternative is editing
  the export by hand, behind `br`'s back, which is how the database and the
  JSONL come apart.
## ADR-019 — The graph's camera is a value, and the trackpad reaches it through a monitor

**Date:** 2026-08-24 · **Status:** Accepted

**Context.** The graph could be zoomed only with two buttons and panned only by
holding the mouse down and dragging. On a laptop that is the wrong shape for the
gesture: a pinch is how a canvas is zoomed on macOS and two fingers are how it
is moved, and neither reached the graph.

SwiftUI supplies exactly half of what is needed. `MagnifyGesture` is a pinch and
works over a `Canvas`. There is **no** scroll gesture — `ScrollView` is the only
route to a two-finger scroll, and it is the wrong one here: the camera is a
transform applied inside the `Canvas`, so wrapping the canvas would hand the
offset to a container that knows nothing about the zoom, and hit-testing would
have to be reconciled with a scrolled clip view.

**Decision, part one: the camera is a value type.** ``GraphCamera`` holds the
scale and the offset and owns every operation on them, including the arithmetic
that keeps a point fixed while the scale changes. Drawing, hit-testing, the
buttons and both gestures all go through it.

This is what makes any of it assertable. A pinch cannot be delivered to a
headless test, so if the camera lived as two `@State` numbers mutated inside
gesture closures there would be nothing to test but pixels. As a value, the
anchored zoom, the clamping and the pan are ordinary assertions.

**Decision, part two: two-finger scrolling arrives through a local event
monitor.** ``GraphScrollCatcher`` is an `NSViewRepresentable` whose view returns
`nil` from `hitTest(_:)` — it never takes a click — and whose coordinator holds
an `NSEvent` local monitor for `.scrollWheel`, scoped to events whose window is
this view's window and whose location falls inside its bounds.

The obvious alternative is an `NSView` that hit-tests and implements
`scrollWheel(with:)`. A scroll event is delivered to the view under the pointer,
so that view must be in the hit-testing path — and then it also receives every
click, taking selection, hover and the drag-pan away from SwiftUI and putting
them on the responder chain to be forwarded by hand. ADR-014 is the record of
what it costs to fight that. A monitor sees the event before delivery without
being in the hit-testing path at all, which is why the mouse still belongs
entirely to SwiftUI.

**Consequences.**

- **The buttons now zoom about the middle of the pane**, where before they
  changed the scale and left the offset alone — which slid the graph across the
  pane and off it, so zooming in twice needed a drag afterwards to find the
  nodes again. The buttons and the pinch are the same operation with a different
  anchor, and one range clamps both, so the percentage readout means the same
  thing whichever produced it.
- **A pinch at either end of the range is a no-op**, not a recentre. Clamping
  the scale while still moving the offset would drift the graph a little on
  every event of a gesture that has visibly stopped scaling.
- **Both continuous gestures apply increments**, not a value recomputed from a
  camera captured when the gesture started. A pinch and a drag can run at once
  on a trackpad; two gestures each recomputing from their own baseline discard
  each other's work, and the graph jumps between two cameras while both hands
  are moving.
- **A mouse wheel pans too**, at 16 points per line. Wheel events report a count
  of lines rather than a distance, and unscaled a notch moves the graph by a
  point — which reads as a dead wheel rather than as a unit mistake.
- **Consumed, not observed.** A scroll over the graph returns `nil` from the
  monitor so nothing enclosing the graph scrolls as well.
- **Still not testable: delivery.** Whether macOS routes a real pinch or scroll
  to this view is not something a test process can answer. A synthesised
  `CGEvent` scroll posted to the process arrives with **no window**, so the
  monitor's own scoping rejects it — measured, not assumed. What is asserted is
  either side of the gap: the camera arithmetic, the reading of a scroll event's
  deltas (from a synthesised event, both units), and — with the catcher hosted
  for real in a window — that its rectangle covers the graph and that a point
  outside it is refused. The failure this last one guards is an overlay that
  ends up zero-sized, which is indistinguishable from a gesture the system never
  delivered.

---

## ADR-020 — Only vbx-cli resolves the live tracker; the app explains why it has no claim

**Date:** 2026-10-01 · **Status:** Accepted, implemented

**Context.** bv 0.25 binds every loaded bead to the tracker that supplied it
(`loader.AttachIssueOrigins`), and derives each triage recommendation's
`actions` — a `br show` and, for a claimable bead, the atomic
`br update --claim` — from that binding. `--robot-next` emits its
`claim_command` from the same place, and declines with
`live_action_route_unavailable` when there is no route. The binding reads
`.beads/metadata.json` and then asks the installed `br` what it supports, by
running `br update --help` with a two-second timeout. The App Sandbox forbids
that subprocess, so the app cannot do what bv does; and without the binding
vbx's triage differed from bv on `actions.local_id` and its `--robot-next`
still emitted the pre-0.25 `br update <id> --status=in_progress`, which is not
atomic.

**Decision.** The session takes an explicit `live_tracker_actions` option in
its open configuration (`OpenConfig.LiveTrackerActions`, through the existing
JSON config of `vbx_open` — no new C entry point). `vbx-cli` sets it; the app
never does. With it, the engine calls bv's binding exactly as bv's loader does,
with bv's "complete" verdict (no record failed to parse). Without it, every
bead gets an origin carrying its id and the reason
"live tracker actions are resolved by vbx-cli, not the app" — so the payload
has the same shape in both, and the absence of a command is explained rather
than empty. `--robot-next` is now a port of bv's `handleRobotNext`: the
source-authority, top-pick, claim-gate, metric-completeness and live-route
gates, in bv's order, with the claim command taken from the bead's actions.

**Alternatives.**

- *Sniff the sandbox* (the `APP_SANDBOX_CONTAINER_ID` environment variable).
  Rejected: the Developer ID build is not sandboxed but is still the app, and a
  test process looks like neither. The caller knows what it is; it says so.
- *Bind origins in the app too and let the subprocess fail.* Rejected: a
  sandbox denial costs up to the two-second timeout on every load, and the
  failure reason ("cannot establish installed tracker capabilities") blames the
  user's `br` rather than the app.
- *Keep vbx's own claim string.* Rejected: it is the non-atomic claim bv
  replaced, and an agent racing another on `--status=in_progress` can both
  "win".

**Consequences.**

- The app never spawns a tracker from the engine, for a single repository or a
  `.bv/workspace.yaml` workspace. bv's `workspace.LoadAllFromConfig` binds
  origins inside itself and refreshes a Dolt repository's export with
  `bd export`, with no option to skip either in v0.25.2, so vbx loads
  workspaces through a port of bv's `AggregateLoader`
  (`Engine/bridge/engine/workspace_loader.go`) whose binding and refresh are
  the session's choice. `TestWorkspaceLoaderMatchesBV` holds the port to bv's
  loader, origins included, given bv's choices. The app reads a Dolt
  repository's existing export, as it does for a single repository (vbx-jvj).
- A load with a malformed record is not claim-safe: triage withdraws every
  claim (bv's `suppressUnprovenTriageClaims`) and `--robot-next` answers
  `source_authority_incomplete`.
- `--robot-next` on the demo fixture is no longer actionable, as bv's is not:
  the fixture has no tracker metadata. Run in a real `br` workspace it emits
  bv's claim, byte for byte.
- `parity-check.py` compares `--robot-next` again, less the provenance envelope
  keys vbx-v57 owns (since settled by ADR-023).
- Export hooks (`.bv/hooks.yaml`) follow the same pattern with their own open
  option, `export_hooks`: `export_report` runs bv's `pkg/hooks` around the
  write only when the caller says it may spawn, which vbx-cli does unless
  `--no-hooks` is given and the app never does (vbx-uos).

---

## ADR-021 — Tombstones are records the app keeps and beads the analysis does not

**Date:** 2026-10-01 · **Status:** Accepted, implemented

**Context.** bv 0.25 splits a load in two. Its loaders return the *visible*
set — every record except tombstones — and report the tombstones' ids
separately (`LoadReport.TombstoneIDs`, `workspace.LoadResult.TombstoneIDs`).
Everything bv analyses runs over the visible set: triage counts, the graph, label
health, suggestions, priority and the data hash. Its readiness authority
(`model.ReadinessIndex`) is built over the visible set *plus* a stub per
tombstone id, so a deleted blocker counts as resolved rather than missing; a
missing blocker is "unknown" and withholds its dependents for ever. vbx analysed
every decoded record, tombstones included — 21 beads where bv counts 20 on
`Fixtures/readiness` — and its SQLite loader dropped deleted rows outright,
which turned a tombstoned blocker into a missing one. Meanwhile CLAUDE.md's rule
is that **decoding never drops a record**, because a dropped issue silently
changes every downstream metric.

**Decision.** The session keeps three things where it kept one
(`Engine/bridge/engine/readiness.go`):

- `records` — every decoded record, tombstones included. The `issues` payload,
  `info.issue_count`, the History views and the time-travel diff read this.
- `issues` — the analysis set, `records` less tombstones. The analyzer, triage,
  label health, suggestions, the graph, search and the data hash read this,
  exactly as bv does.
- `readiness` — bv's `ReadinessIndex` over `records` plus any tombstone id a
  loader reported without a record (bv's workspace loader keeps none). It is
  installed into the analyzer with `SetReadinessScope` before analysis starts,
  and passed to triage, `--robot-next`, recipes and the site export.

The SQLite loader returns deleted rows, marking a row a tombstone by bv's rule:
its status, or a nonzero `tombstone` column. `deleted_at` alone does not make
one — bv does not read it, and br sets both together.

**Why this does not break the decoding rule.** The rule is about *decoding*:
nothing the loader reads is dropped, and the record stays available to the app,
which already hid tombstones from every list filter. Leaving a tombstone out of
*analysis* is not a dropped record but bv's definition of what is analysed; the
metric drift the rule guards against is exactly what analysing tombstones
caused here. The rule's text in CLAUDE.md now says so.

**Alternatives.**

- *Keep analysing tombstones.* Rejected: every count, density and label figure
  disagrees with bv on any workspace that has deleted a bead, and parity cannot
  be checked on such a workspace at all.
- *Drop tombstones at load, as bv does.* Rejected: the record is the user's,
  and it is the case the decoding rule exists for — the app could no longer
  show or diff a deleted bead.
- *Treat `deleted_at` as a tombstone too.* Rejected for now: bv does not, so a
  row with `deleted_at` and a live status would be analysed by bv and not by
  vbx. br never writes that combination.

**Consequences.**

- `info.issue_count` is the record count (21 on the readiness fixture); triage's
  `meta.issue_count` is the analysis count (20), as in bv.
- The reload gate hashes every record plus the reported tombstone ids, not the
  analysis set, so an edit confined to a tombstone, or a new one, still reloads.
- Recipes run through bv's `recipe.Apply` with the readiness authority, so
  `actionable` and `blocked` match bv's sets; vbx keeps no copy of the filter.

---

## ADR-022 — A single-bead edit lands only on the record vbx showed

**Date:** 2026-10-01 · **Status:** Accepted, implemented

**Context.** vbx edits a bead by running `br update`, and between the user
reading a record and committing an edit, an agent or a terminal can change it.
An unguarded `br update --priority` then overwrites that change without anyone
seeing it — the user decided against a version that no longer exists. `br`
0.7.0 added `--if-unchanged <updated_at>`: the write happens only if the
record's `updated_at` still matches, otherwise `br` exits 6 with
`UPDATE_PRECONDITION_FAILED` on stdout and writes nothing. It compares
instants at `br`'s full precision (microseconds in practice, nanoseconds
allowed), so `2026-10-01T22:33:13.885Z` against a stored `.885481Z` is a
conflict. `br` 0.6.0 does not have the flag and rejects it as an unexpected
argument.

**Decision.**

- **`Issue.updatedAtStamp` keeps `updated_at` verbatim.** `updatedAt` is a
  `Date`, which the ISO 8601 parser fills to the millisecond and a `Double`
  cannot hold to the nanosecond, so it cannot be the token. The engine's Go
  `time.Time` keeps full precision and emits RFC 3339 with it, so the string
  that reaches Swift is exact.
- **Priority and title edits pass the stamp of the displayed record.** A
  multi-bead priority change is one `br update` per bead, so each is guarded by
  its own stamp. A label change is one `br label` command for many beads and
  has no such flag; it stays unguarded.
- **Support is detected, not assumed.** `BeadWriter` asks `br update --help`
  once whether it lists `--if-unchanged`, caches a conclusive answer, and sends
  the unguarded write to a `br` that does not. Feature detection rather than a
  version comparison: it asks about the thing it is about to use.
- **A refusal is a conflict the user sees.** The store reloads, so the newer
  record is on screen, and says the edit was not written and may be made again.
- **The recovery retry stays guarded.** The `br` 0.7.4 "recovery in progress"
  retry (vbx-1sw) re-sends the same arguments, stamp included. If the first
  attempt landed before failing, the retry is refused by vbx's own write, so a
  refusal *after a retry* reads the record back with `br show` and counts the
  edit done when the record already says what it asked for. A refusal on the
  first attempt is always a conflict.

**Alternatives.**

- *Read the stamp with `br show` just before writing.* Rejected: that is the
  record as it is now, not the one the user decided against, and guards
  nothing.
- *Compare versions (`br --version >= 0.7.0`).* Rejected for the reason above;
  a fork or pre-release can carry the flag under any number.
- *Treat every refusal whose record already matches as success.* Rejected: on a
  first attempt the match was made by someone else, and that is a change the
  user should see rather than have silently absorbed.

**Consequences.**

- With `br` 0.6.0 behaviour is unchanged; the guard arrives with the upgrade.
- An edit costs one extra `br update --help` per writer, once.
- Nothing in vbx reads `updatedAtStamp` for display or arithmetic; it is a
  token handed back to `br`.

---

## ADR-023 — vbx ports bv's provenance envelope, except the source-authority report

**Date:** 2026-10-01 · **Status:** Accepted, implemented

**Context.** bv 0.25 added six keys to the envelope of every issue-backed robot
payload, all built in `cmd/bv`, which vbx cannot import: `output_format`,
`source_path`, `source_kind`, `scope_hash`, `source_authority` and
`authority_hash`. After the engine bump `--robot-suggest` and `--robot-graph`
differed from bv on every fixture on these keys alone, and `--robot-next` and
`--robot-burndown` were compared with them stripped, each command declaring its
own list (vbx-v57).

**Decision.** Per key, port it when vbx can compute it from what it already
holds *and* it means what it means in bv; otherwise declare it envelope-only.

- **Ported** (`Engine/bridge/engine/provenance.go`), on every payload that
  carries vbx's envelope — suggest, priority, next, insights, graph and now
  burndown, which also gained `generated_at` and `data_hash`:
  - `output_format` — `json` from the engine; vbx-cli restamps it `toon` when
    it re-encodes (`RobotEnvelope.stamping`).
  - `source_path` — the file vbx loaded (the workspace config for a
    workspace).
  - `source_kind` — vbx's own kind in bv's vocabulary: its local JSONL is
    `jsonl_local`, `sqlite` and `workspace` are as named.
  - `scope_hash` — bv's `robotScopeHash` verbatim: label, recipe, repo, the
    unscoped data hash and the sorted candidate ids. Under a label — graph,
    triage, plan, priority, next, suggest and insights, all through
    `Session.view` — the ids are the label's core beads as bv's `--label`
    makes them, and the envelope reports `scope.label`. Under a recipe
    (vbx-7d5, the same step) the ids are what the recipe selected, of the
    label's beads when both are given; the recipe is hashed and reported in
    `scope.recipe` exactly as it was given, a path included.
  - Since vbx-shz the label commands, the blocker chain, search and the sprint
    commands carry the envelope too, through `withEnvelope`, which adds
    `generated_at` and `data_hash` beside the provenance keys wherever the
    payload has no field of that name. Their payloads stay the analysis
    result the app decodes, with the envelope at its top level, so
    `parity-check.py` lifts bv's envelope keys into the subtree it compares.
    `data_hash` follows bv per command: the unscoped hash for the label
    commands and search (`ctx.Envelope()`), the scoped issues' hash for the
    blocker chain and the sprint commands (`ComputeDataHash(ctx.Issues)`).
  - `load_stats` (vbx-dv5, `loadstats.go`) — bv's `robotLoadStats`, present
    only when the load dropped a record. bv derives it from
    `source_authority`, but only from each source's parse accounting, which
    vbx's loads already hold: `loader.ParseStats` for a JSONL, each member's
    `workspace.LoadResult` for a workspace, and vbx's SQLite reader, which
    now drops and counts rows by bv's SQLite rule (failed validation, a
    repeated id). Counts sum every source that is not disabled; `source_path`
    is named for exactly one source; warnings are bv's, in its source order,
    capped at ten. bv's source-selection warnings — which only join the
    warning list — are the one part vbx cannot reproduce, because it ranks no
    sources. It rides the same shared helper, so it reaches exactly the
    payloads that carry vbx's envelope. `Fixtures/dropped`, as JSONL and as a
    `beads.db`, compares it on every command that does.
  - Since vbx-6su triage, plan, alerts and metrics carry it too, through the
    same `withEnvelope`, with the unscoped data hash bv's `ctx.Envelope()`
    gives all four. bv nests triage under `triage` and the plan under `plan`;
    vbx keeps each payload the result the app decodes, with the envelope
    beside its fields, so the app's models are unchanged and the harness
    lifts bv's envelope keys for them as for the label commands. bv's
    `--robot-metrics` reports runtime timings rather than vbx's GraphStats,
    so only its envelope is compared.
- **Envelope-only**, in `parity-check.py`'s single `ENVELOPE_ONLY_KEYS`, each
  with its reason:
  - `source_authority` — bv's report of its multi-source selection: candidates
    ranked by freshness, a stale fallback, per-source authority warnings. vbx
    resolves one source and ranks none (ADR-024). Its fields could be
    filled in, but `stale: false` and `state: complete` would then assert
    checks vbx never ran.
  - `authority_hash` — a hash of `source_authority`, so it goes with it.

The values are always vbx's own. In a `br` 0.7 workspace bv reads `beads.db`
where vbx reads `issues.jsonl`; `source_path`, `source_kind`, `data_hash` and
so `scope_hash` then differ honestly; ADR-024 keeps vbx's choice rather than
faking bv's.

**Alternatives.**

- *Declare all six envelope-only.* Rejected: four are cheap, exact and useful
  to an agent reading vbx's output with bv's contract, and a harness that hides
  computable keys stops checking them.
- *Port `source_authority` from the one load vbx does.* Rejected for the reason
  above; vbx's claim-safety verdict is already visible as `--robot-next`'s
  `source_authority_incomplete`.
- *Keep per-command stripping.* Rejected: it is how the same key ended up
  stripped for two commands and compared for two others.

**Consequences.**

- `Fixtures/demo`, `Fixtures/readiness` and `Fixtures/sprints` match bv 0.25.2
  on every compared command; `--robot-burndown` is compared whole.
- The readiness `beads.db` section differs only where vbx-tvi/vbx-dj4 already
  did; `scope_hash` follows `data_hash` there because it hashes it. ADR-024
  declares those differences rather than porting bv's source ranking.
- If vbx ever ports bv's source ranking (ADR-024's revisit trigger),
  `source_authority` becomes portable and this decision should be revisited.

## ADR-024 — vbx keeps its own read of a beads.db rather than bv 0.25's lossy one

**Date:** 2026-10-01 · **Status:** Accepted, implemented

**Context.** bv 0.25 chooses its source through `internal/datasource`: the
freshest candidate wins, and in practically every live `br` 0.7 workspace that
is `beads.db`. vbx's `resolveSource` prefers a non-empty `issues.jsonl` and
reads `beads.db` only when there is none (vbx-tvi). On `br`'s schema bv's main
SQLite query fails — it selects `due_date` and `tombstone`, and `br` has
`due_at` — so bv falls back to `loadIssuesSimple`, which drops `closed_at`,
`notes`, `design`, `source_repo` and dependency timestamps. vbx's own SQLite
loader reads every column. So on the readiness fixture as a `beads.db`, after
vbx-dj4 fixed load order, three differences remained:

- `data_hash` on `--robot-next`, `--robot-suggest` and `--robot-graph`, and
  `scope_hash`, which hashes it;
- `--robot-label-health` `velocity.avg_days_to_close`, a float in vbx and an
  int in bv, which skips the closed bead it cannot see closing;
- `--robot-triage` `velocity.estimated`, present in bv only, because without
  `closed_at` it estimates close times from `updated_at`.

The same beads as JSONL match bv on every one of these.

**Decision.** Option (a): vbx keeps reading what it reads today — the JSONL
where there is one, every column of a `beads.db` where there is not. The three
differences are declared, not fixed, in `parity-check.py`'s single
`DECLARED_DIFFERENCES`: scoped to the `readiness (beads.db)` fixture, the named
command and the exact JSON path, each with its reason. The same paths are
compared on every JSONL fixture; any other difference on the `beads.db` still
fails; a declaration that stops firing fails the run; and each is printed as
`declared`, never as a match.

**Alternatives.**

- *(b) Port bv's source selection.* Rejected. Reading the freshest file would
  put vbx on `beads.db` in most live workspaces, and several things depend on
  the JSONL: ADR-015's uncommitted marks diff the record against the same
  record at `HEAD` through `snapshot_at`, and the database is gitignored.
  vbx opens a database `mode=ro&immutable=1`, which ignores the WAL — fine for
  a fallback, stale as the primary source of a workspace `br` is writing — and
  dropping `immutable` is what makes `br` 0.7.4's next write fail with
  "recovery in progress" (vbx-1sw). A sandboxed app is granted the file the
  user chose, not a database and its `-wal`/`-shm` siblings. And the hashes
  would *still* differ, because vbx reads every column of the database bv
  reads lossily.
- *(c) Port the selection and copy `loadIssuesSimple`.* Rejected. It would make
  the hashes agree by making vbx lose `closed_at`, notes, design and
  `source_repo` — which the inspector shows and the velocity numbers need — to
  match what is a bug in bv's query rather than a choice.

**Consequences.**

- `parity-check.py` exits 0 against bv 0.25.2 on every fixture, with five
  commands on the `beads.db` fixture reported as `declared` — nine since
  capacity and then the label commands (vbx-shz) gained the envelope, whose
  `data_hash` and `scope_hash` differ there for the same reason.
- `source_authority`/`authority_hash` stay envelope-only (ADR-023): vbx still
  ranks no sources.
- **Revisit** when bv fixes its main SQLite query against `br`'s schema
  (`due_date` vs `due_at`) — the declarations then stop firing and the run
  fails, which is the prompt — or when bv exports its source selection, so vbx
  could adopt it without copying `cmd/bv` or `internal/`.

---

## ADR-025 — The app records triage feedback in-process, under whatever access the build has

**Date:** 2026-10-01 · **Status:** Accepted, implemented

**Context.** vbx-442 puts Accept / Not now on each triage recommendation, and
Reset beside the feedback count. Bead edits leave the app through `br`, a
separate process; this write does not. The engine's `triage_feedback_record`
and `triage_feedback_reset` (vbx-rt3) write `.beads/feedback.json` from inside
the app, through bv's own `FeedbackData`. The bead asked whether the
workspace's security-scoped access is active when that happens.

What the code holds today:

- **No security-scoped access is ever started.** Nothing calls
  `startAccessingSecurityScopedResource` and no bookmark is created. The Open
  panel hands over a URL, the store keeps its `path` string, and the recents
  list and window restoration reopen by path. VBX_DESIGN §8.3's "bookmarks
  persisted per document" is the plan, not the build.
- **The Developer ID build** (`--dmg`, the shipping channel, ADR-010/012) is
  not sandboxed, so the write needs no grant, and neither do the engine's other
  in-process workspace writes: correlation verdicts, the drift baseline,
  recipes.
- **The App Store build** declares `files.user-selected.read-only`. In a
  session, a folder picked in the Open panel stays readable, but the
  entitlement makes it read-only. So *every* workspace write fails there, and
  that includes `br`'s and the engine's other in-process writes.

**Decision.** Record through the engine, in-process, exactly as correlation
verdicts already are. Do not wrap the call in
`startAccessingSecurityScopedResource`: on a URL rebuilt from a path string it
returns false and grants nothing, so it would only look like a guard. Where the
process may not write, the engine's error (`Error saving feedback: …`) goes to
`ProjectStore.triageFeedbackError`, the panel shows it, and nothing else
changes. No verdict is marked and the count does not move. A test makes
`.beads` read-only and asserts exactly that.

After a successful write the store reloads at once. The engine leaves its own
copy of the feedback alone, so that reload sees the file changed and re-ranks
(the path an outside `bv --feedback-accept` takes through the watch). The
watch's own reload that follows finds nothing changed.

**Alternatives.**

- *Go through `bv` or `vbx-cli` as a subprocess, like `br`.* Rejected. The
  sandbox forbids spawning either (ADR-006, ADR-020), the App Store build ships
  no `vbx-cli` (ADR-010), and it would be a second process doing what the
  linked engine already does with the same functions.
- *Write to the app's container in the App Store build.* Rejected. bv and
  `vbx-cli` read `.beads/feedback.json` in the workspace, and verdicts nobody
  else can see would score a ranking that only this app shows.
- *Widen the App Store entitlement to read-write and implement bookmarks
  here.* Out of scope: it changes what App Review is asked to approve, and it
  applies to every workspace write, not to this one. Filed as its own bead.

**Consequences.** In the Developer ID build feedback works with no grant. In
the App Store build it fails visibly, alongside the other workspace writes,
until the read-write question is settled. **Revisit** when the App Store build
gains read-write access with security-scoped bookmarks. The write then has to
happen while that access is started, and the denied-write test is where the
switch shows up.

## ADR-026 — Workspace discovery is bv's: a reachable `.beads` wins, in the app too

**Date:** 2026-10-02 · **Status:** Accepted, implemented

**Context.** bv 0.25.2 uses a `.bv/workspace.yaml` only when no `.beads` is
reachable (`discoverWorkspaceConfig` in `cmd/bv/main.go`: `loader.GetBeadsDir`
first, then `workspace.FindWorkspaceConfig`), and `--workspace <file>` is the
explicit override. *Reachable* means `BEADS_DB` / `BEADS_DIR`, else `.beads` in
the directory itself, else at the root of the checkout it sits in. It does
not mean any parent. The configuration, by contrast, is found in the directory
or in any parent. vbx's engine did the opposite and checked for a
configuration first, so a repository with its own `.beads` under (or beside) a
`.bv/workspace.yaml` opened as the aggregate in vbx and as the single
repository in bv. The result was namespaced ids, a different graph and a
different value for every metric. No ADR recorded the difference, and
`vbx-cli` had no `--workspace`. (vbx-1y5)

**Decision.** One rule, in the engine, for every caller: `discoverWorkspaceConfig`
in `workspace.go` ports bv's and applies it to the path the caller names
instead of the working directory. `vbx-cli` gains `--workspace FILE`. It sets
`OpenConfig.Workspace`, which loads that configuration as given, with no
discovery. Like bv, it echoes the argument verbatim as `source_path`. `Probe`
asks the same function, so the Open panel offers exactly what opens. Two cases
are vbx's own, because bv always starts from a directory. A `.yaml`/`.yml`
file chosen directly is the configuration itself, and `Probe` parses it, so a
YAML file that is not a workspace is greyed out. A `.beads` directory chosen
directly is that repository.

**The app follows the same rule, and that changes what some paths open.** A
path that holds both a `.beads` and a `.bv/workspace.yaml`, or a repository
below a workspace root, used to open as the aggregate. It now opens as that
repository, and a recents entry or a restored window pointing at it reopens as
the repository. To get the aggregate, the user opens the
`.bv/workspace.yaml` file itself. The Open panel offers it (⌘⇧. shows the
hidden `.bv`). A workspace root without a `.beads` of its own opens as
before. So does any folder below it from which no `.beads` is reachable.
Launch discovery still only probes (CLAUDE.md), and the probe now answers by
the new rule.

**Alternatives.**

- *Keep workspace-first for the app, bv's rule for `vbx-cli`.* Rejected.
  Opening the same folder would then give a different graph in the app than in
  the CLI that ships inside it. That is the drift ADR-001 exists to prevent,
  moved from bv-versus-vbx to vbx-versus-vbx. It would also need a second
  discovery rule that `Probe` and `load` both carry.
- *Keep workspace-first everywhere and record it as a divergence.* Rejected.
  An agent running `bv` and a person looking at vbx in the same directory
  would rank different beads, and nothing on screen would say why.
- *Show the hidden `.bv` folder in the Open panel by default.* Not done. It
  clutters every folder the panel shows, to help with a case that the
  configuration file already handles.

**Consequences.** `vbx-cli` and bv agree on which graph a directory means.
This is parity-checked from a root holding both, from a member, and from a
plain folder below a workspace, each with and without `--workspace`. One
trap is inherited from bv rather than introduced here. A workspace root that
has a `.beads` only for `feedback.json` is now taken for a single repository
with no bead data. The Open panel refuses it and `vbx-cli` reports "no bead
data found", so open the configuration instead. Neither bv nor the engine
creates that directory when it records feedback, because `FeedbackData.Save`
writes into an existing one.
