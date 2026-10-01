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
command declares which subtree to compare on each side.

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

# The provenance envelope bv 0.25 builds in `cmd/bv`, which vbx cannot
# import. Whether vbx ports it or the harness declares it envelope-only is
# bead vbx-v57's call; until then a command that opts in with
# `skip_top_level` is compared without these top-level keys. Only the top
# level — a nested key of the same name is data and is still compared.
PROVENANCE_KEYS = {
    "output_format",
    "source_path",
    "source_kind",
    "source_authority",
    "authority_hash",
    "scope_hash",
}

# bv's provenance envelope plus its `data_hash`, for commands where vbx emits
# neither. Whether vbx should is vbx-v57's call, made for every command at once.
ENVELOPE_KEYS = PROVENANCE_KEYS | {"data_hash"}

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
     "vbx_args": ["--id", "spr-sprint-2"], "bv_args": ["spr-sprint-2"],
     "skip_top_level": ENVELOPE_KEYS},
    {"vbx": "robot-insights", "bv": "robot-insights", "compare": False,
     "note": "bv inlines Insights' PascalCase fields at the top level"},
    {"vbx": "robot-priority", "bv": "robot-priority", "bv_path": "recommendations",
     "vbx_path": "recommendations"},
    # The payload is compared whole, less bv's provenance envelope, which
    # vbx-v57 decides for every command at once.
    {"vbx": "robot-next", "bv": "robot-next", "skip_top_level": PROVENANCE_KEYS},
]


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


def compare_workspace(vbx: str, bv: str, have_bv: bool, workspace: Path,
                      label: str, verbose: bool) -> tuple[int, int]:
    """Runs every comparison over one workspace and prints the result.

    Returns (differed, missing) so the caller can total them across
    workspaces.
    """
    available = implemented_commands(vbx, workspace)

    matched: list[str] = []
    differed: list[tuple[str, list[str]]] = []
    skipped: list[tuple[str, str]] = []
    vbx_only: list[str] = []
    missing: list[str] = []

    for entry in COMPARISONS:
        name = entry["vbx"]

        if name not in available:
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
        if not have_bv:
            skipped.append((name, "bv is not installed"))
            continue

        vbx_status, vbx_out, vbx_err = run(
            vbx, [f"--{name}", *entry.get("vbx_args", [])], workspace)
        bv_status, bv_out, bv_err = run(
            bv, [f"--{entry['bv']}", *entry.get("bv_args", []), "--format", "json"], workspace)

        if vbx_status != 0:
            differed.append((name, [f"vbx-cli exited {vbx_status}: {vbx_err.strip()}"]))
            continue
        if bv_status != 0:
            skipped.append((name, f"bv exited {bv_status}: {bv_err.strip()[:80]}"))
            continue

        try:
            vbx_payload = dig(json.loads(vbx_out), entry.get("vbx_path"))
            bv_payload = dig(json.loads(bv_out), entry.get("bv_path"))
        except json.JSONDecodeError as error:
            differed.append((name, [f"could not parse output: {error}"]))
            continue

        if bv_payload is None:
            skipped.append((name, f"bv payload has no {entry.get('bv_path')}"))
            continue

        skip_top_level = entry.get("skip_top_level", set())
        if skip_top_level:
            vbx_payload = {k: v for k, v in vbx_payload.items() if k not in skip_top_level}
            bv_payload = {k: v for k, v in bv_payload.items() if k not in skip_top_level}

        bv_payload = strip_bv_zero_times(bv_payload, entry.get("bv_omitzero", set()))

        differences = describe_differences(normalise(vbx_payload), normalise(bv_payload))
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
    for name, reason in skipped:
        print(f"  skip       --{name}: {reason}")
    for name in vbx_only:
        print(f"  vbx-only   --{name}")
    for name in missing:
        print(f"  MISSING    --{name}: declared here but not implemented")

    print()
    print(
        f"{len(matched)} matched, {len(differed)} differed, {len(skipped)} skipped, "
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

    have_bv = subprocess.run(
        ["which", args.bv], capture_output=True, text=True
    ).returncode == 0

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
            d, m = compare_workspace(vbx, args.bv, have_bv, workspace,
                                     fixture["name"], args.verbose)
            differed += d
            missing += m

    print(f"{len(fixtures)} workspaces: {differed} differing commands, {missing} missing")
    if not have_bv:
        print("bv is not installed; comparisons were skipped rather than passed.")

    return 1 if differed or missing else 0


if __name__ == "__main__":
    sys.exit(main())
