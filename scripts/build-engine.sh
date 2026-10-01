#!/usr/bin/env bash
#
# Builds bv's Go engine into a static archive that the Swift app links against.
#
#   ./scripts/build-engine.sh            # build for the host architecture
#   ./scripts/build-engine.sh --universal  # arm64 + x86_64, lipo'd together
#   ./scripts/build-engine.sh --check    # build, then run the C ABI smoke test
#
# The archive is intentionally not committed: it is ~25 MB and reproducible
# from the pinned beads_viewer module version in Engine/bridge/go.mod.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="$ROOT/Engine/bridge"
BUILD="$ROOT/Engine/build"
OUT="$BUILD/libvbxgo.a"
HEADER_DEST="$ROOT/Sources/CVBXEngine/include/libvbxgo.h"

# The deployment target the archive is built for.
#
# This has to match `platforms: [.macOS(...)]` in Package.swift. Without it the
# Go toolchain targets whatever SDK the host has, and the linker warns that the
# archive "was built for newer 'macOS' version (26.0) than being linked (14.0)"
# — which is not cosmetic: the app would claim to support macOS 14 while
# carrying objects that require 26. It runs on the build machine and fails on
# the machine the deployment target promised.
#
# The two are checked against each other below rather than trusted to stay in
# step, because nothing else would notice them drifting apart.
MACOS_DEPLOYMENT_TARGET=14.0

UNIVERSAL=0
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --check) CHECK=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$BUILD"
cd "$BRIDGE"

# assert_package_target fails when Package.swift and the value above disagree.
#
# Derived from the manifest rather than duplicated in a comment: a mismatch is
# silent otherwise, and the symptom — an app that runs here and crashes on an
# older machine — surfaces a long way from the cause.
assert_package_target() {
  local manifest="$ROOT/Package.swift" declared
  declared="$(sed -n 's/.*\.macOS(\.v\([0-9]*\)).*/\1/p' "$manifest" | head -1)"
  if [[ -z "$declared" ]]; then
    echo "could not read the macOS platform from Package.swift" >&2
    exit 1
  fi
  if [[ "${MACOS_DEPLOYMENT_TARGET%%.*}" != "$declared" ]]; then
    echo "deployment target mismatch: this script targets" \
      "$MACOS_DEPLOYMENT_TARGET, Package.swift declares macOS $declared" >&2
    echo "update MACOS_DEPLOYMENT_TARGET in $0 to match the manifest" >&2
    exit 1
  fi
}

# go_link_ldflags prints the -ldflags that put the deployment target on the
# Go-linked object, or nothing when this toolchain's linker cannot take it.
#
# The cgo flags below reach every cgo-compiled object, but `go.o` is written by
# Go's own linker, which stamps its LC_BUILD_VERSION itself. Up to Go 1.26 it
# copied the platform from the cgo host objects, so the cgo flags reached it
# too. Go 1.27 stopped copying a macOS platform and writes its built-in default
# (13.0) instead, unless `-ldflags=-macos=<version>` overrides it — and Go 1.26's
# linker has no `-macos` flag and rejects it. So the flag is passed only when
# the linker lists it: one script then builds under either toolchain, and
# assert_archive_target still checks the result. See BUGS.md, 2026-10-01.
go_link_ldflags() {
  local help
  help="$(go tool link -help 2>&1 || true)"
  if grep -qE '^[[:space:]]*-macos[[:space:]]' <<<"$help"; then
    printf '%s' "-macos=$MACOS_DEPLOYMENT_TARGET"
  fi
}

build_slice() {
  local arch="$1" out="$2"
  echo "  building darwin/$arch (deployment target $MACOS_DEPLOYMENT_TARGET)"
  # `go build -o` refuses to overwrite anything it does not recognise as an
  # object file, and the fat archive a --universal build leaves behind is not
  # one. Without this, the next host-only build fails with "already exists and
  # is not an object file", which names the archive rather than the flag that
  # produced it.
  rm -f "$out"
  # Both the environment variable and the explicit compiler flags are set, and
  # the flags are the ones that actually work: with this toolchain
  # MACOSX_DEPLOYMENT_TARGET alone leaves every object — the Go-linked `go.o`
  # and the cgo-compiled ones alike — carrying the host SDK's minimum.
  # -mmacosx-version-min reaches the cgo objects, and reached `go.o` too up to
  # Go 1.26; from 1.27 `go.o` needs the linker flag in GO_LDFLAGS (see
  # go_link_ldflags). The variable is kept because it is the conventional knob
  # and costs nothing.
  CGO_ENABLED=1 GOOS=darwin GOARCH="$arch" \
    MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
    CGO_CFLAGS="-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET" \
    CGO_LDFLAGS="-mmacosx-version-min=$MACOS_DEPLOYMENT_TARGET" \
    go build -buildmode=c-archive -trimpath -ldflags="$GO_LDFLAGS" -o "$out" ./cbridge
}

