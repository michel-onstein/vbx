#!/usr/bin/env python3
"""Diff vbx-cli's robot output against bv's, command by command.

The point of this script is that it makes "vbx agrees with bv" a checked claim
rather than an assertion. It runs both binaries over the same workspace and
compares the substantive payloads.

Two things make a naive diff useless, and both are handled explicitly rather
than by loosening the comparison until it passes:

*Volatile fields.* A timestamp, a wall-clock duration or an absolute path
differs between two runs of the *same* binary. Those keys are enumerated in
VOLATILE_KEYS and stripped from both sides before comparing. The list is
deliberately short and specific: dropping `data_hash` would hide exactly the
class of bug this script exists to catch.

Every analysis reads SOURCE_DATE_EPOCH as "now" — triage, priority, label
health, alerts and the rest, in bv 0.23+ and in vbx alike — so pinning it makes
staleness deterministic on both sides. Floats are still compared with a
relative tolerance rather than rounded — rounding has boundaries, and values
landing either side of one compare unequal however close they are.

*Different envelopes.* bv wraps most payloads in a header that vbx returns
bare — `bv --robot-label-flow` yields `{generated_at, data_hash, flow, …}`
where vbx yields the flow itself. Rather than pretend those are equal, each
command declares which subtree to compare on each side. Where vbx does carry
the envelope it carries bv's provenance keys too, except the two listed in
ENVELOPE_ONLY_KEYS with their reasons — one list for every command.

*Declared differences.* A few differences are decisions rather than bugs:
on a br beads.db bv 0.25.2 falls back to a lossy read that vbx deliberately
does not copy (ADR-024). Those are listed in DECLARED_DIFFERENCES, each scoped
to one fixture, one command and one exact path, and reported as `declared` —
never as a match. The same paths are compared on every other fixture, any
other difference still fails, and a declaration that stops firing fails too.

*More than one workspace.* The demo fixture exercises none of the readiness
and blocking cases bv 0.25 changed — custom statuses, `waits-for` and
`conditional-blocks`, `defer_until`, a missing blocker, parent-child gating, a
tombstoned blocker — which is how numbers moved under the engine bump while
every check stayed green. So the run covers every workspace in FIXTURES: the
demo, `Fixtures/readiness`, the same readiness beads as a `beads.db`, built
at run time by `build_sqlite_workspace` because vbx reads SQLite through its
own loader rather than bv's, `Fixtures/sprints`, the only one with sprints
for the burndown and sprint commands to read, and `Fixtures/feedback` and
`Fixtures/feedback-few`, the only ones with a triage feedback file — one with
enough verdicts for bv to apply its weights and one without, and
`Fixtures/search`, whose text buries a bead below a query for its own id — the
case bv's guaranteed exact-id hit exists for — and which runs only the search
comparisons, and `Fixtures/dropped`, as JSONL and as a beads.db, whose
malformed line and invalid record make every envelope carry `load_stats`. `--workspace` narrows the run to one.

Each differing command reports its first difference and how many more there
are; `--verbose` lists every one.

*Which bv.* The comparison is only meaningful against the bv the engine is
built on — the beads_viewer version in Engine/bridge/go.mod. A bv from another
release disagrees wherever upstream changed its output between the two, and
every such change reads as a vbx bug. So the run reads `bv --version` first
and, when it does not match (or cannot be read), says so at the top and in the
summary, naming both versions and the binary's path, and compares nothing:
every command is reported as skipped and the run exits 1. A missing bv is
skipped too, but exits 0 as before — nothing was claimed either way.
`--allow-bv-mismatch` runs the comparisons anyway, still under the warning,
for deliberately measuring what an upgrade would change.

Exit status is 0 when every comparable command agrees, 1 when any differs.
Commands bv does not have, and commands vbx has not implemented, are reported
as coverage gaps rather than silently skipped — a harness that only checks the
easy half is worse than none.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

# Why the dropped-records fixtures skip the feedback comparisons.
_NO_LOAD_WARNINGS = "vbx-cli prints no loader warnings to stderr where bv does (vbx-1l6)"

# The workspaces every default run covers. A `sqlite` entry is the named
# fixture's JSONL rebuilt as a beads.db in a temporary directory, so the run
# reaches the SQLite loader too: vbx carries its own (Engine/bridge/engine/
# sqlite.go, since bv's is internal), and a JSONL-only check cannot see it.
FIXTURES = [
    {"name": "demo", "workspace": "Fixtures/demo"},
    {"name": "readiness", "workspace": "Fixtures/readiness"},
    {"name": "readiness (beads.db)", "workspace": "Fixtures/readiness", "sqlite": True},
    # Sprints of its own rather than in the demo, whose numbers every other
    # comparison depends on. Sprint 2 spans PINNED_CLOCK and holds a bead of
    # each at-risk signal, a reopened bead with a stale closed_at, a tombstone
    # and an id no bead has.
    {"name": "sprints", "workspace": "Fixtures/sprints"},
    # Triage feedback (.beads/feedback.json), which bv applies to triage, next
    # and priority once it holds MinFeedbackSamples (3) verdicts. The same
    # beads twice: with four verdicts, whose weights put fb-5 above the hub
    # fb-1, and with two, which bv reports but does not apply (vbx-5ba).
    {"name": "feedback", "workspace": "Fixtures/feedback"},
    {"name": "feedback-few", "workspace": "Fixtures/feedback-few"},
    # Search beads (vbx-52c): decoys whose text is all "tax 7", which bury the
    # bead whose id is tax-7 below the text top-K, and two ids that differ
    # only in case. Built for --robot-search alone, so it is `only_named`:
    # just the comparisons whose `only` names it run here, and every other is
    # reported skipped rather than compared over beads not made for it.
    {"name": "search", "workspace": "Fixtures/search", "only_named": True},
    # The demo's beads in a temporary directory beside two recipe files
    # (RECIPE_FILES): one in .beads/recipes, which bv loads by name, and one
    # outside it, reached only by its path. Built here rather than committed,
    # because a recipe in the demo would change what the app lists there.
    # `only_named`: only the recipe-scope comparisons run over it (vbx-7d5).
    {"name": "recipes", "workspace": "Fixtures/demo", "recipes": True, "only_named": True},
    # Dropped records (vbx-dv5): four valid beads, a line cut off mid-record
    # and a record whose updated_at precedes its created_at. Every command
    # runs over it, so each envelope bv gives `load_stats` is compared — the
    # clean fixtures above prove the key stays absent when nothing dropped.
    # As a beads.db the malformed line never becomes a row, and the invalid
    # one is dropped by the SQLite loaders instead. `skip_feedback`: bv's
    # feedback commands print the loader's warnings to stderr and vbx-cli's do
    # not (vbx-1l6), which is not what this fixture is for.
    {"name": "dropped", "workspace": "Fixtures/dropped", "skip_feedback": _NO_LOAD_WARNINGS},
    {"name": "dropped (beads.db)", "workspace": "Fixtures/dropped", "sqlite": True,
     "skip_feedback": _NO_LOAD_WARNINGS},
]

# The recipe files of the `recipes` fixture, by path relative to the
# workspace — which is both binaries' working directory, so the path recipe is
# given exactly as written here. `ui-open` is a project-file recipe, filtering
# on status and a label. `hub-first.yml` sorts on PageRank, so its metrics
# must be the whole source's, and caps at four, so the selection is cut.
RECIPE_FILES = {
    ".beads/recipes/ui-open.yaml":
        "name: ui-open\ndescription: Open UI work\n"
        "filters:\n  status: [open]\n  tags: [ui]\nsort:\n  field: priority\n",
    "hub-first.yml":
        "name: hub-first\ndescription: The most central unfinished beads\n"
        "filters:\n  status: [open, in_progress, blocked]\n"
        "sort:\n  field: pagerank\n  direction: desc\nview:\n  max_items: 4\n",
}

# br's issues columns, in br's order. A beads.db built here has the column
# shape a real one has — including the ones neither loader reads — so a loader
# that silently skips a column (defer_until) or filters on one (deleted_at) is
# exercised exactly as it would be on a user's database.
BR_ISSUE_COLUMNS = [
    "id", "content_hash", "title", "description", "design", "acceptance_criteria",
    "notes", "status", "priority", "issue_type", "assignee", "owner",
    "estimated_minutes", "created_at", "created_by", "updated_at", "closed_at",
    "close_reason", "closed_by_session", "due_at", "defer_until", "external_ref",
    "source_system", "source_repo", "deleted_at", "deleted_by", "delete_reason",
    "original_type", "compaction_level", "compacted_at", "compacted_at_commit",
    "original_size", "sender", "ephemeral", "pinned", "is_template",
    "source_repo_path", "agent_context", "prerequisites",
]

# Both binaries read SOURCE_DATE_EPOCH as "now". Pinning it is what makes the
# comparison exact: staleness is measured from the current instant, so two
# processes a second apart legitimately disagree in the sixth decimal — and a
# tolerance wide enough to absorb that is wide enough to hide a real
# difference. The value is after the fixture's bead dates, so staleness is a
# real number rather than uniformly zero.
PINNED_CLOCK = "1788000000"  # 2026-08-29T10:40:00Z

# Keys whose values legitimately differ between two runs. Nothing derived from
# the bead data belongs here.
VOLATILE_KEYS = {
    "generated_at",  # wall clock
    "computed_at",  # wall clock
    "detected_at",  # wall clock
    "loaded_at",  # wall clock
    "compute_time_ms",  # timing
    "ms",  # timing
    "elapsed_ms",  # timing
    "source",  # absolute path
    "path",  # absolute path
    "config_path",  # absolute path
    "index_path",  # absolute path
    "output_dir",  # absolute path
    "version",  # build identity
    "contract_version",  # build identity
    "usage_hints",  # prose, tuned per tool
    "commands",  # copy-paste helpers naming the tool itself
    "history_status",  # depends on whether a git walk was reachable
}

# bv envelope keys vbx deliberately does not emit, each with its reason. This
# is the only place the harness drops a key for being bv's alone, and it
# applies to every command: each is removed from the top level of both whole
# outputs before any subtree is taken. A nested key of the same name is data
# and is still compared.
#
# The rest of bv 0.25's provenance envelope — output_format, source_path,
# source_kind, scope_hash — vbx ports (ADR-023), so it is compared like any
# other field. Where vbx and bv read different sources in the same workspace,
# those keys differ honestly: vbx keeps its own source choice (ADR-024).
ENVELOPE_ONLY_KEYS = {
    "source_authority": "bv's multi-source selection report (freshness ranking,"
                        " stale fallback); vbx ranks no sources (ADR-024), ADR-023",
    "authority_hash": "a hash of source_authority, so it goes wherever that goes",
}

# Differences vbx accepts rather than fixes, each scoped to one fixture, one
# command and one exact difference path, with its reason. This is the only
# place the harness tolerates a difference in data: a declared path is ignored
# on its own fixture and compared everywhere else, and any other difference on
# that fixture still fails. Each one is reported as `declared`, never as a
# match, and a declaration that stops firing fails the run — that is the
# signal to revisit the decision behind it.
#
# bv 0.25.2 reads a br beads.db through a main query that selects due_date and
# tombstone, which br's schema lacks (br has due_at). It falls back to
# loadIssuesSimple, which drops closed_at, notes, design, source_repo and
# dependency timestamps. vbx keeps reading every column (ADR-024), so on a
# beads.db the fingerprint and the closed-time velocity differ by design.
_LOSSY_HASH = "bv hashes its lossy fallback read of br's beads.db; vbx reads every column (ADR-024)"
_LOSSY_SCOPE = "hashes data_hash, so it follows it (ADR-024)"
DECLARED_DIFFERENCES = {
    "readiness (beads.db)": {
        ("robot-label-health", ".labels[0].velocity.avg_days_to_close"):
            "bv's fallback read has no closed_at, so it skips the closed bead and averages"
            " an int 0; vbx averages its real close time (ADR-024)",
        ("robot-label-health", ".data_hash"): _LOSSY_HASH,
        ("robot-label-health", ".scope_hash"): _LOSSY_SCOPE,
        ("robot-label-flow", ".data_hash"): _LOSSY_HASH,
        ("robot-label-flow", ".scope_hash"): _LOSSY_SCOPE,
        ("robot-label-attention", ".data_hash"): _LOSSY_HASH,
        ("robot-label-attention", ".scope_hash"): _LOSSY_SCOPE,
        ("robot-triage", ".project_health.velocity.estimated"):
            "bv's fallback read has no closed_at, so it estimates close times from"
            " updated_at; vbx reads closed_at and estimates nothing (ADR-024)",
        ("robot-suggest", ".data_hash"): _LOSSY_HASH,
        ("robot-suggest", ".suggestions.data_hash"): _LOSSY_HASH,
        ("robot-suggest", ".scope_hash"): _LOSSY_SCOPE,
        ("robot-graph", ".data_hash"): _LOSSY_HASH,
        ("robot-graph", ".scope_hash"): _LOSSY_SCOPE,
        ("robot-next", ".data_hash"): _LOSSY_HASH,
        ("robot-next", ".scope_hash"): _LOSSY_SCOPE,
        ("robot-capacity", ".data_hash"): _LOSSY_HASH,
        ("robot-capacity", ".scope_hash"): _LOSSY_SCOPE,
        ("robot-capacity --agents 3", ".data_hash"): _LOSSY_HASH,
        ("robot-capacity --agents 3", ".scope_hash"): _LOSSY_SCOPE,
    },
    # The dropped-records beads as a beads.db (vbx-dv5) are there for
    # load_stats, which matches; their fingerprint differs as every beads.db's
    # does. Its beads have no closed one, so no velocity differs as well.
    "dropped (beads.db)": {
        (command, path): reason
        for command in ("robot-label-flow", "robot-label-health", "robot-label-attention",
                        "robot-suggest", "robot-graph", "robot-next", "robot-capacity",
                        "robot-capacity --agents 3")
        for path, reason in ((".data_hash", _LOSSY_HASH), (".scope_hash", _LOSSY_SCOPE))
    } | {("robot-suggest", ".suggestions.data_hash"): _LOSSY_HASH},
}


def difference_path(difference: str) -> str:
    """The path a describe_differences line is about — the text before ': '."""
    return difference.split(": ", 1)[0]


def split_declared(differences: list[str], fixture: str, command: str
                   ) -> tuple[list[str], list[tuple[str, str]], list[str]]:
    """Separates one command's differences into undeclared and declared.

    Returns (undeclared, declared, stale): `declared` pairs each difference
    with its reason, and `stale` lists the paths declared for this fixture and
    command that did not differ — a declaration that no longer fires.
    """
    declarations = {
        path: reason
        for (name, path), reason in DECLARED_DIFFERENCES.get(fixture, {}).items()
        if name == command
    }
    undeclared: list[str] = []
    declared: list[tuple[str, str]] = []
    fired: set[str] = set()
    for difference in differences:
        path = difference_path(difference)
        if path in declarations:
            declared.append((difference, declarations[path]))
            fired.add(path)
        else:
            undeclared.append(difference)
    stale = sorted(set(declarations) - fired)
    return undeclared, declared, stale

# Go's zero time.Time as bv's JSON encoder writes it. See strip_bv_zero_times.
GO_ZERO_TIME = "0001-01-01T00:00:00Z"

# model.Sprint's `omitzero` timestamps, which bv writes anyway.
SPRINT_OMITZERO = {"created_at", "updated_at"}

# How each command lines up. `bv_path` and `vbx_path` name the subtree to
# compare, as a dotted path; None means the whole payload. `vbx_args` and
# `bv_args` follow the flag on each side — the two spell a value differently.
# `only` names the fixtures a command is compared over, for one that needs data
# only some fixtures hold; elsewhere it is reported as skipped, never passed.
# `bv_lift` copies top-level bv keys into the compared subtree (see lift), and
# `env` is given to both binaries. `keys` compares only those top-level keys of
# each side's subtree, a key absent on both staying absent. `rejects` expects
# both binaries to refuse the arguments, and compares the exit status and the
# first line of stderr — vbx-cli adds a pointer to --help after it.
#
# Triage's `feedback` block is lifted on every run, so a fixture with no
# feedback.json proves vbx emits none, as well as the feedback fixtures
# proving it emits bv's.
TRIAGE_PATHS = {"bv_path": "triage", "bv_lift": ("feedback",)}
# What a search comparison compares: the ranking and the request it echoes.
SEARCH_KEYS = ("query", "mode", "limit", "min_score", "results")
NOT_READY = "needs-design"
# bv's envelope keys that say what a payload was computed over (vbx-shz). A
# command whose vbx payload is the analysis result itself, with the envelope
# at its top level, lifts these from bv's top level into the subtree it
# compares, so the scope and its hash are checked beside the data.
ENVELOPE_KEYS = ("data_hash", "scope", "scope_hash", "output_format", "source_path",
                 "source_kind", "load_stats")
LABEL_HEALTH_PATHS = {"bv_path": "results", "bv_lift": ENVELOPE_KEYS}
LABEL_FLOW_PATHS = {"bv_path": "flow", "bv_lift": ENVELOPE_KEYS}
# bv projects a ranked subset of the attention scores, cut at
# --attention-limit; vbx returns them all. The count and the envelope are
# what the two share.
LABEL_ATTENTION_PATHS = {"keys": ("total_labels", *ENVELOPE_KEYS)}
# bv nests the chain under `result`; vbx returns it beside the envelope. The
# target is vbx-6, which two blockers hold, labelled graph and ui.
BLOCKER_CHAIN = "vbx-6"
BLOCKER_CHAIN_RUN = {"vbx_args": ["--id", BLOCKER_CHAIN], "bv_args": [BLOCKER_CHAIN],
                     "bv_path": "result", "bv_lift": ENVELOPE_KEYS}
# The commands run under each --label and --recipe scope with the same
# arguments on both sides, and the subtree each compares — the same as its
# unscoped run, except insights, whose top level bv shapes differently and
# which compares the metrics themselves (vbx-4cz).
SCOPED_RUNS = (
    ("robot-graph", {}),
    ("robot-triage", TRIAGE_PATHS),
    ("robot-plan", {"bv_path": "plan"}),
    ("robot-priority", {"bv_path": "recommendations", "vbx_path": "recommendations"}),
    ("robot-next", {}),
    ("robot-suggest", {}),
    ("robot-insights", {"bv_path": "full_stats", "vbx_path": "full_stats"}),
    ("robot-alerts", {"bv_path": "alerts", "vbx_path": "alerts"}),
    ("robot-capacity", {}),
    ("robot-label-health", LABEL_HEALTH_PATHS),
    ("robot-label-flow", LABEL_FLOW_PATHS),
    ("robot-label-attention", LABEL_ATTENTION_PATHS),
)
# The recipe scopes, over the `recipes` fixture: a built-in, the project-file
# recipe, a path, and each beside a label, the last an unknown one.
RECIPE_SCOPES = (
    ["--recipe", "actionable"],
    ["--recipe", "high-impact"],
    ["--recipe", "ui-open"],
    ["--recipe", "hub-first.yml"],
    ["--recipe", "actionable", "--label", "engine"],
    ["--recipe", "hub-first.yml", "--label", "ui"],
    ["--recipe", "ui-open", "--label", "no-such-label"],
)

COMPARISONS = [
    {"vbx": "robot-label-flow", "bv": "robot-label-flow", **LABEL_FLOW_PATHS},
    {"vbx": "robot-label-health", "bv": "robot-label-health", **LABEL_HEALTH_PATHS},
    {"vbx": "robot-label-attention", "bv": "robot-label-attention", **LABEL_ATTENTION_PATHS},
    {"vbx": "robot-blocker-chain", "bv": "robot-blocker-chain", "only": {"demo"},
     **BLOCKER_CHAIN_RUN},
    {"vbx": "robot-triage", "bv": "robot-triage", **TRIAGE_PATHS},
    {"vbx": "robot-plan", "bv": "robot-plan", "bv_path": "plan"},
    {"vbx": "robot-suggest", "bv": "robot-suggest"},
    {"vbx": "robot-recipes", "bv": "robot-recipes", "compare": False,
     "note": "bv lists summaries; vbx returns full definitions plus source"},
    {"vbx": "robot-graph", "bv": "robot-graph"},
    {"vbx": "robot-metrics", "bv": None, "note": "vbx-only: raw GraphStats"},
    {"vbx": "robot-actionable", "bv": None, "note": "vbx-only: actionable ids"},
    {"vbx": "robot-info", "bv": None, "note": "vbx-only: resolved source"},
    {"vbx": "robot-issues", "bv": None, "note": "vbx-only: the bead set"},
    {"vbx": "robot-repos", "bv": None, "note": "vbx-only: workspace repositories"},
    {"vbx": "robot-revisions", "bv": None, "note": "vbx-only: bead-changing commits"},
    {"vbx": "robot-search-presets", "bv": None, "note": "vbx-only: weight presets"},
    {"vbx": "robot-baseline", "bv": None, "note": "vbx-only; bv prints prose"},
    {"vbx": "robot-alerts", "bv": "robot-alerts", "bv_path": "alerts",
     "vbx_path": "alerts"},
    {"vbx": "robot-sprint-list", "bv": "robot-sprint-list", "bv_path": "sprints",
     "vbx_path": "sprints", "bv_omitzero": SPRINT_OMITZERO},
    # The sprint is named rather than `current`: bv resolves `current` against
    # the wall clock, not SOURCE_DATE_EPOCH, so it would stop matching once the
    # sprint ended.
    {"vbx": "robot-sprint-show", "bv": "robot-sprint-show", "only": {"sprints"},
     "vbx_args": ["--id", "spr-sprint-2"], "bv_args": ["spr-sprint-2"],
     "bv_path": "sprint", "vbx_path": "sprint", "bv_omitzero": SPRINT_OMITZERO},
    {"vbx": "robot-burndown", "bv": "robot-burndown", "only": {"sprints"},
     "vbx_args": ["--id", "spr-sprint-2"], "bv_args": ["spr-sprint-2"]},
    {"vbx": "robot-insights", "bv": "robot-insights", "compare": False,
     "note": "bv inlines Insights' PascalCase fields at the top level"},
    {"vbx": "robot-priority", "bv": "robot-priority", "bv_path": "recommendations",
     "vbx_path": "recommendations"},
    {"vbx": "robot-next", "bv": "robot-next"},
    {"vbx": "robot-capacity", "bv": "robot-capacity"},
    {"vbx": "robot-capacity", "bv": "robot-capacity", "name": "robot-capacity --agents 3",
     "vbx_args": ["--agents", "3"], "bv_args": ["--agents", "3"]},
] + [
    # Label-scoped runs. bv 0.25's --label is a global scope — the label's
    # subgraph, its beads plus their direct dependency neighbours — so every
    # command that loads issues answers differently under it, and a run that
    # never passes --label checks none of that (vbx-7dm). `name` tells each
    # apart from its unscoped run in the report and in DECLARED_DIFFERENCES.
    # Over the demo only: `engine` is a demo label, and the unknown label is
    # the empty selection, which still has to carry its envelope. Each command
    # compares the same subtree as its unscoped run; insights, whose top level
    # bv shapes differently, compares the metrics themselves (vbx-4cz).
    {"vbx": command, "bv": command, "name": f"{command} --label {label}",
     "vbx_args": ["--label", label], "bv_args": ["--label", label], "only": {"demo"},
     **paths}
    for command, paths in SCOPED_RUNS
    for label in ("engine", "no-such-label")
] + [
    # Recipe-scoped runs (vbx-7d5). bv's --recipe is a global scope like
    # --label: the command answers over what the recipe selects, of the
    # label's beads when both are given, and the envelope names the recipe as
    # it was given and hashes the selection into scope_hash. A built-in, the
    # project-file recipe, a path, and each beside a label; the same subtrees
    # as the label runs.
    {"vbx": command, "bv": command, "name": f"{command} {' '.join(args)}",
     "vbx_args": args, "bv_args": args, "only": {"recipes"}, **paths}
    for command, paths in SCOPED_RUNS
    for args in RECIPE_SCOPES
] + [
    # The blocker chain under each scope (vbx-shz): its id is spelled
    # differently on each side, so it is not one of SCOPED_RUNS. `graph` holds
    # vbx-6 and one of its blockers; a scope that leaves vbx-6 out — the
    # unknown label, or a recipe that does not select it — is bv's "Issue not
    # found", which both must refuse with.
    {"vbx": "robot-blocker-chain", "bv": "robot-blocker-chain",
     "name": f"robot-blocker-chain {BLOCKER_CHAIN} {' '.join(args)}",
     **BLOCKER_CHAIN_RUN,
     "vbx_args": [*BLOCKER_CHAIN_RUN["vbx_args"], *args],
     "bv_args": [*BLOCKER_CHAIN_RUN["bv_args"], *args], **how}
    for args, how in (
        (["--label", "graph"], {"only": {"demo"}}),
        (["--label", "no-such-label"], {"only": {"demo"}, "rejects": True}),
        (["--recipe", "ui-open"], {"only": {"recipes"}}),
        (["--recipe", "hub-first.yml", "--label", "ui"], {"only": {"recipes"}}),
        (["--recipe", "hub-first.yml"], {"only": {"recipes"}, "rejects": True}),
        (["--recipe", "actionable"], {"only": {"recipes"}, "rejects": True}),
    )
] + [
    # The sprint commands under each scope (vbx-shz), over the sprints
    # fixture: a label, the unknown label, a built-in recipe, and both. The
    # sprints themselves are the file's whatever the scope; the burndown
    # counts only the beads inside it, and every envelope hashes the scoped
    # issues as bv's does.
    {"vbx": command, "bv": command, "name": f"{command} {' '.join(args)}",
     "only": {"sprints"}, **run, "vbx_args": [*run.get("vbx_args", []), *args],
     "bv_args": [*run.get("bv_args", []), *args]}
    for command, run in (
        ("robot-sprint-list", {"keys": ("sprints", "sprint_count", *ENVELOPE_KEYS),
                               "bv_omitzero": SPRINT_OMITZERO}),
        ("robot-sprint-show", {"vbx_args": ["--id", "spr-sprint-2"], "bv_args": ["spr-sprint-2"],
                               "keys": ("sprint", *ENVELOPE_KEYS),
                               "bv_omitzero": SPRINT_OMITZERO}),
        ("robot-burndown", {"vbx_args": ["--id", "spr-sprint-2"], "bv_args": ["spr-sprint-2"]}),
    )
    for args in (
        ["--label", "at-risk"],
        ["--label", "no-such-label"],
        ["--recipe", "actionable"],
        ["--recipe", "actionable", "--label", "burndown"],
    )
] + [
    # A recipe that does not resolve fails the command before it runs, as
    # bv's does: an unknown name, and a path that is not there. The same for
    # --robot-correlation-stats, whose output reads neither flag: bv still
    # resolves the recipe before loading issues.
    {"vbx": command, "bv": command, "name": f"{command} --recipe {recipe}",
     "vbx_args": ["--recipe", recipe], "bv_args": ["--recipe", recipe],
     "rejects": True, "only": {"recipes"}}
    for command in ("robot-triage", "robot-plan", "robot-capacity", "robot-label-health",
                    "robot-correlation-stats")
    for recipe in ("no-such-recipe", "missing.yaml")
] + [
    # bv's --alert-label is a filter on the alerts, separate from the --label
    # scope: it keeps the alerts naming the label and drops workspace-wide ones,
    # so an unknown label returns none (vbx-jnm). Two demo labels, because
    # `engine` and `ui` keep different alert types, and an unknown one.
    {"vbx": "robot-alerts", "bv": "robot-alerts", "name": f"robot-alerts --alert-label {label}",
     "vbx_args": ["--alert-label", label], "bv_args": ["--alert-label", label],
     "only": {"demo"}, "bv_path": "alerts", "vbx_path": "alerts"}
    for label in ("engine", "ui", "no-such-label")
] + [
    # bv's --capacity-label is likewise a filter of its own: an exact match on
    # a bead's labels over the scope's candidates, with readiness still read
    # from the whole source (vbx-ko1). `engine` and `ui` simulate different
    # beads, the unknown label is the empty selection, and the last pairs the
    # filter with the --label scope it applies within.
    {"vbx": "robot-capacity", "bv": "robot-capacity", "name": f"robot-capacity {' '.join(args)}",
     "vbx_args": args, "bv_args": args, "only": {"demo"}}
    for args in (
        ["--capacity-label", "engine"],
        ["--capacity-label", "ui"],
        ["--capacity-label", "no-such-label"],
        ["--label", "ui", "--capacity-label", "engine"],
    )
] + [
    # Search (vbx-52c). bv 0.25 guarantees a query that is a bead id that
    # bead, first, even outside the text top-K, and --search-min-score drops
    # candidates below a raw-similarity threshold — exact ids too. Compared on
    # the ranking and what echoes it (SEARCH_KEYS), not the envelope, whose
    # index statistics and hashes are bv's alone. Text mode only: hybrid
    # recency reads the wall clock in vbx (vbx-48y), so its scores differ for
    # a reason that is not search's.
    {"vbx": "robot-search", "bv": "robot-search", "name": "robot-search " + " ".join(arg or "''" for arg in args),
     "vbx_args": ["--search", query, "--limit", limit, *rest],
     "bv_args": ["--search", query, "--search-limit", limit, *rest],
     "keys": SEARCH_KEYS, "only": {fixture}}
    for fixture, query, limit, rest in (
        ("demo", "graph", "5", []),
        ("demo", "graph", "5", ["--search-min-score", "0.3"]),
        ("demo", "graph", "5", ["--search-min-score", "-1"]),
        ("demo", "graph", "5", ["--search-min-score", "1"]),
        ("demo", "graph", "5", ["--search-min-score", ""]),
        ("demo", "vbx-17", "1", []),
        # The control: the same words as tax-7, not spelled as its id, never
        # reach it — which is what makes the next one a test of the guarantee.
        ("search", "tax 7", "3", []),
        ("search", "tax-7", "3", []),
        ("search", "TAX-7", "3", []),
        ("search", "tax-7", "1", []),
        ("search", "tax-7", "3", ["--search-min-score", "0.2"]),
        ("search", "tax-7", "3", ["--search-min-score", "0.5"]),
        ("search", "case-1", "2", []),
        ("search", "CASE-1", "2", []),
        ("search", "tax-70", "3", []),
    )
    for args in [[query, limit, *rest]]
] + [
    # Each rejected as bv rejects it: exit 2, and bv's message.
    {"vbx": "robot-search", "bv": "robot-search",
     "name": f"robot-search graph --search-min-score {value!r}",
     "vbx_args": ["--search", "graph", "--search-min-score", value],
     "bv_args": ["--search", "graph", "--search-min-score", value],
     "rejects": True, "only": {"demo"}}
    for value in ("2", "-1.5", "abc", "NaN", "inf")
] + [
    # Search under each scope (vbx-shz): only the scope's beads are eligible
    # results — an exact id outside it included — while the index is the
    # whole workspace's. Compared on the ranking and the scope it names.
    {"vbx": "robot-search", "bv": "robot-search",
     "name": f"robot-search {query} {limit} {' '.join(rest)}",
     "vbx_args": ["--search", query, "--limit", limit, *rest],
     "bv_args": ["--search", query, "--search-limit", limit, *rest],
     "keys": (*SEARCH_KEYS, "scope", "scope_hash", "data_hash"), "only": {fixture}}
    for fixture, query, limit, rest in (
        ("demo", "graph", "5", ["--label", "engine"]),
        ("demo", "graph", "5", ["--label", "no-such-label"]),
        ("recipes", "graph", "5", ["--recipe", "actionable"]),
        ("recipes", "graph", "5", ["--recipe", "hub-first.yml", "--label", "ui"]),
        ("search", "tax-7", "3", ["--label", "tax"]),
        ("search", "tax-7", "3", ["--label", "finance"]),
    )
] + [
    # load_stats on the envelope-carrying commands whose usual comparison
    # takes a subtree that leaves it out (vbx-dv5). The rest — label health,
    # flow and attention, suggest, graph, next, capacity — compare it already,
    # whole or lifted.
    {"vbx": command, "bv": command, "name": f"{command} load_stats",
     "vbx_args": vbx_args, "bv_args": bv_args,
     "keys": ("load_stats", "source_path", "source_kind"),
     "only": {"dropped", "dropped (beads.db)"}}
    for command, vbx_args, bv_args in (
        ("robot-priority", [], []),
        ("robot-insights", [], []),
        ("robot-sprint-list", [], []),
        ("robot-search", ["--search", "import"], ["--search", "import"]),
        ("robot-blocker-chain", ["--id", "drop-2"], ["drop-2"]),
    )
] + [
    # bv's opt-in not-ready label-class keeps a bead out of the claimable top
    # picks of triage and --robot-next, from the flag or, failing that, the
    # environment (vbx-5ba). Over the feedback fixture, whose fb-6 is a
    # high-ranked bead labelled needs-design. The last run sets both, and the
    # flag must win.
    {"vbx": command, "bv": command, "name": f"{command} {spelling}", "only": {"feedback"},
     **paths, **how}
    for command, paths in (("robot-triage", TRIAGE_PATHS), ("robot-next", {}))
    for spelling, how in (
        (f"--robot-not-ready-labels {NOT_READY}",
         {"vbx_args": ["--robot-not-ready-labels", NOT_READY],
          "bv_args": ["--robot-not-ready-labels", NOT_READY]}),
        (f"BV_ROBOT_NOT_READY_LABELS={NOT_READY}",
         {"env": {"BV_ROBOT_NOT_READY_LABELS": NOT_READY}}),
        (f"--robot-not-ready-labels control BV_ROBOT_NOT_READY_LABELS={NOT_READY}",
         {"vbx_args": ["--robot-not-ready-labels", "control"],
          "bv_args": ["--robot-not-ready-labels", "control"],
          "env": {"BV_ROBOT_NOT_READY_LABELS": NOT_READY}}),
    )
]


# Recording triage feedback: bv's --feedback-accept/-ignore/-reset/-show
# (vbx-rt3). These are not robot commands — they print prose, and all but show
# write .beads/feedback.json — so they are run as sequences rather than as one
# robot call each. Every sequence runs on a fresh copy of the workspace's
# .beads per binary, so the fixture is never touched and the two sides start
# from the same file. Each step's exit status and output are compared — the
# prose exactly, show's JSON parsed with the float tolerance — a failing step's
# stderr too, and then the feedback.json each side was left with, parsed, with
# FEEDBACK_TIME_KEYS dropped.
#
# The clock: bv stamps every event and adjustment with time.Now and scores the
# verdict at the wall clock — its --feedback-accept never reads
# SOURCE_DATE_EPOCH — and vbx matches it there. The stamps are dropped; the
# score is computed by both sides within the same second or two, and differs
# by far less than the float tolerance. A show after a write, or with no file,
# reports a wall-clock updated_at, which is dropped there and only there.
FEEDBACK_TIME_KEYS = {"created_at", "updated_at", "timestamp", "last_updated"}
FEEDBACK_COMPARISONS = [
    # Over every fixture: most have no feedback.json, so these prove the
    # defaults, an unknown bead, and that reset creates the file bv creates.
    {"name": "feedback-show", "steps": [["--feedback-show"]]},
    {"name": "feedback-reset", "steps": [["--feedback-reset"], ["--feedback-show"]]},
    {"name": "feedback-accept no-such-bead",
     "steps": [["--feedback-accept", "no-such-bead"]]},
    # Verdicts on beads with an impact score and on a closed one (score 0).
    # Over feedback-few, the third verdict is the one that turns the weights
    # on; over feedback, they add to four.
    {"name": "feedback-accept/ignore", "only": {"feedback", "feedback-few"},
     "steps": [["--feedback-accept", "fb-5"], ["--feedback-ignore", "fb-1"],
               ["--feedback-ignore", "fb-8"], ["--feedback-show"]]},
    # A tombstone is not found; the bead it blocked is.
    {"name": "feedback-accept tombstone", "only": {"readiness", "readiness (beads.db)"},
     "steps": [["--feedback-accept", "rdy-10"], ["--feedback-accept", "rdy-11"]]},
]


# Reports: bv 0.25's --export / --export-md (vbx-im9). Not robot commands —
# each writes a file and prints two progress lines — so each is run once per
# binary, writing to the same path in turn, and compared on its exit status,
# stdout, stderr and the file it left. The clock is pinned, so the file is
# compared byte for byte; only a JSON report is parsed, to drop
# ENVELOPE_ONLY_KEYS from its top level exactly as from a robot envelope —
# GenerateReport writes bv's source_authority, which vbx does not port.
#
# The placeholders are files written fresh for every workspace: {out} the
# report, {template} EXPORT_TEMPLATE, and each EXPORT_RECIPES key its recipe,
# whose export defaults the explicit flags then override or not. Over the demo
# and the readiness fixture, whose tombstones, deferrals and missing blockers
# are what decide each bead's claim command in the report.
EXPORT_TEMPLATE = (
    "# {{.Title}} ({{len .Issues}} beads, {{.GeneratedAt}})\n"
    "{{range .Issues}}- [{{.Status}}] {{.ID}} P{{.Priority}} {{.Title}}"
    "{{range .Labels}} #{{.}}{{end}}\n{{end}}"
    "{{if .Graph}}\n```mermaid\n{{.Graph}}```\n{{end}}"
)
EXPORT_RECIPES = {
    # Export defaults the flags leave alone, then override.
    "recipe_json": "name: export-json\ndescription: Open beads as JSON\n"
                   "filters:\n  status: [open]\n"
                   "export:\n  format: json\n  include_graph: false\n",
    # A template default, which an explicit empty --export-template disables.
    "recipe_template": "name: export-template\ndescription: Templated\n"
                       "export:\n  template: {template}\n",
}
EXPORT_ONLY = {"demo", "readiness"}
EXPORT_COMPARISONS = [
    {"name": f"export {' '.join(args)}".strip(), "args": args, "only": EXPORT_ONLY}
    for args in (
        [],
        ["--export-format", "markdown"],
        ["--export-format", "json"],
        ["--export-format", "csv"],
        ["--export-format", "mermaid"],
        ["--export-include-graph=false"],
        ["--export-format", "json", "--export-include-graph=false"],
        ["--export-format", "csv", "--export-include-graph=false"],
        ["--export-template", "{template}"],
        ["--export-template={template}", "--export-include-graph=false"],
        ["--recipe", "actionable"],
        ["--recipe", "{recipe_json}"],
        ["--recipe", "{recipe_json}", "--export-format", "csv"],
        ["--recipe", "{recipe_json}", "--export-include-graph"],
        ["--recipe", "{recipe_template}"],
        ["--recipe", "{recipe_template}", "--export-template="],
        ["--label", "engine"],
        ["--label", "no-such-label"],
        # Rejected combinations: each must fail on both sides with bv's text.
        ["--export-format", "mermaid", "--export-include-graph=false"],
        ["--export-format", "csv", "--export-include-graph"],
        ["--export-format", "json", "--export-template", "{template}"],
        ["--export-format", "pdf"],
        ["--export-template", "{missing}"],
    )
] + [
    # bv's older flag, which forces Markdown whatever --export-format says.
    {"name": f"export-md {' '.join(args)}".strip(), "args": args, "flag": "--export-md",
     "only": EXPORT_ONLY}
    for args in ([], ["--export-format", "json"])
]


def write_export_inputs(scratch: Path) -> dict[str, str]:
    """Writes the template and recipes into scratch; returns the placeholders."""
    scratch.mkdir(parents=True, exist_ok=True)
    places = {"out": str(scratch / "report"), "template": str(scratch / "template.md"),
              "missing": str(scratch / "no-such-template.md")}
    (scratch / "template.md").write_text(EXPORT_TEMPLATE)
    for key, text in EXPORT_RECIPES.items():
        path = scratch / f"{key}.yaml"
        path.write_text(text.replace("{template}", places["template"]))
        places[key] = str(path)
    return places


def run_export(binary: str, flag: str, args: list[str], places: dict[str, str],
               workspace: Path) -> tuple[int, str, str, bytes | None]:
    """Runs one export; returns (status, stdout, stderr, the file or None)."""
    out = Path(places["out"])
    if out.exists():
        out.unlink()
    status, stdout, stderr = run(
        binary, [flag, str(out), *(arg.format(**places) for arg in args)], workspace)
    return status, stdout, stderr, out.read_bytes() if out.exists() else None


def export_differences(vbx_run, bv_run) -> list[str]:
    """Every difference between two runs of one export."""
    found: list[str] = []
    (vs, vo, ve, vfile), (bs, bo, be, bfile) = vbx_run, bv_run
    if vs != bs:
        found.append(f"exit {vs} vs {bs}: {ve.strip()!r} vs {be.strip()!r}")
    if vo != bo:
        found.append(f"stdout {vo!r} vs {bo!r}")
    if ve.strip() != be.strip():
        found.append(f"stderr {ve.strip()!r} vs {be.strip()!r}")
    if (vfile is None) != (bfile is None):
        found.append("file: " + ("absent" if vfile is None else "written") + " on the vbx side, "
                     + ("absent" if bfile is None else "written") + " on the bv side")
    elif vfile is not None and vfile != bfile:
        try:
            left, right = json.loads(vfile), json.loads(bfile)
        except (json.JSONDecodeError, UnicodeDecodeError):
            left = right = None
        if isinstance(left, dict) and isinstance(right, dict) and "issues" in right:
            found.extend(f"file{difference}" for difference in describe_differences(
                strip_envelope_only(left), strip_envelope_only(right)))
        else:
            vlines = vfile.decode(errors="replace").splitlines()
            blines = bfile.decode(errors="replace").splitlines()
            for number, (a, b) in enumerate(zip(vlines, blines), 1):
                if a != b:
                    found.append(f"file line {number}: {a!r} vs {b!r}")
                    break
            else:
                found.append(f"file: {len(vfile)} bytes vs {len(bfile)}")
    return found


# Export hooks: bv 0.25's .bv/hooks.yaml, run around --export (vbx-uos). Each
# HOOK_CONFIGS entry is a hooks.yaml, written into a copy of the demo's .beads
# in a temporary directory — both binaries' working directory, since bv reads
# the file from there — and every one is exported with and without
# --no-hooks. The hooks are harmless: each writes a marker beside the report,
# recording what it saw (whether the report existed yet, the BV_* context, a
# hook env entry expanded from it, and whether an ambient credential leaked
# or was re-granted). Compared on exit status, stdout, stderr, the report and
# every marker. The one volatile part, each successful hook's run time in the
# summary, is normalised by HOOK_DURATION on both sides.
HOOK_ENV = {"PARITY_SECRET_TOKEN": "hunter2"}
# Go's Duration.String: "0s", "12ms", "1.002s", "1m0.5s", "1h2m3s".
HOOK_DURATION = re.compile(r"\((?:[0-9.]+(?:ns|µs|ms|h|m|s))+\)")
_HOOK_WITNESS = (
    "'if [ -e \"$BV_EXPORT_PATH\" ]; then echo present; else echo absent; fi"
    " > \"$BV_EXPORT_PATH.{phase}\"; printf \"%s|%s|%s|%s|%s|%s\\n\" \"$BV_EXPORT_PATH\""
    " \"$BV_EXPORT_FORMAT\" \"$BV_ISSUE_COUNT\" \"$BV_TIMESTAMP\" \"$GREETING\""
    " \"$PARITY_SECRET_TOKEN|$REGRANTED\" >> \"$BV_EXPORT_PATH.{phase}\"; echo quiet'"
)
_HOOK_ENV_BLOCK = ("      env:\n        GREETING: \"hello ${BV_ISSUE_COUNT}\"\n"
                   "        REGRANTED: \"${PARITY_SECRET_TOKEN}\"\n")
HOOK_CONFIGS = {
    # Both phases succeed; the pre hook sees no report, the post hook sees it.
    "pass": ("hooks:\n  pre-export:\n    - name: before\n      command: "
             + _HOOK_WITNESS.format(phase="pre") + "\n" + _HOOK_ENV_BLOCK
             + "  post-export:\n    - command: " + _HOOK_WITNESS.format(phase="post") + "\n"
             + _HOOK_ENV_BLOCK),
    # A pre-export failure (on_error defaults to fail) stops the write.
    "pre-fail": ("hooks:\n  pre-export:\n    - name: gate\n"
                 "      command: 'echo nope >&2; exit 3'\n"
                 "  post-export:\n    - command: " + _HOOK_WITNESS.format(phase="post") + "\n"),
    # Post-export failures: one tolerated (the default), one on_error: fail.
    "post-fail": ("hooks:\n  post-export:\n    - name: tolerated\n"
                  "      command: 'echo soft >&2; exit 1'\n"
                  "    - name: strict\n      command: 'echo hard >&2; exit 2'\n"
                  "      on_error: fail\n"),
    # A timeout, an invalid on_error (warned about only internally) and a
    # pre-export hook told to continue past its own failure.
    "lenient": ("hooks:\n  pre-export:\n    - name: shrug\n      command: 'exit 4'\n"
                "      on_error: continue\n"
                "  post-export:\n    - name: slow\n      command: 'exec sleep 2'\n"
                "      timeout: 200ms\n      on_error: sometimes\n"),
    # A file that does not parse is bv's warning, and the export goes on.
    "unreadable": "hooks: [not, a, map\n",
}
HOOK_COMPARISONS = [
    {"name": f"export hooks:{config} {' '.join(args)}".strip(), "config": config,
     "args": args, "only": {"demo"}}
    for config in HOOK_CONFIGS
    for args in ([], ["--no-hooks"])
] + [
    {"name": f"{flag.removeprefix('--')} hooks:pass {' '.join(args)}".strip(), "config": "pass",
     "flag": flag, "args": args, "only": {"demo"}}
    for flag, args in (("--export", ["--export-format", "json"]), ("--export-md", []))
]


def build_hook_workspace(source: Path, destination: Path, config: str) -> Path:
    """Copies `source`'s .beads to `destination` beside a .bv/hooks.yaml."""
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source / ".beads", destination / ".beads")
    (destination / ".bv").mkdir()
    (destination / ".bv" / "hooks.yaml").write_text(HOOK_CONFIGS[config])
    return destination


