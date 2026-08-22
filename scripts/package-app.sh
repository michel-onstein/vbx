#!/usr/bin/env bash
#
# Signs vbx.app for distribution and packages it.
#
#   ./scripts/package-app.sh --dmg          # Developer ID, notarized, stapled .dmg
#   ./scripts/package-app.sh --app-store    # sandboxed, signed .pkg for App Store Connect
#   ./scripts/package-app.sh --sign         # sign in place, package nothing
#   ./scripts/package-app.sh --check        # validate config and toolchain, build nothing
#   ./scripts/package-app.sh --dmg --dry-run       # print the plan, run nothing
#   ./scripts/package-app.sh --dmg --no-notarize   # sign and package, skip the round trip
#
# Normally reached through `build-app.sh --release --dmg`, which builds the
# bundle first. Run directly to re-sign a bundle that already exists.
#
# ---------------------------------------------------------------------------
# On secrets, because this repository is public
# ---------------------------------------------------------------------------
#
# Every identifier this needs — the Team ID, the certificate names that embed
# it, the notary credential, the provisioning profile — is account-specific.
# None of it is in the repository and none of it can be, so:
#
#   * configuration is read from `scripts/signing.env` (gitignored) or the
#     environment, and the committed `signing.env.example` holds placeholders;
#   * the App Store entitlements are a template; the expanded copy carrying the
#     Team ID is written to `.build/dist/`, which is ignored;
#   * **everything this script prints is passed through `redact`**, which masks
#     the configured values. That matters because the output of `codesign
#     -dvvv`, `security find-identity` and `notarytool` all contain the Team ID,
#     and build logs get pasted into public issues.
#
# The masking is verified by `scripts/test-packaging.py`, along with a check
# that no tracked file contains the configured Team ID.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/.build/dist"
STAGE="$DIST/stage"

MODE=""          # sign | dmg | app-store
DRY_RUN=0
CHECK=0
NOTARIZE=1
APP_IN="$ROOT/.build/vbx.app"

usage() {
  sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sign)        MODE=sign ;;
    --dmg)         MODE=dmg ;;
    --app-store)   MODE=app-store ;;
    --check)       CHECK=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    --app)         shift; APP_IN="${1:-}" ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The environment wins over the file, so CI can supply everything from a secret
# store and never write a config file into the checkout at all.
CONFIG_FILE="${VBX_SIGNING_CONFIG:-$ROOT/scripts/signing.env}"
if [[ -f "$CONFIG_FILE" ]]; then
  # Snapshot what the environment already set, then restore it afterwards.
  _env_team="${VBX_TEAM_ID:-}"
  _env_bundle="${VBX_BUNDLE_ID:-}"
  _env_devid="${VBX_DEVELOPER_ID_APP:-}"
  _env_notary="${VBX_NOTARY_PROFILE:-}"
  _env_as_app="${VBX_APP_STORE_APP:-}"
  _env_as_inst="${VBX_APP_STORE_INSTALLER:-}"
  _env_profile="${VBX_PROVISION_PROFILE:-}"

  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  [[ -n "$_env_team" ]]    && VBX_TEAM_ID="$_env_team"
  [[ -n "$_env_bundle" ]]  && VBX_BUNDLE_ID="$_env_bundle"
  [[ -n "$_env_devid" ]]   && VBX_DEVELOPER_ID_APP="$_env_devid"
  [[ -n "$_env_notary" ]]  && VBX_NOTARY_PROFILE="$_env_notary"
  [[ -n "$_env_as_app" ]]  && VBX_APP_STORE_APP="$_env_as_app"
  [[ -n "$_env_as_inst" ]] && VBX_APP_STORE_INSTALLER="$_env_as_inst"
  [[ -n "$_env_profile" ]] && VBX_PROVISION_PROFILE="$_env_profile"

  # A config written before the bvx -> vbx rename defines BVX_* keys, which
  # nothing reads. Every channel then reports itself unconfigured, which reads
  # as "not set up yet" rather than "set up under the old name" — so the file
  # sits there, complete and ignored. Naming it costs one grep and turns a
  # silent dead end into a one-line fix.
  if grep -qE '^[[:space:]]*(export[[:space:]]+)?BVX_' "$CONFIG_FILE"; then
    echo "error: ${CONFIG_FILE##*/} uses the pre-rename BVX_ prefix; the scripts read VBX_." >&2
    echo "  The project was renamed from bvx to vbx, and these keys are ignored." >&2
    echo "  Fix it in place:  sed -i '' 's/^\\([[:space:]]*\\)BVX_/\\1VBX_/' \"$CONFIG_FILE\"" >&2
    exit 1
  fi
