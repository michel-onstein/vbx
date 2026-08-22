#!/usr/bin/env python3
"""Tests for the signing and packaging setup.

Run with:

    python3 scripts/test-packaging.py

Two things are being protected here, and only one of them is "the script
works".

The other is that this repository is public. A Team ID, a certificate name or
a provisioning profile committed by accident is not recoverable by deleting it
in a later commit — it is in the history. So the leak tests below run against
the *tracked* files rather than the working tree, and the redaction tests drive
the real script with fabricated credentials and assert they do not come back
out in its output.

No certificates are needed: every packaging path is exercised through
``--dry-run``, which prints the plan and runs nothing.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = ROOT / "scripts" / "package-app.sh"
EXAMPLE = ROOT / "scripts" / "signing.env.example"
BUILD_APP = ROOT / "scripts" / "build-app.sh"
BUILD_ENGINE = ROOT / "scripts" / "build-engine.sh"
RELEASE = ROOT / "scripts" / "release.sh"
VERSION = ROOT / "scripts" / "version.sh"
CASK_TEMPLATE = ROOT / "packaging" / "homebrew" / "vbx.rb.template"
BUMP = ROOT / "scripts" / "version-bump.sh"
NOTES = ROOT / "scripts" / "release-notes.py"

# Fabricated, and deliberately distinctive: a substring that appears nowhere
# else means an assertion that it is absent cannot pass by coincidence.
FAKE = {
    "VBX_TEAM_ID": "ZZ9PLURAL9",
    "VBX_BUNDLE_ID": "com.qjam.vbx",
    "VBX_DEVELOPER_ID_APP": "Developer ID Application: Nemo Nobody (ZZ9PLURAL9)",
    "VBX_NOTARY_PROFILE": "test-notary-profile",
    "VBX_APP_STORE_APP": "Apple Distribution: Nemo Nobody (ZZ9PLURAL9)",
    "VBX_APP_STORE_INSTALLER": "3rd Party Mac Developer Installer: Nemo Nobody (ZZ9PLURAL9)",
    "VBX_PROVISION_PROFILE": "/nowhere/secret-team.provisionprofile",
}

failures: list[str] = []
passed = 0


def check(name: str, condition: bool, detail: str = "") -> None:
    global passed
    if condition:
        passed += 1
        print(f"  ok    {name}")
    else:
        failures.append(f"{name}: {detail}" if detail else name)
        print(f"  FAIL  {name}" + (f"  ({detail})" if detail else ""))


def run_package(*args: str, env_extra: dict[str, str] | None = None,
                config: Path | None = None) -> subprocess.CompletedProcess[str]:
    """Run package-app.sh with the fake credentials in the environment."""
    env = dict(os.environ)
    env.update(FAKE)
    # Point at a config file that does not exist unless the test supplies one,
    # so a developer's real scripts/signing.env cannot influence the result.
    env["VBX_SIGNING_CONFIG"] = str(config) if config else "/nonexistent/signing.env"
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        ["bash", str(PACKAGE), *args],
        capture_output=True, text=True, env=env, cwd=ROOT,
    )


# Which settings are actually secret.
#
# VBX_BUNDLE_ID is not: `com.qjam.vbx` is committed in Info.plist, in the
# scripts and in the Swift sources, deliberately. Scanning for it flagged nine
# tracked files the first time this ran against a real config — and a leak
# detector that cries wolf on its first real use is one people learn to ignore.
#
# VBX_NOTARY_PROFILE is not secret either: it names a keychain profile, while
# the credential it stores stays in the keychain.
SECRET_KEYS = {
    "VBX_TEAM_ID",
    "VBX_DEVELOPER_ID_APP",
    "VBX_APP_STORE_APP",
    "VBX_APP_STORE_INSTALLER",
    "VBX_PROVISION_PROFILE",
}


def parse_env_file(path: Path) -> dict[str, str]:
    """Read KEY=value lines, ignoring comments and blanks."""
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def parse_config_secrets(path: Path) -> list[tuple[str, str]]:
    """The secret (key, value) pairs actually configured on this machine.

    Values still equal to the template's placeholders are skipped: a config
    copied from `signing.env.example` and only partly filled in would otherwise
    report the example file as leaking its own placeholders.
    """
    placeholders = set(parse_env_file(EXAMPLE).values())
    out: list[tuple[str, str]] = []
    for key, value in parse_env_file(path).items():
        if key not in SECRET_KEYS:
            continue
        if not value or value in placeholders or value.startswith("$"):
            continue
        out.append((key, value))
    return out


def tracked_files() -> list[Path]:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z"],
        capture_output=True, text=True, check=True,
    ).stdout
    return [ROOT / name for name in out.split("\0") if name]


# ---------------------------------------------------------------------------


def test_dry_runs_do_not_leak() -> None:
    """The point of the redaction: fake IDs go in, none come out."""
    print("\nRedaction")
    for mode in ("--sign", "--dmg", "--app-store"):
        result = run_package(mode, "--dry-run")
        combined = result.stdout + result.stderr
        check(f"{mode} --dry-run succeeds", result.returncode == 0,
              combined.strip()[-300:])
        check(f"{mode} --dry-run does not print the Team ID",
              FAKE["VBX_TEAM_ID"] not in combined,
              "the Team ID appeared in the output")
        check(f"{mode} --dry-run does not print a certificate name",
              "Nemo Nobody" not in combined,
              "a certificate common name appeared in the output")
        check(f"{mode} --dry-run does not print the profile path",
              "secret-team.provisionprofile" not in combined)
        check(f"{mode} --dry-run says it changed nothing",
              "dry run" in combined)


def test_redaction_covers_unrelated_identities() -> None:
    """Masking the configured values is not enough on its own.

    `security find-identity` lists every certificate in the keychain, so a
    build for one team can print another team's ID. The pattern-based pass is
    what covers that, and this checks it is actually applied.
    """
    print("\nRedaction of identities the build does not use")
    result = run_package("--sign", "--dry-run",
                         env_extra={"VBX_DEVELOPER_ID_APP":
                                    "Developer ID Application: Someone Else (QQ1OTHER77)"})
    combined = result.stdout + result.stderr
    check("a differently-shaped identity is still masked",
          "QQ1OTHER77" not in combined, combined.strip()[-200:])


def test_missing_config_is_a_clear_error() -> None:
    print("\nMissing configuration")
    env_cleared = {k: "" for k in FAKE}
    result = run_package("--dmg", "--dry-run", env_extra=env_cleared)
    combined = result.stdout + result.stderr
    check("a missing certificate fails", result.returncode != 0)
    check("the error names the file to create",
          "signing.env" in combined, combined.strip()[-200:])


def test_config_file_is_read_and_env_wins() -> None:
    print("\nConfiguration precedence")
    with tempfile.TemporaryDirectory() as tmp:
        config = Path(tmp) / "signing.env"
        config.write_text(
            'VBX_TEAM_ID=FILE123456\n'
            'VBX_DEVELOPER_ID_APP="Developer ID Application: From File (FILE123456)"\n'
        )
        # Nothing in the environment: the file supplies the values.
        env = {k: "" for k in FAKE}
        result = run_package("--sign", "--dry-run", env_extra=env, config=config)
        combined = result.stdout + result.stderr
        check("a config file alone is enough", result.returncode == 0,
              combined.strip()[-200:])
        check("values from the file are masked too",
              "FILE123456" not in combined)

        # With both, the environment wins — which is how CI supplies secrets
        # without writing them into the checkout.
        result = run_package("--sign", "--dry-run", config=config)
        check("the environment overrides the file", result.returncode == 0)
        check("neither value leaks when both are present",
              "FILE123456" not in (result.stdout + result.stderr)
              and FAKE["VBX_TEAM_ID"] not in (result.stdout + result.stderr))


def test_app_store_entitlements_are_generated_not_committed() -> None:
    print("\nApp Store entitlements")
    template = ROOT / "Resources" / "entitlements" / "app-store.entitlements.template"
    check("the template exists", template.exists())
    text = template.read_text()
    check("the template has a placeholder, not a Team ID",
          "__TEAM_ID__" in text)
    check("the template contains no 10-character team-shaped literal",
          not re.search(r"<string>[A-Z0-9]{10}\.", text))

    expanded = ROOT / ".build" / "dist" / "app-store.entitlements"
    check("the expanded file is gitignored",
          subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", str(expanded)]
                         ).returncode == 0,
          "an expanded entitlements file would be committable")


def test_signing_env_is_ignored() -> None:
    print("\nThe config file cannot be committed")
    target = ROOT / "scripts" / "signing.env"
    ignored = subprocess.run(
        ["git", "-C", str(ROOT), "check-ignore", "-q", str(target)]
    ).returncode == 0
    check("scripts/signing.env is gitignored", ignored,
          "the file holding the Team ID is committable")

    check("the example template is NOT ignored",
          subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", str(EXAMPLE)]
                         ).returncode != 0,
          "the template should be committed")

    profile = ROOT / "some-team.provisionprofile"
    check("provisioning profiles are gitignored",
          subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", str(profile)]
                         ).returncode == 0)

    # Regression: the rule was the exact filename, so `scripts/signing.env` was
    # ignored while vim's `.signing.env.swp` — holding the same buffer, Team ID
    # and all — sat next to it untracked and committable. Every file an editor
    # leaves beside the real one carries the same contents.
    for leftover in (".signing.env.swp", ".signing.env.swo", "signing.env~",
                     "signing.env.bak", "signing.env.save", "signing.env.orig"):
        path = ROOT / "scripts" / leftover
        check(f"editor leftover {leftover} is gitignored",
              subprocess.run(["git", "-C", str(ROOT), "check-ignore", "-q", str(path)]
                             ).returncode == 0,
              "it would hold the same Team ID as signing.env")


def test_no_tracked_file_carries_credentials() -> None:
    """The regression test for the thing that cannot be undone.

    Scans every file git tracks. If a real Team ID is configured on this
    machine, its literal value is searched for as well — which is the check
    that would actually catch a leak, since a placeholder looks nothing like
    the real thing.
    """
    print("\nNo credentials in tracked files")

    real_values = parse_config_secrets(ROOT / "scripts" / "signing.env")

    offenders: list[str] = []
    apple_id_re = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")
    for path in tracked_files():
        if not path.is_file():
            continue
        try:
            text = path.read_text(errors="ignore")
        except OSError:
            continue
        for key, value in real_values:
            if value in text:
                # The key is named so the report is actionable; the value never
                # is, because this output goes wherever test output goes.
                offenders.append(f"{path.relative_to(ROOT)} contains {key}")
        # An Apple ID would most plausibly arrive inside the example file or
        # the docs, as someone's address pasted over the placeholder.
        if path.name in ("signing.env.example", "package-app.sh"):
            for match in apple_id_re.findall(text):
                if not match.endswith("example.com"):
                    offenders.append(f"{path.relative_to(ROOT)} contains {match}")

    check("no tracked file carries a configured signing value",
          not offenders, "; ".join(offenders))

    # Three states, not two. "Nothing to scan for" and "no config at all" look
    # identical to the assertion and mean different things to a reader, and
    # reporting the second when the first is true is a lie about coverage —
    # which is what this check exists to avoid in the first place.
    config = ROOT / "scripts" / "signing.env"
    if real_values:
        names = ", ".join(sorted(key for key, _ in real_values))
        print(f"        (checked against {len(real_values)} configured value(s): {names})")
    elif config.exists():
        print("        (scripts/signing.env holds only template placeholders — "
              "nothing to scan for yet)")
    else:
        print("        (no scripts/signing.env on this machine — literal-value "
              "check did not run)")


def test_the_leak_scan_still_detects() -> None:
    """Narrowing the scan must not have switched it off.

    Two directions, because a detector that never fires and a detector that
    always fires are equally useless — and the second is how the first happens,
    since people stop reading it.
    """
    print("\nThe leak scan itself")
    with tempfile.TemporaryDirectory() as tmp:
        config = Path(tmp) / "signing.env"
        config.write_text(
            "VBX_TEAM_ID=QQ1OTHER77\n"
            "VBX_BUNDLE_ID=com.qjam.vbx\n"
            "VBX_NOTARY_PROFILE=vbx-notary\n"
            'VBX_DEVELOPER_ID_APP="Developer ID Application: Nemo Nobody (QQ1OTHER77)"\n'
        )
        secrets = dict(parse_config_secrets(config))

        check("a real Team ID is scanned for", "VBX_TEAM_ID" in secrets)
        check("a real certificate name is scanned for",
              "VBX_DEVELOPER_ID_APP" in secrets)
        # The false positive that started this: com.qjam.vbx is committed in
        # Info.plist, the scripts and the Swift sources, on purpose.
        check("the bundle id is not treated as a secret",
              "VBX_BUNDLE_ID" not in secrets)
        check("the notary profile name is not treated as a secret",
              "VBX_NOTARY_PROFILE" not in secrets)

    with tempfile.TemporaryDirectory() as tmp:
        # A config copied from the template and not yet filled in has nothing
        # worth scanning for, and must not report the template as leaking its
        # own placeholders.
        config = Path(tmp) / "signing.env"
        config.write_text(EXAMPLE.read_text())
        check("untouched placeholders are not scanned for",
              parse_config_secrets(config) == [],
              str(parse_config_secrets(config)))


def test_example_holds_only_placeholders() -> None:
    print("\nThe committed template")
    text = EXAMPLE.read_text()
    check("the example exists and mentions the Team ID", "VBX_TEAM_ID" in text)
    check("the example's Team ID is the documented placeholder",
          "ABCDE12345" in text)
    check("the example tells you the file is gitignored",
          "gitignored" in text)
    check("the example does not hard-code a real-looking Apple ID",
          "@" not in text or "example.com" in text)


def test_short_values_are_not_masked() -> None:
    """Regression: the ad-hoc identity is a single hyphen.

    Masking it blindly replaced every `-` in the output — flags, paths and
    prose all turned into `<DEVELOPER_ID_APP>`. Only values long enough to be
    a credential are masked.
    """
    print("\nShort values")
    result = run_package("--sign", "--dry-run",
                         env_extra={"VBX_DEVELOPER_ID_APP": "-"})
    combined = result.stdout + result.stderr
    check("an ad-hoc identity leaves flags intact",
          "--force" in combined and "--timestamp" in combined,
          combined.strip()[-200:])
    check("an ad-hoc identity leaves paths intact",
          "developer-id.entitlements" in combined)
    check("an ad-hoc build warns that it is not distributable",
          "ad-hoc" in combined)


def test_ad_hoc_cannot_be_notarized() -> None:
    print("\nAd-hoc guard rails")
    result = run_package("--dmg", "--dry-run",
                         env_extra={"VBX_DEVELOPER_ID_APP": "-"})
    combined = result.stdout + result.stderr
    check("notarizing an ad-hoc signature is refused", result.returncode != 0)
    check("the refusal points at the fix",
          "--no-notarize" in combined or "VBX_DEVELOPER_ID_APP" in combined,
          combined.strip()[-200:])


def test_real_app_store_run() -> None:
    """Exercises the App Store path for real, as far as certificates allow.

    Everything up to `productbuild` runs: staging, removing the CLI, embedding
    the profile, expanding the entitlements and signing the sandboxed bundle.
    `productbuild` then refuses the ad-hoc identity, which is correct — so the
    assertions are about the artifacts, not the exit code.
    """
    print("\nApp Store build (ad-hoc, as far as it goes)")
    app = ROOT / ".build" / "vbx.app"
    if not app.is_dir():
        # Said out loud rather than silently passing: a skipped check that
        # looks like a green one is worse than no check.
        print("        (no .build/vbx.app — run ./scripts/build-app.sh first; "
              "these checks did not run)")
        return

    with tempfile.TemporaryDirectory() as tmp:
        profile = Path(tmp) / "fake.provisionprofile"
        profile.write_text("not a real profile")
        run_package("--app-store", env_extra={
            "VBX_APP_STORE_APP": "-",
            "VBX_APP_STORE_INSTALLER": "-",
            "VBX_PROVISION_PROFILE": str(profile),
        })

    entitlements = ROOT / ".build" / "dist" / "app-store.entitlements"
    check("the entitlements were generated", entitlements.exists())
    if entitlements.exists():
        text = entitlements.read_text()
        check("no placeholder survived substitution",
              "__TEAM_ID__" not in text and "__BUNDLE_ID__" not in text)
        check("the Team ID was substituted in",
              f"{FAKE['VBX_TEAM_ID']}.{FAKE['VBX_BUNDLE_ID']}" in text)
        check("the generated file is valid plist",
              subprocess.run(["plutil", "-lint", str(entitlements)],
                             capture_output=True).returncode == 0)
        # It carries the Team ID, so it should not be world-readable on a
        # shared machine either.
        check("the generated file is not world-readable",
              (entitlements.stat().st_mode & 0o077) == 0,
              oct(entitlements.stat().st_mode))

    staged = ROOT / ".build" / "dist" / "stage" / "vbx.app"
    check("the App Store bundle drops the CLI",
          not (staged / "Contents" / "MacOS" / "vbx-cli").exists(),
          "a sandboxed app cannot install it, so shipping it invites review questions")
    check("the provisioning profile is embedded",
          (staged / "Contents" / "embedded.provisionprofile").exists())
    check("the input bundle was not mutated",
          (app / "Contents" / "MacOS" / "vbx-cli").exists(),
          "packaging must work on a copy")


def test_check_reports_per_channel() -> None:
    """--check answers "can I ship?", not "are some settings present?".

    The first version printed CONFIG OK with nothing configured at all, which
    reads as a green light for a machine that cannot sign anything.
    """
    print("\n--check")
    empty = {k: "" for k in FAKE}
    result = run_package("--check", env_extra=empty)
    combined = result.stdout + result.stderr
    check("nothing configured fails", result.returncode != 0, combined.strip()[-200:])
    check("it names both channels",
          "--dmg" in combined and "--app-store" in combined)

    # A Developer ID build without notarization needs no notary profile, so
    # this is a legitimately complete configuration. Signed ad-hoc because a
    # real certificate name would have to be in this machine's keychain —
    # `--check` verifies that, which is the point of it.
    result = run_package("--check", "--no-notarize",
                         env_extra={"VBX_NOTARY_PROFILE": "",
                                    "VBX_DEVELOPER_ID_APP": "-"})
    check("a Developer ID identity alone is enough with --no-notarize",
          result.returncode == 0, (result.stdout + result.stderr).strip()[-200:])
    check("--check masks the values it reports",
          FAKE["VBX_TEAM_ID"] not in (result.stdout + result.stderr))
    check("--check does not print the values, only whether they are set",
          "set" in result.stdout)


def test_notary_probe_uses_flags_this_notarytool_has() -> None:
    """A flag notarytool does not have fails the probe, not the flag.

    `notarytool history --limit 1` kept the preflight round trip small, and
    notarytool 1.1.2 has no `--limit`: it exits 64 on the unknown option. So a
    profile that worked was reported unusable, `--check` exited non-zero, and
    release.sh — which runs it unwrapped in preflight — aborted before building
    anything. No release was ever cut. The probe discarded stderr, so "unknown
    flag" and "no such credential" printed the same sentence, and the sentence
    said to store credentials that were already stored.

    So: every flag handed to notarytool must exist in *this* notarytool, and a
    failing probe must say what actually went wrong.
    """
    print("\nNotary probe")
    if not shutil.which("xcrun"):
        print("  skip  notarytool flags (xcrun is not on the PATH)")
        return

    # Continuations joined first, so a flag on the next line still belongs to
    # the invocation that opened it.
    joined = PACKAGE.read_text().replace("\\\n", " ")
    invocations = re.findall(r"xcrun notarytool ([a-z][a-z-]*)([^\n]*)", joined)
    check("the notarytool invocations are found", len(invocations) >= 2,
          f"found {len(invocations)}")

    for sub, rest in invocations:
        usage = subprocess.run(["xcrun", "notarytool", sub, "--help"],
                               capture_output=True, text=True)
        if usage.returncode != 0:
            check(f"notarytool {sub} --help succeeds", False,
                  (usage.stdout + usage.stderr).strip()[:200])
            continue
        supported = set(re.findall(r"--[a-z][a-z-]*", usage.stdout + usage.stderr))
        for flag in sorted(set(re.findall(r"--[a-z][a-z-]*", rest))):
            check(f"notarytool {sub} accepts {flag}", flag in supported,
                  "this notarytool has no such option")

    # And the diagnosis, which is the half that made the flag bug unreadable.
    result = run_package("--check", env_extra={"VBX_DEVELOPER_ID_APP": "-"})
    combined = result.stdout + result.stderr
    check("an unusable notary profile is reported as such",
          "notary profile" in combined and "not usable" in combined,
          combined.strip()[-200:])
    check("a failed probe reports why it failed",
          FAKE["VBX_NOTARY_PROFILE"] in combined,
          "the probe's own error was swallowed")


def test_a_certificate_of_the_wrong_kind_is_refused() -> None:
    """`assert_identity`'s label has to mean something.

    It took a label — "Developer ID Application" — put it in the error message,
    and then checked only whether the configured string appeared in
    `security find-identity` at all. So an "Apple Development" certificate
    configured as VBX_DEVELOPER_ID_APP passed `--check` ("Developer ID cert in
    the keychain": true, and useless), passed the assertion, signed the app,
    built the disk image, and was refused by Apple six minutes later — "The
    binary is not signed with a valid Developer ID certificate", every binary,
    every architecture.

    Apple names these certificates canonically, so the prefix is the check.
    """
    print("\nCertificate kind")
    wrong = "Apple Development: Nemo Nobody (ZZ9PLURAL9)"

    result = run_package("--check", env_extra={"VBX_DEVELOPER_ID_APP": wrong})
    combined = result.stdout + result.stderr
    check("a development certificate is not accepted as a Developer ID one",
          "NOT a Developer ID Application certificate" in combined,
          combined.strip()[-200:])
    check("...and --dmg is reported not ready", "--dmg          not ready" in combined)
    check("...and it says where to get the right one",
          "developer.apple.com" in combined)

    # Before the build, not after it: the assertion runs ahead of the dry-run
    # return precisely so a plan that cannot work says so without building.
    result = run_package("--dmg", "--dry-run", env_extra={"VBX_DEVELOPER_ID_APP": wrong})
    combined = result.stdout + result.stderr
    check("signing with it is refused before anything is built",
          result.returncode != 0, combined.strip()[-200:])
    check("the refusal names the kind of certificate needed",
          "Developer ID Application" in combined)
    check("the refusal does not leak the certificate's name",
          "Nemo Nobody" not in combined)

    # The right shape still passes, or the check above would be a wall.
    result = run_package("--dmg", "--dry-run")
    check("a Developer ID Application name is accepted", result.returncode == 0,
          (result.stdout + result.stderr).strip()[-200:])

    # The App Store channel takes its own kind, and the same reasoning.
    result = run_package("--app-store", "--dry-run",
                         env_extra={"VBX_APP_STORE_APP": wrong})
    check("an App Store build refuses a development certificate too",
          result.returncode != 0)


def test_help_and_bad_flags() -> None:
    print("\nInterface")
    result = run_package("--help")
    check("--help succeeds", result.returncode == 0)
    check("--help lists the modes",
          "--dmg" in result.stdout and "--app-store" in result.stdout)

    result = run_package("--nonsense")
    check("an unknown flag is rejected", result.returncode == 2)

    result = run_package()
    check("no mode is rejected rather than doing something", result.returncode == 2)


def test_build_app_forwards() -> None:
    print("\nbuild-app.sh hand-off")
    text = (ROOT / "scripts" / "build-app.sh").read_text()
    for flag in ("--sign", "--dmg", "--app-store", "--dry-run", "--no-notarize"):
        check(f"build-app.sh accepts {flag}", flag in text)
    check("build-app.sh delegates rather than reimplementing",
          "package-app.sh" in text)
    check("a distribution build forces --release", "implies --release" in text)


def test_universal_is_implied_and_verified() -> None:
    """An arm64-only .dmg excludes every Intel Mac, and only the user finds out.

    So the flag has to exist, distribution has to imply it, and — separately —
    the artefact has to be checked. "--universal was passed" and "--universal
    took effect" are different claims; build-engine.sh already made that
    distinction for the deployment target, and it applies here for the same
    reason.
    """
    print("\nUniversal binary")
    app = BUILD_APP.read_text()
    engine = BUILD_ENGINE.read_text()

    check("build-app.sh accepts --universal", "--universal) UNIVERSAL=1" in app)
    check("a distribution build forces --universal", "implies --universal" in app)
    check("both architectures are asked of SwiftPM",
          "--arch arm64 --arch x86_64" in app)
    check("the bin path is asked for, not hardcoded", "--show-bin-path" in app)

    check("the app binary's slices are asserted",
          'assert_binary_slices "$APP/Contents/MacOS/vbx"' in app)
    check("the CLI binary's slices are asserted too",
          'assert_binary_slices "$APP/Contents/MacOS/vbx-cli"' in app)
    check("the assertion reads the artefact", "lipo -archs" in app)

    check("the engine archive's slices are asserted",
          "assert_archive_universal" in engine)
    # A universal archive is a fat file, which `go build -o` will not overwrite:
    # without this, the first host-only build after a release fails with
    # "already exists and is not an object file".
    check("a stale archive is removed before the slice is built",
          'rm -f "$out"' in engine)
    check("the deployment target is still checked across objects",
          "assert_archive_target" in engine)

    # The nested binary loses its linker signature when lipo fuses the slices,
    # so signing the bundle alone fails with "code object is not signed at all".
    check("nested code is signed before the bundle",
          app.index('codesign --force --sign - "$APP/Contents/MacOS/vbx-cli"')
          < app.index('codesign --force --sign - "$APP"'))


def git_repo(directory: Path, *, tag: str | None = None, commits: int = 1) -> None:
    """A throwaway repository, so version.sh can be driven at a known state."""
    env = {
        **os.environ,
        "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
        "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
    }
    def git(*args: str) -> None:
        subprocess.run(["git", *args], cwd=directory, env=env,
                       check=True, capture_output=True)
    git("init", "-q")
    for index in range(commits):
        (directory / f"file{index}").write_text(f"{index}\n")
        git("add", ".")
        git("commit", "-qm", f"commit {index}")
        if tag and index == 0:
            git("tag", "-a", tag, "-m", tag)


def run_version(directory: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(directory / "scripts" / "version.sh"), *args],
        capture_output=True, text=True)


def test_version_comes_from_the_tag() -> None:
    """The version has to agree in three places at once.

    CFBundleShortVersionString, the .dmg filename and a cask's `version`. A cask
    whose version disagrees with what the app reports cannot be upgraded, so the
    literal that used to be in build-app.sh is the bug this prevents.
    """
    print("\nVersion derivation")
    app = BUILD_APP.read_text()
    check("no hardcoded marketing version in build-app.sh",
          "<string>0.1.0</string>" not in app)
    check("the version is stamped from version.sh",
          "scripts/version.sh" in app and "CFBundleShortVersionString $VERSION" in app)

    with tempfile.TemporaryDirectory() as raw:
        for state in ("untagged", "tagged", "ahead", "dirty"):
            directory = Path(raw) / state
            (directory / "scripts").mkdir(parents=True)
            (directory / "scripts" / "version.sh").write_bytes(VERSION.read_bytes())
            (directory / "scripts" / "version.sh").chmod(0o755)

        untagged = Path(raw) / "untagged"
        git_repo(untagged)
        result = run_version(untagged)
        check("an untagged checkout still builds", result.stdout.strip() == "0.0.0")
        result = run_version(untagged, "--check")
        check("...but is not a release point", result.returncode != 0)
        check("...and says why", "tag" in result.stderr)

        tagged = Path(raw) / "tagged"
        git_repo(tagged, tag="1.2.3")
        result = run_version(tagged)
        check("the tag is the version verbatim", result.stdout.strip() == "1.2.3")
        check("the build number is the commit count",
              run_version(tagged, "--build").stdout.strip() == "1")
        check("a clean tag is a release point",
              run_version(tagged, "--check").returncode == 0)

        ahead = Path(raw) / "ahead"
        git_repo(ahead, tag="1.2.3", commits=3)
        check("commits after the tag keep its version",
              run_version(ahead).stdout.strip() == "1.2.3")
        result = run_version(ahead, "--check")
        check("...but are not a release point", result.returncode != 0)
        check("...because the tag does not name that commit",
              "not at a release tag" in result.stderr)

        dirty = Path(raw) / "dirty"
        git_repo(dirty, tag="1.2.3")
        (dirty / "file0").write_text("changed\n")
        result = run_version(dirty, "--check")
        check("a dirty tree is not a release point", result.returncode != 0)
        check("...and says so", "dirty" in result.stderr)


def test_cask_and_release_script() -> None:
    """Every placeholder the template carries must be one release.sh fills.

    A leftover `@SHA256@` in a published cask is a checksum that can never
    match; a substitution release.sh makes for a placeholder that no longer
    exists is silently nothing. Both directions are checked.
    """
    print("\nRelease and Homebrew cask")
    release = RELEASE.read_text()
    template = CASK_TEMPLATE.read_text()

    check("release.sh is executable", os.access(RELEASE, os.X_OK))
    check("version.sh is executable", os.access(VERSION, os.X_OK))
    for script in (RELEASE, VERSION):
        syntax = subprocess.run(["bash", "-n", str(script)], capture_output=True, text=True)
        check(f"{script.name} parses", syntax.returncode == 0, syntax.stderr.strip())

    placeholders = set(re.findall(r"@[A-Z0-9_]+@", template))
    substituted = set(re.findall(r"s\|(@[A-Z0-9_]+@)\|", release))
    check("every placeholder is substituted",
          placeholders <= substituted, f"unfilled: {sorted(placeholders - substituted)}")
    check("every substitution has a placeholder",
          substituted <= placeholders, f"stale: {sorted(substituted - placeholders)}")

    # A cask installing an un-notarized app gives every user a Gatekeeper block.
    code = "\n".join(
        line for line in release.splitlines() if not line.lstrip().startswith("#"))
    check("release.sh never skips notarization", "--no-notarize" not in code)
    check("release.sh fails rather than warns on an unstapled ticket",
          "stapler validate" in release and "not stapled" in release)

    # The bundle on disk is vbx.app; a cask naming "Visual Beads.app" installs
    # nothing and fails at the end of a download.
    check("the cask names the real bundle", 'app "vbx.app"' in template)
    check("the cask zaps the preferences the app writes",
          "com.qjam.vbx.plist" in template)
    check("the cask says how to remove the Keychain items --zap cannot reach",
          "delete-generic-password" in template)
    check("the cask tracks new releases", "livecheck" in template)

    result = subprocess.run([str(RELEASE), "--help"], capture_output=True, text=True)
    check("--help succeeds", result.returncode == 0)
    check("--help explains the modes",
          "--dry-run" in result.stdout and "--publish" in result.stdout)

    result = subprocess.run([str(RELEASE), "--nonsense"], capture_output=True, text=True)
    check("an unknown flag is rejected", result.returncode == 2)

    result = subprocess.run([str(RELEASE), "--tag", "v0.2.0"], capture_output=True, text=True)
    check("a tag with a leading v is refused before anything happens",
          result.returncode == 1 and "X.Y.Z" in result.stderr,
          result.stderr.strip()[:160])
    check("...and says the v is the problem", "no leading v" in result.stderr)

    result = subprocess.run([str(RELEASE), "--tag", "nonsense"], capture_output=True, text=True)
    check("so is a tag that is not a version at all", result.returncode == 1)

    # With a well-formed tag it must still refuse here — either the tree is
    # dirty or signing is unconfigured. What matters is that it stops before
    # building, so neither outcome can be mistaken for a release.
    result = subprocess.run([str(RELEASE), "--tag", "99.0.0"], capture_output=True, text=True)
    check("a release is refused before building when preflight fails",
          result.returncode != 0 and "Building" not in result.stdout)


GIT_ENV = {
    "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
    "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
}


def bump_repo(directory: Path) -> None:
    """A throwaway repo carrying both versioning scripts, so the bump can run.

    No remote, so `gh pr view` cannot answer and the default path is exercised —
    which is the one that matters, since the default is what fires when nobody
    labelled the PR.
    """
    (directory / "scripts").mkdir(parents=True)
    for script in (BUMP, NOTES):
        target = directory / "scripts" / script.name
        target.write_bytes(script.read_bytes())
        target.chmod(0o755)
    (directory / "docs").mkdir()
    subprocess.run(["git", "init", "-q"], cwd=directory, check=True,
                   capture_output=True, env={**os.environ, **GIT_ENV})


def commit(directory: Path, subject: str) -> None:
    (directory / "work").write_text(subject)
    env = {**os.environ, **GIT_ENV}
    subprocess.run(["git", "add", "."], cwd=directory, check=True,
                   capture_output=True, env=env)
    subprocess.run(["git", "commit", "-qm", subject], cwd=directory, check=True,
                   capture_output=True, env=env)


def run_bump(directory: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(directory / "scripts" / "version-bump.sh"), *args],
        cwd=directory, capture_output=True, text=True,
        env={**os.environ, **GIT_ENV})


def test_version_bump() -> None:
    """The version advances from what merged, and never twice for one commit."""
    print("\nVersion bump")
    check("version-bump.sh is executable", os.access(BUMP, os.X_OK))
    syntax = subprocess.run(["bash", "-n", str(BUMP)], capture_output=True, text=True)
    check("version-bump.sh parses", syntax.returncode == 0, syntax.stderr.strip())

    result = subprocess.run([str(BUMP), "--nonsense"], capture_output=True, text=True)
    check("an unknown flag is rejected", result.returncode == 2)

    text = BUMP.read_text()
    check("a breaking change before 1.0.0 bumps minor",
          "major on a 0.x version bumps MINOR" in text)

    with tempfile.TemporaryDirectory() as raw:
        first = Path(raw) / "first"
        bump_repo(first)
        commit(first, "Do the first thing")
        result = run_bump(first, "--dry-run")
        check("the first release starts from 0.0.0",
              "0.0.0 -> 0.0.1 (patch)" in result.stdout, result.stdout.strip())
        # A silent default is how a feature ships as a patch and nobody notices.
        check("the default level says which rule fired",
              "no-labels" in result.stdout or "no-pr-reference" in result.stdout)
        check("a dry run creates no tag",
              subprocess.run(["git", "tag"], cwd=first, capture_output=True,
                             text=True).stdout.strip() == "")

        again = Path(raw) / "again"
        bump_repo(again)
        commit(again, "Do a thing")
        result = run_bump(again)
        check("a real run tags", result.returncode == 0 and "Tagged 0.0.1" in result.stdout,
              result.stdout.strip() + result.stderr.strip())
        check("the notes list the release",
              "## 0.0.1" in (again / "docs" / "RELEASES.md").read_text())
        check("a patch lands under Fixes",
              "### Fixes" in (again / "docs" / "RELEASES.md").read_text())

        # Re-running on the same commit — a retried workflow job — must not cut
        # a second version for no change.
        result = run_bump(again)
        check("a second run on the same commit is a no-op",
              "nothing to bump" in result.stdout, result.stdout.strip())
        tags = subprocess.run(["git", "tag"], cwd=again, capture_output=True,
                              text=True).stdout.split()
        check("...and leaves exactly one tag, unprefixed", tags == ["0.0.1"], str(tags))

        # Nothing landed since the tag: also nothing to bump, but for a
        # different reason, and it should say so rather than cut an empty patch.
        empty = Path(raw) / "empty"
        bump_repo(empty)
        commit(empty, "Do a thing")
        run_bump(empty)
        result = run_bump(empty, "--dry-run")
        check("a run with nothing new is a no-op", "nothing to bump" in result.stdout)


def test_no_v_prefix() -> None:
    """The tag is the version. Nothing may prepend a v, or strip one.

    A `v` on the tag is a prefix that then has to be removed everywhere the
    version is actually used — the plist, the .dmg filename, the cask. Each of
    those is a place the strip can be forgotten, and forgetting it produces a
    cask version of "v0.2.0" that brew compares wrongly. Checked across the
    scripts rather than in one, because the convention drifts back one script at
    a time.
    """
    print("\nNo v prefix")
    for script in (BUMP, NOTES, RELEASE, VERSION, BUILD_APP):
        code = "\n".join(
            line for line in script.read_text().splitlines()
            if not line.lstrip().startswith("#"))
        check(f"{script.name} does not prepend a v",
              'v$VERSION' not in code and 'v$NEXT' not in code
              and '"v$' not in code and "v{version}" not in code)
        check(f"{script.name} does not strip a v",
              "#v}" not in code and 'removeprefix("v")' not in code)
        check(f"{script.name} does not match tags on a v",
              "'v[0-9]" not in code and '"v[0-9]' not in code)


def test_release_notes() -> None:
    """The notes are generated from the tags, and --check is offline."""
    print("\nRelease notes")
    check("release-notes.py is executable", os.access(NOTES, os.X_OK))
    text = NOTES.read_text()
    # The verify block runs offline; a --check that reaches GitHub would fail on
    # a plane and pass in CI, which is worse than not having it.
    check("the notes are read from git, not GitHub",
          "gh " not in text and "Change:" in text)

    result = subprocess.run(["python3", str(NOTES), "--check"],
                            cwd=ROOT, capture_output=True, text=True)
    check("the committed notes are up to date", result.returncode == 0,
          result.stderr.strip())

    with tempfile.TemporaryDirectory() as raw:
        stale = Path(raw) / "stale"
        bump_repo(stale)
        commit(stale, "Do a thing")
        run_bump(stale)
        notes = stale / "docs" / "RELEASES.md"
        notes.write_text(notes.read_text() + "\nhand-edited\n")
        result = subprocess.run(["python3", str(stale / "scripts" / "release-notes.py"),
                                 "--check"], capture_output=True, text=True)
        check("a hand-edited file is caught", result.returncode != 0)
        check("...and says how to fix it", "release-notes.py" in result.stderr)


def test_release_workflow() -> None:
    """The workflow delegates rather than reimplementing the bump."""
    print("\nRelease workflow")
    workflow = ROOT / ".github" / "workflows" / "release.yml"
    check("the workflow exists", workflow.exists())
    if not workflow.exists():
        return
    text = workflow.read_text()
    check("it runs the script rather than its own logic",
          "version-bump.sh" in text and "git tag -a" not in text)
    check("it fetches the tags the bump reads", "fetch-depth: 0" in text)
    check("two bumps cannot race", "concurrency:" in text)
    check("it can read the semver label", "pull-requests: read" in text)
    # Nothing is signed on a runner that holds no identity.
    steps = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith("#"))
    check("it does not build or publish",
          "release.sh" not in steps and "notarytool" not in steps)


def test_stale_prefix_is_named() -> None:
    """A config from before the bvx -> vbx rename must say so, not read as unset.

    Every BVX_ key is simply unrecognised, so the scripts reported "no
    distribution channel is configured" — which reads as "you have not set this
    up yet" while a complete, correct config sat in the file. The real one in
    this checkout had been dead that way since the rename in #13.
    """
    print("\nStale config prefix")
    with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as handle:
        handle.write("BVX_DEVELOPER_ID_APP=\"Developer ID Application: Nobody (X)\"\n")
        handle.write("BVX_NOTARY_PROFILE=old-profile\n")
        stale = handle.name
    try:
        result = subprocess.run(
            [str(PACKAGE), "--check"], capture_output=True, text=True,
            env={**os.environ, "VBX_SIGNING_CONFIG": stale})
        check("a BVX_ config is rejected", result.returncode != 0)
        check("...by name, not as 'unconfigured'",
              "BVX_" in result.stderr and "VBX_" in result.stderr,
              result.stderr.strip()[:200])
        check("...with the one-line fix", "sed" in result.stderr)
    finally:
        os.unlink(stale)

    # And the reverse: a VBX_ config must not trip the check.
    with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as handle:
        handle.write(f'VBX_DEVELOPER_ID_APP="{FAKE["VBX_DEVELOPER_ID_APP"]}"\n')
        handle.write("VBX_NOTARY_PROFILE=test-notary-profile\n")
        current = handle.name
    try:
        result = subprocess.run(
            [str(PACKAGE), "--check"], capture_output=True, text=True,
            env={**os.environ, "VBX_SIGNING_CONFIG": current})
        check("a VBX_ config is not flagged", "pre-rename" not in result.stderr)
    finally:
        os.unlink(current)


def test_cask_lint() -> None:
    """brew style is the mechanical check that can run without a release."""
    print("\nCask lint")
    release = RELEASE.read_text()
    check("release.sh has a --lint-cask mode", "--lint-cask) LINT_CASK=1" in release)
    check("the template is rendered before linting, not linted raw",
          "render_cask" in release)
    check("the rendered release cask is linted too",
          release.count("brew style") >= 2)
    # brew audit takes a cask *name*, which only resolves for an installed tap.
    check("audit is named rather than run", "brew audit --cask --new" in release)

    if not shutil.which("brew"):
        print("  skip  brew is not on the PATH")
        return
    result = subprocess.run([str(RELEASE), "--lint-cask"],
                            capture_output=True, text=True, cwd=ROOT)
    check("the cask passes brew style",
          result.returncode == 0 and "no offenses detected" in result.stdout,
          (result.stdout + result.stderr).strip()[-300:])


def test_built_bundle_carries_the_tag() -> None:
    """The plist a built app actually carries must match scripts/version.sh.

    This is the hop the Swift tests cannot reach: they run in a process whose
    `Bundle.main` is SwiftPM's helper binary, with no version keys at all. So
    the formatting is asserted over there and the stamping is asserted here,
    against a real bundle.

    Skipped rather than passed when no bundle has been built — a check that
    silently passes on a missing artefact is worse than one that says it did
    not run, which is the same reason parity-check.py reports skips.
    """
    print("\nBuilt bundle version")
    plist = ROOT / ".build" / "vbx.app" / "Contents" / "Info.plist"
    if not plist.exists():
        print("  skip  no .build/vbx.app — run ./scripts/build-app.sh")
        return

    def key(name: str) -> str:
        return subprocess.run(
            ["/usr/libexec/PlistBuddy", "-c", f"Print :{name}", str(plist)],
            capture_output=True, text=True).stdout.strip()

    expected = subprocess.run([str(VERSION)], capture_output=True, text=True,
                              cwd=ROOT).stdout.strip()
    expected_build = subprocess.run([str(VERSION), "--build"], capture_output=True,
                                    text=True, cwd=ROOT).stdout.strip()

    check("the bundle's marketing version is the tag",
          key("CFBundleShortVersionString") == expected,
          f"plist {key('CFBundleShortVersionString')!r} != version.sh {expected!r}")
    check("the bundle's build number is the commit count",
          key("CFBundleVersion") == expected_build,
          f"plist {key('CFBundleVersion')!r} != version.sh {expected_build!r}")
    # The literal that used to be here shipped as 0.1.0 in every build ever made.
    check("it is not the old hardcoded version",
          key("CFBundleShortVersionString") != "0.1.0"
          or expected == "0.1.0")


def main() -> int:
    print("Packaging and signing tests")
    check("package-app.sh is executable", os.access(PACKAGE, os.X_OK))
    syntax = subprocess.run(["bash", "-n", str(PACKAGE)], capture_output=True, text=True)
    check("package-app.sh parses", syntax.returncode == 0, syntax.stderr.strip())

    test_dry_runs_do_not_leak()
    test_redaction_covers_unrelated_identities()
    test_missing_config_is_a_clear_error()
    test_config_file_is_read_and_env_wins()
    test_app_store_entitlements_are_generated_not_committed()
    test_signing_env_is_ignored()
    test_no_tracked_file_carries_credentials()
    test_the_leak_scan_still_detects()
    test_example_holds_only_placeholders()
    test_short_values_are_not_masked()
    test_ad_hoc_cannot_be_notarized()
    test_real_app_store_run()
    test_check_reports_per_channel()
    test_notary_probe_uses_flags_this_notarytool_has()
    test_a_certificate_of_the_wrong_kind_is_refused()
    test_help_and_bad_flags()
    test_build_app_forwards()
    test_universal_is_implied_and_verified()
    test_version_comes_from_the_tag()
    test_cask_and_release_script()
    test_version_bump()
    test_no_v_prefix()
    test_release_notes()
    test_release_workflow()
    test_stale_prefix_is_named()
    test_cask_lint()
    test_built_bundle_carries_the_tag()

    print()
    if failures:
        print(f"{len(failures)} failed, {passed} passed")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"{passed} passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
