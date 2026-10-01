#!/usr/bin/env bash
#
# Assembles vbx.app from the SwiftPM executable.
#
#   ./scripts/build-app.sh              # debug build
#   ./scripts/build-app.sh --release    # optimised
#   ./scripts/build-app.sh --run        # build, then open the demo fixture
#   ./scripts/build-app.sh --universal  # arm64 + x86_64 in both binaries
#
# --universal roughly doubles the build: the engine archive is built twice and
# lipo'd, and SwiftPM compiles and links each product for both architectures.
# That is why the host-only build stays the default for development and why the
# universal check is not in CLAUDE.md's verify block — it is implied by every
# distribution build instead, where the cost is paid once and shipping an
# arm64-only app would reach a user.
#
# Distribution builds — see scripts/package-app.sh, which these hand off to:
#
#   ./scripts/build-app.sh --release --dmg        # signed, notarized .dmg
#   ./scripts/build-app.sh --release --app-store  # sandboxed .pkg for the App Store
#   ./scripts/build-app.sh --release --sign       # Developer ID signature, no package
#
# SwiftPM produces a bare Mach-O; macOS needs a bundle with an Info.plist for
# the app to get a Dock icon, a menu bar, and normal activation. The CLI
# binary is placed inside the bundle too, mirroring how Xcode ships `xcodebuild`
# so "Install Command Line Tool" can symlink it later.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=debug
RUN=0
UNIVERSAL=0
PACKAGE_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --release) CONFIG=release ;;
    --run) RUN=1 ;;
    --universal) UNIVERSAL=1 ;;
    # Forwarded verbatim. The signing configuration and the redaction that
    # keeps account identifiers out of the log both live in one place rather
    # than being half-implemented here as well.
    --sign|--dmg|--app-store|--dry-run|--no-notarize) PACKAGE_ARGS+=("$arg") ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# A distribution build is always optimised. Shipping a debug binary because the
