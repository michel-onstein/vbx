#!/usr/bin/env python3
"""Tests for parity-check.py's own machinery, which needs neither binary.

The parity run is only as good as the workspace it compares and the report it
prints. Two pieces of that are code rather than configuration: the beads.db
built from a fixture's JSONL, and the difference walk. Both are checked here so
a harness bug cannot read as agreement.
"""

from __future__ import annotations

import importlib.util
import json
import re
import sqlite3
import subprocess
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


def test_sqlite_workspace_skips_a_malformed_line(parity) -> None:
    print("\nbeads.db built from Fixtures/dropped (vbx-dv5)")
    jsonl = ROOT / "Fixtures" / "dropped" / ".beads" / "issues.jsonl"
    with tempfile.TemporaryDirectory() as scratch:
        workspace = parity.build_sqlite_workspace(jsonl, Path(scratch) / "ws")
        connection = sqlite3.connect(workspace / ".beads" / "beads.db")
        try:
            ids = sorted(row[0] for row in connection.execute("SELECT id FROM issues"))
        finally:
            connection.close()
    check("the malformed line is no row, and the invalid record still is one",
          ids == ["drop-1", "drop-2", "drop-3", "drop-4", "drop-6"], str(ids))


def test_dropped_fixture_drops_what_it_says(parity) -> None:
    print("\nFixtures/dropped (vbx-dv5)")
    lines = (ROOT / "Fixtures" / "dropped" / ".beads" / "issues.jsonl").read_text().splitlines()
    malformed, records = [], []
    for number, line in enumerate(lines, start=1):
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            malformed.append(number)
    check("exactly one line is malformed", malformed == [5], str(malformed))
    invalid = [record["id"] for record in records
               if record.get("updated_at", "") < record.get("created_at", "")]
    check("exactly one record is updated before it was created", invalid == ["drop-6"], str(invalid))
    # vbx-1l6: the feedback runs compare stderr, where bv prints the loader's
    # warnings, so they run over the dropped records rather than skipping them.
    check("no fixture skips the feedback sequences",
          all("skip_feedback" not in fixture for fixture in parity.FIXTURES))
    over_dropped = [entry["name"] for entry in parity.FEEDBACK_COMPARISONS
                    if "dropped" in entry.get("only", {"dropped"})]
    check("a feedback verdict that lands is compared over the dropped records",
          "feedback-accept over dropped records" in over_dropped, str(over_dropped))
    exported = [entry["name"] for entry in parity.EXPORT_COMPARISONS
                if {"dropped", "dropped (beads.db)", "dropped (workspace)"} <= entry["only"]]
    check("an export, an export-md and an unmatched label are compared over the dropped records",
          {"export", "export-md", "export --label no-such-label"} <= set(exported), str(exported))
    check("load_stats is lifted with the rest of the envelope", "load_stats" in parity.ENVELOPE_KEYS,
          str(parity.ENVELOPE_KEYS))
    keyed = {entry["vbx"] for entry in parity.COMPARISONS
             if "load_stats" in entry.get("keys", ()) and "dropped" in entry.get("only", ())}
    check("the commands whose subtree leaves load_stats out compare it on its own",
          keyed == {"robot-priority", "robot-insights", "robot-sprint-list", "robot-search",
                    "robot-blocker-chain"}, str(sorted(keyed)))
    # vbx-6su: triage, plan, alerts and metrics carry the envelope, so each
    # comparison of them takes every envelope key — lifted from beside bv's
    # nested payload, or named among the keys compared.
    envelope = set(parity.ENVELOPE_KEYS)
    four = {"robot-triage", "robot-plan", "robot-alerts", "robot-metrics"}
    runs = [entry for entry in parity.COMPARISONS if entry["vbx"] in four and not entry.get("rejects")]
    short = [entry.get("name", entry["vbx"]) for entry in runs
             if not envelope <= set(entry.get("bv_lift", ())) | set(entry.get("keys", ()))
             and (entry.get("bv_path") or entry.get("keys"))]
    check("triage, plan, alerts and metrics compare their whole envelope",
          {entry["vbx"] for entry in runs} == four and short == [], str(short))


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
    check("the demo, the readiness fixture, its beads.db form, the sprints, both feedback"
          " fixtures, the search fixture, the recipes workspace, the dropped records in"
          " both forms and as a workspace member, the discovery layout, and the dropped"
          " records and workspace reached through a symlink are all compared",
          names == ["demo", "readiness", "readiness (beads.db)", "sprints", "feedback",
                    "feedback-few", "search", "recipes", "dropped", "dropped (beads.db)",
                    "dropped (workspace)", "discovery", "history",
                    "history (vbx baseline)", "dropped (symlinked)",
                    "dropped (workspace, symlinked)"],
          str(names))
    for fixture in parity.FIXTURES:
        if fixture.get("history"):
            continue  # built at run time; see test_history_workspace
        root = ROOT / fixture["workspace"]
        path = root / ".beads" / "issues.jsonl"
        if (root / ".bv" / "workspace.yaml").exists():
            path = root / ".bv" / "workspace.yaml"
        check(f"{fixture['workspace']} exists", path.exists(), str(path))

    # The multi-repository fixture (vbx-koc): every member it names holds an
    # export, and one of them a line that does not parse — the dropped record
    # the claim gate must see.
    members = ROOT / "Fixtures" / "dropped-workspace"
    exports = {name: members / name / ".beads" / "issues.jsonl" for name in ("api", "web")}
    check("both dropped-workspace members hold an export",
          all(path.exists() for path in exports.values()), str(exports))

    def parses(line: str) -> bool:
        try:
            json.loads(line)
            return True
        except ValueError:
            return False

    broken = [name for name, path in exports.items() if path.exists()
              and not all(parses(line) for line in path.read_text().splitlines() if line)]
    check("exactly one dropped-workspace member holds a malformed line",
          broken == ["web"], str(broken))

    # A command scoped to one fixture must name one that exists, or it is
    # skipped everywhere and never compared at all.
    for entry in parity.COMPARISONS:
        for name in entry.get("only", ()):
            check(f"--{entry['vbx']} is scoped to a real fixture ({name})", name in names)
    sprints = ROOT / "Fixtures" / "sprints" / ".beads" / "sprints.jsonl"
    check("the sprints fixture has a sprint file", sprints.exists(), str(sprints))


