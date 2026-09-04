"""#527: the Swift test bundle must compile every Sources file, not a hand list.

`PostRollApp/project.yml` used to name every Sources file the `PostRollTests`
target compiles, one path at a time, maintained by hand. A new file was
invisible to the entire Swift suite until somebody remembered to add it, and
nothing failed when they did not: the tests still passed, just without that file
in them. Six entries were added by hand in one session, twice only after a build
error made it obvious.

That is the shape of #488 and #273 and of L96: a hand-kept registry decides what
gets checked, so anything missing from the registry is exempt from the very
check meant to catch it, and the sweep reports green while blind.

So the manifest globs the directory and lists what it leaves OUT instead. This
holds it to that: every `.swift` file under `Sources/` is either compiled into
the test bundle or named in the target's `excludes`, where leaving it out is a
decision somebody wrote down rather than one nobody made.

Read as text rather than through a YAML parser, for the same reason
`test_ci_gates.py` reads the workflow as text: one test is not worth adding a
runtime dependency for. The block is located by its target header and ended at
the next key at the same indentation, so a rule expressed elsewhere in the file
cannot satisfy it.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from workflow_commands import runs_the_gui_scheme, xcodebuild_commands
from source_text import without_prose


REPO_ROOT = Path(__file__).resolve().parent.parent
APP = REPO_ROOT / "PostRollApp"
MANIFEST = APP / "project.yml"
SOURCES = APP / "Sources"


def _strip_comments(text: str) -> str:
    """The manifest with its `#` comment lines removed.

    A guard satisfied by a comment ABOUT a path is indistinguishable from one
    that works, and can even be satisfied by prose explaining that the path was
    removed (L103).
    """
    kept = [line for line in text.split("\n") if not line.strip().startswith("#")]
    return "\n".join(kept)


def _target_block(manifest: str, target: str) -> str:
    """The lines belonging to one target in the manifest."""
    marker = f"  {target}:\n"
    assert marker in manifest, (
        f"the {target} target is not in project.yml under the name this test "
        "looks for, so this guard is checking nothing"
    )
    rest = manifest.split(marker, 1)[1]
    lines: list[str] = []
    for line in rest.split("\n"):
        # A key at the target's own indentation ends the block.
        if line.strip() and not line.startswith("    "):
            break
        lines.append(line)
    return "\n".join(lines)


def _sources_paths(block: str) -> list[str]:
    """The `- path:` entries in a target's `sources:` list."""
    body = block.split("sources:", 1)[1].split("settings:", 1)[0]
    return [
        line.split("- path:", 1)[1].strip()
        for line in body.split("\n")
        if line.strip().startswith("- path:")
    ]


def _excludes(block: str) -> list[str]:
    """The `excludes:` globs under the target's `sources:` list."""
    body = block.split("sources:", 1)[1].split("settings:", 1)[0]
    if "excludes:" not in body:
        return []
    after = body.split("excludes:", 1)[1]
    out: list[str] = []
    for line in after.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        if not stripped.startswith("- "):
            break
        out.append(stripped[2:].strip().strip('"').strip("'"))
    return out


@pytest.fixture(scope="module")
def tests_target() -> str:
    return _target_block(_strip_comments(MANIFEST.read_text()), "PostRollTests")


def test_the_sources_on_disk_are_not_empty() -> None:
    # Finding no files would satisfy every assertion below while proving
    # nothing, which is the failure this whole file is about (L98).
    assert len(list(SOURCES.rglob("*.swift"))) > 50, (
        "almost no Swift sources were found, so this guard has stopped working"
    )


def test_every_sources_file_is_compiled_or_deliberately_excluded(tests_target: str) -> None:
    paths = _sources_paths(tests_target)
    excluded = set(_excludes(tests_target))

    globbed: set[Path] = set()
    for entry in paths:
        if not entry.startswith("Sources"):
            continue
        target = APP / entry
        if target.is_dir():
            globbed.update(target.rglob("*.swift"))
        elif target.is_file():
            globbed.add(target)

    missing = sorted(
        str(p.relative_to(SOURCES))
        for p in SOURCES.rglob("*.swift")
        if p not in globbed and str(p.relative_to(SOURCES)) not in excluded
    )

    assert not missing, (
        "These Sources files are not compiled into PostRollTests, so no Swift "
        "test can reference them and nothing goes red when one is added:\n  "
        + "\n  ".join(missing)
        + "\n\nThe target globs Sources; list a file under the target's "
        "`excludes:` if leaving it out is deliberate, with the reason written "
        "beside it."
    )


def test_the_target_does_not_go_back_to_naming_files_one_at_a_time(
    tests_target: str,
) -> None:
    # The assertion above passes either way, because a complete hand list
    # covers every file too. This is what stops the manifest drifting back to
    # the registry that has to be remembered.
    per_file = [p for p in _sources_paths(tests_target) if p.endswith(".swift")]
    assert not per_file, (
        "PostRollTests names individual Sources files again instead of globbing "
        "the directory. A file added later is then invisible to the whole Swift "
        "suite until somebody remembers to add it here, and nothing fails when "
        "they do not:\n  " + "\n  ".join(per_file)
    )


