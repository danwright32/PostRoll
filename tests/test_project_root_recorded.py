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
phase in `project.yml` that writes the key, and the key `AppPaths` reads in
Swift. Neither file looks wrong on its own if they drift, so the agreement is
what is checked here rather than either half alone.

The last two checks are the ones that matter most, and they are the two the
first attempt at this fix failed. `project.yml` is a manifest;
`PostRoll.xcodeproj` is GENERATED from it and committed, and it is the generated
file that Xcode actually builds; and neither of those is the built app. The
first version of this recorded the path with an `INFOPLIST_KEY_` build setting,
which reached both files and produced a built app with no such key, because
Xcode maps that prefix onto a known set of Info.plist keys only. Everything read
as fixed (L3, built is not wired).
"""

from __future__ import annotations

import plistlib
import re
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
APP = REPO_ROOT / "PostRollApp"
MANIFEST = APP / "project.yml"
PBXPROJ = APP / "PostRoll.xcodeproj" / "project.pbxproj"
APP_PATHS = APP / "Sources" / "Services" / "AppPaths.swift"

# The Info.plist key the build writes and the app reads back.
#
# Written by a post-build script rather than by an `INFOPLIST_KEY_` build
# setting. That was tried first and does not work: Xcode maps that prefix onto a
# known set of Info.plist keys only, so `INFOPLIST_KEY_POSTROLLProjectRoot` sat
# in project.yml, generated into the .xcodeproj, and produced a built app with
# no such key. Nothing about the setting looked wrong, and the only way to find
# out was to read the built bundle (L3). These checks therefore assert the
# SCRIPT is present, and `test_the_built_app_records_its_checkout` below reads a
# real build.
WRITER_ANCHOR = "PlistBuddy"


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
    """The Info.plist key the app target's post-build script writes."""
    block = _app_target_block(_strip_comments(MANIFEST.read_text(encoding="utf-8")))
    assert WRITER_ANCHOR in block, (
        "the PostRoll app target has no script recording the checkout path, so "
        "the installed app has no way to find this repo and every generation "
        "fails with nothing naming the cause."
    )
    written = set(re.findall(r"Add :(\w+) string", block))
    assert len(written) == 1, (
        f"expected exactly one recorded Info.plist key, found {sorted(written)}"
    )
    return written.pop()


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
    assert key in pbxproj, (
        f"the script recording {key} is in project.yml but not in the generated "
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


def test_the_built_app_records_its_checkout():
    """Read a real build, not the settings that are supposed to produce one.

    This is the check the first attempt at #648 would have failed while every
    other check here passed: the manifest and the generated project both carried
    an `INFOPLIST_KEY_POSTROLLProjectRoot` that Xcode silently did not emit.

    A missing build is a SKIP with its reason named, never a pass: finding
    nothing to inspect and reporting success is indistinguishable from having
    inspected something (L98). The build itself is where this is really
    enforced, since the post-build script reads its own write back and fails the
    build when it did not land.

    Scoped to the BUILD PRODUCT, deliberately not to /Applications/PostRoll.app.
    The installed copy is a deployment state rather than a property of this
    code: an install made before this change has no recorded checkout, and
    failing the suite over that would be a gate going red for a reason unrelated
    to the code, which is how a gate ends up routinely bypassed. What covers the
    installed copy instead is build-install.sh, which copies this exact product,
    plus a check by hand at install time.
    """
    key = _recorded_key_from_swift()
    app = Path.home() / "Library/Developer/PostRoll/Build/Products/Release/PostRoll.app"
    plist = app / "Contents" / "Info.plist"
    if not plist.exists():
        pytest.skip(
            f"no build product at {app}, so nothing was checked. Run `make "
            "build` to exercise this."
        )

    data = plistlib.loads(plist.read_bytes())
    recorded = data.get(key)
    assert recorded, (
        f"{app} carries no {key}, so that build cannot find the Python checkout "
        "and every generation in it fails. The build settings can look entirely "
        "correct while this is true, which is exactly what happened once."
    )
    assert Path(recorded).is_absolute(), (
        f"{app} recorded {recorded!r}, which is not an absolute path"
    )