def test_history_workspace(parity) -> None:
    print("\nThe history fixture (vbx-9gl)")
    with tempfile.TemporaryDirectory() as scratch:
        heads = []
        for name in ("one", "two"):
            workspace = parity.build_history_workspace(Path(scratch) / name, None)
            head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=workspace,
                                  capture_output=True, text=True, check=True).stdout.strip()
            count = subprocess.run(["git", "rev-list", "--count", "HEAD"], cwd=workspace,
                                   capture_output=True, text=True, check=True).stdout.strip()
            heads.append(head)
            named = subprocess.run(
                ["git", "log", "--format=%s", "--name-only", "-1", "--grep", "hist-q7x"],
                cwd=workspace, capture_output=True, text=True, check=True).stdout.split()
        beads = [json.loads(line) for line in
                 (workspace / ".beads" / "issues.jsonl").read_text().splitlines()]
        baseline = workspace / ".bv" / "baseline.json"
        day_four = [json.loads(line) for line in
                    parity.history_beads_jsonl(4, {"hist-1": ("closed", 4)}).splitlines()]

    # Fixed authors, dates and configuration: the same SHAs on every run, so
    # a difference in a resolved revision is never the fixture's.
    check("two builds have the same HEAD", heads[0] == heads[1], str(heads))
    check("every commit is built", count == str(len(parity.HISTORY_COMMITS)), count)
    status = {bead["id"]: bead["status"] for bead in beads}
    check("hist-8 ends as a tombstone, hist-1 closed and hist-7 present",
          status.get("hist-8") == "tombstone" and status.get("hist-1") == "closed"
          and "hist-7" in status, str(status))
    blockers = {bead["id"]: [dep["depends_on_id"] for dep in bead.get("dependencies", [])]
                for bead in beads}
    check("hist-6 and hist-7 block each other, the cycle drift must report",
          blockers.get("hist-6") == ["hist-7"] and blockers.get("hist-7") == ["hist-6"],
          str(blockers))
    check("the day-4 beads have neither hist-7 nor the cycle",
          "hist-7" not in {bead["id"] for bead in day_four}
          and not any(bead.get("dependencies") and bead["id"] == "hist-6" for bead in day_four),
          str(day_four))
    check("no bv, no baseline: nothing to compare against", not baseline.exists())
    # vbx-znj: a commit names a br-shaped id without touching the beads, so
    # only --id-pattern can link it.
    check("a commit names hist-q7x and changes only code",
          "hist-q7x" in status and named[-1:] == ["src/cache.go"]
          and not any(".beads" in part for part in named), str(named))
    check("hist-q7x has no numeric suffix for bv's own patterns to find",
          not re.search(r"-\d+\b", "hist-q7x")
          and re.fullmatch(parity.HISTORY_ID_PATTERN, "hist-q7x")
          and not re.fullmatch(parity.HISTORY_ID_PATTERN, "hist-1"))
    pattern_runs = [entry for entry in parity.COMPARISONS
                    if any(arg.startswith("--id-pattern") for arg in entry.get("bv_args", []))]
    check("--id-pattern runs exist, and every one that is answered bypasses bv's cache",
          pattern_runs and all(entry.get("rejects") or entry.get("env") == {"BV_NO_CACHE": "1"}
                               for entry in pattern_runs), str(len(pattern_runs)))
    check("history and orphans are compared under --id-pattern",
          {"robot-history", "robot-orphans"} <= {entry["vbx"] for entry in pattern_runs})

    # bv's drift exits 1 or 2 when it finds drift, so its runs compare the
    # exit status rather than skipping bv's non-zero one.
    drift = [entry for entry in parity.COMPARISONS
             if entry["vbx"] == "robot-drift" and not entry.get("rejects")]
    check("every drift run compares the exit status",
          drift and all(entry.get("exits") for entry in drift), str(drift))
    check("every drift run asks bv for --check-drift",
          all(entry["bv_args"][:1] == ["--check-drift"] for entry in drift))
    # vbx-6s8: each side reads the baseline the other saved.
    savers = {fixture["name"]: bool(fixture.get("vbx_baseline"))
              for fixture in parity.FIXTURES if fixture.get("history")}
    check("one history fixture has bv's baseline and one vbx's",
          savers == {"history": False, "history (vbx baseline)": True}, str(savers))
    scanned = [entry for entry in drift if entry["name"] != "robot-drift no baseline"]
    check("every drift run reads both baselines",
          all(entry["only"] == set(savers) for entry in scanned), str(scanned))


def test_baseline_save(parity) -> None:
    print("\n--save-baseline (vbx-6s8)")
    entry = parity.BASELINE_SAVE_COMPARISONS[0]
    check("the save runs inside the history repository, so the commit is compared",
          entry["only"] == {"history"} and entry["args"][0] == "--save-baseline")
    check("bv's map-ordered ties are compared in id order",
          parity.ranked_ties([{"id": "b", "value": 1.0}, {"id": "a", "value": 1.0},
                              {"id": "c", "value": 2.0}])
          == [{"id": "c", "value": 2.0}, {"id": "a", "value": 1.0},
              {"id": "b", "value": 1.0}])

    saved = {"version": 1, "commit_sha": "abc", "branch": "main", "stats": {"node_count": 2}}
    same = (0, "Baseline saved to <copy>\n", "", saved)
    check("two identical saves are no difference",
          parity.baseline_save_differences(same, same) == [])
    other = (0, "Baseline saved to <copy>\n", "", dict(saved, commit_sha="def"))
    check("a different commit is a difference",
          any("commit_sha" in line for line in parity.baseline_save_differences(other, same)))
    check("a file on one side only is a difference",
          parity.baseline_save_differences((0, same[1], "", None), same) != [])
    check("another summary is a difference",
          parity.baseline_save_differences((0, "Baseline saved to x\n", "", saved), same) != [])
    check("another exit status is a difference",
          parity.baseline_save_differences((1, "", "boom", None), same) != [])

    with tempfile.TemporaryDirectory() as scratch:
        workspace = Path(scratch) / "ws"
        (workspace / ".bv").mkdir(parents=True)
        (workspace / ".bv" / "baseline.json").write_text("{}")
        printer = Path(scratch) / "printer"
        created = "Baseline created: Mon, 01 Jan 2026 00:00:00 UTC"
        printer.write_text(
            "#!/bin/sh\nmkdir -p .bv\necho '{\"created_at\": \"now\", \"version\": 1}'"
            " > .bv/baseline.json\n"
            f"echo \"Baseline saved to $PWD/.bv/baseline.json\"\necho '{created}'\n"
            "printf '\\nTop PageRank:\\n  b: 0.5000\\n  a: 0.5000\\n  c: 0.9000\\n'\n")
        printer.chmod(0o755)
        status, out, _, written = parity.run_baseline_save(
            str(printer), [], workspace, Path(scratch) / "copy")
    check("the save runs on a copy with no baseline of its own, and drops created_at",
          status == 0 and written == {"version": 1}, str(written))
    check("the copy's path and the creation time are normalised",
          out.startswith("Baseline saved to <copy>/.bv/baseline.json\n"
                         "Baseline created: <now>\n"), out)
    check("the summary's leaders are in value then id order",
          out.endswith("Top PageRank:\n  c: 0.9000\n  a: 0.5000\n  b: 0.5000\n"), out)


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
    ported = {"output_format", "source_path", "source_kind", "scope_hash", "data_hash",
              "load_stats"}
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
    check("only the beads.db fixtures declare differences",
          set(declared) == {"readiness (beads.db)", "dropped (beads.db)"}, str(sorted(declared)))
    dropped = {path for (_, path) in declared["dropped (beads.db)"]}
    check("the dropped beads.db declares only the lossy fingerprint, never load_stats",
          dropped == {".data_hash", ".scope_hash", ".suggestions.data_hash"}, str(dropped))
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

    # Priority compares its recommendations alone, so it declares no hash.
    undeclared, _, _ = parity.split_declared([hash_diff], "readiness (beads.db)", "robot-priority")
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
    # The arguments may be spelled differently — an id as --id or as the
    # flag's value — but the scope must be the same on both sides.
    for entry in scoped:
        vbx_args, bv_args = entry["vbx_args"], entry.get("bv_args", [])
        same = all(
            (flag in vbx_args) == (flag in bv_args)
            and (flag not in vbx_args
                 or vbx_args[vbx_args.index(flag) + 1] == bv_args[bv_args.index(flag) + 1])
            for flag in ("--label", "--recipe"))
        check(f"--{entry.get('name', entry['vbx'])} passes the same scope to bv", same, str(entry))

    gaps = [entry for entry in parity.COMPARISONS
            if entry.get("compare") is False and "--label" in entry.get("name", "")]
    # Vacuous once every label-scoped run matches, as it has since #103.
    check("a label-scoped command that does not match yet is a skip naming its bead",
          all("(vbx-" in entry.get("note", "") for entry in gaps),
          str([entry.get("note") for entry in gaps]))