def test_every_exclude_still_names_a_file_that_exists(tests_target: str) -> None:
    # An exclude that has outlived its file silently exempts whatever drifts
    # into its place, and reads as a considered decision while doing it (L96).
    stale = [name for name in _excludes(tests_target) if not (SOURCES / name).exists()]
    assert not stale, (
        "These entries under PostRollTests `excludes:` no longer name a file "
        "under Sources/, so delete them:\n  " + "\n  ".join(stale)
    )


# ── the exemption's reviewer (#849) ───────────────────────────────────────────


@pytest.fixture(scope="module")
def manifest() -> str:
    return _strip_comments(MANIFEST.read_text())


def test_every_exclusion_is_still_compiled_into_the_app_itself(
    manifest: str, tests_target: str
) -> None:
    """A file no target compiles cannot be run by anything at all.

    The exclusions exist because a unit test bundle must not carry a second
    entry point, not because the file is dead. If it ever stops being compiled
    into the application too, it is not exempt from one suite, it is gone.
    """
    app = _target_block(manifest, "PostRoll")
    globbed = [p for p in _sources_paths(app) if p == "Sources"]
    assert globbed, (
        "the PostRoll app target no longer globs Sources, so which files it "
        "compiles is a hand list again and this check cannot answer for them"
    )
    assert not _excludes(app), (
        "the PostRoll app target now excludes files, so a file can be exempt "
        "from the unit bundle AND absent from the app, which is not an "
        "exemption but a deletion: " + ", ".join(_excludes(app))
    )
    for name in _excludes(tests_target):
        assert (SOURCES / name).exists(), f"{name} is excluded but not on disk"


def test_the_unit_bundle_exclusions_have_a_reviewer_that_runs_them(
    manifest: str, tests_target: str
) -> None:
    """#849: the exemption is right, which is exactly why nothing reviewed it.

    `PostRollApp.swift` is excluded from `PostRollTests` for a good reason, so
    nothing in the unit suite can run it and its only cover was guards matching
    its TEXT. #842 lived there: a link left an extra window behind and every
    unit test passed, because the defect was which scene type the app declares
    and how many windows exist, and a text match can see neither.

    A deliberate exemption with no reviewer named in the same change has no
    reviewer at all (L129). This holds the pair together: as long as anything is
    excluded from the unit bundle, a target that launches the real application
    has to exist. Removing the reviewer then fails here rather than quietly
    restoring the blind spot.
    """
    if not _excludes(tests_target):
        pytest.skip("nothing is excluded from the unit bundle, so nothing needs "
                    "a second reviewer")

    ui = _target_block(manifest, "PostRollUITests")
    assert "type: bundle.ui-testing" in ui, (
        "PostRollUITests is not a UI testing bundle, so it cannot launch the "
        "app and the files excluded from the unit bundle have no reviewer: "
        + ", ".join(_excludes(tests_target))
    )
    assert "- target: PostRoll" in ui, (
        "PostRollUITests does not depend on the PostRoll app target, so there "
        "is nothing for it to launch"
    )
    assert "TEST_TARGET_NAME: PostRoll" in ui, (
        "PostRollUITests names no target application, so `XCUIApplication()` "
        "has nothing to drive and every test in it reports about nothing (L98)"
    )



def test_something_actually_runs_the_reviewer(tests_target: str) -> None:
    """A target that compiles and never executes is coverage on paper.

    That is what #509 found the last UI target to be, and why it was deleted:
    it had been added and nothing had ever run it. Naming a reviewer that
    nothing invokes would repeat exactly that, one issue later (L3).
    """
    if not _excludes(tests_target):
        pytest.skip("nothing is excluded from the unit bundle")

    workflows = REPO_ROOT / ".github" / "workflows"
    runners = [
        path for path in sorted(workflows.glob("*.yml"))
        if any(runs_the_gui_scheme(command)
               for command in xcodebuild_commands(path.read_text()))
    ]
    assert runners, (
        "no workflow runs the PostRollUITests scheme, so the reviewer named for "
        "the unit bundle's exclusions compiles and never executes, which is "
        "what #509 deleted the last UI target for"
    )
    for path in runners:
        # As code (#1074): a workflow that lost its dispatch trigger
        # still explains it in the comment above where it was.
        text = without_prose(path)
        assert "workflow_dispatch:" in text, (
            f"{path.name} runs the GUI suite but cannot be run by hand, so "
            "there is no way to ask the question the day it matters"
        )
        assert "branches: [main]" in text, (
            f"{path.name} runs the GUI suite on no branch, so it only ever runs "
            "when somebody remembers to ask, which is a rule living in a "
            "person's head (L27)"
        )