# flag was forgotten is a mistake that survives all the way to a user.
if [[ ${#PACKAGE_ARGS[@]} -gt 0 && "$CONFIG" != release ]]; then
  echo "==> Distribution build implies --release"
  CONFIG=release
fi

# ...and it is always universal. An arm64-only app does not run on an Intel Mac
# at all — Rosetta translates x86_64 to arm64, not the reverse — so a .dmg built
# without this excludes half the Macs, silently, and only the user finds out.
if [[ ${#PACKAGE_ARGS[@]} -gt 0 && $UNIVERSAL -eq 0 ]]; then
  echo "==> Distribution build implies --universal"
  UNIVERSAL=1
fi

cd "$ROOT"

ARCH_ARGS=()
if [[ $UNIVERSAL -eq 1 ]]; then
  ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

# The archive has to carry both slices before the Swift link can, so a host-only
# archive left over from a development build is rebuilt rather than linked
# against — the failure it causes otherwise is a linker error about a missing
# architecture, a long way from the flag that caused it.
if [[ ! -f Engine/build/libvbxgo.a ]]; then
  echo "==> Engine archive missing; building it first"
  if [[ $UNIVERSAL -eq 1 ]]; then
    ./scripts/build-engine.sh --universal
  else
    ./scripts/build-engine.sh
  fi
elif [[ $UNIVERSAL -eq 1 ]] && ! lipo -archs Engine/build/libvbxgo.a | grep -q x86_64; then
  echo "==> Engine archive is host-only; rebuilding it universal"
  ./scripts/build-engine.sh --universal
fi

LABEL="$CONFIG"
if [[ $UNIVERSAL -eq 1 ]]; then LABEL="$CONFIG, universal"; fi
echo "==> Building vbx ($LABEL)"
swift build -c "$CONFIG" "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}" --product vbx
swift build -c "$CONFIG" "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}" --product vbx-cli

# Asked rather than assumed: with several `--arch` flags SwiftPM writes to
# .build/apple/Products/<Config> instead of .build/<config>, and a hardcoded
# path would quietly bundle the previous host-only binaries.
BIN_DIR="$(swift build -c "$CONFIG" "${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}" --show-bin-path)"
APP="$ROOT/.build/vbx.app"

# Stamped from the git tag, never written down here. See scripts/version.sh for
# why: the app, the .dmg filename and a Homebrew cask all have to agree, and a
# literal in this file is what makes them drift.
VERSION="$("$ROOT/scripts/version.sh")"
BUILD_NUMBER="$("$ROOT/scripts/version.sh" --build)"
echo "==> Version $VERSION ($BUILD_NUMBER)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/vbx" "$APP/Contents/MacOS/vbx"
cp "$BIN_DIR/vbx-cli" "$APP/Contents/MacOS/vbx-cli"

# assert_binary_slices checks the artefact, not the flag.
#
# The same reasoning as build-engine.sh's assert_archive_target: "--universal
# was passed" and "--universal took effect" are different claims, and only the
# second one is what ships. Both binaries are checked — vbx-cli is installed
# onto the user's PATH, so an arm64-only CLI inside a universal app is just the
# same bug one level down.
assert_binary_slices() {
  local binary="$1" archs
  archs="$(lipo -archs "$binary" 2>/dev/null || true)"
  if [[ $UNIVERSAL -eq 1 ]]; then
    for want in arm64 x86_64; do
      if [[ " $archs " != *" $want "* ]]; then
        echo "$(basename "$binary") is missing the $want slice (got: ${archs:-none})" >&2
        exit 1
      fi
    done
  fi
  echo "  $(basename "$binary"): $archs"
}

assert_binary_slices "$APP/Contents/MacOS/vbx"
assert_binary_slices "$APP/Contents/MacOS/vbx-cli"

if [[ -f "$ROOT/Resources/vbx.icns" ]]; then
  cp "$ROOT/Resources/vbx.icns" "$APP/Contents/Resources/vbx.icns"
else
  # Without the icon the app still runs; it just gets the generic Dock tile.
  echo "  (no Resources/vbx.icns — run ./scripts/build-icon.sh)"
fi

# The third-party licence notices the About window displays. Several of the
# engine's dependencies require their notice to be carried with the binary, and
# beads_viewer's rider must travel unmodified, so a bundle without this file is
# not distributable — hence the hard failure rather than a warning.
if [[ -f "$ROOT/Resources/ACKNOWLEDGEMENTS.md" ]]; then
  cp "$ROOT/Resources/ACKNOWLEDGEMENTS.md" "$APP/Contents/Resources/ACKNOWLEDGEMENTS.md"
else
  echo "Resources/ACKNOWLEDGEMENTS.md is missing; run ./scripts/build-notices.py" >&2
  exit 1
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- The product is "Visual Beads"; `vbx` is the short form that names the
         executable, the CLI, the bundle identifier and the URL scheme.
         CFBundleName is what the menu bar shows, so it carries the real name
         rather than the abbreviation. -->
    <key>CFBundleName</key>            <string>Visual Beads</string>
    <key>CFBundleDisplayName</key>     <string>Visual Beads</string>
    <key>CFBundleIdentifier</key>      <string>com.qjam.vbx</string>
    <key>CFBundleExecutable</key>      <string>vbx</string>
    <key>CFBundleIconFile</key>        <string>vbx</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <!-- Both are overwritten from the git tag immediately below; these
         placeholders exist only so the keys are present and typed. -->
    <key>CFBundleShortVersionString</key> <string>0.0.0</string>
    <key>CFBundleVersion</key>         <string>0</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <!-- Required for an App Store submission, and harmless otherwise. -->
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
    <!-- vbx uses no encryption beyond what macOS itself provides; declaring it
         here is what skips the export-compliance questionnaire on every
         upload rather than answering it identically each time. -->
    <key>ITSAppUsesNonExemptEncryption</key> <false/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>    <string>Visual Beads workspace</string>
            <key>CFBundleURLSchemes</key> <array><string>vbx</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
  "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
  "$APP/Contents/Info.plist"

# Ad-hoc signature so the app launches locally without a Developer ID.
#
# Skipped for a distribution build: package-app.sh signs a staged copy with a
# real certificate, and an ad-hoc signature here would only be thrown away.
if [[ ${#PACKAGE_ARGS[@]} -eq 0 ]]; then
  codesign --force --sign - "$APP/Contents/MacOS/vbx-cli" 2>/dev/null || true
  codesign --force --sign - "$APP" 2>/dev/null || \
    echo "  (ad-hoc signing skipped)"
fi

echo "==> Built $APP"

if [[ ${#PACKAGE_ARGS[@]} -gt 0 ]]; then
  exec "$ROOT/scripts/package-app.sh" --app "$APP" "${PACKAGE_ARGS[@]}"
fi

if [[ $RUN -eq 1 ]]; then
  echo "==> Launching with the demo fixture"
  open -a "$APP" --args "$ROOT/Fixtures/demo"
fi