def cli_scope_rules() -> dict[str, str]:
    """Each vbx-cli command's ScopeRule, read from its command table."""
    import re
    source = (ROOT / "Sources" / "vbx-cli" / "main.swift").read_text()
    table = source.split("let robotCommands: [RobotCommand] = [", 1)[1].split("\n]\n", 1)[0]
    rules = {}
    for block in re.split(r"RobotCommand\(", table)[1:]:
        flag = re.match(r'\s*"([^"]+)"', block)
        rule = re.search(r"scope: \.(\w+)", block)
        if flag:
            rules[flag.group(1)] = rule.group(1) if rule else "ignored"
    return rules


def cli_load_warning_commands() -> set[str]:
    """The vbx-cli commands that print the loader's warnings, read from its table."""
    import re
    source = (ROOT / "Sources" / "vbx-cli" / "main.swift").read_text()
    table = source.split("let robotCommands: [RobotCommand] = [", 1)[1].split("\n]\n", 1)[0]
    found = set()
    for block in re.split(r"RobotCommand\(", table)[1:]:
        flag = re.match(r'\s*"([^"]+)"', block)
        if flag and "printsLoadWarnings: true" in block:
            found.add(flag.group(1))
    return found


def test_load_warnings_follow_bv(parity) -> None:
    print("\nThe loader's warnings reach stderr where bv prints them (vbx-1l6)")
    # bv prints them whenever it loads issues outside robot mode. Of the
    # flags in the command table that is the two feedback verdicts and
    # --save-baseline (vbx-6s8): show and reset answer before bv loads, and
    # every --robot-* flag is robot mode.
    found = cli_load_warning_commands()
    check("feedback-accept, feedback-ignore and save-baseline print them, and nothing else"
          " in the table",
          found == {"feedback-accept", "feedback-ignore", "save-baseline"}, str(found))
    source = (ROOT / "Sources" / "vbx-cli" / "main.swift").read_text()
    export = source.split("if let path = options.exportPath ?? options.exportMarkdownPath {", 1)[1]
    export = export.split("\n    }\n", 1)[0]
    check("--export and --export-md print them, after --recipe resolves and before the export",
          export.index("recipeResolves") < export.index("printLoadWarnings(info)")
          < export.index("runExport"), export)


def test_every_scoped_command_is_compared_under_scope(parity) -> None:
    print("\nEvery command vbx-cli scopes is compared under a scope (vbx-shz)")
    rules = cli_scope_rules()
    scoped = sorted(flag for flag, rule in rules.items() if rule == "scoped")
    check("the CLI table was read", len(rules) > 40 and "robot-label-health" in scoped,
          str(rules))

    def runs(command: str):
        for entry in parity.COMPARISONS:
            if entry["vbx"] == command and entry.get("compare") is not False:
                yield entry.get("vbx_args", [])

    def value(args: list[str], flag: str):
        return args[args.index(flag) + 1] if flag in args else None

    for command in scoped:
        labels = {value(args, "--label") for args in runs(command) if "--recipe" not in args}
        recipes = [args for args in runs(command) if "--recipe" in args]
        check(f"--{command} runs under a label and an unknown label",
              "no-such-label" in labels and len(labels - {None, "no-such-label"}) > 0,
              str(labels))
        check(f"--{command} runs under a recipe, alone and beside a label",
              any("--label" not in args for args in recipes)
              and any("--label" in args for args in recipes), str(recipes))

    # A command the CLI refuses a scope for is not compared under one: bv
    # would answer, vbx-cli exits 2, and the run could only ever differ.
    unported = {flag for flag, rule in rules.items() if rule == "unported"}
    compared = {entry["vbx"] for entry in parity.COMPARISONS
                if {"--label", "--recipe"} & set(entry.get("vbx_args", []))}
    check("no refused command is compared under a scope", not (unported & compared),
          str(unported & compared))


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


