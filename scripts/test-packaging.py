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
import pathlib
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
SIGNING_SETUP = ROOT / "scripts" / "signing-setup.sh"
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

    # Three things `brew audit` rejected, all found by running it for real
    # against a published release rather than reasoning about the template.
    #
    # A URL with the number written into it reads to the audit as *unversioned*
    # — it looks for the interpolation, not for digits — and it then demands
    # `sha256 :no_check`, which would switch the checksum off entirely.
    check("the url interpolates the version",
          "#{version}" in template, "the URL hard-codes the version")
    check("...so no placeholder URL is substituted", "@URL@" not in template)
    # `verified:` vouches for a URL whose host is not obviously the project's.
    # A github.com release URL under the project's own repository is not that,
    # and the parameter is deprecated.
    check("the deprecated verified parameter is gone", "verified:" not in template)
    # `>= :sonoma` and `:sonoma` mean the same thing; only one passes style.
    check("the macOS requirement uses the bare symbol",
          'macos: :sonoma' in template and '">= :sonoma"' not in template)


def test_release_instructions_are_runnable() -> None:
    """The tap instructions `release.sh` prints have to work when pasted.

    They did not: they told you to run `brew audit --cask --new Casks/vbx.rb`,
    and `brew audit` refuses a path outright — "Calling `brew audit [path ...]`
    is disabled". Someone followed them and hit exactly that.
    """
    print("\nRelease instructions")
    text = RELEASE.read_text()
    lines = [ln for ln in text.splitlines() if not ln.lstrip().startswith("#")]
    body = "\n".join(lines)

    check("brew audit is never given a path",
          "brew audit --cask Casks/" not in body
          and "brew audit --cask --new Casks/" not in body)
    check("brew audit is given a tap-qualified name",
          "brew audit --cask michel-onstein/tap/vbx" in body)
    # `--new` is the strict submission audit for homebrew/homebrew-cask. It
    # fails a personal tap on "repository not notable enough", which is not
    # something a new project can act on.
    check("the strict submission audit is not suggested for a personal tap",
          "--cask --new" not in body)
    # Tapping a directory clones it, so an uncommitted cask is invisible —
    # which is what happened.
    check("the instructions say the cask must be committed first",
          "committed" in body.lower())

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
    # brew audit takes a cask *name*, which only resolves for an installed tap,
    # so it is named rather than run. Without `--new`: that is the submission
    # audit for homebrew/homebrew-cask and it fails a personal tap on rules a
    # new project cannot act on.
    check("audit is named rather than run", "brew audit --cask michel" in release)

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


def test_notarization_accepts_an_api_key() -> None:
    """One credential should cover the certificate and the notarization.

    `notarytool store-credentials` writes a keychain profile from an Apple ID
    and an app-specific password. That works on one machine and nowhere else —
    a keychain profile cannot go to CI, and the app-specific password is a
    second thing to create and rotate. An App Store Connect API key is the same
    credential that creates the Developer ID certificate, and it travels.
    """
    print("\nNotarization credentials")
    text = PACKAGE.read_text()
    for name in ("VBX_NOTARY_KEY", "VBX_NOTARY_KEY_ID", "VBX_NOTARY_ISSUER"):
        check(f"{name} is read", name in text)

    # The identifiers are account data and end up beside build logs in issues.
    for name in ("NOTARY_KEY", "NOTARY_KEY_ID", "NOTARY_ISSUER"):
        check(f"{name} is masked in output", f'_mask "${name}"' in text)

    # Resolved in one place, so --check and the real submission cannot disagree
    # about which credential is in play.
    check("the credential is resolved once", "notary_auth()" in text)

    env = {**os.environ}
    for key in ("VBX_NOTARY_PROFILE", "VBX_NOTARY_KEY", "VBX_NOTARY_KEY_ID",
                "VBX_NOTARY_ISSUER", "VBX_DEVELOPER_ID_APP"):
        env.pop(key, None)
    env["VBX_SIGNING_CONFIG"] = "/nowhere/none.env"

    result = subprocess.run([str(PACKAGE), "--check"], capture_output=True, text=True, env=env)
    check("no credentials is reported as such",
          "no credentials" in result.stdout, result.stdout.strip()[-200:])

    # A .p8 that is not there fails inside notarytool minutes into a release,
    # after the build and the signing — so it is named before anything is built.
    missing = {**env, "VBX_NOTARY_KEY": "/nowhere/key.p8",
               "VBX_NOTARY_KEY_ID": "ABC123", "VBX_NOTARY_ISSUER": "iss"}
    result = subprocess.run([str(PACKAGE), "--check"], capture_output=True, text=True, env=missing)
    check("a missing key file is named before building",
          "API key file not found" in result.stdout, result.stdout.strip()[-200:])

    with tempfile.NamedTemporaryFile(suffix=".p8", delete=False) as handle:
        handle.write(b"not a key")
        fake_key = handle.name
    try:
        both = {**env, "VBX_NOTARY_KEY": fake_key, "VBX_NOTARY_KEY_ID": "ABC123",
                "VBX_NOTARY_ISSUER": "iss", "VBX_NOTARY_PROFILE": "some-profile"}
        result = subprocess.run(
            [str(PACKAGE), "--check"], capture_output=True, text=True, env=both)
        # The key wins when both are set: it is the form that behaves the same
        # everywhere, so a machine that has both should use the portable one.
        check("the API key is preferred over a keychain profile",
              "App Store Connect API key" in result.stdout,
              result.stdout.strip()[-200:])
    finally:
        os.unlink(fake_key)


