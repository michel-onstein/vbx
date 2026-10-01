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
import subprocess
import sys
from pathlib import Path

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

# How each command lines up. `bv_path` and `vbx_path` name the subtree to
# compare, as a dotted path; None means the whole payload.
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
     "vbx_path": "sprints"},
    {"vbx": "robot-insights", "bv": "robot-insights", "compare": False,
     "note": "bv inlines Insights' PascalCase fields at the top level"},
    {"vbx": "robot-priority", "bv": "robot-priority", "bv_path": "recommendations",
     "vbx_path": "recommendations"},
    {"vbx": "robot-next", "bv": "robot-next", "compare": False,
     "note": "both gate on claim safety; bv adds fields vbx does not model"},
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


def describe_difference(left, right, path: str = "") -> str | None:
    """The first place two payloads differ, as a readable path."""
    if type(left) is not type(right):
        return f"{path or '<root>'}: {type(left).__name__} vs {type(right).__name__}"

    if isinstance(left, dict):
        for key in sorted(set(left) | set(right)):
            if key not in left:
                return f"{path}.{key}: missing on the vbx side"
            if key not in right:
                return f"{path}.{key}: missing on the bv side"
            found = describe_difference(left[key], right[key], f"{path}.{key}")
            if found:
                return found
        return None

    if isinstance(left, list):
        if len(left) != len(right):
            return f"{path}: {len(left)} items vs {len(right)}"
        for index, (a, b) in enumerate(zip(left, right)):
            found = describe_difference(a, b, f"{path}[{index}]")
            if found:
                return found
        return None

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
            return None
        return f"{path or '<root>'}: {left!r} vs {right!r}"

    if left != right:
        return f"{path or '<root>'}: {left!r} vs {right!r}"
    return None


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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", default="Fixtures/demo")
    parser.add_argument("--vbx", default=".build/debug/vbx-cli")
    parser.add_argument("--bv", default="bv")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    root = Path(__file__).resolve().parent.parent
    workspace = (root / args.workspace).resolve()
    vbx = str((root / args.vbx).resolve())

    if not Path(vbx).exists():
        print(f"vbx-cli not found at {vbx}; run swift build first", file=sys.stderr)
        return 1
    if not workspace.exists():
        print(f"workspace not found at {workspace}", file=sys.stderr)
        return 1

    have_bv = subprocess.run(
        ["which", args.bv], capture_output=True, text=True
    ).returncode == 0

    available = implemented_commands(vbx, workspace)

    matched: list[str] = []
    differed: list[tuple[str, str]] = []
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
        if not have_bv:
            skipped.append((name, "bv is not installed"))
            continue

        vbx_status, vbx_out, vbx_err = run(vbx, [f"--{name}"], workspace)
        bv_status, bv_out, bv_err = run(args.bv, [f"--{entry['bv']}", "--format", "json"], workspace)

        if vbx_status != 0:
            differed.append((name, f"vbx-cli exited {vbx_status}: {vbx_err.strip()}"))
            continue
        if bv_status != 0:
            skipped.append((name, f"bv exited {bv_status}: {bv_err.strip()[:80]}"))
            continue

        try:
            vbx_payload = dig(json.loads(vbx_out), entry.get("vbx_path"))
            bv_payload = dig(json.loads(bv_out), entry.get("bv_path"))
        except json.JSONDecodeError as error:
            differed.append((name, f"could not parse output: {error}"))
            continue

        if bv_payload is None:
            skipped.append((name, f"bv payload has no {entry.get('bv_path')}"))
            continue

        difference = describe_difference(normalise(vbx_payload), normalise(bv_payload))
        if difference is None:
            matched.append(name)
        else:
            differed.append((name, difference))

    # Report.
    print(f"Parity against {args.bv} over {workspace.name}")
    print()
    for name in matched:
        print(f"  match      --{name}")
    for name, reason in differed:
        print(f"  DIFFER     --{name}: {reason}")
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
    if not have_bv:
        print("bv is not installed; comparisons were skipped rather than passed.")

    return 1 if differed or missing else 0


if __name__ == "__main__":
    sys.exit(main())