def test_triage_feedback_and_not_ready(parity) -> None:
    print("\nTriage feedback and not-ready labels (vbx-5ba)")
    for fixture in ("feedback", "feedback-few"):
        path = ROOT / "Fixtures" / fixture / ".beads" / "feedback.json"
        check(f"{fixture} has a feedback file", path.exists(), str(path))

    whole = {"triage": {"recommendations": []}, "feedback": {"applied": True}}
    lifted = parity.lift(whole, whole["triage"], ("feedback",))
    check("bv's feedback block is lifted into the triage it sits beside",
          lifted == {"recommendations": [], "feedback": {"applied": True}}, str(lifted))
    check("lifting copies rather than editing bv's payload", "feedback" not in whole["triage"])
    bare = {"triage": {"recommendations": []}}
    check("a block bv omits stays omitted, so one vbx adds still differs",
          parity.lift(bare, bare["triage"], ("feedback",)) == {"recommendations": []})

    # A rejection compares exit status and stderr, so it has no payload to
    # lift into.
    triage = [entry for entry in parity.COMPARISONS
              if entry["vbx"] == "robot-triage" and entry.get("compare") is not False
              and not entry.get("rejects")]
    check("every triage run compares bv's feedback block",
          all("feedback" in entry.get("bv_lift", ()) for entry in triage),
          str([entry.get("name", entry["vbx"]) for entry in triage]))

    gated = [entry for entry in parity.COMPARISONS
             if "not-ready" in entry.get("name", "").lower()
             or "NOT_READY" in entry.get("name", "")]
    for command in ("robot-triage", "robot-next"):
        runs = [entry for entry in gated if entry["vbx"] == command]
        check(f"--{command} is compared under the flag, the environment and both",
              {bool(entry.get("vbx_args")) for entry in runs} == {True, False}
              and any(entry.get("env") and entry.get("vbx_args") for entry in runs),
              str(runs))
    for entry in gated:
        check(f"--{entry['name']} gives bv what it gives vbx",
              entry.get("bv_args") == entry.get("vbx_args"), str(entry))


def test_feedback_recording(parity) -> None:
    print("\nRecording triage feedback (vbx-rt3)")
    flags = {parity.feedback_step(step)[1][0]
             for entry in parity.FEEDBACK_COMPARISONS for step in entry["steps"]}
    check("all four of bv's feedback flags are compared",
          flags == {"--feedback-accept", "--feedback-ignore", "--feedback-reset", "--feedback-show"},
          str(flags))

    steps = [["--feedback-accept", "fb-5"], ["--feedback-show"]]
    show = '{"total_events": 5, "updated_at": "%s", "effective_weights": {"Risk": %s}}'
    stored = {"version": "1.0", "updated_at": "%s",
              "events": [{"issue_id": "fb-5", "score": 0.376, "timestamp": "%s"}]}

    def side(stamp: str, weight: str, score: float = 0.376, volatile: bool = True):
        file = parity.json.loads(parity.json.dumps(stored).replace("%s", stamp))
        file["events"][0]["score"] = score
        return ([(0, "Recorded accept feedback for fb-5 (score: 0.376)\n", "", False),
                 (0, show % (stamp, weight), "", volatile)], {".beads/feedback.json": file})

    same = parity.feedback_differences(
        side("2026-10-01T10:00:00Z", "0.12121212121212123"),
        side("2026-10-01T10:00:01Z", "0.12121212121212122"), steps)
    check("wall-clock stamps and last-bit float noise are not differences", same == [], str(same))

    pinned = parity.feedback_differences(
        side("2026-10-01T10:00:00Z", "0.1", volatile=False),
        side("2026-10-01T10:00:01Z", "0.1", volatile=False), steps)
    check("show's updated_at is compared when nothing was written",
          any("updated_at" in difference for difference in pinned), str(pinned))

    scored = parity.feedback_differences(
        side("t", "0.1"), side("t", "0.1", score=0.377), steps)
    check("a recorded score that differs is a difference",
          any("score" in difference for difference in scored), str(scored))

    vbx_steps, vbx_files = side("t", "0.1")
    failed = parity.feedback_differences(
        ([(1, "", "Issue not found: x\n", False)], {}),
        ([(1, "", "Issue not found: y\n", False)], {}), [["--feedback-accept", "x"]])
    check("a failing step's stderr is compared", len(failed) == 1, str(failed))
    absent = parity.feedback_differences(
        (vbx_steps, vbx_files), (vbx_steps, {}), steps)
    check("a file only one side wrote is a difference",
          any("feedback.json" in difference for difference in absent), str(absent))
    # vbx-v1t: from a folder below a workspace, the file landing in the
    # root's .beads rather than the folder's is the bug, so where is compared.
    elsewhere = parity.feedback_differences(
        (vbx_steps, {".beads/feedback.json": vbx_files[".beads/feedback.json"]}),
        (vbx_steps, {"notes/.beads/feedback.json": vbx_files[".beads/feedback.json"]}), steps)
    check("the same file written to another directory is a difference",
          any(difference.startswith(".beads/feedback.json") for difference in elsewhere)
          and any(difference.startswith("notes/") for difference in elsewhere), str(elsewhere))
    check("a step run from a folder is named with it",
          parity.feedback_step_text({"cwd": "notes", "args": ["--feedback-show"]})
          == "(in notes) --feedback-show")

    with tempfile.TemporaryDirectory() as scratch:
        workspace = Path(scratch) / "workspace"
        (workspace / "notes").mkdir(parents=True)
        (workspace / ".beads").mkdir()
        (workspace / "member").mkdir()
        script = Path(scratch) / "fake-bv"
        # Fails naming the folder it ran in, as bv's errors name the path.
        script.write_text("#!/bin/sh\necho \"Error: open $PWD/.beads\" >&2\nexit 1\n")
        script.chmod(0o755)
        runs = [parity.run_feedback_sequence(
                    str(script), [{"cwd": "notes", "args": ["--feedback-reset"]}], workspace,
                    Path(scratch) / side, whole=True)
                for side in ("vbx", "bv")]
        check("a whole-workspace sequence copies the folders discovery reads",
              (Path(scratch) / "vbx" / "member").is_dir(), str(list(Path(scratch).iterdir())))
        check("each side's copy is named alike in what it prints",
              runs[0][0][0][2] == runs[1][0][0][2] and "<copy>/notes/.beads" in runs[0][0][0][2],
              str(runs))


