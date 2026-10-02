#!/usr/bin/env python3
"""Tests for parity-check.py's own machinery, which needs neither binary.

The parity run is only as good as the workspace it compares and the report it
prints. Two pieces of that are code rather than configuration: the beads.db
built from a fixture's JSONL, and the difference walk. Both are checked here so
a harness bug cannot read as agreement.
"""

from __future__ import annotations

import importlib.util
import sqlite3
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FAILURES: list[str] = []


def load_parity():
    spec = importlib.util.spec_from_file_location("parity_check", ROOT / "scripts" / "parity-check.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check(name: str, condition: bool, detail: str = "") -> None:
    print(f"  {'ok  ' if condition else 'FAIL'}  {name}")
    if not condition:
        FAILURES.append(f"{name}: {detail}")


def test_sqlite_workspace_keeps_every_record(parity) -> None:
    print("\nbeads.db built from Fixtures/readiness")
    jsonl = ROOT / "Fixtures" / "readiness" / ".beads" / "issues.jsonl"
    with tempfile.TemporaryDirectory() as scratch:
        workspace = parity.build_sqlite_workspace(jsonl, Path(scratch) / "ws")
        database = workspace / ".beads" / "beads.db"
        connection = sqlite3.connect(database)
        try:
            rows = dict(connection.execute("SELECT id, status FROM issues"))
            columns = [row[1] for row in connection.execute("PRAGMA table_info(issues)")]
            defer = dict(connection.execute(
                "SELECT id, defer_until FROM issues WHERE defer_until IS NOT NULL"))
            deleted = [row[0] for row in connection.execute(
                "SELECT id FROM issues WHERE deleted_at IS NOT NULL")]
            edges = set(connection.execute(
                "SELECT issue_id, depends_on_id, type FROM dependencies"))
            labels = connection.execute("SELECT COUNT(*) FROM labels").fetchone()[0]
        finally:
            connection.close()

    check("every record is a row, the tombstone included", len(rows) == 21, f"{len(rows)} rows")
    check("the tombstone keeps its status and deleted_at",
          rows.get("rdy-10") == "tombstone" and deleted == ["rdy-10"], f"{rows.get('rdy-10')} {deleted}")
    check("the custom status is stored as written", rows.get("rdy-2") == "triage", rows.get("rdy-2"))
    check("the columns are br's, in br's order", columns == parity.BR_ISSUE_COLUMNS, str(columns))
    check("both deferrals are stored", set(defer) == {"rdy-5", "rdy-6"}, str(defer))
    check("the dangling edge stays dangling",
          ("rdy-9", "external:upstream:rdy-404", "blocks") in edges, str(edges))
    check("waits-for and conditional-blocks keep their type",
          {("rdy-7", "rdy-1", "waits-for"), ("rdy-8", "rdy-1", "conditional-blocks")} <= edges)
    check("every label is a row", labels == 21, str(labels))


def test_every_difference_is_reported(parity) -> None:
    print("\nDifference walk")
    vbx = {"a": 1, "b": [1, 2], "c": {"d": 1.0, "e": "x"}, "only_vbx": 0}
    bv = {"a": 2, "b": [1, 2, 3], "c": {"d": 1.5, "e": "y"}, "only_bv": 0}
    found = parity.describe_differences(vbx, bv)
    check("every difference is listed, not just the first", found == [
        ".a: 1 vs 2",
        ".b: 2 items vs 3",
        ".c.d: 1.0 vs 1.5",
        ".c.e: 'x' vs 'y'",
        ".only_bv: missing on the vbx side",
        ".only_vbx: missing on the bv side",
    ], str(found))
    check("equal payloads report nothing", parity.describe_differences(vbx, vbx) == [])
    check("floats within tolerance are equal",
          parity.describe_differences({"x": 0.1 + 0.2}, {"x": 0.3}) == [])


def test_default_run_covers_every_fixture(parity) -> None:
    print("\nFixtures")
    names = [fixture["name"] for fixture in parity.FIXTURES]
    check("the demo, the readiness fixture, its beads.db form and the sprints are all compared",
          names == ["demo", "readiness", "readiness (beads.db)", "sprints"], str(names))
    for fixture in parity.FIXTURES:
        path = ROOT / fixture["workspace"] / ".beads" / "issues.jsonl"
        check(f"{fixture['workspace']} exists", path.exists(), str(path))

    # A command scoped to one fixture must name one that exists, or it is
    # skipped everywhere and never compared at all.
    for entry in parity.COMPARISONS:
        for name in entry.get("only", ()):
            check(f"--{entry['vbx']} is scoped to a real fixture ({name})", name in names)
    sprints = ROOT / "Fixtures" / "sprints" / ".beads" / "sprints.jsonl"
    check("the sprints fixture has a sprint file", sprints.exists(), str(sprints))


def test_bv_zero_times_are_dropped_only_when_zero(parity) -> None:
    print("\nbv's ignored omitzero")
    bv = {"sprints": [
        {"id": "s", "created_at": parity.GO_ZERO_TIME, "updated_at": "2026-08-01T00:00:00Z"},
    ], "created_at": parity.GO_ZERO_TIME}
    stripped = parity.strip_bv_zero_times(bv, {"created_at", "updated_at"})
    check("a zero time under a named key is dropped, nested too",
          stripped == {"sprints": [{"id": "s", "updated_at": "2026-08-01T00:00:00Z"}]},
          str(stripped))
    check("nothing is dropped without named keys",
          parity.strip_bv_zero_times(bv, set()) == bv)


def test_envelope_only_keys_are_one_list(parity) -> None:
    print("\nbv's envelope-only keys (ADR-023)")
    keys = parity.ENVELOPE_ONLY_KEYS
    check("exactly source_authority and authority_hash are declared envelope-only",
          set(keys) == {"source_authority", "authority_hash"}, str(sorted(keys)))
    check("every declared key gives its reason",
          all(isinstance(reason, str) and reason.strip() for reason in keys.values()), str(keys))
    # The provenance vbx ports must be compared, not hidden.
    ported = {"output_format", "source_path", "source_kind", "scope_hash", "data_hash"}
    check("the ported provenance is not declared away", not (ported & set(keys)),
          str(ported & set(keys)))
    check("no ported key is volatile either", not (ported & parity.VOLATILE_KEYS),
          str(ported & parity.VOLATILE_KEYS))
    ad_hoc = [entry["vbx"] for entry in parity.COMPARISONS if "skip_top_level" in entry]
    check("no command strips keys of its own", not ad_hoc, str(ad_hoc))

    bv = {"source_authority": {"state": "complete"}, "authority_hash": "x", "scope_hash": "s",
          "triage": {"source_authority": "nested data"}}
    stripped = parity.strip_envelope_only(bv)
    check("the declared keys go from the top level",
          stripped == {"scope_hash": "s", "triage": {"source_authority": "nested data"}},
          str(stripped))
    check("a non-object output passes through", parity.strip_envelope_only([1]) == [1])


def test_declared_differences_are_narrow(parity) -> None:
    print("\nDeclared differences (ADR-024)")
    declared = parity.DECLARED_DIFFERENCES
    names = {fixture["name"] for fixture in parity.FIXTURES}
    check("only the readiness beads.db declares differences",
          set(declared) == {"readiness (beads.db)"}, str(sorted(declared)))
    check("every declaring fixture is a real one", set(declared) <= names,
          str(set(declared) - names))
    sqlite_fixtures = {fixture["name"] for fixture in parity.FIXTURES if fixture.get("sqlite")}
    check("every declaring fixture is read from a beads.db", set(declared) <= sqlite_fixtures,
          str(set(declared) - sqlite_fixtures))
    # Declarations are keyed by the run's name, which is the command unless the
    # entry is one of several runs of it (`robot-capacity --agents 3`).
    commands = {entry.get("name", entry["vbx"]) for entry in parity.COMPARISONS if entry.get("bv")}
    for fixture, entries in declared.items():
        for (command, path), reason in entries.items():
            check(f"{fixture}: --{command} {path} names a compared command",
                  command in commands, command)
            check(f"{fixture}: --{command} {path} is one exact path",
                  path.startswith(".") and "*" not in path, path)
            check(f"{fixture}: --{command} {path} gives its reason, citing ADR-024",
                  isinstance(reason, str) and "ADR-024" in reason, str(reason))

    hash_diff = ".data_hash: 'a' vs 'b'"
    velocity_diff = ".project_health.velocity.estimated: missing on the vbx side"
    other_diff = ".project_health.counts.total: 21 vs 20"

    undeclared, accepted, stale = parity.split_declared(
        [hash_diff], "readiness (beads.db)", "robot-next")
    check("a declared path is accepted on its own fixture",
          undeclared == [] and [d for d, _ in accepted] == [hash_diff], f"{undeclared} {accepted}")
    check("its reason travels with it", "ADR-024" in accepted[0][1] if accepted else False)

    undeclared, accepted, _ = parity.split_declared([hash_diff], "readiness", "robot-next")
    check("the same path still fails on the JSONL readiness fixture",
          undeclared == [hash_diff] and accepted == [], f"{undeclared} {accepted}")
    undeclared, accepted, _ = parity.split_declared([hash_diff], "demo", "robot-next")
    check("and on the demo", undeclared == [hash_diff] and accepted == [], str(undeclared))

    undeclared, accepted, _ = parity.split_declared(
        [velocity_diff, other_diff], "readiness (beads.db)", "robot-triage")
    check("an undeclared difference on the beads.db still fails",
          undeclared == [other_diff], str(undeclared))
    check("beside it the declared one is still reported",
          [d for d, _ in accepted] == [velocity_diff], str(accepted))

    undeclared, _, _ = parity.split_declared([hash_diff], "readiness (beads.db)", "robot-triage")
    check("a path declared for one command is not declared for another",
          undeclared == [hash_diff], str(undeclared))

    _, _, stale = parity.split_declared([], "readiness (beads.db)", "robot-next")
    check("a declaration that no longer fires is reported stale",
          stale == [".data_hash", ".scope_hash"], str(stale))
    _, _, stale = parity.split_declared([], "demo", "robot-next")
    check("a fixture with no declarations has nothing stale", stale == [], str(stale))


def test_label_scoped_runs(parity) -> None:
    print("\nLabel-scoped runs (vbx-7dm)")
    names = [entry.get("name", entry["vbx"]) for entry in parity.COMPARISONS]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    # Two runs of one command under one name would share their report line and
    # their DECLARED_DIFFERENCES entries.
    check("every run has its own name", duplicates == [], str(duplicates))

    scoped = [entry for entry in parity.COMPARISONS if "--label" in entry.get("vbx_args", [])]
    compared = {
        entry["vbx_args"][entry["vbx_args"].index("--label") + 1]
        for entry in scoped
        if entry["vbx"] == "robot-graph" and entry.get("compare") is not False
    }
    check("the graph is compared under a known and an unknown label",
          {"engine", "no-such-label"} <= compared, str(compared))
    for entry in scoped:
        check(f"--{entry['vbx']} passes the same label to bv",
              entry.get("bv_args") == entry["vbx_args"], str(entry))

    gaps = [entry for entry in parity.COMPARISONS
            if entry.get("compare") is False and "--label" in entry.get("name", "")]
    # Vacuous once every label-scoped run matches, as it has since #103.
    check("a label-scoped command that does not match yet is a skip naming its bead",
          all("(vbx-" in entry.get("note", "") for entry in gaps),
          str([entry.get("note") for entry in gaps]))


def test_bv_version_gate(parity) -> None:
    print("\nbv's version against the engine's (vbx-1z7)")
    engine = parity.engine_bv_version(ROOT / "Engine" / "bridge" / "go.mod")
    check("the engine's beads_viewer version is read from go.mod",
          engine is not None and engine.startswith("v"), str(engine))
    with tempfile.TemporaryDirectory() as scratch:
        go_mod = Path(scratch) / "go.mod"
        go_mod.write_text("module x\n\nrequire (\n\tgithub.com/Dicklesworthstone/beads_viewer"
                          " v0.25.3-0.20261001000000-abcdef123456 // indirect\n)\n")
        check("a pseudo-version is read whole",
              parity.engine_bv_version(go_mod) == "v0.25.3-0.20261001000000-abcdef123456",
              str(parity.engine_bv_version(go_mod)))
        check("an unreadable go.mod has no version",
              parity.engine_bv_version(Path(scratch) / "absent") is None)

    path = "/opt/homebrew/bin/bv"

    state, message = parity.check_bv_version("v0.25.2", path, "bv v0.25.2\n")
    check("equal versions match", state == "match", message)
    check("equal versions compare and pass",
          parity.bv_skip_reason(state, "v0.25.2", False) is None
          and parity.bv_banner(state, message, False) is None
          and parity.exit_status(0, 0, state, False) == 0)

    state, message = parity.check_bv_version("v0.25.2", path, "bv v0.20.0")
    check("a different version is a mismatch", state == "mismatch", message)
    check("the mismatch names both versions and the path",
          all(part in message for part in ("v0.20.0", "v0.25.2", path)), message)
    check("the mismatch says how to get the matching bv",
          "brew upgrade bv" in message and "releases/tag/v0.25.2" in message, message)
    check("a mismatch compares nothing", parity.bv_skip_reason(state, "v0.25.2", False) is not None)
    banner = parity.bv_banner(state, message, False) or ""
    check("a mismatch prints a banner naming both versions",
          "BV VERSION MISMATCH" in banner and "v0.20.0" in banner and "v0.25.2" in banner, banner)
    check("a mismatch fails the run even with nothing differing",
          parity.exit_status(0, 0, state, False) == 1)
    check("--allow-bv-mismatch compares anyway",
          parity.bv_skip_reason(state, "v0.25.2", True) is None)
    check("--allow-bv-mismatch still warns",
          "BV VERSION MISMATCH" in (parity.bv_banner(state, message, True) or ""))
    check("--allow-bv-mismatch passes a clean run",
          parity.exit_status(0, 0, state, True) == 0)
    check("--allow-bv-mismatch does not hide a difference",
          parity.exit_status(1, 0, state, True) == 1)

    for output in ("", "beads viewer (devel)", "<[Errno 13] Permission denied>"):
        state, message = parity.check_bv_version("v0.25.2", path, output)
        check(f"an unparseable version ({output!r}) is a mismatch, not a match",
              state == "mismatch" and "cannot read a version" in message and path in message,
              f"{state}: {message}")
    state, message = parity.check_bv_version(None, path, "bv v0.25.2")
    check("an unreadable engine version is a mismatch too", state == "mismatch", message)

    state, message = parity.check_bv_version("v0.25.2", None, None)
    check("a missing bv is missing", state == "missing", message)
    check("a missing bv skips every comparison",
          parity.bv_skip_reason(state, "v0.25.2", False) == "bv is not installed")
    check("a missing bv says skipped, not passed", "skipped rather than passed" in message, message)
    check("a missing bv does not fail the run", parity.exit_status(0, 0, state, False) == 0)

    check("`bv --version` output is parsed", parity.parse_bv_version("bv v0.25.2") == "v0.25.2")
    check("a version without a v is parsed", parity.parse_bv_version("0.25.2") == "v0.25.2")


def main() -> int:
    parity = load_parity()
    test_bv_version_gate(parity)
    test_label_scoped_runs(parity)
    test_envelope_only_keys_are_one_list(parity)
    test_declared_differences_are_narrow(parity)
    test_sqlite_workspace_keeps_every_record(parity)
    test_every_difference_is_reported(parity)
    test_default_run_covers_every_fixture(parity)
    test_bv_zero_times_are_dropped_only_when_zero(parity)
    print()
    if FAILURES:
        print(f"{len(FAILURES)} failed:")
        for failure in FAILURES:
            print(f"  {failure}")
        return 1
    print("all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
