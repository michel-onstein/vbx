#!/usr/bin/env bash
#
# Creates the Developer ID Application certificate a signed release needs.
#
#   ./scripts/signing-setup.sh --check     # what is missing, and what to do
#   ./scripts/signing-setup.sh --dry-run   # the plan, without touching anything
#   ./scripts/signing-setup.sh             # create the certificate and install it
#
# ## What this is for
#
# A `--dmg` release needs two things this repository cannot create for itself:
# a **Developer ID Application** certificate, and credentials to notarize with.
# Both come from the Apple developer account.
#
# One App Store Connect API key covers both. It creates the certificate here,
# and `package-app.sh` notarizes with the same key — so there is no second
# credential, no app-specific password, and nothing that only exists in one
# machine's keychain. See scripts/signing.env.example.
#
# ## What it deliberately does not do
#
# Write anything into the repository. The private key and the certificate go to
# `~/.vbx-signing` by default, outside the checkout, because this repository is
# public and ADR-009 is that no signing material is in it. Nothing here prints a
# certificate name, a Team ID or a key id either.
#
# ## The role requirement
#
# Apple restricts Developer ID certificate creation to the **Account Holder**.
# An Admin key can read certificates and will fail to create one, with an error
# that does not obviously say so — which is why `--check` names it up front.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${VBX_SIGNING_DIR:-$HOME/.vbx-signing}"
CERT_TYPE=DEVELOPER_ID_APPLICATION

CHECK=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { echo "$@"; }
fail() { echo "error: $*" >&2; exit 1; }

have_developer_id() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -q "Developer ID Application"
}

asc_authenticated() {
  command -v asc >/dev/null 2>&1 || return 1
  # `credentials` is empty when nothing is stored; the env form sets
  # environmentCredentialsComplete instead.
  asc auth status 2>/dev/null \
    | grep -qE '"credentials":\[[^]]' || \
  asc auth status 2>/dev/null \
    | grep -q '"environmentCredentialsComplete":true'
}

# ---------------------------------------------------------------------------
# --check
# ---------------------------------------------------------------------------

if [[ $CHECK -eq 1 ]]; then
  say "==> Signing prerequisites"

  if have_developer_id; then
    say "  Developer ID Application certificate   present"
  else
    say "  Developer ID Application certificate   MISSING"
  fi

  if command -v asc >/dev/null 2>&1; then
    if asc_authenticated; then
      say "  asc                                    authenticated"
    else
      say "  asc                                    installed, no credentials"
    fi
  else
    say "  asc                                    not installed (brew install asc)"
  fi

  say ""
  if have_developer_id; then
    say "The certificate exists. Point VBX_DEVELOPER_ID_APP at its full name:"
    say "  security find-identity -v -p codesigning | grep 'Developer ID Application'"
  else
    say "To create it you need an App Store Connect API key belonging to the"
    say "**Account Holder** — Apple does not let an Admin key create a Developer"
    say "ID certificate, and the failure does not say so clearly."
    say ""
    say "  1. appstoreconnect.apple.com -> Users and Access -> Integrations"
    say "     -> App Store Connect API -> generate a Team key, download the .p8"
    say "  2. asc auth login          (or set ASC_* environment variables)"
    say "  3. ./scripts/signing-setup.sh"
    say ""
    say "The same key notarizes: set VBX_NOTARY_KEY, VBX_NOTARY_KEY_ID and"
    say "VBX_NOTARY_ISSUER in scripts/signing.env and no app-specific password"
    say "is needed."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Create
# ---------------------------------------------------------------------------

if have_developer_id; then
  say "A Developer ID Application certificate is already in the keychain."
  say "Nothing to do. Re-creating one would leave two valid certificates and an"
  say "ambiguous VBX_DEVELOPER_ID_APP; revoke the old one deliberately instead:"
  say "  asc certificates list --certificate-type $CERT_TYPE"
  say "  asc certificates revoke --id CERT_ID --confirm"
  exit 0
fi

KEY_PATH="$OUT_DIR/developer-id.key"
CSR_PATH="$OUT_DIR/developer-id.csr"
CER_PATH="$OUT_DIR/developer-id.cer"

say "==> Creating a $CERT_TYPE certificate"
say "  key and certificate -> $OUT_DIR (outside the repository, deliberately)"

# The credential checks come after this, so the plan can be read before anyone
# has a key — which is when it is most useful.
if [[ $DRY_RUN -eq 1 ]]; then
  say ""
  say "Would run:"
  say "  mkdir -p $OUT_DIR && chmod 700 $OUT_DIR"
  say "  asc certificates create --certificate-type $CERT_TYPE \\"
  say "    --generate-csr --key-out $KEY_PATH --csr-out $CSR_PATH"
  say "  security import $KEY_PATH -k login.keychain-db -T /usr/bin/codesign"
  say "  security import $CER_PATH -k login.keychain-db -T /usr/bin/codesign"
  say ""
  say "Then print the identity to configure, and nothing else."
  exit 0
fi

command -v asc >/dev/null 2>&1 || fail "asc is not installed (brew install asc)"
asc_authenticated || fail "asc has no credentials — run ./scripts/signing-setup.sh --check"

mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

# The private key never leaves this machine: `asc` generates it locally and
# sends only the CSR. Apple never sees it, and neither does the repository.
RESPONSE_PATH="$OUT_DIR/create-response.json"
asc certificates create --certificate-type "$CERT_TYPE" \
  --generate-csr --key-out "$KEY_PATH" --csr-out "$CSR_PATH" --output json \
  > "$RESPONSE_PATH"
chmod 600 "$KEY_PATH" "$RESPONSE_PATH"

# `certificateContent` is base64 DER. Extracted with python rather than a grep,
# because a JSON field is not a line — and read from a file rather than stdin,
# because stdin is already carrying this script.
python3 - "$CER_PATH" "$RESPONSE_PATH" <<'PY' || fail "could not read the certificate from asc's response"
import base64, json, sys
path, response = sys.argv[1], sys.argv[2]
payload = json.load(open(response))
def find(node):
    if isinstance(node, dict):
        if "certificateContent" in node:
            return node["certificateContent"]
        for value in node.values():
            found = find(value)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find(value)
            if found:
                return found
    return None
content = find(payload)
if not content:
    raise SystemExit(1)
open(path, "wb").write(base64.b64decode(content))
PY

# The response carries the certificate and nothing secret, but it is account
# data and there is no reason to leave it lying about.
rm -f "$RESPONSE_PATH"

say "==> Importing into the login keychain"
security import "$KEY_PATH" -k login.keychain-db -T /usr/bin/codesign >/dev/null
security import "$CER_PATH" -k login.keychain-db -T /usr/bin/codesign >/dev/null

if ! have_developer_id; then
  fail "the certificate imported but does not appear as a codesigning identity"
fi

say ""
say "Done. Set this in scripts/signing.env, with the full identity string:"
say "  security find-identity -v -p codesigning | grep 'Developer ID Application'"
say ""
say "Then confirm the whole channel is ready:"
say "  ./scripts/package-app.sh --check"
