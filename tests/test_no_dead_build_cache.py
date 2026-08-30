"""#991: the Swift DerivedData cache restored on every run and saved nothing.

A cache that never prevents a rebuild is not neutral. It costs the restore, it
costs the upload, and its entries evict the caches that DO work. This one held
19 GB against GitHub's 10 GB per-repository limit while preventing zero
compilation, so the pip and ffmpeg caches were being evicted to store it.

## The measurement, because "a cache must help" is an intuition

Across the eight most recent `swift-unit` runs on 2026-08-30, every one restored
a cache and every one compiled 529 or 530 units. Three of them rule out the
comfortable explanation that these were all prefix restores of a different tree:

* `a45b77e4`, `36ac281b` and `4a3af765` changed ZERO files matching
  `PostRollApp/**/*.swift` and no `project.yml`, which is exactly what the cache
  key hashes, so all three computed the same primary key that the `21ea9a18` run
  had just saved.
* All three restored precisely that entry.
* All three skipped their save step, which is what `actions/cache` does when the
  primary key already exists, corroborating the hit from the other side.
* All three compiled 530 units.

An exact hit on an identical tree that rebuilds the whole module is a cache
doing nothing at all.

## The cause named in the issue was wrong, and that matters

#991 supposed that `xcodegen generate` rewrites the project before the restore
and the build system keys on that. Measured locally: a warm build took 72s, then
`xcodegen generate` ran, then the same build took 2s and compiled 0 units.
Regenerating the project invalidates nothing.

What does is the environment. A fresh checkout stamps every source file with a
new mtime, newer than the restored object files, and Xcode's incremental build
is mtime based, so every source reads as stale however exact the hit is. That is
inherent to restoring build products onto a fresh checkout, which is why the
answer is to stop paying for it rather than to tune the key.

## Why this is a test and not a comment

A deleted mechanism leaves nothing to read. The next person to notice that CI
rebuilds from scratch will reach for a build cache, because that is the obvious
fix, and they will be reintroducing something already measured not to work
(L29: dead code is worse than deleted code, and its counterpart, a removal needs
its reason kept somewhere that fails).

This does not forbid a build cache forever. It forbids adding one without an
answer to the measurement above, and it names what that answer would have to be:
a run showing an exact-key hit compiling near zero units.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"

#: What a DerivedData build cache looks like, by what it CACHES rather than by
#: the action's name. Keyed on the path so a different caching action, a manual
#: tar to a artifact, or a rename of actions/cache is all covered (L96).
DERIVED_DATA = re.compile(r"\.derived-data|DerivedData")
CACHING = re.compile(r"uses:\s*actions/cache|cache-dependency-path|actions/upload-artifact")


def _cache_steps() -> list[tuple[str, str]]:
    """Every step in every workflow that caches something, as (file, step)."""
    found = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        text = path.read_text(encoding="utf-8")
        settings = "\n".join(line for line in text.splitlines()
                             if not line.strip().startswith("#"))
        for match in re.finditer(r"^      - (?:name|uses):.*?$(?:\n(?:        |\n).*?$)*",
                                 settings, re.M):
            step = match.group(0)
            if CACHING.search(step):
                found.append((path.name, step))
    return found


def test_the_scan_can_see_a_cache_step_at_all():
    """The control. This whole file is an assertion that something is ABSENT,
    and an absence check whose scan has stopped matching passes over everything
    (L98, L159: prove the positive fires in the same fixture).

    The pip caches are real cache steps and are meant to stay, so their presence
    is what proves the scan works.
    """
    steps = _cache_steps()
    assert steps, (
        "no caching step was found in any workflow, so the check below would "
        "pass over an empty set. Either every cache is gone, or this scan has "
        "stopped matching the shape they are written in")


def test_nothing_caches_the_swift_build_products():
    offenders = [f"{name}: {step.splitlines()[0].strip()}"
                 for name, step in _cache_steps() if DERIVED_DATA.search(step)]
    assert not offenders, (
        "a DerivedData build cache is back: "
        + ", ".join(offenders)
        + ". Measured on 2026-08-30, the last one restored on every run, hit "
          "its exact primary key on three consecutive commits with identical "
          "Swift sources, and compiled 530 units every time, while its entries "
          "held 19 GB against GitHub's 10 GB limit and evicted the pip and "
          "ffmpeg caches. Before adding one, show a run with an exact-key hit "
          "that compiles near zero units. See #991 and this file's docstring "
          "for why the mtime of a fresh checkout makes that hard.")


def test_every_python_setup_still_caches_pip():
    """The other half. Removing the dead cache must not take the live ones with
    it, and "no caches at all" satisfies the check above perfectly (L283: a
    guard asserting something is absent is satisfied by a deletion).

    Asked per `setup-python` step rather than per repository. Written the loose
    way first, "some workflow still caches pip", it SURVIVED its mutation:
    deleting swift.yml's pip cache left tests.yml's, and one workflow answered
    for the other (L135). The pip cache is one of the things the DerivedData
    cache was evicting from the 10 GB budget, so it is the thing most likely to
    be lost by accident here.
    """
    uncached = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        settings = "\n".join(line for line in path.read_text(encoding="utf-8").splitlines()
                              if not line.strip().startswith("#"))
        for match in re.finditer(
                r"^      - (?:name:.*\n        )?uses: actions/setup-python@[^\n]*"
                r"(?:\n(?:        |\n)[^\n]*)*", settings, re.M):
            if "cache: pip" not in match.group(0):
                uncached.append(f"{path.name}: {match.group(0).splitlines()[0].strip()}")
    assert not uncached, (
        f"these setup-python steps no longer cache pip: {uncached}. #991 removed "
        "the DerivedData cache because it never hit; the pip cache does hit, and "
        "it was one of the things the dead one was evicting")


def test_the_pip_check_can_see_an_uncached_setup():
    """The control for the check above, on a fixture rather than on the tree, so
    it cannot pass by the scan having stopped matching (L1)."""
    settings = ("jobs:\n  a:\n    steps:\n"
                "      - uses: actions/setup-python@v6\n        with:\n"
                "          python-version: \"3.11\"\n")
    found = re.search(
        r"^      - (?:name:.*\n        )?uses: actions/setup-python@[^\n]*"
        r"(?:\n(?:        |\n)[^\n]*)*", settings, re.M)
    assert found, "the setup-python pattern matches nothing, so the check is vacuous"
    assert "cache: pip" not in found.group(0)
