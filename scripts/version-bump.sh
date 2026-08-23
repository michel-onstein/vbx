#!/usr/bin/env bash
#
# Advances the version and cuts a tag, from what merged.
#
#   ./scripts/version-bump.sh --dry-run   # say what would happen, change nothing
#   ./scripts/version-bump.sh             # tag, regenerate docs/RELEASES.md
#   ./scripts/version-bump.sh --check     # is the tree in the state a bump leaves?
#
# Nobody edits a version by hand. The tag is the version — `scripts/version.sh`
# reads it, `build-app.sh` stamps it into the plist, and a Homebrew cask is
# written against it — so this is the only thing that decides what the next one
# is.
#
# Where the bump level comes from
# -------------------------------
#
# Not from the commit subject. This repository's subjects are prose:
#
#     Hand the priority cell its store, so scrolling the list cannot crash (#29)
#
# A Conventional Commits parser reads that as "no bump", and would read all 38
# commits here the same way. Adopting `feat:`/`fix:` prefixes would overwrite a
# house style the log has held since the beginning, for the convenience of a
# script.
#
# So the level comes from a `semver:major` / `semver:minor` / `semver:patch`
# label on the pull request, which is a reliable handle because every change
# lands here as a squash-merged PR — every subject ends in `(#N)`. The label is
# set during review, by someone who knows what the change is.
#
# **A missing label defaults to patch, and says so.** A silent default is how a
# feature ships as a patch release and nobody notices.
#
# While the version is 0.x, a breaking change bumps MINOR. MAJOR waits for 1.0.0.
#
# What does not count as a change
# -------------------------------
#
# A commit that touches nothing but `.beads/` is tracker bookkeeping, and does
# not bump anything. Beads land here as ordinary squash-merged PRs, so without
# this rule every `br create` that reached main would cut a patch release —
# a version whose notes describe an issue somebody wrote down rather than
# anything a user can install, and a tag nobody can tell apart from a real one.
#
# The test is the diff, not the subject. A PR that edits code *and* a bead is a
# real change and bumps as usual; only a commit with no file outside `.beads/`
# is skipped. When every commit since the last tag is bead-only there is nothing
# to release, and the script says that rather than cutting an empty patch.
#
# The label is read once, here, and written into the annotated tag's message.
# Everything downstream — `release-notes.py`, and therefore the `--check` in the
# verify block — reads git alone and needs no network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --check) CHECK=1 ;;
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { echo "$@"; }
fail() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# --check: the state a bump leaves behind
# ---------------------------------------------------------------------------
#
# Offline on purpose, so it can sit in CLAUDE.md's verify block beside
# build-engine.sh --check and build-notices.py --check.

if [[ $CHECK -eq 1 ]]; then
  python3 "$ROOT/scripts/release-notes.py" --check
  exit 0
fi

# ---------------------------------------------------------------------------
# Idempotence
# ---------------------------------------------------------------------------
#
# Run twice on the same commit — a re-run of a workflow, a retried job — and the
# second run must do nothing rather than cut 0.2.1 for no change.

EXISTING="$(git describe --tags --match '[0-9]*.[0-9]*.[0-9]*' --exact-match 2>/dev/null || true)"
if [[ -n "$EXISTING" ]]; then
  say "==> $EXISTING already names this commit; nothing to bump"
  exit 0
fi

LAST_TAG="$(git describe --tags --match '[0-9]*.[0-9]*.[0-9]*' --abbrev=0 2>/dev/null || true)"
if [[ -z "$LAST_TAG" ]]; then
  RANGE=""
  CURRENT="0.0.0"
  say "==> No previous release; starting from $CURRENT"
else
  RANGE="$LAST_TAG..HEAD"
  CURRENT="$LAST_TAG"
  say "==> Last release $LAST_TAG"
fi

# ---------------------------------------------------------------------------
# What merged, and how big each one was
# ---------------------------------------------------------------------------
#
# --no-merges because work lands squash-merged: the commit carrying `(#N)` is an
# ordinary commit, and a real merge commit would be a duplicate of it.

