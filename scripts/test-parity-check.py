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
    check("the demo, the readiness fixture and its beads.db form are all compared",
          names == ["demo", "readiness", "readiness (beads.db)"], str(names))
    for fixture in parity.FIXTURES:
        path = ROOT / fixture["workspace"] / ".beads" / "issues.jsonl"
        check(f"{fixture['workspace']} exists", path.exists(), str(path))


def main() -> int:
    parity = load_parity()
    test_sqlite_workspace_keeps_every_record(parity)
    test_every_difference_is_reported(parity)
    test_default_run_covers_every_fixture(parity)
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