def test_signing_setup_script() -> None:
    """Getting the certificate should be one command, not a wiki page."""
    print("\nSigning setup")
    check("signing-setup.sh exists", SIGNING_SETUP.exists())
    if not SIGNING_SETUP.exists():
        return
    check("it is executable", os.access(SIGNING_SETUP, os.X_OK))
    syntax = subprocess.run(["bash", "-n", str(SIGNING_SETUP)], capture_output=True, text=True)
    check("it parses", syntax.returncode == 0, syntax.stderr.strip())

    result = subprocess.run([str(SIGNING_SETUP), "--nonsense"], capture_output=True, text=True)
    check("an unknown flag is rejected", result.returncode == 2)

    result = subprocess.run([str(SIGNING_SETUP), "--check"], capture_output=True, text=True)
    check("--check succeeds", result.returncode == 0, result.stderr.strip())
    check("--check says whether the certificate exists",
          "Developer ID Application certificate" in result.stdout)
    # Apple restricts Developer ID creation to the Account Holder, and the
    # failure when an Admin key tries does not say so.
    check("--check names the Account Holder requirement",
          "Account Holder" in result.stdout or "certificate exists" in result.stdout)

    # A dry run must work with no credentials at all: reading the plan before
    # obtaining a key is when it is most useful. Run against a scratch HOME so
    # the answer does not depend on whether *this* machine already has the
    # certificate — an earlier version of this asserted the plan unconditionally
    # and started failing the moment one was installed.
    scratch = pathlib.Path(tempfile.mkdtemp())
    try:
        env = {**os.environ, "VBX_SIGNING_DIR": str(scratch / "sign")}
        result = subprocess.run([str(SIGNING_SETUP), "--dry-run"],
                                capture_output=True, text=True, env=env)
        check("--dry-run works without credentials",
              result.returncode == 0, (result.stdout + result.stderr).strip()[-200:])
        # Either it prints the plan, or it says there is nothing to do because
        # the certificate is already here. Both are "changed nothing".
        check("--dry-run changes nothing",
              "Would run:" in result.stdout or "already in the keychain" in result.stdout,
              result.stdout.strip()[:200])
        check("--dry-run really wrote nothing", not (scratch / "sign").exists())
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    text = SIGNING_SETUP.read_text()
    # This repository is public; ADR-009 is that no signing material is in it.
    check("the key is written outside the repository", "$HOME/.vbx-signing" in text)
    check("nothing is written into the checkout",
          "$ROOT/signing" not in text and "$ROOT/scripts/developer-id" not in text)
    check("the certificate type is the Developer ID one",
          "DEVELOPER_ID_APPLICATION" in text)