def test_report_exports(parity) -> None:
    print("\nReport exports (vbx-im9)")
    formats = set()
    for entry in parity.EXPORT_COMPARISONS:
        args = entry["args"]
        if "--export-format" in args:
            formats.add(args[args.index("--export-format") + 1])
    check("every bv export format is compared",
          {"markdown", "json", "csv", "mermaid"} <= formats, str(formats))
    names = [entry["name"] for entry in parity.EXPORT_COMPARISONS]
    check("each export run has its own name", len(names) == len(set(names)), str(names))
    joined = [" ".join(entry["args"]) for entry in parity.EXPORT_COMPARISONS]
    check("a template, a graph-less run and a recipe default are all compared",
          any("{template}" in a for a in joined)
          and any("--export-include-graph=false" in a for a in joined)
          and any("{recipe_json}" in a for a in joined), str(joined))
    check("--export-md is compared too",
          any(entry.get("flag") == "--export-md" for entry in parity.EXPORT_COMPARISONS))

    with tempfile.TemporaryDirectory() as scratch:
        places = parity.write_export_inputs(Path(scratch))
        recipe = Path(places["recipe_template"]).read_text()
        check("a recipe's template default names the written template",
              places["template"] in recipe and "{template}" not in recipe, recipe)

    ok = (0, "Exporting 1 issues to r...\nDone!\n", "", b"# Beads Export\n*Generated: x*\n")
    check("identical runs are no difference", parity.export_differences(ok, ok) == [])
    other = (0, ok[1], "", b"# Beads Export\n*Generated: y*\n")
    found = parity.export_differences(other, ok)
    check("a differing line is reported by number",
          len(found) == 1 and "line 2" in found[0], str(found))
    check("a file only one side wrote is a difference",
          len(parity.export_differences((0, ok[1], "", None), ok)) == 1)
    failed = parity.export_differences((1, "", "a\n", None), (1, "", "b\n", None))
    check("a failure's stderr is compared", len(failed) == 1, str(failed))

    def report(authority) -> bytes:
        body = {"title": "Beads Export", "source_authority": authority,
                "data_hash": "h", "issues": [{"id": "a"}]}
        if authority is not None:
            body["authority_hash"] = "x"
        return parity.json.dumps(body).encode()

    vbx_json = (0, ok[1], "", report(None))
    bv_json = (0, ok[1], "", report({"claim_safe": True}))
    check("a JSON report drops only the envelope-only keys",
          parity.export_differences(vbx_json, bv_json) == [],
          str(parity.export_differences(vbx_json, bv_json)))
    changed = (0, ok[1], "", report(None).replace(b'"h"', b'"g"'))
    found = parity.export_differences(changed, bv_json)
    check("a JSON report's data hash is still compared",
          any("data_hash" in difference for difference in found), str(found))


def test_export_hooks(parity) -> None:
    print("\nExport hooks (vbx-uos)")
    names = [entry["name"] for entry in parity.HOOK_COMPARISONS]
    check("each hook run has its own name", len(names) == len(set(names)), str(names))
    check("every hook config runs with and without --no-hooks",
          all({(entry["config"], "--no-hooks" in entry["args"])
               for entry in parity.HOOK_COMPARISONS} >= {(config, False), (config, True)}
              for config in parity.HOOK_CONFIGS), str(names))
    yaml = "".join(parity.HOOK_CONFIGS.values())
    check("pre- and post-export, an on_error: fail, a timeout and bad YAML are all covered",
          all(part in yaml for part in ("pre-export:", "post-export:", "on_error: fail",
                                        "timeout:", "hooks: [")), yaml)
    check("--export-md and a JSON export run the hooks too",
          any(entry.get("flag") == "--export-md" for entry in parity.HOOK_COMPARISONS)
          and any("json" in entry["args"] for entry in parity.HOOK_COMPARISONS))

    with tempfile.TemporaryDirectory() as scratch:
        workspace = parity.build_hook_workspace(
            ROOT / "Fixtures" / "demo", Path(scratch) / "ws", "pass")
        check("the hooked workspace is the demo's beads beside .bv/hooks.yaml",
              (workspace / ".beads" / "issues.jsonl").exists()
              and (workspace / ".bv" / "hooks.yaml").read_text() == parity.HOOK_CONFIGS["pass"])

    summary = "  [OK] before ({})\n  [OK] after ({})\n"
    for left, right in (("3ms", "12ms"), ("0s", "1.002s"), ("250µs", "1m0s")):
        check(f"run times {left} and {right} normalise alike",
              parity.HOOK_DURATION.sub("x", summary.format(left, left))
              == parity.HOOK_DURATION.sub("x", summary.format(right, right)))
    check("a timeout is not a run time",
          parity.HOOK_DURATION.sub("x", "  [FAIL] slow: timeout after 200ms\n")
          == "  [FAIL] slow: timeout after 200ms\n")

    ok = ((0, "Done!\n", "", b"r"), {"report.pre": "absent\n"})
    check("identical hooked runs are no difference", parity.hook_differences(ok, ok) == [])
    found = parity.hook_differences(((0, "Done!\n", "", b"r"), {"report.pre": "present\n"}), ok)
    check("a differing marker is a difference", len(found) == 1 and "report.pre" in found[0],
          str(found))
    found = parity.hook_differences(((0, "Done!\n", "", b"r"), {}), ok)
    check("a marker only one side left is a difference", len(found) == 1, str(found))


def cli_before_discovery_commands() -> set[str]:
    """The vbx-cli commands answered before workspace discovery, from its table."""
    import re
    source = (ROOT / "Sources" / "vbx-cli" / "main.swift").read_text()
    table = source.split("let robotCommands: [RobotCommand] = [", 1)[1].split("\n]\n", 1)[0]
    found = set()
    for block in re.split(r"RobotCommand\(", table)[1:]:
        flag = re.match(r'\s*"([^"]+)"', block)
        if flag and "answersBeforeDiscovery: true" in block:
            found.add(flag.group(1))
    return found


def test_feedback_before_discovery(parity) -> None:
    print("\nFeedback flags answer before workspace discovery (vbx-v1t)")
    found = cli_before_discovery_commands()
    check("the four feedback flags, and nothing else in the table, skip discovery",
          found == {"feedback-accept", "feedback-ignore", "feedback-reset", "feedback-show"},
          str(found))
    by_fixture = {}
    for entry in parity.FEEDBACK_COMPARISONS:
        for fixture in entry.get("only", ()):
            by_fixture.setdefault(fixture, []).append(entry)
    for fixture in ("dropped (workspace)", "discovery"):
        entries = by_fixture.get(fixture, [])
        check(f"feedback is compared over {fixture}, on a copy of the whole workspace",
              entries and all(entry.get("whole_workspace") for entry in entries),
              str([entry["name"] for entry in entries]))
        flags = {parity.feedback_step(step)[1][0] for entry in entries for step in entry["steps"]}
        check(f"all four flags are compared over {fixture}",
              {"--feedback-accept", "--feedback-reset", "--feedback-show"} <= flags, str(flags))
    discovered = by_fixture.get("dropped (workspace)", [])
    check("a verdict on a member's bead and one naming --workspace are compared",
          any(parity.feedback_step(step)[1][:2] == ["--feedback-accept", "api-1"]
              for entry in discovered for step in entry["steps"])
          and any("--workspace" in parity.feedback_step(step)[1]
                  for entry in discovered for step in entry["steps"]))
    below = by_fixture.get("discovery", [])
    check("over the discovery fixture, steps run from the folder below the root",
          any(parity.feedback_step(step)[0] == "notes"
              for entry in below for step in entry["steps"]))


