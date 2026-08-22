# vbx — Feature Parity Matrix

| Field | Value |
|---|---|
| **Status** | Living document — the Phase column is the *plan*, not the build state |
| **Date** | 2026-08-20 |
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

**Verified rather than asserted.** `scripts/parity-check.py` runs `vbx-cli` and
`bv` over the same workspace and diffs them command by command, stripping only
an enumerated list of volatile fields — timestamps, wall-clock durations,
absolute paths and build identity. It reports commands bv does not have and
commands vbx has not implemented as coverage gaps rather than skipping them
silently, and exits non-zero when any comparable command differs.

Two known non-comparisons are declared in the harness rather than hidden:
`--robot-insights`, because bv inlines `analysis.Insights`' untagged PascalCase
fields at the top level, and `--robot-label-attention`, because bv projects a
ranked subset where vbx returns the full result.

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
| Legacy field aliases (`depends_on`, `target_id`) | Transparent | Engine | 0 |
| Comment ID as UUIDv7 or legacy integer | Transparent | Engine | 0 |
| Multi-repo workspace (`.bv/workspace.yaml`) | Sidebar "Repos" section, repo picker | Engine + Native | 2 |
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
| Baseline save / show / drift check | Toolbar menu + Alerts integration | Engine + Native | 4 |
| Duplicate detection | Inspector "Possible duplicates" | Engine + Native | 4 |
| Dependency suggestions | Inspector "Suggested dependencies" | Engine + Native | 4 |
| Label suggestions | Inspector "Suggested labels" | Engine + Native | 4 |
| What-if analysis | Graph "what if this closes" mode | Engine + Native | 4 |
| Risk scoring | List column + insights | Engine + Native | 4 |
| Blocker chain | Inspector chain walk + graph path highlight | Engine + Native | 3 |
| Feedback system (adaptive recommendation weights) | Thumbs up/down on recommendations | Engine + Native | 4 |

---

## 4. Git Correlation and History