def test_signing_setup_portal_route() -> None:
    """The API route cannot work for most accounts, so the portal route must.

    Apple restricts Developer ID creation to the Account Holder, and a *Team*
    API key cannot hold that role — no configuration fixes it. Measured, not
    assumed: `asc certificates create` returned "This operation can only be
    performed by the Account Holder."
    """
    print("\nSigning setup: portal route")
    if not SIGNING_SETUP.exists():
        print("  skip  signing-setup.sh is absent")
        return

    scratch = pathlib.Path(tempfile.mkdtemp())
    try:
        env = {**os.environ, "VBX_SIGNING_DIR": str(scratch / "fresh")}
        result = subprocess.run([str(SIGNING_SETUP), "--csr"],
                                capture_output=True, text=True, env=env)
        check("--csr succeeds with no credentials", result.returncode == 0,
              (result.stdout + result.stderr).strip()[-200:])

        key = scratch / "fresh" / "developer-id.key"
        csr = scratch / "fresh" / "developer-id.csr"
        check("it writes a key and a request", key.exists() and csr.exists())
        # Without this the certificate that comes back cannot sign, and the
        # failure appears much later.
        check("the key is private to the user",
              oct(key.stat().st_mode)[-3:] == "600", oct(key.stat().st_mode))

        valid = subprocess.run(["openssl", "req", "-in", str(csr), "-noout", "-subject"],
                               capture_output=True, text=True)
        check("the request is a real CSR", valid.returncode == 0, valid.stderr.strip())

        # Re-running must not mint a second key: a new key would not match a
        # certificate issued for the first request, and the mismatch only shows
        # up at import.
        before = key.read_bytes()
        subprocess.run([str(SIGNING_SETUP), "--csr"],
                       capture_output=True, text=True, env=env)
        check("re-running reuses the same key", key.read_bytes() == before)

        # A certificate with no matching key is not an identity. AppKit will
        # import it happily and codesign cannot use it.
        empty = {**os.environ, "VBX_SIGNING_DIR": str(scratch / "empty")}
        result = subprocess.run([str(SIGNING_SETUP), "--import", str(csr)],
                                capture_output=True, text=True, env=empty)
        check("--import refuses without the private key", result.returncode == 1)
        check("...and says why", "private key" in result.stderr, result.stderr.strip()[:160])

        result = subprocess.run([str(SIGNING_SETUP), "--import", "/nowhere/missing.cer"],
                                capture_output=True, text=True, env=env)
        check("--import refuses a certificate that is not there", result.returncode == 1)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)

    # The request has to be *reachable*. It is uploaded through a web form, and
    # macOS open dialogs do not show dot-directories — so a CSR that only exists
    # in ~/.vbx-signing is effectively unreachable without knowing about ⌘⇧G.
    home = pathlib.Path(tempfile.mkdtemp())
    try:
        (home / "Desktop").mkdir()
        env = {**os.environ, "HOME": str(home),
               "VBX_SIGNING_DIR": str(home / ".vbx-signing")}
        result = subprocess.run([str(SIGNING_SETUP), "--csr"],
                                capture_output=True, text=True, env=env)
        visible = home / "Desktop" / "vbx-developer-id.csr"
        canonical = home / ".vbx-signing" / "developer-id.csr"
        check("--csr puts the request where a picker can see it", visible.exists())
        check("...and points at it", str(visible) in result.stdout,
              result.stdout.strip()[:200])
        # A copy, not a move: the canonical pair stays together so --import has
        # one place to look, and deleting the visible copy breaks nothing.
        check("the canonical request is still there", canonical.exists())
        check("the copy is identical",
              visible.exists() and canonical.exists()
              and visible.read_bytes() == canonical.read_bytes())
        # The private key must not follow it out.
        check("the key is not copied anywhere visible",
              not (home / "Desktop" / "developer-id.key").exists()
              and (home / ".vbx-signing" / "developer-id.key").exists())
    finally:
        shutil.rmtree(home, ignore_errors=True)

    # No Desktop — a CI runner, a container. It must still work, and say how to
    # reach the file rather than inventing a location.
    bare = pathlib.Path(tempfile.mkdtemp())
    try:
        env = {**os.environ, "HOME": str(bare),
               "VBX_SIGNING_DIR": str(bare / ".vbx-signing")}
        result = subprocess.run([str(SIGNING_SETUP), "--csr"],
                                capture_output=True, text=True, env=env)
        check("--csr works with no Desktop", result.returncode == 0,
              (result.stdout + result.stderr).strip()[-200:])
        check("...and explains how to reach a hidden path",
              "Cmd-Shift-G" in result.stdout, result.stdout.strip()[:200])
        check("...without creating a Desktop", not (bare / "Desktop").exists())
    finally:
        shutil.rmtree(bare, ignore_errors=True)

    # The guidance has to name the route that works — and which route that is
    # depends on whether the certificate exists yet. Asserting only the
    # not-yet-created branch made this test fail the moment the certificate
    # appeared, which is a test that expires rather than one that holds.
    guidance = subprocess.run([str(SIGNING_SETUP), "--check"],
                              capture_output=True, text=True).stdout
    if "MISSING" in guidance:
        check("--check points at the portal route",
              "--csr" in guidance and "--import" in guidance, guidance.strip()[-200:])
        check("--check names the Account Holder refusal", "Account Holder" in guidance)
    else:
        check("--check says how to configure the certificate it found",
              "VBX_DEVELOPER_ID_APP" in guidance, guidance.strip()[-200:])
        check("--check does not still ask for a request",
              "--csr" not in guidance, guidance.strip()[-200:])

    # Both branches exist and are reachable, whichever this machine is in.
    check("the guidance covers the missing case",
          "--csr" in SIGNING_SETUP.read_text())
    check("the guidance covers the present case",
          "VBX_DEVELOPER_ID_APP" in SIGNING_SETUP.read_text())