def run_hooked_export(binary: str, flag: str, args: list[str], workspace: Path,
                      out_dir: Path) -> tuple[tuple[int, str, str, bytes | None], dict[str, str]]:
    """Runs one export over a hooked workspace; returns run_export's tuple, the
    summary's run times normalised, and every marker the hooks left."""
    if out_dir.exists():
        shutil.rmtree(out_dir)
    out_dir.mkdir()
    out = out_dir / "report"
    status, stdout, stderr = run(binary, [flag, str(out), *args], workspace, HOOK_ENV)
    report = out.read_bytes() if out.exists() else None
    markers = {path.name: path.read_text() for path in sorted(out_dir.iterdir()) if path != out}
    return (status, HOOK_DURATION.sub("(<duration>)", stdout), stderr, report), markers


def hook_differences(vbx_run, bv_run) -> list[str]:
    """Every difference between two hooked exports, markers included."""
    (vbx_export, vbx_markers), (bv_export, bv_markers) = vbx_run, bv_run
    found = export_differences(vbx_export, bv_export)
    for name in sorted(set(vbx_markers) | set(bv_markers)):
        left, right = vbx_markers.get(name), bv_markers.get(name)
        if left != right:
            found.append(f"marker {name}: {left!r} vs {right!r}")
    return found


