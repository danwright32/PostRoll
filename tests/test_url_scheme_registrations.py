"""Which PostRoll.app macOS may hand a `postroll://` link to (#840).

When #840 was filed, `lsregister` on this Mac held 14 registrations for
PostRoll.app: build products under two DerivedData roots, copies under paths the
project has not lived at since it moved, two under /private/tmp, and the
installed one. While PostRoll answered no URLs that was harmless. Declaring the
scheme makes every one of them a candidate, and macOS picks by its own rules.

`PostRollApp/register-url-scheme.sh` narrows the field: it registers the
installed copy and unregisters every other PostRoll.app LaunchServices knows
about. The one thing it must never do is unregister /Applications/PostRoll.app,
because that is the copy the whole exercise exists to make answer.

Driven through a dry run against a recorded dump rather than against this Mac's
real LaunchServices database. A test that unregistered real applications to
check that it would not is not a test anybody can run twice (L2), and a test
that read the live database would be asserting about whatever happens to be
installed today rather than about the script.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "PostRollApp" / "register-url-scheme.sh"

INSTALLED = "/Applications/PostRoll.app"
STALE = [
    "/Users/dan/Library/Developer/PostRoll/Build/Products/Debug/PostRoll.app",
    "/Users/dan/Library/Developer/PostRoll/Build/Products/Release/PostRoll.app",
    "/private/tmp/PostRoll-build/Build/Products/Release/PostRoll.app",
]


def _dump(paths: list[str]) -> str:
    """An `lsregister -dump` extract, in the shape the real one has.

    Only the `path:` lines matter, and they are indented and carry a trailing
    LaunchServices id. A different unrelated application is included so a sweep
    that matched everything would be caught rather than looking correct.
    """
    lines = ["--------------------------------------------------------"]
    for index, path in enumerate(paths):
        lines.append(f"bundle id:            {index}")
        lines.append(f"path:                 {path} (0x{index:04x})")
    lines.append("path:                 /Applications/Numbers.app (0xbeef)")
    return "\n".join(lines) + "\n"


def _run(tmp_path: Path, dump_paths: list[str]) -> subprocess.CompletedProcess:
    dump = tmp_path / "lsregister.dump"
    dump.write_text(_dump(dump_paths), encoding="utf-8")
    return subprocess.run(
        ["/bin/bash", str(SCRIPT)],
        capture_output=True,
        text=True,
        env={
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "POSTROLL_LS_DUMP_FILE": str(dump),
            "POSTROLL_LS_DRY_RUN": "1",
        },
    )


def _planned(output: str) -> list[str]:
    return [line for line in output.split("\n") if line.startswith("WOULD:")]


def test_the_script_exists_and_is_runnable():
    assert SCRIPT.exists(), f"{SCRIPT} is missing"


def test_the_installed_copy_is_never_unregistered(tmp_path):
    """The one outcome that would break the feature outright."""
    result = _run(tmp_path, [INSTALLED, *STALE])

    unregisters = [line for line in _planned(result.stdout) if "-u " in line]
    assert unregisters, "nothing was unregistered at all, so the sweep matched nothing"
    for line in unregisters:
        assert INSTALLED not in line, (
            "the script would unregister the installed copy, which is the one "
            f"the link has to reach: {line}"
        )


def test_every_other_postroll_copy_is_unregistered(tmp_path):
    result = _run(tmp_path, [INSTALLED, *STALE])

    planned = "\n".join(_planned(result.stdout))
    for stale in STALE:
        assert stale in planned, (
            f"{stale} stays registered, so macOS may still hand it the link"
        )


def test_an_unrelated_application_is_left_alone(tmp_path):
    """The sweep is for PostRoll copies, not for everything in the dump."""
    result = _run(tmp_path, [INSTALLED, *STALE])

    # Proved against a run that DID sweep something. Without this the check is
    # satisfied by a script that produced no output at all, which is how a
    # negative assertion passes in a fixture where it could not fail (L159).
    assert _planned(result.stdout), f"the sweep planned nothing: {result.stdout}"
    assert "Numbers.app" not in result.stdout, (
        "the sweep matched an application that has nothing to do with PostRoll: "
        f"{result.stdout}"
    )


def test_the_installed_copy_is_registered_rather_than_only_assumed(tmp_path):
    """Unregistering the others does not make the survivor the answer.

    LaunchServices has to know about the installed copy, and after a fresh
    install it may not yet.
    """
    result = _run(tmp_path, [INSTALLED, *STALE])

    registers = [line for line in _planned(result.stdout) if "-u " not in line]
    assert any(INSTALLED in line for line in registers), (
        f"the installed copy is never registered: {result.stdout}"
    )


def test_a_dump_naming_no_postroll_at_all_is_an_error_not_a_clean_sweep(tmp_path):
    """Finding nothing is not the same as there being nothing to find.

    The script registers the installed copy before it reads the dump, so the
    installed copy must be in it. A dump with no PostRoll.app in it means the
    reading is broken, and reporting that as a tidy database would be a sweep
    matching nothing and calling it success (L98, L100).
    """
    result = _run(tmp_path, [])

    assert result.returncode != 0, (
        "a dump the script could find no PostRoll.app in was reported as fine: "
        f"{result.stdout}{result.stderr}"
    )
    assert "PostRoll.app" in result.stderr, (
        f"the error does not say what was not found: {result.stderr}"
    )


def test_a_dump_missing_only_the_installed_copy_is_an_error(tmp_path):
    """The installed copy was just registered. Its absence means either the
    registration silently did nothing or the parse is wrong, and both of those
    end with the link reaching a build product."""
    result = _run(tmp_path, STALE)

    assert result.returncode != 0, (
        f"the installed copy was missing and nothing said so: {result.stdout}"
    )
    assert INSTALLED in result.stderr, (
        f"the error does not name the copy that was missing: {result.stderr}"
    )


def test_the_install_script_runs_this(tmp_path):
    """Built is not wired (L3).

    A tidy-up nobody runs leaves the 14 registrations exactly where they were.
    `build-install.sh` is the one path that puts a copy into /Applications, so
    it is where this belongs.
    """
    install = (REPO_ROOT / "PostRollApp" / "build-install.sh").read_text(encoding="utf-8")
    kept = "\n".join(
        line for line in install.split("\n") if not line.strip().startswith("#")
    )
    assert "register-url-scheme.sh" in kept, (
        "nothing runs register-url-scheme.sh, so the stale registrations stay "
        "and macOS goes on choosing between them"
    )
