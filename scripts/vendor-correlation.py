#!/usr/bin/env python3
"""Copy bv's correlation package into the engine, with its git calls rerouted.

    python3 scripts/vendor-correlation.py           # regenerate Engine/bridge/correlation
    python3 scripts/vendor-correlation.py --check   # prove the copy matches upstream

bv's history correlator (pkg/correlation) reaches git through one function,
`gitCommand` in gitcmd.go, which returns an `exec.Cmd` running the `git`
binary. The App Sandbox cannot spawn that binary (ADR-006), and the package
offers no other way in: the orchestration that turns git's output into a
report — which strategies run, in which order, over which window — is
unexported. So vbx carries the package itself, every file byte for byte except
for the handful of substitutions below, and supplies its own `gitCommand`
(vbx_gitcmd.go), which answers the same git invocations from the object store
through go-git (package objgit). See ADR-027.

The copy is generated, never edited: each upstream file is written with a
`Code generated ... DO NOT EDIT.` line above it, and `--check` regenerates the
whole set in memory and fails on any difference, so a hand edit, a missed
upgrade or a stray file cannot survive the verify block. Files vbx owns in the
directory are named `vbx_*.go` (and the `internal/env` shim); they are left
alone.

Every substitution asserts that it matched exactly once. An upstream change
that moves one of them fails the run rather than producing a copy that quietly
spawns git again.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = ROOT / "Engine" / "bridge"
GOMOD = BRIDGE / "go.mod"
DEST = BRIDGE / "correlation"
MODULE = "github.com/Dicklesworthstone/beads_viewer"
PACKAGE = "pkg/correlation"

# gitcmd.go is the one file not copied: vbx_gitcmd.go replaces it.
SKIPPED = {"gitcmd.go"}

# The licence travels with the copy, unmodified, as its rider requires.
LICENCE = "LICENSE"

ENV_IMPORT = '"github.com/Dicklesworthstone/beads_viewer/internal/env"'
ENV_SHIM = '"github.com/qjam/vbx/engine/correlation/internal/env"'

# (file, old, new, why). Each must match exactly once.
SUBSTITUTIONS = [
    # internal/env is not importable from another module. The shim answers the
    # three variables the caches read, with every disk cache off (see it).
    ("disk_cache.go", ENV_IMPORT, ENV_SHIM, "internal package"),
    ("head_artifact_cache.go", ENV_IMPORT, ENV_SHIM, "internal package"),
    ("per_commit_event_cache.go", ENV_IMPORT, ENV_SHIM, "internal package"),
    ("per_commit_cocommit_cache.go", ENV_IMPORT, ENV_SHIM, "internal package"),
    # The two places the package names exec.Cmd as a type rather than holding
    # what gitCommand returns.
    ("extractor_snapshot.go", "\tcmd         *exec.Cmd\n", "\tcmd         *gitCmd\n",
     "blobReader holds a gitCmd"),
    ("stream.go",
     "func (s *StreamExtractor) buildStreamCommand(opts StreamOptions, limit int) *exec.Cmd {",
     "func (s *StreamExtractor) buildStreamCommand(opts StreamOptions, limit int) *gitCmd {",
     "buildStreamCommand returns a gitCmd"),
    # bv picks between two extractions it proves byte-identical: `git log -p`
    # for a small beads file, a snapshot diff in Go for a large one. vbx always
    # takes the snapshot path, so a git patch never has to be rendered.
    ("extractor.go", "\tif e.preferSnapshotPath() {\n", "\tif vbxPreferSnapshotPath(e) {\n",
     "always the snapshot extraction"),
]


def upstream_version() -> str:
    match = re.search(rf"^\s*{re.escape(MODULE)}\s+(v\S+)\s*$", GOMOD.read_text(), re.M)
    if not match:
        sys.exit(f"{MODULE} is not required in {GOMOD}")
    return match.group(1)


def module_dir(version: str) -> Path:
    """The module's directory in the Go module cache, downloading it if need be."""
    result = subprocess.run(
        ["go", "mod", "download", "-json", f"{MODULE}@{version}"],
        cwd=BRIDGE, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        sys.exit(f"go mod download {MODULE}@{version} failed:\n{result.stderr}")
    match = re.search(r'"Dir":\s*"([^"]+)"', result.stdout)
    if not match:
        sys.exit(f"go mod download printed no directory for {MODULE}@{version}")
    return Path(match.group(1))


def gofmt(source: str, name: str) -> bytes:
    """The file as gofmt leaves it. A substituted import path sorts elsewhere
    in its block, and gofmt -l in the verify block must print nothing."""
    result = subprocess.run(["gofmt"], input=source.encode(), capture_output=True, check=False)
    if result.returncode != 0:
        sys.exit(f"gofmt rejected the generated {name}:\n{result.stderr.decode()}")
    return result.stdout


def generate(version: str) -> dict[str, bytes]:
    """Every generated file, by its path relative to DEST."""
    source = module_dir(version) / PACKAGE
    names = sorted(
        name for name in os.listdir(source)
        if name.endswith(".go") and not name.endswith("_test.go") and name not in SKIPPED)
    files: dict[str, str] = {name: (source / name).read_text() for name in names}

    for name, old, new, why in SUBSTITUTIONS:
        if name not in files:
            sys.exit(f"{name} is no longer in {PACKAGE} ({why}); update {Path(__file__).name}")
        count = files[name].count(old)
        if count != 1:
            sys.exit(f"{name}: expected one match for the {why!r} substitution, found {count}; "
                     f"update {Path(__file__).name}")
        files[name] = files[name].replace(old, new)

    out: dict[str, bytes] = {}
    for name, text in files.items():
        header = (f"// Code generated by scripts/vendor-correlation.py from {MODULE}@{version}"
                  f" {PACKAGE}/{name}. DO NOT EDIT.\n\n")
        out[name] = gofmt(header + text, name)
    out[LICENCE] = (module_dir(version) / LICENCE).read_bytes()
    return out


def generated_on_disk() -> dict[str, bytes]:
    """The files in DEST this script owns: everything but vbx_* and internal/."""
    found: dict[str, bytes] = {}
    if not DEST.exists():
        return found
    for path in DEST.iterdir():
        if path.is_dir() or path.name.startswith("vbx_"):
            continue
        found[path.name] = path.read_bytes()
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--check", action="store_true",
                        help="verify the committed copy, rewriting nothing")
    args = parser.parse_args()

    version = upstream_version()
    wanted = generate(version)
    present = generated_on_disk()

    if args.check:
        problems = []
        for name in sorted(set(wanted) | set(present)):
            if name not in present:
                problems.append(f"missing: {name}")
            elif name not in wanted:
                problems.append(f"not from upstream (vbx-owned files are vbx_*.go): {name}")
            elif present[name] != wanted[name]:
                problems.append(f"differs from {MODULE}@{version}: {name}")
        if problems:
            print("Engine/bridge/correlation does not match upstream:", file=sys.stderr)
            for problem in problems:
                print(f"  {problem}", file=sys.stderr)
            print("Regenerate with: python3 scripts/vendor-correlation.py", file=sys.stderr)
            return 1
        print(f"Engine/bridge/correlation matches {MODULE}@{version} "
              f"({len(wanted) - 1} files, {len(SUBSTITUTIONS)} substitutions)")
        return 0

    DEST.mkdir(parents=True, exist_ok=True)
    for name in present:
        if name not in wanted:
            (DEST / name).unlink()
    for name, content in wanted.items():
        (DEST / name).write_bytes(content)
    print(f"Wrote {len(wanted)} files from {MODULE}@{version} to {DEST.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