def select_keys(payload, keys):
    """Keeps `keys` of a dict payload; a key neither side has stays absent."""
    if not keys or not isinstance(payload, dict):
        return payload
    return {key: payload[key] for key in keys if key in payload}


def rejection_differences(vbx_run: tuple[int, str], bv_run: tuple[int, str]) -> list[str]:
    """How two runs that should both refuse their arguments disagree.

    Each run is (status, stderr). Only stderr's first line is compared: bv
    prints one, and vbx-cli follows it with a pointer to --help.
    """
    (vs, ve), (bs, be) = vbx_run, bv_run
    first = lambda text: (text.strip().splitlines() or [""])[0]  # noqa: E731
    if vs == 0 or bs == 0:
        return [f"expected both to refuse: exit {vs} vs {bs}"]
    found = []
    if vs != bs:
        found.append(f"exit {vs} vs {bs}")
    if first(ve) != first(be):
        found.append(f"stderr {first(ve)!r} vs {first(be)!r}")
    return found


def strip_keys(value, keys: set[str]):
    """Drops `keys` at every depth."""
    if isinstance(value, dict):
        return {key: strip_keys(item, keys) for key, item in value.items() if key not in keys}
    if isinstance(value, list):
        return [strip_keys(item, keys) for item in value]
    return value


