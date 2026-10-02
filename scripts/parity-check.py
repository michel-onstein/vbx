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
own loader rather than bv's, and `Fixtures/sprints`, the only one with sprints
for the burndown and sprint commands to read. `--workspace` narrows the run to
one.

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
]

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
COMPARISONS = [
    {"vbx": "robot-label-flow", "bv": "robot-label-flow", "bv_path": "flow"},
    {"vbx": "robot-label-health", "bv": "robot-label-health", "bv_path": "results"},
    {"vbx": "robot-label-attention", "bv": "robot-label-attention", "compare": False,
     "note": "bv projects a ranked subset; vbx returns the full result"},
    {"vbx": "robot-triage", "bv": "robot-triage", "bv_path": "triage"},
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
    for command, paths in (
        ("robot-graph", {}),
        ("robot-triage", {"bv_path": "triage"}),
        ("robot-plan", {"bv_path": "plan"}),
        ("robot-priority", {"bv_path": "recommendations", "vbx_path": "recommendations"}),
        ("robot-next", {}),
        ("robot-suggest", {}),
        ("robot-insights", {"bv_path": "full_stats", "vbx_path": "full_stats"}),
        ("robot-alerts", {"bv_path": "alerts", "vbx_path": "alerts"}),
        ("robot-capacity", {}),
    )
    for label in ("engine", "no-such-label")
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
]


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


def run(binary: str, args: list[str], cwd: Path) -> tuple[int, str, str]:
    """Runs a binary, returning (status, stdout, stderr)."""
    environment = dict(os.environ, SOURCE_DATE_EPOCH=PINNED_CLOCK)
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
            record = json.loads(line)
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
    return {entry["flag"] for entry in json.loads(out)["commands"]}


def compare_workspace(vbx: str, bv: str, bv_skip: str | None, workspace: Path,
                      label: str, verbose: bool) -> tuple[int, int]:
    """Runs every comparison over one workspace and prints the result.

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
        if "only" in entry and label not in entry["only"]:
            skipped.append((name, f"compared over {', '.join(sorted(entry['only']))} only"))
            continue
        if bv_skip:
            skipped.append((name, bv_skip))
            continue

        vbx_status, vbx_out, vbx_err = run(
            vbx, [f"--{command}", *entry.get("vbx_args", [])], workspace)
        bv_status, bv_out, bv_err = run(
            bv, [f"--{entry['bv']}", *entry.get("bv_args", []), "--format", "json"], workspace)

        if vbx_status != 0:
            differed.append((name, [f"vbx-cli exited {vbx_status}: {vbx_err.strip()}"]))
            continue
        if bv_status != 0:
            skipped.append((name, f"bv exited {bv_status}: {bv_err.strip()[:80]}"))
            continue

        try:
            vbx_payload = dig(strip_envelope_only(json.loads(vbx_out)), entry.get("vbx_path"))
            bv_payload = dig(strip_envelope_only(json.loads(bv_out)), entry.get("bv_path"))
        except json.JSONDecodeError as error:
            differed.append((name, [f"could not parse output: {error}"]))
            continue

        if bv_payload is None:
            skipped.append((name, f"bv payload has no {entry.get('bv_path')}"))
            continue

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
            d, m = compare_workspace(vbx, bv_path or args.bv, bv_skip, workspace,
                                     fixture["name"], args.verbose)
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
