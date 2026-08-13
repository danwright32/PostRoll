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