def test_check_does_not_fail_closed_on_its_own_bugs() -> None:
    """Two false negatives, both of which sent someone to fix nothing.

    A check that reports a working setup as broken is worse than no check: it
    costs the time of investigating something that was never wrong. Both of
    these did exactly that, and both were found by disbelieving the check and
    running the underlying command by hand.
    """
    print("\nCheck accuracy")
    text = PACKAGE.read_text()

    # 1. `notarytool history` has no --limit. Passing one made the command fail
    #    for a reason unrelated to the credential, and a perfectly good API key
    #    was reported "configured but not usable".
    # Comments stripped first: the line explaining why --limit is absent
    # naturally mentions both, and a naive search reads the explanation as the
    # thing it warns against. Third time this trap has been hit in this file.
    history_lines = [
        line for line in text.splitlines()
        if "notarytool history" in line and not line.lstrip().startswith("#")
    ]
    check("notarytool history is called", bool(history_lines))
    check("...without a flag it does not have",
          all("--limit" not in line for line in history_lines), str(history_lines))

    # 2. `check-ignore` was run from $ROOT against a path that can be outside
    #    it. On a path in another checkout it answers "not ignored", turning
    #    "your config lives in the primary worktree" into "your secrets are
    #    about to be committed".
    check("check-ignore is asked of the tree that owns the file",
          'check-ignore -q "$CONFIG_FILE"' in text
          and 'git -C "$(dirname "$CONFIG_FILE")"' in text)


def test_config_is_found_from_a_worktree() -> None:
    """The config is gitignored, so it exists in exactly one checkout.

    This repository is worked in through linked worktrees, where
    `scripts/signing.env` does not exist. `--check` reported every setting as
    unset there, which reads as "you have not configured signing" rather than
    "the configuration is in the other tree".
    """
    print("\nConfig discovery")
    text = PACKAGE.read_text()
    check("the primary worktree is consulted", "--git-common-dir" in text)
    check("the fallback is visible in the output",
          "the primary checkout, not this worktree" in text)

    # An explicit override still wins over both.
    env = {**os.environ, "VBX_SIGNING_CONFIG": "/nowhere/none.env"}
    for key in ("VBX_DEVELOPER_ID_APP", "VBX_NOTARY_KEY", "VBX_NOTARY_KEY_ID",
                "VBX_NOTARY_ISSUER", "VBX_NOTARY_PROFILE", "VBX_TEAM_ID"):
        env.pop(key, None)
    result = subprocess.run([str(PACKAGE), "--check"], capture_output=True, text=True, env=env)
    check("VBX_SIGNING_CONFIG still overrides the search",
          "absent" in result.stdout, result.stdout.strip()[:200])


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
    test_notarization_accepts_an_api_key()
    test_signing_setup_script()
    test_release_instructions_are_runnable()
    test_signing_setup_portal_route()
    test_check_does_not_fail_closed_on_its_own_bugs()
    test_config_is_found_from_a_worktree()

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