def test_workspace_discovery(parity) -> None:
    print("\nWorkspace discovery (vbx-1y5)")
    gate = [entry for entry in parity.COMPARISONS
            if "dropped (workspace)" in entry.get("only", ())]
    check("the claim gate is compared once by discovery, naming no configuration",
          any(entry["vbx_args"] == [] and entry["bv_args"] == [] for entry in gate),
          str([entry["name"] for entry in gate]))
    check("and once with --workspace, spelled the same on both sides",
          any(entry["vbx_args"][:1] == ["--workspace"]
              and entry["vbx_args"] == entry["bv_args"] for entry in gate))

    found = [entry for entry in parity.COMPARISONS if entry.get("only") == {"discovery"}]
    names = [entry["name"] for entry in found]
    check("each discovery run has its own name", len(names) == len(set(names)), str(names))
    layouts = {(entry.get("cwd"), "--workspace" in entry["vbx_args"]) for entry in found}
    check("discovery is compared from the root, a member and a plain folder, with and"
          " without --workspace",
          {(None, False), (None, True), ("api", False), ("notes", False),
           ("notes", True)} <= layouts, str(sorted(layouts, key=str)))
    fixtures = {fixture["name"]: fixture for fixture in parity.FIXTURES}
    check("both workspace fixtures are compared outside this checkout",
          fixtures["dropped (workspace)"].get("outside_checkout")
          and fixtures["discovery"].get("discovery"))

    with tempfile.TemporaryDirectory() as scratch:
        built = parity.build_discovery_workspace(
            ROOT / "Fixtures" / "dropped-workspace", ROOT / "Fixtures" / "demo",
            Path(scratch) / "discovery")
        check("the discovery workspace holds both a .beads and a configuration at its root",
              (built / ".beads" / "issues.jsonl").exists()
              and (built / ".bv" / "workspace.yaml").exists())
        check("its members and a plain folder sit below the root",
              (built / "api" / ".beads").is_dir() and (built / "notes").is_dir()
              and not (built / "notes" / ".beads").exists())
        # vbx-15s: bv reads feedback from the working directory's .beads, so
        # a root feedback.json that applies is what tells the rules apart.
        feedback = built / ".beads" / "feedback.json"
        check("the root's .beads holds enough verdicts for the weights to apply",
              feedback.exists()
              and len(json.loads(feedback.read_text()).get("events", [])) >= 3)

    scored = {(entry["vbx"], entry.get("cwd"), "--workspace" in entry["vbx_args"])
              for entry in found}
    check("triage, next and priority are each compared from the folder below the root,"
          " with and without --workspace (vbx-15s)",
          {(command, "notes", workspace)
           for command in ("robot-triage", "robot-next", "robot-priority")
           for workspace in (False, True)} <= scored, str(sorted(scored, key=str)))


def test_symlinked_working_directory(parity) -> None:
    print("\nA symlinked working directory (vbx-9g1)")
    with tempfile.TemporaryDirectory() as scratch:
        link = parity.build_symlinked_workspace(
            ROOT / "Fixtures" / "dropped-workspace", Path(scratch) / "symlinked")
        check("the workspace is reached through a symlink, returned unresolved",
              link.is_symlink() and link.resolve() != link
              and link.resolve() == (Path(scratch) / "symlinked" / "real").resolve(),
              str(link))
        check("the copy holds the fixture's configuration and members",
              (link / ".bv" / "workspace.yaml").exists()
              and (link / "web" / ".beads" / "issues.jsonl").exists())
        # A stale PWD is what hid the bug: subprocess changes the directory
        # and leaves PWD as the harness's own, which Go's os.Getwd ignores.
        status, out, _ = parity.run("/usr/bin/env", [], link)
        pwd = [line.removeprefix("PWD=") for line in out.splitlines()
               if line.startswith("PWD=")]
        check("run() gives each binary PWD spelled as its working directory was given",
              status == 0 and pwd == [str(link)], str(pwd))

    fixtures = {fixture["name"]: fixture for fixture in parity.FIXTURES}
    check("both dropped fixtures are also compared through a symlink",
          parity.SYMLINKED == {"dropped (symlinked)", "dropped (workspace, symlinked)"}
          and fixtures["dropped (symlinked)"]["workspace"] == "Fixtures/dropped"
          and fixtures["dropped (workspace, symlinked)"]["workspace"]
          == "Fixtures/dropped-workspace", str(parity.SYMLINKED))
    for name, wanted in (("dropped (symlinked)", "load_stats"),
                         ("dropped (workspace, symlinked)", "workspace claim gate")):
        named = [entry["name"] for entry in parity.COMPARISONS
                 if name in entry.get("only", ()) and wanted in entry["name"]]
        check(f"source_path is compared over {name}", bool(named), str(named))
    exports = [entry["name"] for entry in parity.EXPORT_COMPARISONS
               if "dropped (workspace, symlinked)" in entry["only"]]
    check("the workspace discovery notice an export prints is compared through the symlink",
          bool(exports), str(exports))