def read_feedback_file(beads: Path):
    """The parsed feedback.json in `beads`, None when there is none."""
    path = beads / "feedback.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as error:
        return f"<unparseable: {error}>"


def run_feedback_sequence(binary: str, steps: list[list[str]], workspace: Path,
                          scratch: Path) -> tuple[list[tuple[int, str, str, bool]], object]:
    """Runs `steps` on a fresh copy of the workspace's .beads.

    Returns each step's (status, stdout, stderr, volatile) — volatile when the
    step is a show whose updated_at is the wall clock — and the feedback.json
    left behind.
    """
    if scratch.exists():
        shutil.rmtree(scratch)
    shutil.copytree(workspace / ".beads", scratch / ".beads")
    wrote = not (scratch / ".beads" / "feedback.json").exists()
    results = []
    for step in steps:
        status, out, err = run(binary, step, scratch)
        results.append((status, out, err, step[0] == "--feedback-show" and wrote))
        if step[0] != "--feedback-show":
            wrote = True
    return results, read_feedback_file(scratch / ".beads")


def feedback_differences(vbx_run, bv_run, steps: list[list[str]]) -> list[str]:
    """Every difference between two runs of one feedback sequence."""
    (vbx_steps, vbx_file), (bv_steps, bv_file) = vbx_run, bv_run
    found: list[str] = []
    for step, (vs, vo, ve, volatile), (bs, bo, be, _) in zip(steps, vbx_steps, bv_steps):
        where = " ".join(step)
        if vs != bs:
            found.append(f"{where}: exit {vs} vs {bs}")
            continue
        if vs != 0:
            if ve.strip() != be.strip():
                found.append(f"{where}: stderr {ve.strip()!r} vs {be.strip()!r}")
            continue
        if step[0] == "--feedback-show":
            # Parsed, not compared as text: bv normalises the effective
            # weights by summing a Go map, whose order is random, so two runs
            # of bv itself differ in the last bit.
            dropped = {"updated_at"} if volatile else set()
            try:
                left = strip_keys(json.loads(vo), dropped)
                right = strip_keys(json.loads(bo), dropped)
            except json.JSONDecodeError as error:
                found.append(f"{where}: could not parse output: {error}")
                continue
            found.extend(f"{where} {difference}"
                         for difference in describe_differences(left, right))
        elif vo != bo:
            found.append(f"{where}: stdout {vo!r} vs {bo!r}")
    if (vbx_file is None) != (bv_file is None):
        found.append("feedback.json: " + ("absent" if vbx_file is None else "written")
                     + " on the vbx side, " + ("absent" if bv_file is None else "written")
                     + " on the bv side")
    elif vbx_file is not None:
        found.extend(
            f"feedback.json{difference}" for difference in describe_differences(
                strip_keys(vbx_file, FEEDBACK_TIME_KEYS), strip_keys(bv_file, FEEDBACK_TIME_KEYS)))
    return found