| `bv` capability | `vbx` surface | Mechanism | Phase |
|---|---|---|---|
| Bead ↔ commit correlation (explicit, co-commit, file, temporal) | History view | Engine + Native | 5 |
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
| Incremental per-commit disk caches | Transparent, under `~/Library/Caches/vbx` | Engine | 5 |
| cass session correlation + preview modal | Optional; sheet showing matched sessions | Engine + Native | 5 |
| Git subprocess usage | Replaced by direct object-store reads inside the sandbox; the CLI keeps the subprocess path | Engine | 5 |

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
| Sprint dashboard + burndown + at-risk | Swift Charts | Engine + Native | 4 |
| Velocity comparison | Chart | Engine + Native | 4 |
| History view (all modes) | See §4 | Engine + Native | 5 |
| Alerts panel (`!`) | Severity-grouped list | Engine + Native | 4 |
| Recipe picker (`'`) and recipe files | Sidebar section + form editor | Engine + Native | 2 |
| Repo picker (`w`) | Sidebar repos section | Engine + Native | 2 |
| Time-travel mode + diff badges + summary | Revision scrubber + row badges | Engine + Native | 7 |
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
| `--robot-triage`, `--robot-triage-by-track`, `--robot-triage-by-label` | ✓ | Insights triage section | 6 |
| `--robot-next` | ✓ | "Next bead" toolbar action + Shortcuts intent | 6 |
| `--robot-plan` | ✓ | Actionable Plan view | 6 |
| `--robot-insights`, `--robot-metrics` | ✓ | Insights dashboard | 6 |
| `--robot-priority` | ✓ | Priority hints overlay | 6 |
| `--robot-impact`, `--robot-impact-network` | ✓ | Graph impact-network mode | 6 |
| `--robot-blocker-chain` | ✓ | Inspector chain walk | 6 |
| `--robot-related` | ✓ | Inspector related work | 6 |
| `--robot-causality` | ✓ | Inspector causal chain | 6 |
| `--robot-history` (+ `--robot-history-timeout-ms`) | ✓ | History view | 6 |
| `--robot-file-beads`, `--robot-file-hotspots`, `--robot-file-relations` | ✓ | History file drill-down | 6 |
| `--robot-orphans` | ✓ | History orphans tab | 6 |
| `--robot-explain-correlation`, `--robot-confirm-correlation`, `--robot-reject-correlation`, `--robot-correlation-stats` | ✓ | History feedback controls | 6 |
| `--robot-search` (+ mode, preset, weights, limit) | ✓ | Search field | 6 |
| `--robot-suggest` (+ type, bead, confidence) | ✓ | Inspector suggestions | 6 |
| `--robot-forecast`, `--robot-capacity` | ✓ | Inspector forecast, sprint scenarios | 6 |
| `--robot-burndown`, `--robot-sprint-list`, `--robot-sprint-show` | ✓ | Sprint dashboard | 6 |
| `--robot-label-health`, `--robot-label-flow`, `--robot-label-attention` | ✓ | Label dashboard, Flow matrix, Attention | 6 |
| `--robot-alerts` (+ severity, type, label) | ✓ | Alerts panel | 6 |
| `--robot-drift`, `--check-drift`, baseline save/show | ✓ | Alerts + baseline menu | 6 |
| `--robot-diff`, `--diff-since`, `--as-of` | ✓ | Time-travel mode | 7 |
| `--robot-graph` (+ format, root, depth) | ✓ | Graph export menu | 6 |
| `--robot-recipes` | ✓ | Recipe sidebar | 6 |
| `--robot-by-label`, `--robot-by-assignee` | ✓ | Grouping controls | 6 |
| `--robot-capabilities`, `--robot-schema`, `--robot-docs`, `--robot-help` | ✓ | Help menu → "Robot protocol reference" | 6 |
| `--robot-not-ready-labels`, `--robot-max-results`, `--robot-min-confidence` | ✓ | Corresponding UI controls | 6 |
| TOON token-optimised encoding | ✓ | — | 6 |
| Data hash + config echoed in every payload | ✓ | Status bar shows the hash | 6 |
| — | App Intents / Shortcuts actions | **New** | 6 |
| — | `vbx://` URL scheme deep links | **New** | 6 |

---

## 7. Exports and Integration

| `bv` capability | `vbx` surface | Mechanism | Phase |
|---|---|---|---|
| `--export-md` Markdown report with Mermaid | File → Export → Markdown Report (`⌘⇧E`) | Engine + Native | 7 |
| Priority brief, agent brief bundle | Export submenu | Engine + Native | 7 |
| `--export-graph` interactive HTML | Export submenu; opens in the browser | Engine | 7 |
| Static site export wizard | Native multi-step sheet | Engine + Native | 7 |
| Static site preview / `--watch-export` | Preview window + live reload | Engine + Native | 7 |
| GitHub Pages deploy | Deploy sheet; token in the Keychain | Engine + Native | 7 |
| Cloudflare deploy | Deploy sheet; token in the Keychain | Engine + Native | 7 |
| WASM hybrid search scorer for the static bundle | Built and embedded as `bv` does | Engine | 7 |
| Graph snapshots (SVG/PNG) | Export + drag-out from the canvas + Share sheet | Engine + Native | 3 |
| Shell script emission | Export submenu; copy to clipboard | Engine + Native | 7 |
| Hooks around export phases | Full support in `vbx-cli`; in the sandboxed app via user-approved tasks | Engine + Native | 7 |
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
| Correlation reads the git object store directly in the sandboxed app | The App Sandbox cannot spawn `git`; the CLI keeps the subprocess path |
| Optional Core ML embedder for semantic search | Better on-device quality, but off by default because it changes ranking relative to the CLI |
| Shell hooks restricted under the sandbox | Sandbox policy; `vbx-cli` retains full behaviour |
| ASCII sparklines and heatmaps become real charts | The whole point of a native UI |
