#!/usr/bin/env python3
"""Every bead should say it came from this repository, not from a worktree.

    ./scripts/beads-check.py            # report records stamped with something else
    ./scripts/beads-check.py --fix      # rewrite them through `br update`

`br` stamps `source_repo` with the basename of the directory it runs in, and
this repository's discipline is that every session works in
`.claude/worktrees/<topic>`. Those two rules are in direct conflict, and the
worktree rule is the correct one — so essentially every bead filed since it took
hold has been stamped with a throwaway topic name, and its `source_repo_path`
points at a directory that was deleted when the work landed.

Nothing reads the field today: `RepoInfo.owns(_:)` matches beads to a repository
by id prefix, and `--robot-repos` reports this workspace as single-repo. The
cost is latent rather than current — `br`'s own help calls `source_repo_path`
"the canonical filesystem location of the repo for cross-machine sync
awareness", and half of ours named a path that does not exist on this machine.

**This check is what stops it recurring.** There is no configuration for it:
`br create` has no `--source-repo` flag and `.beads/config.yaml` holds only
`issue_prefix`, so the value cannot be set correctly at creation time. The real
fix is upstream in `beads_rust`. Until then a failing check in the verify block
turns "remember to run `br update` after `br create`" — a rule of exactly the
kind that produced this mess — into something the build says out loud, with
`--fix` as the one-line answer.

The canonical name and path come from git rather than from a constant: the
common git directory is shared by every worktree and its parent is the primary
checkout, so this is right whichever worktree it runs in.
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def canonical() -> tuple[str, str]:
    """The repository's own name and path, as every record should carry them."""
    common = subprocess.run(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
        cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    primary = Path(common).parent
    return primary.name, str(primary)


def records(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def offenders(rows: list[dict], name: str, path: str) -> list[tuple[str, str, str]]:
    """Records whose stamp is not this repository's, as (id, repo, path)."""
    out = []
    for row in rows:
        repo = row.get("source_repo") or ""
        where = row.get("source_repo_path") or ""
        if repo != name or where != path:
            out.append((row.get("id", "<no id>"), repo, where))
    return out


def main() -> int:
    fix = "--fix" in sys.argv[1:]
    for arg in sys.argv[1:]:
        if arg not in ("--fix", "--check"):
            print(f"unknown option: {arg}", file=sys.stderr)
            return 2

    jsonl = ROOT / ".beads" / "issues.jsonl"
    if not jsonl.exists():
        print(f"no beads export at {jsonl}", file=sys.stderr)
        return 1

    name, path = canonical()
    rows = records(jsonl)
    wrong = offenders(rows, name, path)

    if not wrong:
        print(f"==> beads check ok ({len(rows)} records stamped {name})")
        return 0

    if not fix:
        print(
            f"error: {len(wrong)} of {len(rows)} beads are stamped with another "
            f"repository — run scripts/beads-check.py --fix",
            file=sys.stderr)
        # Grouped, because the interesting fact is *which* worktrees, and a
        # list of 30 ids is not readable.
        by_repo: dict[str, list[str]] = {}
        for issue, repo, _ in wrong:
            by_repo.setdefault(repo or "<unset>", []).append(issue)
        for repo, ids in sorted(by_repo.items(), key=lambda kv: -len(kv[1])):
            shown = ", ".join(sorted(ids)[:6])
            more = f", +{len(ids) - 6} more" if len(ids) > 6 else ""
            print(f"  {len(ids):>3}  {repo}: {shown}{more}", file=sys.stderr)
        return 1

    failed: list[str] = []
    for issue, _, _ in wrong:
        result = subprocess.run(
            ["br", "update", issue, "--source-repo", name, "--source-repo-path", path],
            cwd=ROOT, capture_output=True, text=True)
        if result.returncode != 0:
            failed.append(f"{issue}: {(result.stderr or result.stdout).strip()}")
    print(f"==> rewrote {len(wrong) - len(failed)} of {len(wrong)} records to {name}")
    if failed:
        # A tombstone, or a record `br` will not update, is a real answer rather
        # than something to retry silently.
        print("could not rewrite:", file=sys.stderr)
        for line in failed:
            print(f"  {line}", file=sys.stderr)
        return 1
    print("Now: br sync --flush-only, then check the JSONL diff is per-record, not a rewrite.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