mapfile -t COMMITS < <(git log ${RANGE:+"$RANGE"} --no-merges --format='%H %s')
if [[ ${#COMMITS[@]} -eq 0 ]]; then
  say "==> Nothing has landed since $LAST_TAG; nothing to bump"
  exit 0
fi

# pr_level answers with the PR's semver label, or patch.
#
# `gh` may be absent (a local run) or the PR unreachable (a fork). Either way
# the answer is patch *and a line saying which rule fired* — the bead this
# implements asks for the default to be explicit, because a silent one is how a
# feature ships as a patch.
pr_level() {
  local number="$1" labels=""
  if ! command -v gh >/dev/null 2>&1; then
    echo "patch gh-absent"
    return
  fi
  labels="$(gh pr view "$number" --json labels \
    --jq '.labels[].name' 2>/dev/null || true)"
  if [[ -z "$labels" ]]; then
    echo "patch no-labels"
    return
  fi
  for level in major minor patch; do
    if grep -qx "semver:$level" <<<"$labels"; then
      echo "$level label"
      return
    fi
  done
  echo "patch no-semver-label"
}

# beads_only answers whether a commit changed nothing outside `.beads/`.
#
# `--pretty=format:` empties the header so only the file list is left, and
# `git show` rather than `git diff-tree` so a root commit — the first commit in
# a fresh clone, and in the tests — lists its files instead of nothing.
#
# A commit with no files at all is *not* bead-only: it is an unknown case, and
# the conservative answer keeps it on the default path where it is at least
# reported.
beads_only() {
  local files
  files="$(git show --pretty=format: --name-only "$1" | grep -v '^$' || true)"
  [[ -n "$files" ]] || return 1
  ! grep -qv '^\.beads/' <<<"$files"
}

CHANGES=()
LEVEL=patch
rank() { case "$1" in major) echo 3 ;; minor) echo 2 ;; *) echo 1 ;; esac; }

for entry in "${COMMITS[@]}"; do
  sha="${entry%% *}"
  subject="${entry#* }"
  # Bookkeeping. Named on the way past, because a commit that silently did not
  # count is indistinguishable from one the script failed to see.
  if beads_only "$sha"; then
    say "  none   (beads-only)  $subject"
    continue
  fi
  number="$(sed -nE 's/.*\(#([0-9]+)\)$/\1/p' <<<"$subject")"
  if [[ -z "$number" ]]; then
    level=patch
    why="no-pr-reference"
  else
    read -r level why <<<"$(pr_level "$number")"
  fi
  say "  $level  ($why)  $subject"
  CHANGES+=("Change: $level: $subject")
  if [[ "$(rank "$level")" -gt "$(rank "$LEVEL")" ]]; then LEVEL="$level"; fi
done

# Everything that landed was bookkeeping. Distinct from "nothing landed", and
# worth saying differently: this run had commits to consider and declined all of
# them.
if [[ ${#CHANGES[@]} -eq 0 ]]; then
  say "==> Only bead bookkeeping has landed since ${LAST_TAG:-the beginning}; nothing to bump"
  exit 0
fi

# ---------------------------------------------------------------------------
# The next version
# ---------------------------------------------------------------------------

IFS=. read -r MAJOR MINOR PATCH <<<"$CURRENT"

# Before 1.0.0 a breaking change is a minor bump. Promoting to 1.0.0 is a
# decision about the software being finished, not one a label should make.
if [[ "$LEVEL" == major && "$MAJOR" -eq 0 ]]; then
  say "==> major on a 0.x version bumps MINOR; 1.0.0 is a deliberate step"
  LEVEL=minor
fi

case "$LEVEL" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
esac

NEXT="$MAJOR.$MINOR.$PATCH"
# The tag is the version, with no `v` in front of it. See scripts/version.sh.
TAG="$NEXT"
say "==> $CURRENT -> $NEXT ($LEVEL)"

MESSAGE="vbx $NEXT"$'\n\n'"$(printf '%s\n' "${CHANGES[@]}")"

if [[ $DRY_RUN -eq 1 ]]; then
  say ""
  say "Would create $TAG with:"
  printf '%s\n' "$MESSAGE" | sed 's/^/    /'
  say ""
  say "Would regenerate docs/RELEASES.md."
  exit 0
fi

git tag -a "$TAG" -m "$MESSAGE"
say "==> Tagged $TAG"

python3 "$ROOT/scripts/release-notes.py"

if [[ -n "$(git status --porcelain docs/RELEASES.md)" ]]; then
  git add docs/RELEASES.md
  git commit -q -m "Record $TAG in the release notes"
  # Re-pointed at the commit that carries the notes, so a checkout of the tag is
  # a checkout of a tree whose RELEASES.md already lists it. Otherwise
  # `--check` fails on the tag it just created.
  git tag -f -a "$TAG" -m "$MESSAGE" >/dev/null
  say "==> Recorded $TAG in docs/RELEASES.md"
fi

say ""
say "Push it:  git push origin main \"$TAG\""