BEADS_VIEWER_MODULE = "github.com/Dicklesworthstone/beads_viewer"
GET_MATCHING_BV = (
    "Install the matching bv: `brew upgrade bv`, or the release binary from "
    "https://github.com/Dicklesworthstone/beads_viewer/releases/tag/{version} "
    "first on PATH (or pass --bv). --allow-bv-mismatch compares anyway."
)


def engine_bv_version(go_mod: Path) -> str | None:
    """The beads_viewer version the engine is built on, from go.mod."""
    try:
        text = go_mod.read_text()
    except OSError:
        return None
    match = re.search(rf"^\s*(?:require\s+)?{re.escape(BEADS_VIEWER_MODULE)}\s+(v\S+)", text, re.M)
    return match.group(1) if match else None


def parse_bv_version(output: str) -> str | None:
    """`bv --version` prints `bv v0.25.2`; returns `v0.25.2`, or None."""
    match = re.search(r"\bv?(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.+-]+)?)", output)
    return f"v{match.group(1)}" if match else None


def read_bv_version(path: str) -> str:
    """Whatever `bv --version` prints, or why it printed nothing usable."""
    try:
        result = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as error:
        return f"<{error}>"
    return (result.stdout + result.stderr).strip()


def check_bv_version(engine: str | None, bv_path: str | None,
                     version_output: str | None) -> tuple[str, str]:
    """Decides whether this bv can be compared with, returning (state, message).

    state is `missing` (no bv: skip, as ever), `match`, or `mismatch` — which
    covers an unreadable version on either side, because a comparison that
    cannot be shown to be against the right bv is not one.
    """
    if bv_path is None:
        return "missing", "bv is not installed; comparisons were skipped rather than passed."
    if engine is None:
        return "mismatch", (
            f"cannot read the engine's {BEADS_VIEWER_MODULE} version from "
            f"Engine/bridge/go.mod, so {bv_path} cannot be shown to match it.")
    found = parse_bv_version(version_output or "")
    if found is None:
        shown = (version_output or "").strip()[:80] or "nothing"
        return "mismatch", (
            f"cannot read a version from `{bv_path} --version` (it printed {shown!r}); "
            f"the engine is built on bv {engine}. "
            + GET_MATCHING_BV.format(version=engine))
    if found.lstrip("v") == engine.lstrip("v"):
        return "match", f"bv {found} at {bv_path} matches the engine's beads_viewer {engine}."
    return "mismatch", (
        f"bv {found} at {bv_path} is not the engine's beads_viewer {engine}: every "
        f"difference between those releases would read as a vbx bug. "
        + GET_MATCHING_BV.format(version=engine))


