"""The build records where the Python checkout is, and the app reads it (#648).

The app has to find this repo on disk to run anything: the Python is not bundled
into the app, so `postroll/` has to be somewhere real. It used to look in a
hardcoded `~/Documents/PostRoll`, and when the project moved out of iCloud Drive
on 2026-08-16 that folder stopped existing. Every generation, the collage
watermark and the brand-voice seed then resolved under a folder that is not
there.

Pointing the same hardcode at the new place would only reschedule the defect, so
the build now STAMPS the checkout it was built from into the app bundle, and the
app reads it back at runtime. Moving the project and rebuilding therefore fixes
itself.

That makes two halves that must agree and live in different files: the build
setting in `project.yml` and the key `AppPaths` reads in Swift. Neither file
looks wrong on its own if they drift, so the agreement is what is checked here
rather than either half alone.

The third check is the one that matters most. `project.yml` is a manifest;
`PostRoll.xcodeproj` is GENERATED from it and committed, and it is the generated
file that Xcode actually builds. A setting added to the manifest and never
regenerated is a setting the shipping app does not have, and nothing about the
manifest would look wrong (L3, built is not wired).
"""

from __future__ import annotations

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
APP = REPO_ROOT / "PostRollApp"
MANIFEST = APP / "project.yml"
PBXPROJ = APP / "PostRoll.xcodeproj" / "project.pbxproj"
APP_PATHS = APP / "Sources" / "Services" / "AppPaths.swift"

# What the build stamps: the app folder's parent, which is the checkout root.
# Xcode expands this when it generates the app's Info.plist.
RECORDED_VALUE = "$(SRCROOT)/.."


def _strip_comments(text: str) -> str:
    """The manifest with its `#` comment lines removed.

    A guard satisfied by a comment ABOUT a setting is indistinguishable from one
    that works, and can even be satisfied by prose explaining the setting was
    removed (L103).
    """
    kept = [line for line in text.split("\n") if not line.strip().startswith("#")]
    return "\n".join(kept)


def _app_target_block(manifest: str) -> str:
    """The lines belonging to the PostRoll app target.

    Scoped to the one target rather than searched over the whole file: the test
    target sits in the same manifest, and a whole-file match would be answered
    by a setting on the wrong target (L135).
    """
    marker = "  PostRoll:\n"
    assert marker in manifest, (
        "the PostRoll target is not in project.yml under the name this test "
        "looks for, so this guard is checking nothing"
    )
    rest = manifest.split(marker, 1)[1]
    lines: list[str] = []
    for line in rest.split("\n"):
        if line.strip() and not line.startswith("    "):
            break
        lines.append(line)
    return "\n".join(lines)


def _recorded_key_from_manifest() -> str:
    """The Info.plist key the app target stamps the checkout into."""
    block = _app_target_block(_strip_comments(MANIFEST.read_text(encoding="utf-8")))
    found = re.findall(r"^\s*INFOPLIST_KEY_(\w+):\s*(.+?)\s*$", block, re.MULTILINE)
    recorded = [key for key, value in found if value.strip('"') == RECORDED_VALUE]
    assert recorded, (
        "the PostRoll app target records no checkout path. It needs an "
        f'INFOPLIST_KEY_<name>: "{RECORDED_VALUE}" setting, or the installed app '
        "has no way to find this repo and every generation fails."
    )
    assert len(recorded) == 1, f"more than one setting records the checkout: {recorded}"
    return recorded[0]


def _recorded_key_from_swift() -> str:
    """The Info.plist key `AppPaths` reads the checkout back out of."""
    source = APP_PATHS.read_text(encoding="utf-8")
    match = re.search(
        r'projectRootInfoKey\s*=\s*"([^"]+)"', source
    )
    assert match, (
        "AppPaths declares no projectRootInfoKey, so nothing reads the recorded "
        "checkout path back at runtime"
    )
    return match.group(1)


def test_the_app_target_records_the_checkout_it_was_built_from():
    assert _recorded_key_from_manifest()


def test_the_swift_side_reads_the_key_the_build_writes():
    """Two halves in two files, checked against each other rather than each
    against some third idea of what the key is called."""
    assert _recorded_key_from_swift() == _recorded_key_from_manifest()


def test_the_generated_project_carries_the_recording():
    """The manifest is not what Xcode builds.

    `PostRoll.xcodeproj` is generated from `project.yml` and committed, so a
    setting added to the manifest without running `xcodegen generate` is absent
    from every build. The symptom would be the original defect, unchanged, with
    a manifest that reads as fixed.
    """
    key = _recorded_key_from_manifest()
    pbxproj = PBXPROJ.read_text(encoding="utf-8")
    assert f"INFOPLIST_KEY_{key}" in pbxproj, (
        f"INFOPLIST_KEY_{key} is in project.yml but not in the generated "
        "PostRoll.xcodeproj. Run `cd PostRollApp && xcodegen generate` and "
        "commit the result, or the shipping app never records its checkout."
    )


def test_no_home_relative_checkout_guess_survives_in_apppaths():
    """The defect was a home-relative constant standing in for the checkout.

    `legacyDataRoot` is a DIFFERENT thing that must keep its hardcoded
    `~/Documents/PostRoll`: it is the pre-migration DATA location, and its whole
    job is to let `DataMigration` find data written before the move. So this
    checks the project-root resolver specifically rather than sweeping the file.
    """
    source = APP_PATHS.read_text(encoding="utf-8")
    start = source.index("static func resolveProjectRoot")
    end = source.index("\n    }", start)
    body = source[start:end]
    assert "Documents/PostRoll" not in body, (
        "resolveProjectRoot is guessing a home-relative path again. That is the "
        "defect in #648: the folder it names can move, and when it did, nothing "
        "said so."
    )
