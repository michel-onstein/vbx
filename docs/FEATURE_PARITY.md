# vbx — Feature Parity Matrix

| Field | Value |
|---|---|
| **Status** | Living document — the Phase column is the *plan*, not the build state |
| **Date** | 2026-08-20; bv 0.21–0.25 capabilities mapped 2026-10-01 (vbx-htg) |
| **Build state** | See "Implementation status" below, and the root `README.md` |

Companion to the [vbx Design Document](VBX_DESIGN.md). Every capability of `bv` is listed
here with the `vbx` surface that delivers it, the mechanism, and the delivery phase from
[§18 of the design doc](VBX_DESIGN.md#18-delivery-plan).

## Implementation status

As of 2026-08-20 every capability tracked in this matrix is **built and
tested**: JSONL and SQLite loading with discovery fallback, Phase-1 and Phase-2
metrics with honest status reporting, the actionable set, execution plan,
unblocks and blocker chains, triage, the List / Board / Graph / Tree / Insights
/ Plan / Labels / Flow / Attention / History / Alerts / Sprint views with an
Inspector, filters, fuzzy and hybrid search, bv's single-key bindings, live
reload via FSEvents, Markdown and static-site export, git correlation with a
History view, time travel with diff badges, recipes, alerts and drift with
baselines, the sprint dashboard, multi-repository workspaces, App Intents, the
`vbx://` URL scheme, Spotlight indexing, the tutorial, and `vbx-cli` speaking
the robot protocol with TOON output.

**Except the bv 0.21–0.25 additions.** The engine runs on bv v0.25.2, and the
capabilities bv gained between 0.21 and 0.25 are mapped below with their real
state. Built: the six new alert types with `suggested_action` and `labels`
(engine, `vbx-cli` and the Alerts panel, vbx-fc7), `defer_until` in readiness
and in the app (vbx-upz), `.beads/recipes/*.yaml` recipe files — edited and
deleted in their own file (vbx-7d5) — the multi-repository loader, triage
feedback, `--export` reports in four formats (vbx-im9), `--search-min-score`
with bv's guaranteed exact-ID hit (vbx-52c) and its threshold control in the
app's search scope bar (vbx-c1j), `--recipe` as a robot scope,
by name or path (vbx-7d5), `.bv/hooks.yaml` export hooks with `--no-hooks`
in `vbx-cli` (vbx-uos), and `load_stats` in the robot envelope, counted in the
app's warnings badge (vbx-dv5), and bv's `.beads`-first workspace discovery
with `--workspace` (vbx-1y5), and the loader's warnings on `vbx-cli`'s
stderr where bv prints them (vbx-1l6). Nothing in epic vbx-htg is left unbuilt.
A row naming a bead is not built until that bead closes.

**Verified rather than asserted.** `scripts/parity-check.py` runs `vbx-cli` and
`bv` over the same workspace and diffs them command by command, stripping only
an enumerated list of volatile fields — timestamps, wall-clock durations,
absolute paths and build identity. It reports commands bv does not have and
commands vbx has not implemented as coverage gaps rather than skipping them
silently, and exits non-zero when any comparable command differs. It runs over
the demo fixture, over `Fixtures/readiness` — the readiness and blocking
cases bv 0.25 changed — both as JSONL and as a `beads.db`, because vbx reads
SQLite through its own loader rather than bv's, and over `Fixtures/sprints`,
the only one with sprints, where `--robot-sprint-show` and `--robot-burndown`
(at-risk beads included) are compared. `--robot-search` is compared in text
mode over the demo — thresholds at both bounds, between them and empty, and
five rejected values — and over `Fixtures/search`, whose text buries a bead
below a query for its own id, the case bv's exact-ID guarantee exists for.
`Fixtures/dropped`, as JSONL and as a `beads.db`, holds a malformed line and a
record that fails validation, so every envelope's `load_stats` is compared
there — and the clean fixtures prove it absent. `Fixtures/dropped-workspace`
puts a malformed line in one member of a two-repository workspace, where
`--robot-next` and `--robot-triage` are compared on bv's claim gate: no claim
and `source_authority_incomplete` when any member dropped a record.

Two known non-comparisons are declared in the harness rather than hidden:
`--robot-insights`, because bv inlines `analysis.Insights`' untagged PascalCase
fields at the top level, and `--robot-label-attention`, because bv projects a
ranked subset where vbx returns the full result.

Three known differences are declared too, on the `beads.db` form of the
readiness fixture only (ADR-024): `data_hash` (and `scope_hash`, which hashes
it) on `--robot-next`, `--robot-suggest`, `--robot-graph`, `--robot-capacity`
and the three label commands, and the
closed-time velocity in `--robot-label-health` and `--robot-triage`. bv 0.25.2
reads a `br` database through a lossy fallback that drops `closed_at`, notes
and design, and vbx deliberately does not copy it. Each is scoped to that
fixture, that command and that exact path, printed as `declared` rather than
as a match, compared normally on every JSONL fixture — and a declaration that
stops firing fails the run.

bv's `--label` is a global scope — the label's subgraph, its beads plus their
direct dependency neighbours — so the harness also runs label-scoped commands
over the demo. The engine applies that scope in one place (`Session.view`,
`scope.go`), and graph, triage, plan, priority, next, suggest, insights,
alerts and capacity all read it, so each is compared with a known label
(`engine`) and an unknown one (vbx-4cz, vbx-jnm, vbx-ko1); insights compares
its `full_stats`, since bv shapes its top level differently. So do the label
commands, the blocker chain, search and the sprint commands (vbx-shz): the
label commands and the blocker chain lift bv's envelope keys into the subtree
they compare, so `scope` and `scope_hash` are checked beside the data — as
triage and plan do since vbx-6su, and alerts and metrics compare them by key —
and the
sprint commands are compared over the sprints fixture with `at-risk`, an
unknown label, `actionable`, and `actionable` within `burndown`.
`test-parity-check.py` reads vbx-cli's command table and fails when a command
it scopes lacks a label, an unknown-label, a recipe or a recipe-and-label run. Alerts also take
bv's separate `--alert-label` filter, which keeps only the alerts naming the
label and is compared with `engine`, `ui` and an unknown label (vbx-jnm), and
capacity bv's `--capacity-label`, an exact-match filter on the beads simulated,
compared with the same three labels and once within the `ui` scope (vbx-ko1).
No label-scoped command is left unmatched.

`--recipe` is the same kind of scope, applied in the same step: the command
answers over what the recipe selects — of the label's beads, when both are
given — and the envelope names the recipe as given and hashes the selection
into `scope_hash`. The harness builds a `recipes` workspace from the demo's
beads plus two recipe files, one in `.beads/recipes` and one reached only by
its path, and runs the same commands with a built-in (`actionable`,
`high-impact`), the project-file recipe, the path, and three recipe-and-label
pairs; an unknown name and a missing path must be refused as bv refuses them
(vbx-7d5) — `--robot-correlation-stats` too, whose output reads neither flag
but whose recipe bv still resolves.

`--robot-diff`, `--robot-drift` and `--robot-forecast` are scoped too, in
bv's shapes (vbx-9gl). The diff compares the whole revision with the scope's
beads, tombstones dropped on both sides; drift is bv's `--check-drift
--robot-drift` — a fresh analysis of the scope against the saved baseline, no
envelope, and the verdict as the exit code; the forecast estimates the scope's
candidates, filtered by `--forecast-label` and `--forecast-sprint`. The harness
builds a `history` workspace for the first two — a git repository with
deterministic commits, and a baseline bv saves into it — and compares all three
unscoped and under a label, an unknown label, recipes, and both. A second copy,
`history (vbx baseline)`, carries a baseline `vbx-cli --save-baseline` saved,
so bv's drift check reads vbx's file as vbx's reads bv's; and `--save-baseline`
itself is compared inside the repository — the summary and the whole file, the
commit, subject and branch included (vbx-6s8).

The history correlation family is scoped too, and is bv's correlator itself
(vbx-k7j, ADR-027): history, related, impact-network, causality, orphans,
file-beads, file-hotspots, file-relations and impact. The engine carries bv's
`pkg/correlation` unchanged but for its git calls, which it answers from the
object store with the bytes git prints. Each report is built from the scope's
beads, as bv builds it. The harness compares 75 runs on the `history`
workspace: each command unscoped with bv's modifiers (`--history-limit`,
`--history-since`, `--min-confidence`, `--network-depth`,
`--related-min-relevance`, `--related-max-results`, `--related-include-closed`,
`--orphans-min-score`, `--file-beads-limit`, `--hotspots-limit`,
`--relations-threshold`, `--relations-limit`), each under every history scope,
and bv's "not found" errors. bv's `--bead-history` is not compared. On a beads
file under 64 KB it filters with a `\s` regex that macOS's regex engine reads
as a literal `s`, so a record written `"id": "x"` is never found. vbx always
takes the extraction bv itself uses above 64 KB, so `vbx-cli --robot-history
--id X` finds the record.

bv's `--id-pattern` is compared on the same workspace (vbx-znj). Its
`hist-q7x` is a `br`-shaped id, and a commit names it without touching the
beads. The harness runs history (unscoped and under `--label`), orphans
(with and without a minimum score), causality, related and file-beads with
one pattern, and again with two. It also checks bv's error and exit 2 for a
pattern that does not compile. Those runs set `BV_NO_CACHE=1`, because bv's
disk cache does not key on the patterns (ADR-027).

`--save-baseline` is the one post-load command still unscoped: bv saves the
scoped issues and vbx the whole workspace, so `vbx-cli` refuses `--label` and
`--recipe` with it (exit 2) rather than answer over every bead as if scoped.
Commands bv answers before it loads issues — the recipe list,
triage feedback — ignore both, as bv does.

A modifier given without a flag it modifies is refused as bv refuses it
(vbx-uao): `--history-limit` beside `--robot-orphans` is bv's `--history-limit
requires one of --robot-history, --bead-history or --robot-causality`, and exit
1 — bv's `modifierRules`, whose exit status is 1, not the 2 of a value it cannot
parse. `vbx-cli` holds bv's rules for every modifier it parses in one table,
`ModifierRules`, in bv's order (bv names the first rule broken), and prints its
`--help` from the same table. `test-parity-check.py` reads the table against
bv's own source at the go.mod version, and the harness compares one refusal per
rule plus the accepted pairings. Priority and suggest take bv's spellings
`--robot-by-label`, `--robot-by-assignee`, `--robot-max-results`,
`--robot-min-confidence` and `--suggest-confidence`; `--min-confidence` is the
history's alone, as in bv. Search, suggest and the graph take bv's spellings too
— `--search-limit`, `--suggest-bead`, `--graph-root` and `--graph-depth`, which
`vbx-cli` once called `--limit`, `--id`, `--root` and `--depth` — and
`--graph-root` roots triage and `--robot-next` as it does in bv. `--graph-format`
is held to bv's values by bv's enum rule, `EnumRules` beside `ModifierRules`: an
unknown value is bv's `invalid --graph-format "svg" (expected one of json, dot,
mermaid)`, with its "did you mean", and exit 1 (vbx-pfy).

The Phase numbers in the tables below are the original delivery plan and have
not been re-sequenced; treat them as intent, not as a claim about what exists.

**Mechanism legend**

| Mechanism | Meaning |
|---|---|
| **Engine** | Delivered by the reused Go engine through the bridge — no reimplementation, parity by construction |
| **Native** | New Swift/SwiftUI code (presentation only) |
| **Engine + Native** | Engine computes, native renders |
| **New** | A macOS-only capability with no `bv` equivalent |

---

## 1. Data Loading

| `bv` capability | `vbx` surface | Mechanism | Phase |
|---|---|---|---|
| `.beads/issues.jsonl` discovery order (`issues` → `beads` → `beads.base`) | Document open | Engine | 0 |
| SQLite `beads.db` read-only reader | Document open | Engine | 0 |
| `bd` workspace layout detection | Document open | Engine | 0 |
| `BEADS_DIR` override | Settings + env | Engine | 0 |
| BOM stripping, 10 MB line cap, malformed-line skip with warnings | Warnings banner in the window, expandable to a list | Engine + Native | 0 |
| `load_stats` (bv 0.25): valid / dropped / skipped record counts in every robot envelope when a load dropped records | `vbx-cli`: in every envelope vbx carries, JSONL, `beads.db` and workspace alike, compared against bv over `Fixtures/dropped` (vbx-dv5, ADR-023), triage, plan, alerts and metrics included (vbx-6su). App: the warnings badge states how many records were dropped | Engine + Native | — |
| Loader warnings on stderr outside robot mode (`Warning: skipping …`, a discovered workspace's notice, `N repos failed to load`) | `vbx-cli --export`, `--export-md`, `--feedback-accept` and `--feedback-ignore` print them before their own output, as bv does, though a verdict never prints the discovery notice because bv answers it before discovery (vbx-v1t); robot commands, `--feedback-show`, `--feedback-reset` and `BV_ROBOT=1` stay quiet. The engine's `info.load_stderr` holds the lines. Compared against bv over `Fixtures/dropped` as JSONL, `beads.db` and workspace (vbx-1l6) | Engine + Native | — |
| `source_authority` / `authority_hash` (bv 0.25 multi-source ranking) | Deliberately not ported — vbx resolves one source and ranks none; declared envelope-only in the parity harness (ADR-023, ADR-024) | — | — |
| Legacy field aliases (`depends_on`, `target_id`) | Transparent | Engine | 0 |
| Comment ID as UUIDv7 or legacy integer | Transparent | Engine | 0 |
| Multi-repo workspace (`.bv/workspace.yaml`) | Sidebar "Repos" section, repo picker; loader is vbx's port of bv's, held to it by `TestWorkspaceLoaderMatchesBV` | Engine + Native | 2 |
| `.bv/workspace.yaml` discovery: bv 0.25 uses it only when no `.beads` is reachable, `--workspace` overrides | ✓ bv's precedence in the engine, for `vbx-cli` and the app alike, and `vbx-cli --workspace FILE`; compared against bv from a root holding both, a member and a plain folder below a workspace, with and without `--workspace`. In the app, the aggregate of a folder that also has its own `.beads` is opened by choosing its `.bv/workspace.yaml` (vbx-1y5, ADR-026) | Engine | — |
| Repo auto-discovery, monorepo layouts | Workspace open flow | Engine | 2 |
| ID namespacing across repos | Displayed prefix badges on rows | Engine + Native | 2 |
| Cross-repository dependency edges | Graph edges styled as cross-repo | Engine + Native | 3 |
| Live reload (fsnotify + debounce) | FSEvents watcher, hash-gated reload | Native | 2 |
| Polling fallback (`BV_FORCE_POLLING`) | Auto-detected network volumes; Settings override | Native | 2 |
| Background snapshot worker | Always-on: the engine runs off the main actor by construction | Engine + Native | 1 |
| Automatic `.bv/` gitignore handling | Same behaviour, plus a Settings opt-out | Engine | 2 |
| Instance lock (`pkg/instance`) | Not needed — replaced by document-based single-window-per-workspace | Native | 2 |
| — | Security-scoped bookmarks so a workspace reopens without re-prompting | **New** | 2 |
| — | Recent Documents, drag-and-drop onto the Dock icon, Handoff | **New** | 2 |

---

## 2. Graph Analysis

All nine metrics are computed by the engine. `vbx` never reimplements one.

| Metric | `vbx` surface | Mechanism | Phase |
|---|---|---|---|
| In/out degree | List column, node encoding, badges | Engine + Native | 1 |
| Topological sort | Tree ranking, plan ordering, graph layer assignment | Engine + Native | 1 |
| Density | Insights panel, status bar | Engine + Native | 4 |
| PageRank | List column, node radius, insights panel with proof | Engine + Native | 4 |
| Betweenness (exact and sampled) | Insights panel, node ring, `approx` sample-size label | Engine + Native | 4 |
| HITS hubs / authorities | Insights panel | Engine + Native | 4 |
| Eigenvector centrality | Insights panel | Engine + Native | 4 |
| Critical path depth and slack | Insights panel, graph highlight of the critical chain | Engine + Native | 4 |
| Cycle detection (Tarjan SCC) | Alerts entry + graph SCC condensation with back-edge styling | Engine + Native | 3, 4 |
| k-core decomposition | Insights panel | Engine + Native | 4 |
| Articulation points | Node border encoding, insights panel | Engine + Native | 4 |
| Per-metric status (`computed` / `approx` / `timeout` / `skipped`) with elapsed ms | Rendered inline everywhere the metric appears; never shown as a zero | Engine + Native | 4 |
| Size-aware configuration and per-metric deadlines | Settings exposes the overrides `BV_SKIP_PHASE2` / `BV_PHASE2_TIMEOUT_S` provide | Engine | 4 |
| Data-hash memoisation and cache TTL | Transparent; hash shown in the status bar for verification | Engine | 1 |

---

## 3. Derived Analysis

| `bv` capability | `vbx` surface | Mechanism | Phase |
|---|---|---|---|
| Composite impact/triage scoring | List column + inspector score breakdown | Engine + Native | 4 |
| Priority recommendations with confidence | Insights panel, priority-hints overlay on the list | Engine + Native | 4 |
| Execution plan: actionable set, unblocks, tracks | Actionable Plan view with one lane per track | Engine + Native | 4 |
| Quick wins, blockers-to-clear, top picks | Triage section of the Insights dashboard | Engine + Native | 4 |
| Project health and counts | Header cards on the Insights dashboard | Engine + Native | 4 |
| Velocity (weekly) | Sprint dashboard chart | Engine + Native | 4 |
| Staleness | Node opacity, list column, alerts | Engine + Native | 4 |
| ETA forecasting per bead | Inspector "Forecast" section | Engine + Native | 4 |
| Capacity simulation | Sprint dashboard scenario panel | Engine + Native | 4 |
| Label health scores and levels | Label dashboard cards | Engine + Native | 4 |
| Cross-label flow matrix and bottleneck scores | Flow Matrix heat map with drill-down | Engine + Native | 4 |
| Label attention ranking | Attention view | Engine + Native | 4 |
| Alerts (drift + proactive health) | Alerts list, severity-grouped | Engine + Native | 4 |
| bv 0.25 alert types (`velocity_drop`, `high_impact_unblock`, `abandoned_claim`, `potential_duplicate`, `priority_mismatch`, `scope_creep`) with `suggested_action` and `labels` | **Built** — bv's `drift.Calculator` emits them through the engine and `vbx-cli`, parity-checked. The Alerts panel names each type with its own symbol (unknown types fall back to a generic one), shows `suggested_action` verbatim under each alert, `labels` as chips, and `related_issue_id` as a bead link; its label picker offers the bead labels `--alert-label` matches; a notification carries the action (vbx-fc7) | Engine + Native | — |
| Baseline save / show / drift check | Toolbar menu + Alerts integration | Engine + Native | 4 |
| Duplicate detection | Inspector "Possible duplicates" | Engine + Native | 4 |
| Dependency suggestions | Inspector "Suggested dependencies" | Engine + Native | 4 |
| Label suggestions | Inspector "Suggested labels" | Engine + Native | 4 |
| What-if analysis | Graph "what if this closes" mode | Engine + Native | 4 |
| Risk scoring | List column + insights | Engine + Native | 4 |
| Blocker chain | Inspector chain walk + graph path highlight | Engine + Native | 3 |
| Feedback system (adaptive recommendation weights) | **Applied:** `.beads/feedback.json` reweights triage, `--robot-next` and `--robot-priority` from 3 verdicts, and triage reports the `feedback` block; an edit to the file alone reloads (vbx-5ba). `vbx-cli` reads the working directory's `.beads`, as bv does, so from a folder below a workspace root it uses no feedback; the app reads and writes the root's (vbx-15s, ADR-026). **Recording, CLI:** `vbx-cli --feedback-accept` / `-ignore` / `-reset` / `-show`, through bv's own `FeedbackData`, output as bv's; parity-checked (vbx-rt3). **Recording, app:** Accept / Not now on each triage recommendation, a count line saying whether the weights apply yet, and Reset with confirmation, written in-process by the engine and re-ranked by the reload the write triggers (vbx-442) | Engine + Native | 4 |

---

## 4. Git Correlation and History

| `bv` capability | `vbx` surface | Mechanism | Phase |
|---|---|---|---|
| Bead ↔ commit correlation (co-commit, explicit id, temporal author) | History view — bv 0.25.2's own correlator, its git calls answered from the object store (ADR-027) | Engine + Native | 5 |
| `--id-pattern` (custom bead-id regexes for explicit-id matching and orphan detection) | ✓ `vbx-cli --id-pattern`, repeatable, bv's error and exit 2 (vbx-znj). The app registers one pattern per id prefix from `.beads/config.yaml` — an app-side default bv does not have (ADR-027) | Engine + Native | 5 |
| Confidence scoring | Confidence badges on each link | Engine + Native | 5 |
| Correlation feedback: explain / confirm / reject | Inline controls in the History view | Engine + Native | 5 |
| Correlation statistics | History view header | Engine + Native | 5 |
| Timeline panel | Custom `Canvas` timeline synced with the commit table | Engine + Native | 5 |
| Causality markers and causal-chain analysis | Inspector "Causal chain" section | Engine + Native | 5 |
| File-centric drill-down | File list → beads that touched it, with Quick Look on diffs | Engine + Native | 5 |
| File hotspots | History view "Hotspots" tab | Engine + Native | 5 |
| File relations | Relation graph in the History inspector | Engine + Native | 5 |
| Orphan commit detection | History view "Orphans" tab | Engine + Native | 5 |
| Impact network with clusters | Graph view "Impact network" mode | Engine + Native | 5 |
| Related-work discovery | Inspector "Related work" | Engine + Native | 5 |
| Incremental per-commit disk caches | Not used: the git extraction is cached in memory per session, keyed by HEAD (ADR-027); bv's disk caches stay off so a second binary never shares bv's files | Engine | 5 |
| cass session correlation + preview modal | Optional; sheet showing matched sessions | Engine + Native | 5 |
| Git subprocess usage | Replaced, in the app and `vbx-cli` alike, by `objgit`: each git command line bv's correlator runs is answered from the object store with git's own bytes (ADR-027) | Engine | 5 |

---

## 5. Views

| `bv` view | `vbx` surface | Mechanism | Phase |
|---|---|---|---|
| List view with virtualization | `NSTableView` via `NSViewRepresentable`, multi-select, sortable columns, per-cell editing | Native | 0 |
| Sort modes (default, created ↑/↓, priority, updated) | Column-header sorting + a Sort menu preserving `bv`'s exact orderings | Engine + Native | 0 |
| Filters: open / ready / closed / all | Sidebar filter section + toolbar segmented control | Engine + Native | 0 |
| Fuzzy search | `.searchable` field | Engine + Native | 0 |
| Semantic search + mode toggle | Search scope bar | Engine + Native | 2 |
| Hybrid search with weight presets | Weights popover | Engine + Native | 2 |
| Label picker | Sidebar labels section + `⌘K` | Native | 2 |
| Kanban board with swimlanes | Native board with drag-and-drop | Engine + Native | 2 |
| Board dependency indicators, column stats, card expansion | Card chrome and column headers | Engine + Native | 2 |
| Graph visualizer | Interactive vector canvas | Engine + Native | 3 |
| Tree view (parent-child) | `OutlineGroup` source list | Engine + Native | 2 |
| Insights dashboard, six panels | `Grid` + Swift Charts | Engine + Native | 4 |
| Calculation proofs (`x` key) | Expandable inspector section with substituted numbers | Engine + Native | 4 |
| Heatmap overlay (`m` key) | Chart heat maps + optional list-row tinting | Native | 4 |
| Explanations toggle (`e` key) | Persistent help text setting | Native | 4 |
| Actionable plan view | Track lanes | Engine + Native | 4 |
| Flow matrix + drilldown | Heat map + drill-down table | Engine + Native | 4 |
| Attention view | Ranked table with score bars | Engine + Native | 4 |
| Label dashboard | Health cards | Engine + Native | 4 |
| Sprint dashboard + burndown + at-risk | Swift Charts; scope-aware ideal line, at-risk rows from `analysis.DetectAtRisk`, scope-change list (bv 0.25.2) | Engine + Native | 4 |
| Velocity comparison | Chart | Engine + Native | 4 |
| History view (all modes) | See §4 | Engine + Native | 5 |
| Alerts panel (`!`) | Severity-grouped list | Engine + Native | 4 |
| Recipe picker (`'`) and recipe files | Sidebar section + form editor; `.beads/recipes/*.yaml` files listed through bv's own `recipe.Loader`, and an edit or delete of one goes to its own file (vbx-7d5) | Engine + Native | 2 |
| `defer_until` (bv 0.25 scheduler deferral) | **Built** — readiness, triage, plan and next honour it; `actionable` also names the beads a future deferral withholds, at the same pinned clock. The app shows "Deferred until" in the Inspector, a sortable *Deferred until* list column with a title-cell marker, and the count in the Ready filter's tooltip (vbx-upz) | Engine + Native | — |
| Repo picker (`w`) | Sidebar repos section | Engine + Native | 2 |
| Time-travel mode + diff badges + summary | Revision scrubber + row badges. **Not offered in a multi-repository workspace**, where the scrubber states why (ADR-028, vbx-bcq) | Engine + Native | 7 |
| Shortcuts sidebar (`;`) | Menu bar, `⌘/` shortcuts sheet, `⌘K` palette | Native | 2 |
| Help overlay (`?`) | Searchable Help menu | Native | 2 |
| Interactive tutorial with progress | Onboarding window with persisted progress | Native | 7 |
| Update modal | Sparkle 2 | Native | 7 |
| Agent prompt modal | Prompt-builder sheet | Engine + Native | 6 |
| Context-sensitive shortcut filtering | Palette scopes to the active view | Native | 2 |
| Adaptive layout engine (terminal size) | Native responsive layout, split-view collapse, full-screen | Native | 2 |
| Theme detection and colour profiles | System appearance, accent colour, contrast, colour-blind-safe palette | Native | 2 |
| — | Inspector pane with live bead detail | **New** | 2 |
| — | Multiple windows and native tabs over the same workspace | **New** | 2 |
| — | Quick Look integration for diffs and exports | **New** | 5 |
| — | Spotlight indexing of beads | **New** | 6 |
| — | Full VoiceOver support with chart descriptors and graph rotors | **New** | 7 |

---

## 6. Robot Protocol and Outputs

Every `--robot-*` command is available from `vbx-cli` with byte-identical output, verified by
the parity suite. The table marks where the GUI additionally surfaces the same data.

| `bv` command | `vbx-cli` | GUI surface | Phase |
|---|---|---|---|
| `--robot-triage`, `--robot-triage-by-track`, `--robot-triage-by-label` (+ `--graph-root`) | ✓ (`--robot-triage` takes `--graph-root`, vbx-pfy) | Insights triage section | 6 |
| `--robot-next` (+ `--graph-root`) | ✓ (claim command from the live tracker, CLI only — ADR-020) | "Next bead" toolbar action + Shortcuts intent | 6 |
| `--robot-plan` | ✓ | Actionable Plan view | 6 |
| `--robot-insights`, `--robot-metrics` | ✓ | Insights dashboard | 6 |
| `--robot-priority` | ✓ | Priority hints overlay | 6 |
| `--robot-impact`, `--robot-impact-network` (+ `--network-depth`, label and recipe scope) | ✓ bv's correlator (vbx-k7j) | Graph impact-network mode | 6 |
| `--robot-blocker-chain` | ✓ | Inspector chain walk | 6 |
| `--robot-related` (+ `--related-*`, label and recipe scope) | ✓ bv's correlator (vbx-k7j) | Inspector related work | 6 |
| `--robot-causality` (+ `--history-since`, label and recipe scope) | ✓ bv's correlator (vbx-k7j) | Inspector causal chain | 6 |
| `--robot-history` (+ `--history-limit`, `--history-since`, `--min-confidence`, label and recipe scope) | ✓ bv's correlator (vbx-k7j); bv's `--bead-history ID` is `vbx-cli --robot-history --id ID`. **Not built:** `--robot-history-timeout-ms` | History view | 6 |
| `--robot-file-beads`, `--robot-file-hotspots`, `--robot-file-relations` (+ their limits and threshold, label and recipe scope) | ✓ bv's correlator (vbx-k7j) | History file drill-down | 6 |
| `--robot-orphans` (+ `--orphans-min-score`, label and recipe scope) | ✓ bv's detector (vbx-k7j) | History orphans tab | 6 |
| `--robot-explain-correlation`, `--robot-confirm-correlation`, `--robot-reject-correlation`, `--robot-correlation-stats` | ✓ | History feedback controls | 6 |
| `--robot-search` (+ mode, preset, weights, `--search-limit`) | ✓ | Search field | 6 |
| `--search-min-score`, guaranteed exact-ID hit (bv 0.25) | ✓ through bv's `SearchTopKWithOptions`; `vbx-cli --search-min-score` with bv's validation and `min_score` echo (vbx-52c). In the app, a Min score menu in the search scope bar, hybrid mode only, off by default; a threshold that excludes everything says so in the empty list (vbx-c1j) | Search field (hybrid mode gets the exact-ID hit) + scope bar | 6 |
| `--robot-suggest` (+ `--suggest-type`, `--suggest-bead`, `--suggest-confidence`) | ✓ | Inspector suggestions | 6 |
| `--robot-forecast`, `--robot-capacity` (+ agents, forecast-label, forecast-sprint, capacity-label, label and recipe scope) | ✓ | Inspector forecast, sprint scenarios | 6 |
| `--robot-burndown`, `--robot-sprint-list`, `--robot-sprint-show` | ✓ | Sprint dashboard | 6 |
| `--robot-label-health`, `--robot-label-flow`, `--robot-label-attention` (+ label and recipe scope) | ✓ | Label dashboard, Flow matrix, Attention | 6 |
| `--robot-alerts` (+ severity, alert-type, alert-label, label scope) | ✓ | Alerts panel | 6 |
| `--robot-drift`, `--check-drift` (+ label and recipe scope; bv's exit code), baseline save/show | ✓ (`vbx-cli --save-baseline DESC` in bv's file format and prose, the commit read from the workspace's object store rather than a `git` process — vbx-6s8. **Not built:** `--label` / `--recipe` on the save, refused) | Alerts + baseline menu | 6 |
| `--robot-diff`, `--diff-since` (+ label and recipe scope), `--as-of` | ✓ (with `--workspace`, refused where bv reads the working directory's repository — a deliberate divergence, ADR-028) | Time-travel mode | 7 |
| `--robot-graph` (+ `--graph-format`, `--graph-root`, `--graph-depth`) | ✓ | Graph export menu | 6 |
| `--robot-recipes` | ✓ | Recipe sidebar | 6 |
| `--recipe <name or path.yaml>` as a global scope on robot commands (bv 0.25) | ✓ `vbx-cli` triage, next, plan, priority, insights, suggest, alerts, graph, capacity, the three label commands, blocker-chain, search, sprint-list, sprint-show, burndown, diff, drift and forecast, diff, drift, forecast and the nine history commands, alone or with `--label`, with `scope.recipe` and `scope_hash`; a path wherever a name goes (also `--robot-recipe-apply` and `--export`); an unknown recipe refused with bv's message and list. Matched in `parity-check.py` (vbx-7d5, vbx-shz, vbx-9gl, vbx-k7j). **Not built:** `--save-baseline`, which refuses either flag | Recipe sidebar applies by name | — |
| `--robot-by-label`, `--robot-by-assignee` | ✓ (refused beside any command but `--robot-priority`, as in bv — vbx-uao) | Grouping controls | 6 |
| `--robot-capabilities`, `--robot-schema`, `--robot-docs`, `--robot-help` | ✓ | Help menu → "Robot protocol reference" | 6 |
| `--robot-not-ready-labels` (+ `BV_ROBOT_NOT_READY_LABELS`), `--robot-max-results`, `--robot-min-confidence` | ✓ (not-ready labels on triage and `--robot-next`, as in bv; the other two read by `--robot-priority`) | Corresponding UI controls | 6 |
| `--feedback-accept ID`, `--feedback-ignore ID`, `--feedback-reset`, `--feedback-show` (not robot commands: bv prints prose and writes `.beads/feedback.json`) | ✓ (vbx-rt3; two at once is a usage error where bv picks one; answered before workspace discovery and `--workspace`, over the folder's own `.beads`, as bv does — vbx-v1t, ADR-026) | Triage panel: Accept / Not now per recommendation, feedback count line, Reset (vbx-442) | 6 |
| TOON token-optimised encoding | ✓ | — | 6 |
| Data hash + config echoed in every payload | ✓ | Status bar shows the hash | 6 |
| — | App Intents / Shortcuts actions | **New** | 6 |
| — | `vbx://` URL scheme deep links | **New** | 6 |

---

## 7. Exports and Integration

| `bv` capability | `vbx` surface | Mechanism | Phase |
|---|---|---|---|
| `--export-md` Markdown report with Mermaid | `vbx-cli --export-md`; in the app, File → Export Report (`⌘⇧E`) with Markdown chosen | Engine + Native | 7 |
| `--export` with `--export-format` (markdown, json, csv or mermaid), `--export-template`, `--export-include-graph`, recipe export defaults (bv 0.25, `export.GenerateReport`) | ✓ `vbx-cli` with bv's flags, `--recipe` and `--label`; the engine's `export_report`; File → Export Report sheet (format, graph, template). Byte-identical to bv in `parity-check.py`, except the JSON report's `source_authority` (§9) (vbx-im9) | Engine + Native | — |
| Priority brief, agent brief bundle | Export submenu | Engine + Native | 7 |
| `--export-graph` interactive HTML | Export submenu; opens in the browser | Engine | 7 |
| Static site export wizard | Native multi-step sheet | Engine + Native | 7 |
| Static site preview / `--watch-export` | Preview window + live reload | Engine + Native | 7 |
| GitHub Pages deploy | Deploy sheet; token in the Keychain | Engine + Native | 7 |
| Cloudflare deploy | Deploy sheet; token in the Keychain | Engine + Native | 7 |
| WASM hybrid search scorer for the static bundle | Built and embedded as `bv` does | Engine | 7 |
| Graph snapshots (SVG/PNG) | Export + drag-out from the canvas + Share sheet | Engine + Native | 3 |
| Shell script emission | Export submenu; copy to clipboard | Engine + Native | 7 |
| Hooks around export phases (`.bv/hooks.yaml`, `--no-hooks`) | ✓ `vbx-cli --export` / `--export-md` run bv's own `pkg/hooks` around the write — pre-export before it (a failure aborts, exit 1), post-export after it (`on_error: fail` exits 1 after the summary), bv's `BV_*` environment with credential-bearing variables scrubbed — and `--no-hooks` skips them. Output, exit status, file and each hook's effects match bv in `parity-check.py` (vbx-uos). **Security:** a hook is a command the repository configures, run through `sh -c` with your user's rights — exactly as bv runs it, so exporting in an untrusted checkout runs its commands; pass `--no-hooks` there. The app runs none (§9) | Engine + Native | — |
| `AGENTS.md` / `CLAUDE.md` blurb management | Menu item "Add bv blurb to AGENTS.md" | Engine + Native | 7 |
| Self-update engine | Sparkle 2 with a signed appcast | Native | 7 |

---

## 8. Configuration

| `bv` environment variable | `vbx` equivalent | Notes |
|---|---|---|
| `BEADS_DIR` | Honoured; also a per-document setting | |
| `BV_BACKGROUND_MODE` | Not needed — always off the main actor | |
| `BV_FORCE_POLLING` / `BV_FORCE_POLL` | Settings → "Force polling for file changes" | Auto-detected for network volumes |
| `BV_DEBOUNCE_MS` | Settings (advanced) | Default 200 ms |
| `BV_CHANNEL_BUFFER`, `BV_HEARTBEAT_INTERVAL_S`, `BV_WATCHDOG_INTERVAL_S` | Not applicable — replaced by structured concurrency | |
| `BV_FRESHNESS_WARN_S` / `BV_FRESHNESS_STALE_S` | Status-bar freshness indicator thresholds | |
| `BV_MAX_LINE_SIZE_MB` | Settings (advanced) | |
| `BV_NO_GITIGNORE` | Settings → "Manage .bv/ ignore entries" | |
| `BV_SKIP_PHASE2` | Settings → "Skip expensive metrics" | |
| `BV_PHASE2_TIMEOUT_S` | Settings (advanced) | |
| `BV_SEMANTIC_EMBEDDER` / `BV_SEMANTIC_DIM` / `BV_SEMANTIC_MODEL` | Settings → Search → Embedding provider | Adds an on-device Core ML option |
| `~/.config/bv/config.yaml` | Read for compatibility; `vbx` writes its own `UserDefaults` | Shared workspace/recipe files stay canonical |

---

## 9. Deliberate Divergences

These are the only places `vbx` intentionally differs from `bv`. Each is a considered
decision, not an omission.

| Divergence | Reason |
|---|---|
| No instance lock file | Document-based apps handle single-workspace-per-window natively; the lock exists to arbitrate terminal instances |
| No background-mode toggle | `vbx` is always asynchronous; the flag exists in `bv` because Bubble Tea is single-threaded |
| Terminal single-key shortcuts are opt-out, not the only binding | macOS users expect menu-driven `⌘` shortcuts; both are provided ([design doc §10.3](VBX_DESIGN.md#103-keyboard-model)) |
| Correlation reads the git object store directly, in the app and `vbx-cli` | The App Sandbox cannot spawn `git`. bv's own correlator runs unchanged; only its git calls are answered in-process, byte for byte (ADR-027) |
| Optional Core ML embedder for semantic search | Better on-device quality, but off by default because it changes ranking relative to the CLI |
| The app runs no export hooks | A hook is a repository-configured subprocess the App Sandbox forbids; the engine runs them only for a session opened with `export_hooks`, which only `vbx-cli` sets (vbx-uos). `vbx-cli` retains full behaviour |
| ASCII sparklines and heatmaps become real charts | The whole point of a native UI |
| `--robot-metrics` reports GraphStats, not runtime timings, and scopes them | bv's payload is its own timings, cache and memory figures, which describe bv's process rather than the graph. vbx's is the GraphStats the app's metrics view decodes. Under `--label`/`--recipe` the envelope carries bv's `scope` and `scope_hash`, and the GraphStats are the scoped view's, as every other scoped command's analysis is. An envelope that names a scope over whole-load statistics would read as a scoped answer without being one. The app asks unscoped and still gets the whole load (vbx-h48, ADR-023) |
| No `source_authority` / `authority_hash` in the robot envelope | vbx resolves one source and ranks none, so a ported report would assert checks it never ran (ADR-023); vbx also keeps its own read of a `beads.db` (ADR-024) |