def test_search(parity) -> None:
    print("\nSearch (vbx-52c)")
    searches = [entry for entry in parity.COMPARISONS if entry["vbx"] == "robot-search"]
    names = [entry["name"] for entry in searches]
    check("each search run has its own name", len(names) == len(set(names)), str(names))
    compared = [entry for entry in searches if not entry.get("rejects")]
    # A scoped search compares the scope it names too (vbx-shz), and only
    # that much of the envelope.
    scoped = [entry for entry in compared
              if {"--label", "--recipe"} & set(entry["vbx_args"])]
    # The load_stats run (vbx-dv5) compares that envelope key and nothing else.
    compared = [entry for entry in compared if not entry["name"].endswith(" load_stats")]
    # Hybrid runs (vbx-rgw) compare more keys, and are checked below.
    hybrid = [entry for entry in compared if "hybrid" in entry["vbx_args"]]
    compared = [entry for entry in compared if entry not in hybrid]
    scoped = [entry for entry in scoped if entry not in hybrid]
    check("search compares the ranking and its echo, not the envelope",
          all(entry.get("keys") == parity.SEARCH_KEYS
              for entry in compared if entry not in scoped)
          and "results" in parity.SEARCH_KEYS and "min_score" in parity.SEARCH_KEYS)
    check("a scoped search compares its scope and hashes as well",
          scoped != [] and all(
              entry.get("keys") == (*parity.SEARCH_KEYS, "scope", "scope_hash", "data_hash")
              for entry in scoped), str([entry["name"] for entry in scoped]))
    check("an exact id outside the label is compared",
          any(entry["vbx_args"][:2] == ["--search", "tax-7"]
              and "finance" in entry["vbx_args"] for entry in scoped))

    def runs(fixture: str) -> list[list[str]]:
        return [entry["bv_args"] for entry in compared
                if entry["only"] == {fixture} and entry not in scoped]

    buried = runs("search")
    check("an exact id the text ranking buries is compared, with its control",
          ["--search", "tax-7", "--search-limit", "1"] in buried
          and ["--search", "tax 7", "--search-limit", "3"] in buried, str(buried))
    check("an id no bead has is compared",
          any(args[1] == "tax-70" for args in buried), str(buried))
    check("an exact id under a threshold that drops it is compared",
          ["--search", "tax-7", "--search-limit", "3", "--search-min-score", "0.5"] in buried)
    thresholds = {args[-1] for args in runs("demo") if "--search-min-score" in args}
    check("both bounds, a middle value and the empty value are compared",
          {"-1", "1", "0.3", ""} <= thresholds, str(thresholds))
    rejected = {entry["bv_args"][-1] for entry in searches
                if entry.get("rejects") and "--search-min-score" in entry["bv_args"]}
    check("out-of-range and unparseable thresholds are compared as rejections",
          {"2", "-1.5", "abc", "NaN"} <= rejected, str(rejected))

    # Hybrid (vbx-rgw): recency is pinned to SOURCE_DATE_EPOCH on both sides,
    # so the whole ranking is compared — component scores, the weights and
    # the instant recency is measured from — and nothing about it is declared.
    check("hybrid search is compared on bv's flag, both sides alike",
          hybrid != [] and all(
              entry["vbx_args"] == entry["bv_args"]
              and entry["bv_args"][entry["bv_args"].index("--search-mode") + 1] == "hybrid"
              for entry in hybrid), str([entry["name"] for entry in hybrid]))
    check("hybrid compares the ranking, its weights and its ranking_time",
          {"preset", "weights", "ranking_time"} == set(parity.HYBRID_SEARCH_KEYS)
          and all(set(parity.SEARCH_KEYS) | set(parity.HYBRID_SEARCH_KEYS)
                  <= set(entry["keys"]) for entry in hybrid))
    hybrid_runs = {(next(iter(entry["only"])), entry["bv_args"][1]) for entry in hybrid}
    check("hybrid covers the buried exact id, its control and an absent id",
          {("search", "tax-7"), ("search", "tax 7"), ("search", "tax-70")} <= hybrid_runs,
          str(hybrid_runs))
    presets = {entry["bv_args"][entry["bv_args"].index("--search-preset") + 1]
               for entry in hybrid if "--search-preset" in entry["bv_args"]}
    check("hybrid is compared under every non-default preset",
          {"bug-hunting", "sprint-planning", "impact-first", "text-only"} <= presets, str(presets))
    check("a scoped hybrid search compares its scope too",
          any("--label" in entry["bv_args"] and "scope_hash" in entry["keys"] for entry in hybrid))
    declared_paths = [path for declarations in parity.DECLARED_DIFFERENCES.values()
                      for (command, path) in declarations if command.startswith("robot-search")]
    check("no search difference is declared — recency is pinnable on both sides",
          declared_paths == [], str(declared_paths))

    fixture = next(f for f in parity.FIXTURES if f["name"] == "search")
    check("the search fixture runs only what names it", fixture.get("only_named") is True)

    payload = {"query": "q", "results": [], "provider": "hash", "index": {"total": 1}}
    check("select_keys keeps only the named keys",
          parity.select_keys(payload, ("query", "results", "min_score"))
          == {"query": "q", "results": []})
    check("select_keys without keys is the identity", parity.select_keys(payload, None) == payload)

    message = 'Error: invalid --search-min-score "2" (expected a finite number from -1 to 1)'
    check("the same refusal is no difference",
          parity.rejection_differences((2, message + "\nRun vbx-cli --help."), (2, message)) == [])
    check("an accepted value is a difference",
          parity.rejection_differences((0, ""), (2, message)) != [])
    check("another exit status is a difference",
          parity.rejection_differences((1, message), (2, message)) != [])
    check("another message is a difference",
          parity.rejection_differences((2, "Error: no"), (2, message)) != [])


def cli_modifier_rules() -> list[tuple[str, list[str]]]:
    """vbx-cli's modifier rules, (flag, bv's required flags), in table order."""
    source = (ROOT / "Sources" / "VBXCore" / "ModifierRules.swift").read_text()
    table = source.split("public static let all: [ModifierRule] = [", 1)[1].split("\n    ]\n", 1)[0]
    rules = []
    for block in re.split(r"ModifierRule\(", table)[1:]:
        flag = re.match(r'\s*"([^"]+)"', block)
        requires = re.search(r"requires: \[([^\]]*)\]", block)
        if flag and requires:
            rules.append((flag.group(1), re.findall(r'"([^"]+)"', requires.group(1))))
    return rules