def run(binary: str, args: list[str], cwd: Path,
        env: dict[str, str] | None = None) -> tuple[int, str, str]:
    """Runs a binary, returning (status, stdout, stderr).

    `env` adds variables on top of the inherited environment — a comparison's
    own, given identically to both binaries.
    """
    environment = dict(os.environ, SOURCE_DATE_EPOCH=PINNED_CLOCK, **(env or {}))
    result = subprocess.run(
        [binary, *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=180,
        env=environment,
    )
    return result.returncode, result.stdout, result.stderr


def dig(value, path: str | None):
    """Follows a dotted path, returning None when it does not resolve."""
    if not path:
        return value
    for part in path.split("."):
        if not isinstance(value, dict) or part not in value:
            return None
        value = value[part]
    return value


def lift(whole, subtree, keys):
    """Copies bv's top-level `keys` into the subtree being compared.

    bv puts some of a command's data beside its payload rather than in it —
    triage's `feedback` block sits next to `triage` — where vbx, which returns
    the payload itself, carries it at the payload's top level. A key bv omits
    stays omitted, so a block vbx emits and bv does not is still a difference.
    """
    if not keys or not isinstance(whole, dict) or not isinstance(subtree, dict):
        return subtree
    lifted = dict(subtree)
    for key in keys:
        if key in whole:
            lifted[key] = whole[key]
    return lifted


def build_recipe_workspace(source: Path, destination: Path) -> Path:
    """Copies `source`'s .beads to `destination` and writes RECIPE_FILES there.

    Returns the workspace directory. The beads are the source's unchanged, so
    a difference here is the recipe scope's and nothing else.
    """
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source / ".beads", destination / ".beads")
    for relative, text in RECIPE_FILES.items():
        path = destination / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    return destination


