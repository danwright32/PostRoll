"""The built app declares `postroll://`, and Swift reads the same word (#840).

A link in an OmniFocus task note is useless unless macOS knows which bundle
answers it, and macOS learns that from `CFBundleURLTypes` in the BUILT app's
Info.plist. Nothing in the Swift suite can see that key: it is put there by the
build, and the whole trap recorded in #648 is that a plist setting can look
entirely correct in `project.yml`, be carried into the generated `.xcodeproj`,
and produce a built app without the key. `INFOPLIST_KEY_*` maps onto a fixed set
of keys only, and `CFBundleURLTypes` is not one of them.

So the scheme is written by the same PlistBuddy post-build phase that records
the checkout path, for the same reason and with the same read-back, and these
checks read the finished product rather than the manifest that is supposed to
produce one (L3).

Two halves in two languages: the build declares a scheme, and `DeepLink` parses
one. Neither file looks wrong on its own if they drift, and the symptom of drift
is a link that opens PostRoll and is then refused by PostRoll, so the agreement
between them is what is checked here rather than either half alone (L26).
"""

from __future__ import annotations

import plistlib
import re
from pathlib import Path

import pytest
from source_text import without_prose


REPO_ROOT = Path(__file__).resolve().parent.parent
APP = REPO_ROOT / "PostRollApp"
MANIFEST = APP / "project.yml"
PBXPROJ = APP / "PostRoll.xcodeproj" / "project.pbxproj"
DEEP_LINK = APP / "Sources" / "Services" / "DeepLink.swift"

# Where a build product lands. The same one test_project_root_recorded.py reads,
# and for the same reason: it is a property of this code, where
# /Applications/PostRoll.app is a property of when somebody last installed.
BUILT_APP = Path.home() / "Library/Developer/PostRoll/Build/Products/Release/PostRoll.app"


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
    target sits in the same manifest and would answer a whole-file match (L135).
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


def _scheme_from_manifest() -> str:
    """The scheme the app target's post-build script writes into the plist.

    Read from the script's own variable, and then the write is checked to use
    that variable. Reading the `Add` line alone would only ever see the variable
    name, and spelling the scheme twice in the script so it could be read
    literally is two spellings that can drift (L41).
    """
    block = _app_target_block(_strip_comments(MANIFEST.read_text(encoding="utf-8")))

    declared = re.findall(r'POSTROLL_SCHEME="([^"]+)"', block)
    assert declared, (
        "the PostRoll app target registers no URL scheme, so a postroll:// link "
        "in an OmniFocus task note opens nothing and macOS reports that no "
        "application knows how to handle it."
    )
    assert len(set(declared)) == 1, f"more than one scheme is declared: {declared}"

    written = re.findall(
        r'Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string ([^"\s]+)', block
    )
    assert written == ["${POSTROLL_SCHEME}"], (
        "the scheme written into CFBundleURLSchemes is not the POSTROLL_SCHEME "
        f"the script declares, so the two can disagree: {written}"
    )
    return declared[0]


def _scheme_from_swift() -> str:
    """The scheme `DeepLink` will accept a URL under."""
    source = DEEP_LINK.read_text(encoding="utf-8")
    match = re.search(r'static let scheme\s*=\s*"([^"]+)"', source)
    assert match, (
        "DeepLink declares no scheme, so nothing in Swift agrees with what the "
        "build registers"
    )
    return match.group(1)


def test_the_app_registers_a_url_scheme():
    assert _scheme_from_manifest()


def test_swift_accepts_the_scheme_the_build_registers():
    """Drift here is a link that launches PostRoll and is then refused by it,
    which reads as a broken link rather than as a mismatch."""
    assert _scheme_from_swift() == _scheme_from_manifest()


def test_the_generated_project_carries_the_registration():
    """`project.yml` is a manifest; `PostRoll.xcodeproj` is what Xcode builds.

    A scheme added to the manifest without running `xcodegen generate` is absent
    from every build, and the manifest reads as done.
    """
    # Xcode writes `/* Name */` annotations all through this file, so a
    # raw read finds the key in an annotation as readily as in a real
    # build setting (#1074).
    pbxproj = without_prose(PBXPROJ)
    assert "CFBundleURLTypes" in pbxproj, (
        "the URL scheme is in project.yml but not in the generated "
        "PostRoll.xcodeproj. Run `cd PostRollApp && xcodegen generate` and "
        "commit the result, or no build ever declares it."
    )


def test_the_registration_is_read_back_by_the_build():
    """A PlistBuddy write that did nothing is silent.

    The phase that records the checkout path reads its own write back and fails
    the build when it did not land, which is what makes that key trustworthy.
    The scheme needs the same, or the one way this can fail (the write silently
    doing nothing) produces a green build and a dead link.
    """
    block = _app_target_block(_strip_comments(MANIFEST.read_text(encoding="utf-8")))
    assert "Print :CFBundleURLTypes:0:CFBundleURLSchemes:0" in block, (
        "nothing reads the registered scheme back out of the plist it was just "
        "written to, so a write that did nothing ships as a build that passed."
    )


def test_the_built_app_declares_the_scheme():
    """Read a real build, not the settings that are supposed to produce one.

    This is the check the #648 fix failed while every other check passed. A
    missing build is a SKIP naming its reason, never a pass: finding nothing to
    inspect and reporting success is indistinguishable from having inspected
    something (L98).
    """
    plist = BUILT_APP / "Contents" / "Info.plist"
    if not plist.exists():
        pytest.skip(
            f"no build product at {BUILT_APP}, so nothing was checked. Run "
            "`make build` to exercise this."
        )

    data = plistlib.loads(plist.read_bytes())
    types = data.get("CFBundleURLTypes")
    assert types, (
        f"{BUILT_APP} declares no CFBundleURLTypes, so macOS does not know it "
        "answers any URL at all. The build settings can look entirely correct "
        "while this is true, which is exactly what happened in #648."
    )
    schemes = [s for entry in types for s in entry.get("CFBundleURLSchemes", [])]
    assert _scheme_from_swift() in schemes, (
        f"{BUILT_APP} declares {schemes}, and Swift parses "
        f"{_scheme_from_swift()!r}. A link would launch nothing, or launch this "
        "and be refused by it."
    )