# assert_archive_target verifies the flag actually took effect.
#
# Setting an environment variable and assuming it worked is how the mismatch
# went unnoticed in the first place. `otool` reports what is really recorded in
# the Mach-O load commands, so this checks the artefact rather than the intent.
assert_archive_target() {
  local archive="$1" found count
  # Every object is checked, not just the first. The archive holds the
  # Go-linked object alongside one per cgo translation unit, and they are
  # produced by different tools — a flag that reaches one need not reach the
  # others, which is exactly the failure this catches.
  found="$(otool -l "$archive" 2>/dev/null | awk '/minos/ {print $2}' | sort -u)"
  if [[ -z "$found" ]]; then
    echo "could not read a deployment target from $archive" >&2
    exit 1
  fi
  count="$(printf '%s\n' "$found" | wc -l | tr -d ' ')"
  if [[ "$count" != "1" || "$found" != "$MACOS_DEPLOYMENT_TARGET" ]]; then
    echo "archive objects target macOS $(printf '%s' "$found" | tr '\n' ' ')," \
      "expected only $MACOS_DEPLOYMENT_TARGET" >&2
    exit 1
  fi
  echo "  verified minos $found across all objects"
}

# assert_archive_universal verifies both slices are really in the archive.
#
# `--universal` passing is not the same claim as `lipo` having produced two
# architectures — a slice that failed to build would otherwise be noticed only
# when the app refuses to launch on the Mac it was meant for.
assert_archive_universal() {
  local archive="$1" archs
  archs="$(lipo -archs "$archive" 2>/dev/null || true)"
  for want in arm64 x86_64; do
    if [[ " $archs " != *" $want "* ]]; then
      echo "universal build is missing the $want slice (got: ${archs:-none})" >&2
      exit 1
    fi
  done
  echo "  verified slices: $archs"
}

assert_package_target
GO_LDFLAGS="$(go_link_ldflags)"

echo "==> Building vbx engine archive"
if [[ $UNIVERSAL -eq 1 ]]; then
  build_slice arm64 "$BUILD/libvbxgo-arm64.a"
  build_slice amd64 "$BUILD/libvbxgo-amd64.a"
  echo "  lipo -> universal"
  lipo -create "$BUILD/libvbxgo-arm64.a" "$BUILD/libvbxgo-amd64.a" -output "$OUT"
  # Both slices generate the same header; keep the arm64 one.
  cp "$BUILD/libvbxgo-arm64.h" "$BUILD/libvbxgo.h"
  rm -f "$BUILD"/libvbxgo-{arm64,amd64}.{a,h}
else
  build_slice "$(go env GOARCH)" "$OUT"
fi

# The Swift C target reads the header from its include directory, so keep the
# committed copy in step with whatever the build just generated.
cp "$BUILD/libvbxgo.h" "$HEADER_DEST"

echo "==> Built $(du -h "$OUT" | cut -f1) archive"
lipo -info "$OUT" 2>/dev/null || true
assert_archive_target "$OUT"
if [[ $UNIVERSAL -eq 1 ]]; then
  assert_archive_universal "$OUT"
fi

# SwiftPM does not treat the archive as a build input, so a rebuilt engine on
# its own does NOT trigger a relink — `swift test` happily keeps running the
# previous archive. That failure mode is genuinely confusing: the Go tests pass,
# the Swift ones fail, and the fix appears not to have taken. Touching a source
# file in the target that links it forces the relink.
touch "$ROOT/Sources/VBXEngine/BeadsEngine.swift"

if [[ $CHECK -eq 1 ]]; then
  echo "==> Running C ABI smoke test"
  cc -o "$BUILD/smoke" "$ROOT/Engine/smoke/smoke.c" "$OUT" \
    -I"$BUILD" -framework CoreFoundation -framework Security
  "$BUILD/smoke" "$ROOT/Fixtures/demo"
fi