def bv_modifier_rules() -> list[tuple[str, list[str]]] | None:
    """bv's modifierRules from cmd/bv/main.go at the engine's beads_viewer
    version, or None when Go cannot name the module's directory."""
    try:
        directory = subprocess.run(
            ["go", "list", "-m", "-f", "{{.Dir}}", "github.com/Dicklesworthstone/beads_viewer"],
            cwd=ROOT / "Engine" / "bridge", capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    main_go = Path(directory) / "cmd" / "bv" / "main.go"
    if not directory or not main_go.exists():
        return None
    text = main_go.read_text()
    table = text.split("modifierRules := []modifierFlagRule{", 1)[1].split("\n\t\t}\n", 1)[0]
    return [(flag, re.findall(r'"([^"]+)"', requires))
            for flag, requires in re.findall(
                r'\{modifier: "([^"]+)", requires: \[\]string\{([^}]*)\}\}', table)]


def cli_enum_rules() -> list[tuple[str, list[str]]]:
    """vbx-cli's enum rules, (flag, allowed values), in table order."""
    source = (ROOT / "Sources" / "VBXCore" / "ModifierRules.swift").read_text()
    table = source.split("public static let all: [EnumRule] = [", 1)[1].split("\n    ]\n", 1)[0]
    return [(flag, re.findall(r'"([^"]+)"', allowed))
            for flag, allowed in re.findall(
                r'EnumRule\(flag: "([^"]+)", allowed: \[([^\]]*)\]\)', table)]


def bv_enum_rules() -> list[tuple[str, list[str]]] | None:
    """bv's enumRules from cmd/bv/main.go, or None when Go cannot name the
    module's directory."""
    try:
        directory = subprocess.run(
            ["go", "list", "-m", "-f", "{{.Dir}}", "github.com/Dicklesworthstone/beads_viewer"],
            cwd=ROOT / "Engine" / "bridge", capture_output=True, text=True, check=True,
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    main_go = Path(directory) / "cmd" / "bv" / "main.go"
    if not directory or not main_go.exists():
        return None
    table = main_go.read_text().split("enumRules := []enumFlagRule{", 1)[1].split("\n\t\t}\n", 1)[0]
    return [(flag, re.findall(r'"([^"]+)"', allowed))
            for flag, allowed in re.findall(
                r'\{name: "([^"]+)", allowed: \[\]string\{([^}]*)\}\}', table)]


def test_enum_rules_and_bv_spellings(parity) -> None:
    print("\nvbx-cli takes bv's spellings, and bv's enum rules (vbx-pfy)")
    source = (ROOT / "Sources" / "vbx-cli" / "main.swift").read_text()
    parsed = set(re.findall(r'case "--([a-z][a-z-]*)"', source))
    # vbx-cli's own names for bv's flags are gone outright, and the flag it
    # parsed and never read with them.
    for old in ("limit", "depth", "root", "threshold"):
        check(f"vbx-cli no longer parses --{old}", old not in parsed)
    for new in ("search-limit", "graph-root", "graph-depth", "suggest-bead"):
        check(f"vbx-cli parses bv's --{new}", new in parsed)

    rules = cli_enum_rules()
    check("the CLI's enum table was read",
          ("graph-format", ["json", "dot", "mermaid"]) in rules, str(rules))
    bv = bv_enum_rules()
    check("bv's enum rules were read from its source", bool(bv), "go list found no module")
    if bv:
        check("every vbx-cli enum rule is bv's, with the same values",
              all(rule in bv for rule in rules), str(rules))
        unruled = [flag for flag, _ in bv if flag in parsed and flag not in dict(rules)]
        check("every bv enum flag vbx-cli parses has its rule", not unruled, str(unruled))

    refusals = {f"{command} {' '.join(bv_args)}".strip()
                for command, _, bv_args in parity.MODIFIER_REJECTS}
    check("a bad --graph-format is compared refused",
          {"robot-graph --graph-format svg", "robot-graph --graph-format dott"} <= refusals)
    accepted = {entry.get("name") or "" for entry in parity.COMPARISONS
                if not entry.get("rejects")}
    wanted = {"robot-graph --graph-root vbx-3 --graph-depth 1",
              "robot-graph --graph-format DOT",
              "robot-suggest --suggest-bead vbx-6",
              "robot-triage --graph-root vbx-3", "robot-next --graph-root vbx-3"}
    check("bv's spellings are compared beside the commands they modify", wanted <= accepted,
          str(wanted - accepted))
    searches = [entry for entry in parity.COMPARISONS if entry.get("vbx") == "robot-search"]
    check("search is compared with bv's --search-limit on both sides",
          searches and all("--limit" not in entry.get("vbx_args", []) for entry in searches))


def test_modifier_rules(parity) -> None:
    print("\nvbx-cli's modifier rules are bv's, and each is compared refused (vbx-uao)")
    rules = cli_modifier_rules()
    check("the CLI's rule table was read", len(rules) > 30
          and ("history-limit", ["robot-history", "bead-history", "robot-causality"]) in rules,
          str(rules))

    bv = bv_modifier_rules()
    check("bv's modifier rules were read from its source", bool(bv), "go list found no module")
    if bv:
        # Each of vbx-cli's rules is bv's, word for word, and in bv's order:
        # bv names the first rule broken, so the order is part of the message.
        bv_flags = [flag for flag, _ in bv]
        missing = [flag for flag, requires in rules if (flag, requires) not in bv]
        check("every vbx-cli rule is one of bv's, with the same requirements", not missing,
              str(missing))
        order = [bv_flags.index(flag) for flag, _ in rules if flag in bv_flags]
        check("the rules are in bv's order", order == sorted(order), str(order))
        # A bv modifier vbx-cli parses must have its rule. The flags vbx-cli
        # parses are its option cases.
        source = (ROOT / "Sources" / "vbx-cli" / "main.swift").read_text()
        parsed = set(re.findall(r'case "--([a-z][a-z-]*)"', source))
        unruled = sorted(flag for flag in bv_flags
                         if flag in parsed and flag not in dict(rules))
        check("every bv modifier vbx-cli parses has its rule", not unruled, str(unruled))

    # Each rule is compared refused: its modifier beside a command it does not
    # modify, or — for --robot-search and --robot-diff — the command alone.
    def refused(flag: str) -> bool:
        for command, vbx_args, bv_args in parity.MODIFIER_REJECTS:
            if f"--{flag}" in vbx_args and f"--{flag}" in bv_args:
                return True
            if command == flag and not vbx_args:
                return True
        return False
    uncovered = [flag for flag, _ in rules if not refused(flag)]
    check("each rule has a refused comparison", not uncovered, str(uncovered))
    names = {entry.get("name") for entry in parity.COMPARISONS if entry.get("rejects")}
    check("the refusals are compared",
          all(f"{command} {' '.join(bv_args)}".strip() in names
              for command, _, bv_args in parity.MODIFIER_REJECTS))
    check("the refusal the bead reported is one of them",
          "robot-orphans --history-limit 3" in names)
    accepted = {entry.get("name") or "" for entry in parity.COMPARISONS
                if not entry.get("rejects")}
    wanted = {"robot-causality hist-3 --history-limit 5", "robot-history --history-limit 5",
              "robot-orphans --orphans-min-score 0", "robot-priority --robot-by-label engine",
              "robot-suggest --suggest-confidence 0.9"}
    check("modifiers are compared beside a command they modify", wanted <= accepted,
          str(wanted - accepted))


def main() -> int:
    parity = load_parity()
    test_modifier_rules(parity)
    test_enum_rules_and_bv_spellings(parity)
    test_workspace_discovery(parity)
    test_symlinked_working_directory(parity)
    test_search(parity)
    test_report_exports(parity)
    test_export_hooks(parity)
    test_feedback_recording(parity)
    test_feedback_before_discovery(parity)
    test_triage_feedback_and_not_ready(parity)
    test_bv_version_gate(parity)
    test_label_scoped_runs(parity)
    test_every_scoped_command_is_compared_under_scope(parity)
    test_load_warnings_follow_bv(parity)
    test_envelope_only_keys_are_one_list(parity)
    test_declared_differences_are_narrow(parity)
    test_sqlite_workspace_keeps_every_record(parity)
    test_sqlite_workspace_skips_a_malformed_line(parity)
    test_dropped_fixture_drops_what_it_says(parity)
    test_every_difference_is_reported(parity)
    test_default_run_covers_every_fixture(parity)
    test_history_workspace(parity)
    test_baseline_save(parity)
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
