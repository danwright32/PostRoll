"""One build cache, outside the synced checkout, and every build path uses it.

#485. The cache had sprawled into three unreclaimed places at once:

  * the build's DerivedData was pinned inside the iCloud-synced Documents
    checkout, where iCloud had already minted numbered conflict copies of it
    that no clean step named,
  * the pre-install test step ran xcodebuild with no derivedDataPath at all, so
    it minted a second full cache under Xcode's default location, and
  * a fourth build directory sat at the repo root.

Xcode keys DerivedData by workspace path, so every path that gets built mints
its own full copy and nothing reclaims it: the growth is proportional to how
many paths have ever been built rather than to how much work is done, and it is
invisible until the disk stops the machine (L114).

These hold the shape of the fix rather than the current numbers: one location,
defined once, outside the synced tree, used by every xcodebuild the repo runs,
and known to `make clean`.
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PATH_SCRIPT = REPO_ROOT / "PostRollApp" / "derived-data-path.sh"
MAKEFILE = REPO_ROOT / "Makefile"
BUILD_INSTALL = REPO_ROOT / "PostRollApp" / "build-install.sh"


def resolved_cache_path() -> str:
    """What the shared definition actually evaluates to, run as a shell would.

    Read by running it rather than by parsing it, because the thing that has to
    be true is what the builds get, not what the file looks like (L52).
    """
    out = subprocess.run(
        ["bash", "-c", f'. "{PATH_SCRIPT}" && printf %s "$POSTROLL_DERIVED_DATA"'],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip()


def test_there_is_one_shared_definition():
    assert PATH_SCRIPT.exists(), (
        "the cache location has no single home, so the Makefile and the install "
        "script each hold their own copy and drift apart (L41)")
    assert resolved_cache_path(), "the shared definition resolves to nothing"


def test_the_cache_is_not_inside_the_checkout():
    """The checkout lives under iCloud-synced Documents. A cache in there is
    synced, conflict-copied, and counted against his iCloud storage, and the
    conflict copies are what no clean step could name."""
    cache = Path(resolved_cache_path()).resolve()
    repo = REPO_ROOT.resolve()

    assert not str(cache).startswith(str(repo)), (
        f"the build cache is inside the checkout ({cache})")
    assert "Documents" not in cache.parts, (
        f"the build cache is under Documents, which is the synced folder ({cache})")


def test_every_xcodebuild_says_where_its_cache_goes():
    """The failure this catches is an invocation with no derivedDataPath, which
    does not fail, does not warn, and quietly mints a second full cache in
    Xcode's default location."""
    offenders: list[str] = []
    for path in (MAKEFILE, BUILD_INSTALL):
        text = path.read_text(encoding="utf-8")
        # Comments describing an invocation are not an invocation (L103).
        stripped = "\n".join(
            line for line in text.splitlines() if not line.strip().startswith("#"))
        # Each xcodebuild call, up to the end of its line continuations.
        for match in re.finditer(r"xcodebuild((?:.*\\\n)*.*)", stripped):
            call = match.group(0)
            if "-derivedDataPath" not in call:
                offenders.append(f"{path.name}: {call.splitlines()[0].strip()}")

    assert not offenders, (
        "these xcodebuild calls do not say where their cache goes, so each one "
        "mints a full copy under Xcode's default location that nothing here "
        "reclaims:\n  " + "\n  ".join(offenders))


def test_the_scan_can_still_see_an_invocation():
    """Finding none at all would pass the assertion above while checking
    nothing (L98)."""
    text = (MAKEFILE.read_text(encoding="utf-8")
            + BUILD_INSTALL.read_text(encoding="utf-8"))
    assert text.count("xcodebuild") >= 3


def test_neither_file_spells_the_path_itself():
    """Two spellings of one location is how the second stale cache appears: a
    path changed in one file and left in the other keeps filling."""
    for path in (MAKEFILE, BUILD_INSTALL):
        text = path.read_text(encoding="utf-8")
        code = "\n".join(
            line for line in text.splitlines() if not line.strip().startswith("#"))
        assert "Library/Developer/PostRoll" not in code, (
            f"{path.name} spells the cache path itself instead of taking it from "
            f"{PATH_SCRIPT.name}")


def test_make_clean_removes_the_cache_it_created(tmp_path, monkeypatch):
    """A clean step that names a location the builds no longer use leaves the
    real cache growing while reporting that it cleared it."""
    fake_home = tmp_path / "home"
    (fake_home / "Library" / "Developer").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(fake_home))

    cache = Path(subprocess.run(
        ["bash", "-c", f'. "{PATH_SCRIPT}" && printf %s "$POSTROLL_DERIVED_DATA"'],
        capture_output=True, text=True, check=True, env={**os.environ, "HOME": str(fake_home)},
    ).stdout.strip())
    cache.mkdir(parents=True, exist_ok=True)
    (cache / "Build").mkdir()

    subprocess.run(["make", "clean"], cwd=REPO_ROOT, check=True,
                   capture_output=True, text=True,
                   env={**os.environ, "HOME": str(fake_home)})

    assert not cache.exists(), f"make clean left {cache} behind"


@pytest.mark.parametrize("stale", ["PostRollApp/build", "build"])
def test_the_old_locations_are_gone_from_the_checkout(stale):
    """The two directories the sprawl left behind, including the one at the repo
    root that nothing ever named."""
    assert not (REPO_ROOT / stale).exists(), (
        f"{stale} is still in the checkout, so iCloud is still syncing a build "
        f"cache and still making conflict copies of it")


def test_the_install_script_says_so_when_the_shared_definition_is_missing(tmp_path):
    """The failure path of splitting the location into its own file.

    A copy of the script without the file it sources used to fail as a bare
    "No such file or directory" from bash, naming a path with no explanation,
    and a test that copies the script into a scratch directory hit exactly that
    (L11). Distinct causes get distinct messages, and this one has a specific
    thing to say.
    """
    import shutil
    import subprocess

    scratch = tmp_path / "PostRollApp"
    scratch.mkdir()
    shutil.copy2(BUILD_INSTALL, scratch / "build-install.sh")
    # Deliberately NOT copying derived-data-path.sh.

    result = subprocess.run(
        ["/bin/bash", str(scratch / "build-install.sh")],
        capture_output=True, text=True, timeout=120)

    assert result.returncode != 0
    combined = result.stdout + result.stderr
    assert "derived-data-path.sh" in combined, combined[-500:]
    assert "build cache" in combined, (
        f"it failed without saying what the missing file is for:\n{combined[-500:]}")