fi

TEAM_ID="${VBX_TEAM_ID:-}"
BUNDLE_ID="${VBX_BUNDLE_ID:-com.qjam.vbx}"
DEVELOPER_ID_APP="${VBX_DEVELOPER_ID_APP:-}"
NOTARY_PROFILE="${VBX_NOTARY_PROFILE:-}"
APP_STORE_APP="${VBX_APP_STORE_APP:-}"
APP_STORE_INSTALLER="${VBX_APP_STORE_INSTALLER:-}"
PROVISION_PROFILE="${VBX_PROVISION_PROFILE:-}"

# ---------------------------------------------------------------------------
# redact — the reason this script is safe to run with its output visible
# ---------------------------------------------------------------------------
#
# Replaces each configured value with a label. Applied to *everything* printed,
# including the output of the tools invoked, because `codesign -dvvv` prints
# `TeamIdentifier=...` and `security find-identity` prints the full certificate
# name. A build log is a public artifact more often than not.
redact() {
  local text
  text="$(cat)"

  # Only values long enough to *be* a credential are masked. Without this the
  # ad-hoc identity `-` matches every hyphen in the output and turns the log
  # into confetti — flags, paths and prose all mangled. The shortest real value
  # here is a 10-character Team ID.
  _mask() {
    local needle="$1" label="$2"
    [[ ${#needle} -ge 6 ]] || return 0
    text="${text//"$needle"/$label}"
  }

  # Longest first, and this order is load-bearing rather than tidy. A
  # certificate name *contains* the Team ID — "Developer ID Application: Name
  # (TEAMID)" — so masking the Team ID first leaves a string that no longer
  # matches the full name, and the developer's name survives into the log.
  # Tested in scripts/test-packaging.py, which is how that was found.
  _mask "$DEVELOPER_ID_APP"    "<DEVELOPER_ID_APP>"
  _mask "$APP_STORE_APP"       "<APP_STORE_APP>"
  _mask "$APP_STORE_INSTALLER" "<APP_STORE_INSTALLER>"
  _mask "$PROVISION_PROFILE"   "<PROVISION_PROFILE>"
  _mask "$TEAM_ID"             "<TEAM_ID>"

  # Finally, anything shaped like a certificate name that this build never
  # configured. `security find-identity` lists every identity in the keychain,
  # so a build for one team can otherwise print another team's ID and name.
  text="$(printf '%s' "$text" |
    sed -E 's/(Developer ID (Application|Installer)|Apple (Development|Distribution)|3rd Party Mac Developer (Application|Installer)): [^(]*\(([A-Z0-9]{10})\)/\1: <REDACTED>/g;
            s/\(([A-Z0-9]{10})\)/(<TEAM_ID>)/g')"
  printf '%s\n' "$text"
}

# say prints a progress line. run echoes a command and executes it, with both
# streams redacted; in --dry-run it echoes and stops.
say()  { printf '%s\n' "$*" | redact; }
run() {
  printf '  $ %s\n' "$*" | redact
  if [[ $DRY_RUN -eq 1 ]]; then return 0; fi
  # Redaction is applied to the tool's own output as well, which is where the
  # identifiers actually appear.
  "$@" 2>&1 | redact
  return "${PIPESTATUS[0]}"
}

fail() { printf 'error: %s\n' "$*" | redact >&2; exit 1; }

# require_config names the missing setting and where to put it, rather than
# failing inside codesign with "no identity found".
require_config() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    fail "$name is not set. Copy scripts/signing.env.example to scripts/signing.env and fill it in, or export $name."
  fi
}

# assert_identity checks the certificate is actually in the keychain before a
# long build, and never prints the keychain listing unredacted.
# identity_present answers without exiting, for the diagnostic path. `--check`
# reporting "--dmg ready, --app-store not ready" is more useful than aborting
# on the first certificate that happens to be missing.
identity_present() {
  local identity="$1"
  [[ -n "$identity" ]] || return 1
  [[ "$identity" != "-" ]] || return 0
  security find-identity -v -p codesigning 2>/dev/null | grep -qF "$identity"
}

# identity_is answers whether a certificate is of the kind it is being used as.
#
# Apple names these canonically — "Developer ID Application: Name (TEAMID)",
# "Apple Distribution: …", "3rd Party Mac Developer Installer: …" — and the
# prefix is the whole of the distinction. It is not cosmetic: a development
# certificate signs an app that runs on provisioned Macs and nowhere else, and
# the notary service refuses it outright.
identity_is() {
  local identity="$1" kind="$2"
  [[ "$identity" == "$kind: "* ]]
}

assert_identity() {
  local identity="$1" label="$2"
  # `-` is codesign's ad-hoc identity. Supported deliberately: it makes the
  # whole pipeline — staging, inside-out signing, verification, the disk image
  # — runnable on a machine with no certificates, which is the difference
  # between this script being tested and being hoped about. It produces
  # nothing distributable, and says so every time.
  #
  # Checked before the dry-run return, because a plan that does not mention
  # the signature is ad-hoc is a plan that misleads.
  if [[ "$identity" == "-" ]]; then
    say "  NOTE: ad-hoc signature. Gatekeeper will reject this on any other Mac."
    return 0
  fi
  # The kind is checked first, and before the dry-run return: it needs no
  # keychain, and a dry run whose purpose is to prove the plan must catch a
  # certificate that cannot work.
  #
  # `$label` used to be decorative. It named the certificate in the error
  # message while the check underneath only asked whether the string appeared
  # in `security find-identity` at all — so an "Apple Development" identity
  # configured as VBX_DEVELOPER_ID_APP passed --check, passed this assertion,
  # signed the app, built the disk image, and was refused by the notary service
  # six minutes later: "The binary is not signed with a valid Developer ID
  # certificate", every binary, every slice.
  if ! identity_is "$identity" "$label"; then
    fail "the configured certificate is not a $label certificate. Apple issues those with the common name \"$label: Name (TEAMID)\", and nothing else notarizes — a development certificate comes back \"not signed with a valid Developer ID certificate\"."
  fi
  if [[ $DRY_RUN -eq 1 ]]; then return 0; fi
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$identity"; then
    fail "$label certificate is not in the keychain. \`security find-identity -v -p codesigning\` must list it verbatim."
  fi
}

assert_tool() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 is not on the PATH ($2)"
}

# ---------------------------------------------------------------------------
# --check: validate everything that can be validated without building
# ---------------------------------------------------------------------------

check_config() {
  local problems=0
  say "==> Checking distribution configuration"

  if [[ -f "$CONFIG_FILE" ]]; then
    say "  config file            $(basename "$CONFIG_FILE") (present)"
    # A config file that is not ignored is the leak this whole design exists to
    # prevent, so it is an error rather than a warning.
    if git -C "$ROOT" check-ignore -q "$CONFIG_FILE" 2>/dev/null; then
      say "  gitignored             yes"
    else
      say "  gitignored             NO — this file carries account identifiers"
      problems=1
    fi
  else
    say "  config file            absent (using the environment)"
  fi

  local setting
  for setting in TEAM_ID BUNDLE_ID DEVELOPER_ID_APP NOTARY_PROFILE \
                 APP_STORE_APP APP_STORE_INSTALLER PROVISION_PROFILE; do
    if [[ -n "${!setting}" ]]; then
      printf '  %-22s set\n' "$setting"
    else
      printf '  %-22s —\n' "$setting"
    fi
  done

  assert_tool codesign "install the Xcode command line tools"
  assert_tool xcrun "install the Xcode command line tools"
  say "  codesign, xcrun        present"

  DEVID_CERT_OK=1
  STORE_CERT_OK=1
  # The kind before the keychain, because a certificate of the wrong kind is
  # wrong whether or not it is installed — and "NOT in the keychain" sends you
  # looking for a certificate you already have. This is the line that was
  # missing: an "Apple Development" identity configured here read as
  # "Developer ID cert in the keychain", which was true and useless.
  if [[ -n "$DEVELOPER_ID_APP" ]]; then
    if [[ "$DEVELOPER_ID_APP" != "-" ]] \
       && ! identity_is "$DEVELOPER_ID_APP" "Developer ID Application"; then
      say "  Developer ID cert      NOT a Developer ID Application certificate"
      say "                         only that kind notarizes; create one at"
      say "                         https://developer.apple.com/account/resources/certificates"
      DEVID_CERT_OK=0
    elif ! identity_present "$DEVELOPER_ID_APP"; then
      say "  Developer ID cert      NOT in the keychain"
      DEVID_CERT_OK=0
    else
      say "  Developer ID cert      in the keychain"
    fi
  fi
  if [[ -n "$APP_STORE_APP" ]]; then
    if [[ "$APP_STORE_APP" != "-" ]] \
       && ! identity_is "$APP_STORE_APP" "Apple Distribution"; then
      say "  App Store cert         NOT an Apple Distribution certificate"
      STORE_CERT_OK=0
    elif ! identity_present "$APP_STORE_APP"; then
      say "  App Store cert         NOT in the keychain"
      STORE_CERT_OK=0
    else
      say "  App Store cert         in the keychain"
    fi
  fi
  if [[ -n "$APP_STORE_INSTALLER" ]] && ! identity_present "$APP_STORE_INSTALLER"; then
    say "  App Store installer    NOT in the keychain"
    STORE_CERT_OK=0
  fi
  if [[ -n "$PROVISION_PROFILE" && ! -f "$PROVISION_PROFILE" ]]; then
    say "  provisioning profile   not found at the configured path"
    STORE_CERT_OK=0
  fi
  # A notary profile that is configured but unusable is reported against the
  # channel that needs it, not as a global failure — otherwise `--check` says
  # "--dmg ready" and "configuration is incomplete" in the same breath.
  NOTARY_OK=1
  if [[ -n "$NOTARY_PROFILE" ]] && command -v xcrun >/dev/null; then
    # No flag beyond the profile, and the probe's own error is reported when it
    # fails. `--limit 1` was here to keep the round trip cheap, but notarytool
    # 1.1.2 has no such option and exits 64 on it — so a profile that worked
    # was reported unusable, and the advice printed was to store credentials
    # that were already stored. Because `--check` then exits non-zero and
    # release.sh runs it unwrapped in preflight, every release aborted before
    # it built anything. A silent probe is what made that unreadable: an
    # unknown flag and a missing credential looked identical.
    local notary_probe
    if notary_probe="$(xcrun notarytool history \
        --keychain-profile "$NOTARY_PROFILE" 2>&1)"; then
      say "  notary profile         usable"
    else
      say "  notary profile         not usable — run xcrun notarytool store-credentials"
      say "                         $(printf '%s\n' "$notary_probe" | grep -v '^$' | head -1)"
      NOTARY_OK=0
    fi
  fi

  # Readiness is reported per channel, because "some settings are present" is
  # not a useful answer to "can I ship?". A bare OK with nothing configured
  # was the first version of this, and it read as a green light.
  local dmg_ready=1 store_ready=1
  [[ -n "$DEVELOPER_ID_APP" && ${DEVID_CERT_OK:-1} -eq 1 ]] || dmg_ready=0
  if [[ $NOTARIZE -eq 1 ]]; then
    [[ -n "$NOTARY_PROFILE" && ${NOTARY_OK:-1} -eq 1 ]] || dmg_ready=0
  fi
  [[ -n "$TEAM_ID" && -n "$APP_STORE_APP" && -n "$APP_STORE_INSTALLER" \
     && -n "$PROVISION_PROFILE" && ${STORE_CERT_OK:-1} -eq 1 ]] || store_ready=0

  say ""
  if [[ $dmg_ready -eq 1 ]]; then
    say "  --dmg          ready"
  else
    say "  --dmg          not ready (needs VBX_DEVELOPER_ID_APP and a usable VBX_NOTARY_PROFILE)"
  fi
  if [[ $store_ready -eq 1 ]]; then
    say "  --app-store    ready"
  else
    say "  --app-store    not configured (needs VBX_TEAM_ID, VBX_APP_STORE_APP," \
        "VBX_APP_STORE_INSTALLER, VBX_PROVISION_PROFILE)"
  fi

  [[ $problems -eq 0 ]] || fail "configuration is incomplete"
  if [[ $dmg_ready -eq 0 && $store_ready -eq 0 ]]; then
    fail "no distribution channel is configured. Copy scripts/signing.env.example to scripts/signing.env, or export the settings."
  fi
  say ""
  say "CONFIG OK"
}

if [[ $CHECK -eq 1 ]]; then
  check_config
  [[ -n "$MODE" ]] || exit 0
fi

[[ -n "$MODE" ]] || { usage >&2; exit 2; }

# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------

[[ -d "$APP_IN" ]] || [[ $DRY_RUN -eq 1 ]] || \
  fail "no app bundle at ${APP_IN#"$ROOT"/} — run ./scripts/build-app.sh --release first"

APP_VERSION="0.0.0"
if [[ -f "$APP_IN/Contents/Info.plist" ]]; then
  APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP_IN/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
fi

APP="$STAGE/vbx.app"

stage_app() {
  say "==> Staging a copy (the input bundle is left untouched)"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "  $APP_IN -> ${APP#"$ROOT"/}"
    return 0
  fi
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  # -R preserves the bundle; signing mutates what it is given, and mutating the
  # caller's build output would leave `build-app.sh --run` launching a bundle
  # signed for someone else's machine.
  cp -R "$APP_IN" "$APP"
  # A stray extended attribute makes codesign fail with a resource-fork error
  # that names no file.
  xattr -cr "$APP"
}

# ---------------------------------------------------------------------------
# Developer ID
# ---------------------------------------------------------------------------

sign_developer_id() {
  require_config VBX_DEVELOPER_ID_APP "$DEVELOPER_ID_APP"

  local entitlements="$ROOT/Resources/entitlements/developer-id.entitlements"
  [[ -f "$entitlements" ]] || fail "missing $entitlements"

  say "==> Signing for Developer ID (hardened runtime)"
  assert_identity "$DEVELOPER_ID_APP" "Developer ID Application"
  # Inside out: nested code first, the bundle last. `--deep` is the documented
  # wrong answer — it re-signs nested code with the *bundle's* entitlements and
  # skips anything it does not recognise.
  if [[ -f "$APP/Contents/MacOS/vbx-cli" ]]; then
    run codesign --force --timestamp --options runtime \
      --sign "$DEVELOPER_ID_APP" "$APP/Contents/MacOS/vbx-cli"
  fi
  run codesign --force --timestamp --options runtime \
    --entitlements "$entitlements" \
    --sign "$DEVELOPER_ID_APP" "$APP"

  say "==> Verifying the signature"
  run codesign --verify --deep --strict --verbose=2 "$APP"
}

notarize() {
  local target="$1"
  if [[ $NOTARIZE -eq 0 ]]; then
    say "==> Skipping notarization (--no-notarize): Gatekeeper will refuse this on another Mac"
    return 0
  fi
  if [[ "$DEVELOPER_ID_APP" == "-" ]]; then
    fail "an ad-hoc signature cannot be notarized. Add --no-notarize for a local build, or configure VBX_DEVELOPER_ID_APP."
  fi
  require_config VBX_NOTARY_PROFILE "$NOTARY_PROFILE"

  say "==> Notarizing (this waits on Apple; minutes, occasionally longer)"
  run xcrun notarytool submit "$target" \
    --keychain-profile "$NOTARY_PROFILE" --wait

  say "==> Stapling the ticket"
  # Stapling is what makes the download work offline; without it Gatekeeper has
  # to reach Apple on first launch.
  run xcrun stapler staple "$target"
  run xcrun stapler validate "$target"
}

make_dmg() {
  local dmg="$DIST/vbx-$APP_VERSION.dmg"
  say "==> Building ${dmg#"$ROOT"/}"
  if [[ $DRY_RUN -eq 0 ]]; then rm -f "$dmg"; fi

  # A staging folder with an /Applications symlink is the whole of the
  # conventional drag-to-install window.
  local root="$DIST/dmgroot"
  if [[ $DRY_RUN -eq 0 ]]; then
    rm -rf "$root"
    mkdir -p "$root"
    cp -R "$APP" "$root/vbx.app"
    ln -s /Applications "$root/Applications"
  fi

  run hdiutil create -volname "vbx $APP_VERSION" -srcfolder "$root" \
    -ov -format UDZO "$dmg"

  # The disk image is signed and notarized in its own right: the ticket the
  # user's Mac checks on first open is the one stapled to the .dmg, not the one
  # inside it.
  say "==> Signing the disk image"
  run codesign --force --timestamp --sign "$DEVELOPER_ID_APP" "$dmg"
  notarize "$dmg"

  if [[ $DRY_RUN -eq 0 ]]; then rm -rf "$root"; fi
  say ""
  say "Built ${dmg#"$ROOT"/}"
  say "Verify on a machine that has never seen it: spctl -a -vvv -t open --context context:primary-signature <dmg>"
}

# ---------------------------------------------------------------------------
# Mac App Store
# ---------------------------------------------------------------------------

# expand_app_store_entitlements writes the substituted file into .build/dist,
# never into Resources/. The template in the repository has placeholders where
# the Team ID goes, and this is the only place the real value is written to
# disk by the build.
expand_app_store_entitlements() {
  local template="$ROOT/Resources/entitlements/app-store.entitlements.template"
  local out="$DIST/app-store.entitlements"
  [[ -f "$template" ]] || fail "missing $template"

  if [[ $DRY_RUN -eq 1 ]]; then
    say "  expanding app-store.entitlements.template -> ${out#"$ROOT"/}"
    printf '%s' "$out"
    return 0
  fi
  mkdir -p "$DIST"
  sed -e "s/__TEAM_ID__/$TEAM_ID/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" \
    "$template" > "$out"
  # The expanded file carries the Team ID. .build/ is gitignored, and this
  # keeps it unreadable by other accounts on a shared machine as well.
  chmod 600 "$out"
  printf '%s' "$out"
}

sign_app_store() {
  require_config VBX_TEAM_ID "$TEAM_ID"
  require_config VBX_APP_STORE_APP "$APP_STORE_APP"
  require_config VBX_APP_STORE_INSTALLER "$APP_STORE_INSTALLER"
  require_config VBX_PROVISION_PROFILE "$PROVISION_PROFILE"
  assert_identity "$APP_STORE_APP" "Apple Distribution"
  assert_identity "$APP_STORE_INSTALLER" "3rd Party Mac Developer Installer"

  if [[ $DRY_RUN -eq 0 && ! -f "$PROVISION_PROFILE" ]]; then
    fail "no provisioning profile at the configured path"
  fi

  local entitlements
  entitlements="$(expand_app_store_entitlements)"

  say "==> Preparing the App Store bundle"
  # The bundled CLI comes out. A sandboxed app cannot symlink it into
  # /usr/local/bin, so shipping it would add an unusable binary that App Review
  # would reasonably ask about. `vbx-cli` stays a Developer ID feature.
  if [[ $DRY_RUN -eq 0 ]]; then
    rm -f "$APP/Contents/MacOS/vbx-cli"
    cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"
  else
    say "  removing Contents/MacOS/vbx-cli (not usable from a sandbox)"
    say "  copying the provisioning profile to Contents/embedded.provisionprofile"
  fi

  say "==> Signing for the App Store (sandboxed)"
  # No --options runtime here: the hardened runtime is a notarization
  # requirement for Developer ID, and the App Store applies its own policy.
  run codesign --force --timestamp \
    --entitlements "$entitlements" \
    --sign "$APP_STORE_APP" "$APP"
  run codesign --verify --deep --strict --verbose=2 "$APP"

  local pkg="$DIST/vbx-$APP_VERSION.pkg"
  say "==> Building ${pkg#"$ROOT"/} for App Store Connect"
  run productbuild --component "$APP" /Applications \
    --sign "$APP_STORE_INSTALLER" "$pkg"

  say ""
  say "Built ${pkg#"$ROOT"/}"
  say "Upload with:  xcrun altool --upload-app -f <pkg> -t macos --apple-id <id> --password <app-specific>"
  say "         or:  xcrun notarytool is not used for App Store submissions; App Store Connect validates instead."
}

# ---------------------------------------------------------------------------

mkdir -p "$DIST"
stage_app

case "$MODE" in
  sign)
    sign_developer_id
    say ""
    say "Signed ${APP#"$ROOT"/}"
    ;;
  dmg)
    sign_developer_id
    make_dmg
    ;;
  app-store)
    sign_app_store
    ;;
esac

if [[ $DRY_RUN -eq 1 ]]; then
  say ""
  say "(dry run — nothing was signed, built or submitted)"
fi