def build_sqlite_workspace(jsonl: Path, destination: Path) -> Path:
    """Writes `destination/.beads/beads.db` holding the beads in `jsonl`.

    Every record is kept, tombstones included, because br keeps them: a
    deleted bead is a row with `status = 'tombstone'` and `deleted_at` set,
    and what a loader does with that row is part of what is being compared.
    Dependency rows are written as given, so a reference to a bead that does
    not exist stays dangling. Returns the workspace directory.
    """
    beads = destination / ".beads"
    beads.mkdir(parents=True, exist_ok=True)
    database = beads / "beads.db"
    if database.exists():
        database.unlink()

    connection = sqlite3.connect(database)
    try:
        column_list = ", ".join(
            f"{column} DATETIME" if column.endswith("_at") or column == "defer_until"
            else column
            for column in BR_ISSUE_COLUMNS
        )
        connection.execute(f"CREATE TABLE issues ({column_list}, PRIMARY KEY (id))")
        connection.execute(
            "CREATE TABLE dependencies (issue_id TEXT, depends_on_id TEXT, type TEXT,"
            " created_at DATETIME, created_by TEXT, metadata TEXT, thread_id TEXT)")
        connection.execute("CREATE TABLE labels (issue_id TEXT, label TEXT)")
        connection.execute(
            "CREATE TABLE comments (id TEXT, issue_id TEXT, author TEXT, text TEXT,"
            " created_at DATETIME)")

        for line in jsonl.read_text().splitlines():
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                # A malformed line (Fixtures/dropped) is a JSONL failure: it
                # never becomes a row, as br could never have written it. Its
                # record-level problems — a failed validation — do become
                # rows, so the SQLite loader's own drop is still exercised.
                continue
            row = {column: record.get(column) for column in BR_ISSUE_COLUMNS}
            for column, default in (("description", ""), ("design", ""),
                                    ("acceptance_criteria", ""), ("notes", ""),
                                    ("source_repo", "."), ("ephemeral", 0),
                                    ("pinned", 0), ("is_template", 0),
                                    ("prerequisites", "")):
                if row[column] is None:
                    row[column] = default
            placeholders = ", ".join("?" for _ in BR_ISSUE_COLUMNS)
            connection.execute(
                f"INSERT INTO issues ({', '.join(BR_ISSUE_COLUMNS)}) VALUES ({placeholders})",
                [row[column] for column in BR_ISSUE_COLUMNS])
            for label in record.get("labels") or []:
                connection.execute("INSERT INTO labels VALUES (?, ?)", (record["id"], label))
            for dependency in record.get("dependencies") or []:
                connection.execute(
                    "INSERT INTO dependencies VALUES (?, ?, ?, ?, ?, '{}', '')",
                    (dependency.get("issue_id", record["id"]), dependency["depends_on_id"],
                     dependency.get("type", ""), dependency.get("created_at"),
                     dependency.get("created_by", "")))
            for comment in record.get("comments") or []:
                connection.execute(
                    "INSERT INTO comments VALUES (?, ?, ?, ?, ?)",
                    (str(comment.get("id")), record["id"], comment.get("author"),
                     comment.get("text"), comment.get("created_at")))
        connection.commit()
    finally:
        connection.close()
    return destination


def strip_envelope_only(output):
    """Drops ENVELOPE_ONLY_KEYS from the top level of one whole output.

    Applied to both sides of every comparison, before the compared subtree is
    taken, so the envelope is the only place a key is removed from — the same
    name nested inside a payload is data.
    """
    if not isinstance(output, dict):
        return output
    return {key: value for key, value in output.items() if key not in ENVELOPE_ONLY_KEYS}


def strip_bv_zero_times(value, keys: set[str]):
    """Drops the named keys from bv's payload where they hold Go's zero time.

    bv tags these fields `omitzero` — absent when unset — but encodes robot
    output with goccy/go-json, which ignores that tag and writes
    `0001-01-01T00:00:00Z` instead. vbx encodes with encoding/json, which
    honours it. The zero time is not data, so only that exact value is
    dropped: a real timestamp under the same key is still compared.
    """
    if not keys:
        return value
    if isinstance(value, dict):
        return {
            key: strip_bv_zero_times(item, keys)
            for key, item in value.items()
            if not (key in keys and item == GO_ZERO_TIME)
        }
    if isinstance(value, list):
        return [strip_bv_zero_times(item, keys) for item in value]
    return value


def normalise(value):
    """Strips volatile keys and rounds floats so two runs can be compared.

    Floats are rounded rather than compared exactly: the two binaries marshal
    the same float64 through different JSON encoders, and a last-bit difference
    in the text is not a disagreement about the number.
    """
    if isinstance(value, dict):
        return {
            key: normalise(item)
            for key, item in sorted(value.items())
            if key not in VOLATILE_KEYS
        }
    if isinstance(value, list):
        return [normalise(item) for item in value]
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        return str(value)
    return value


def describe_differences(left, right, path: str = "") -> list[str]:
    """Every place two payloads differ, as readable paths, in a stable order.

    Lists of unequal length report the lengths and are not walked further:
    once one side has an extra item, comparing by position only restates it.
    """
    if type(left) is not type(right):
        return [f"{path or '<root>'}: {type(left).__name__} vs {type(right).__name__}"]

    if isinstance(left, dict):
        found: list[str] = []
        for key in sorted(set(left) | set(right)):
            if key not in left:
                found.append(f"{path}.{key}: missing on the vbx side")
            elif key not in right:
                found.append(f"{path}.{key}: missing on the bv side")
            else:
                found.extend(describe_differences(left[key], right[key], f"{path}.{key}"))
        return found

    if isinstance(left, list):
        if len(left) != len(right):
            return [f"{path}: {len(left)} items vs {len(right)}"]
        found = []
        for index, (a, b) in enumerate(zip(left, right)):
            found.extend(describe_differences(a, b, f"{path}[{index}]"))
        return found

    if isinstance(left, float) or isinstance(right, float):
        # Compared with a tolerance rather than rounded. Rounding was tried
        # first and is the wrong tool: two values either side of a rounding
        # boundary compare unequal however close they are, which made the
        # check intermittently fail. A relative tolerance has no boundary.
        #
        # The clock is pinned on both sides, so what remains is floating-point
        # noise from summation order. This tolerance is far below anything
        # that would change a decision.
        if math.isclose(left, right, rel_tol=1e-6, abs_tol=1e-9):
            return []
        return [f"{path or '<root>'}: {left!r} vs {right!r}"]

    if left != right:
        return [f"{path or '<root>'}: {left!r} vs {right!r}"]
    return []


def implemented_commands(vbx: str, cwd: Path) -> set[str]:
    """The commands vbx-cli actually offers, read from the binary itself.

    Asked rather than hardcoded, so this script cannot drift out of date
    without the drift being visible.
    """
    status, out, err = run(vbx, ["--list-commands"], cwd)
    if status != 0:
        print(f"could not list vbx-cli commands: {err}", file=sys.stderr)
        return set()
    listing = json.loads(out)
    # The report flags are a mode rather than a robot command, listed apart.
    return ({entry["flag"] for entry in listing["commands"]}
            | set(listing.get("exports", [])))


def compare_workspace(vbx: str, bv: str, bv_skip: str | None, workspace: Path,
                      label: str, verbose: bool, only_named: bool = False,
                      skip_feedback: str | None = None) -> tuple[int, int]:
    """Runs every comparison over one workspace and prints the result.

    only_named, for a fixture built for a few commands, runs only the
    comparisons whose `only` names it; the rest are reported skipped.
    skip_feedback, when set, is why the feedback sequences are reported
    skipped over this workspace.

    bv_skip, when set, is why no command is compared against bv — it is not
    installed, or it is not the engine's version — and every comparable
    command is reported as skipped with it.

    Returns (differed, missing) so the caller can total them across
    workspaces.
    """
    available = implemented_commands(vbx, workspace)

    matched: list[str] = []
    differed: list[tuple[str, list[str]]] = []
    declared: list[tuple[str, list[tuple[str, str]]]] = []
    skipped: list[tuple[str, str]] = []
    vbx_only: list[str] = []
    missing: list[str] = []
    not_named = f"{label} is compared only for the commands that name it"

    for entry in COMPARISONS:
        command = entry["vbx"]
        # What the report and DECLARED_DIFFERENCES call this run: the command,
        # unless the entry is one of several runs of it.
        name = entry.get("name", command)

        if command not in available:
            missing.append(name)
            continue
        if entry.get("bv") is None:
            vbx_only.append(name)
            continue
        if entry.get("compare") is False:
            skipped.append((name, entry.get("note", "not comparable")))
            continue
        if only_named and label not in entry.get("only", ()):
            skipped.append((name, not_named))
            continue
        if "only" in entry and label not in entry["only"]:
            skipped.append((name, f"compared over {', '.join(sorted(entry['only']))} only"))
            continue
        if bv_skip:
            skipped.append((name, bv_skip))
            continue

        vbx_status, vbx_out, vbx_err = run(
            vbx, [f"--{command}", *entry.get("vbx_args", [])], workspace, entry.get("env"))
        bv_status, bv_out, bv_err = run(
            bv, [f"--{entry['bv']}", *entry.get("bv_args", []), "--format", "json"], workspace,
            entry.get("env"))

        if entry.get("rejects"):
            differences = rejection_differences((vbx_status, vbx_err), (bv_status, bv_err))
            if differences:
                differed.append((name, differences))
            else:
                matched.append(name)
            continue

        if vbx_status != 0:
            differed.append((name, [f"vbx-cli exited {vbx_status}: {vbx_err.strip()}"]))
            continue
        if bv_status != 0:
            skipped.append((name, f"bv exited {bv_status}: {bv_err.strip()[:80]}"))
            continue

        try:
            vbx_payload = dig(strip_envelope_only(json.loads(vbx_out)), entry.get("vbx_path"))
            bv_whole = strip_envelope_only(json.loads(bv_out))
            bv_payload = lift(bv_whole, dig(bv_whole, entry.get("bv_path")),
                              entry.get("bv_lift", ()))
        except json.JSONDecodeError as error:
            differed.append((name, [f"could not parse output: {error}"]))
            continue

        if bv_payload is None:
            skipped.append((name, f"bv payload has no {entry.get('bv_path')}"))
            continue
        vbx_payload = select_keys(vbx_payload, entry.get("keys"))
        bv_payload = select_keys(bv_payload, entry.get("keys"))

        bv_payload = strip_bv_zero_times(bv_payload, entry.get("bv_omitzero", set()))

        differences = describe_differences(normalise(vbx_payload), normalise(bv_payload))
        undeclared, accepted, stale = split_declared(differences, label, name)
        undeclared += [f"{path}: declared in DECLARED_DIFFERENCES but no longer differs;"
                       " remove it and revisit its ADR" for path in stale]
        # Declared differences are listed even beside undeclared ones, so a
        # failing command never hides what else it was let off.
        if accepted:
            declared.append((name, accepted))
        if undeclared:
            differed.append((name, undeclared))
        elif not accepted:
            matched.append(name)

    for entry in FEEDBACK_COMPARISONS:
        name = entry["name"]
        flags = {step[0].removeprefix("--") for step in entry["steps"]}
        if not flags <= available:
            missing.append(name)
            continue
        if only_named and label not in entry.get("only", ()):
            skipped.append((name, not_named))
            continue
        if "only" in entry and label not in entry["only"]:
            skipped.append((name, f"compared over {', '.join(sorted(entry['only']))} only"))
            continue
        if skip_feedback:
            skipped.append((name, skip_feedback))
            continue
        if bv_skip:
            skipped.append((name, bv_skip))
            continue
        with tempfile.TemporaryDirectory(prefix="vbx-parity-feedback-") as scratch:
            vbx_run = run_feedback_sequence(vbx, entry["steps"], workspace, Path(scratch) / "vbx")
            bv_run = run_feedback_sequence(bv, entry["steps"], workspace, Path(scratch) / "bv")
        differences = feedback_differences(vbx_run, bv_run, entry["steps"])
        if differences:
            differed.append((name, differences))
        else:
            matched.append(name)

    for entry in EXPORT_COMPARISONS:
        name = entry["name"]
        flag = entry.get("flag", "--export")
        if flag.removeprefix("--") not in available:
            missing.append(name)
            continue
        if only_named and label not in entry["only"]:
            skipped.append((name, not_named))
            continue
        if label not in entry["only"]:
            skipped.append((name, f"compared over {', '.join(sorted(entry['only']))} only"))
            continue
        if bv_skip:
            skipped.append((name, bv_skip))
            continue
        with tempfile.TemporaryDirectory(prefix="vbx-parity-export-") as scratch:
            places = write_export_inputs(Path(scratch))
            vbx_run = run_export(vbx, flag, entry["args"], places, workspace)
            bv_run = run_export(bv, flag, entry["args"], places, workspace)
        differences = export_differences(vbx_run, bv_run)
        if differences:
            differed.append((name, differences))
        else:
            matched.append(name)

    for entry in HOOK_COMPARISONS:
        name = entry["name"]
        flag = entry.get("flag", "--export")
        if flag.removeprefix("--") not in available:
            missing.append(name)
            continue
        if only_named and label not in entry["only"]:
            skipped.append((name, not_named))
            continue
        if label not in entry["only"]:
            skipped.append((name, f"compared over {', '.join(sorted(entry['only']))} only"))
            continue
        if bv_skip:
            skipped.append((name, bv_skip))
            continue
        with tempfile.TemporaryDirectory(prefix="vbx-parity-hooks-") as scratch:
            hooked = build_hook_workspace(workspace, Path(scratch) / "workspace", entry["config"])
            out_dir = Path(scratch) / "out"
            vbx_run = run_hooked_export(vbx, flag, entry["args"], hooked, out_dir)
            bv_run = run_hooked_export(bv, flag, entry["args"], hooked, out_dir)
        differences = hook_differences(vbx_run, bv_run)
        if differences:
            differed.append((name, differences))
        else:
            matched.append(name)

    # Report.
    print(f"Parity against {bv} over {label}")
    print()
    for name in matched:
        print(f"  match      --{name}")
    for name, differences in differed:
        if verbose:
            print(f"  DIFFER     --{name}:")
            for difference in differences:
                print(f"               {difference}")
        else:
            more = f" (+{len(differences) - 1} more)" if len(differences) > 1 else ""
            print(f"  DIFFER     --{name}: {differences[0]}{more}")
    for name, accepted in declared:
        if verbose:
            print(f"  declared   --{name}:")
            for difference, reason in accepted:
                print(f"               {difference}")
                print(f"                 ({reason})")
        else:
            paths = ", ".join(difference_path(difference) for difference, _ in accepted)
            print(f"  declared   --{name}: {paths}")
    for name, reason in skipped:
        print(f"  skip       --{name}: {reason}")
    for name in vbx_only:
        print(f"  vbx-only   --{name}")
    for name in missing:
        print(f"  MISSING    --{name}: declared here but not implemented")

    print()
    print(
        f"{len(matched)} matched, {len(differed)} differed, "
        f"{len(declared)} with declared differences, {len(skipped)} skipped, "
        f"{len(vbx_only)} vbx-only, {len(missing)} missing"
    )
    print()
    return len(differed), len(missing)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace",
                        help="compare this workspace only, instead of every one in FIXTURES")
    parser.add_argument("--vbx", default=".build/debug/vbx-cli")
    parser.add_argument("--bv", default="bv")
    parser.add_argument("--allow-bv-mismatch", action="store_true",
                        help="compare even when bv --version is not the engine's beads_viewer "
                             "version (Engine/bridge/go.mod); the run still warns")
    parser.add_argument("--verbose", action="store_true",
                        help="list every difference, not just the first per command")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    vbx = str((root / args.vbx).resolve())

    if not Path(vbx).exists():
        print(f"vbx-cli not found at {vbx}; run swift build first", file=sys.stderr)
        return 1

    fixtures = FIXTURES
    if args.workspace:
        fixtures = [{"name": Path(args.workspace).name, "workspace": args.workspace}]

    bv_path = shutil.which(args.bv)
    engine = engine_bv_version(root / "Engine" / "bridge" / "go.mod")
    version_output = read_bv_version(bv_path) if bv_path else None
    state, message = check_bv_version(engine, bv_path, version_output)
    bv_skip = bv_skip_reason(state, engine, args.allow_bv_mismatch)
    banner = bv_banner(state, message, args.allow_bv_mismatch)
    if banner:
        print(banner)
        print()
    else:
        print(message)
        print()

    differed = missing = 0
    with tempfile.TemporaryDirectory(prefix="vbx-parity-") as scratch:
        for fixture in fixtures:
            workspace = (root / fixture["workspace"]).resolve()
            if not workspace.exists():
                print(f"workspace not found at {workspace}", file=sys.stderr)
                return 1
            if fixture.get("sqlite"):
                workspace = build_sqlite_workspace(
                    workspace / ".beads" / "issues.jsonl",
                    Path(scratch) / fixture["workspace"].replace("/", "-"))
            if fixture.get("recipes"):
                workspace = build_recipe_workspace(
                    workspace, Path(scratch) / f"{fixture['name']}-recipes")
            d, m = compare_workspace(vbx, bv_path or args.bv, bv_skip, workspace,
                                     fixture["name"], args.verbose,
                                     fixture.get("only_named", False),
                                     fixture.get("skip_feedback"))
            differed += d
            missing += m

    print(f"{len(fixtures)} workspaces: {differed} differing commands, {missing} missing")
    if banner:
        print()
        print(banner)

    return exit_status(differed, missing, state, args.allow_bv_mismatch)


def bv_skip_reason(state: str, engine: str | None, allow_mismatch: bool) -> str | None:
    """Why no command is compared against bv, or None when they all are."""
    if state == "missing":
        return "bv is not installed"
    if state == "mismatch" and not allow_mismatch:
        return f"bv is not the engine's {engine or 'beads_viewer version'}"
    return None


def bv_banner(state: str, message: str, allow_mismatch: bool) -> str | None:
    """The block printed at the top and again under the summary, if any."""
    if state == "missing":
        return message
    if state != "mismatch":
        return None
    rule = "!" * 78
    verdict = ("--allow-bv-mismatch: compared anyway, so differences may be upstream's, not vbx's."
               if allow_mismatch else
               "Nothing was compared, and the run fails.")
    return f"{rule}\nBV VERSION MISMATCH: {message}\n{verdict}\n{rule}"


def exit_status(differed: int, missing: int, state: str, allow_mismatch: bool) -> int:
    """1 for any difference, unimplemented command, or unaccepted bv mismatch.

    A missing bv is not a failure — every comparison says skipped — but a
    mismatched one is: it is installed, so the run looks like a comparison.
    """
    if differed or missing:
        return 1
    return 1 if state == "mismatch" and not allow_mismatch else 0


if __name__ == "__main__":
    sys.exit(main())
