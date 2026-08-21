"""No one worker carries the whole run (#783).

`-n auto` is a shortcut for `--dist load`, and load does NOT deal tests out one
at a time. It gives each worker an initial CONTIGUOUS chunk of the collection,
`len(collection) // numprocesses // 4` items, and only refills singly after
that. A test file's tests are contiguous in collection order, so a whole
expensive file fits inside one chunk and lands on one worker, and the run's wall
clock becomes that worker's share while the rest sit idle.

Measured on this Mac on 2026-08-21, 3327 tests over 12 workers, 770s of summed
CPU: one worker carried 220.9s, two carried about 150s each, and the remaining
nine carried 22 to 37s. The run took 224s. Switching to `--dist worksteal`, which
lets an idle worker take pending work off a busy one, took the same suite on the
same machine to 121s.

The flag lives in `pyproject.toml`'s `addopts` so every invocation gets it: the
local targets, both CI legs, and the reference-frame shards. This holds it there,
and holds every pytest command in the Makefile and the workflows to not quietly
overriding it, because a scheduler set in one place and undone in another is a
setting nobody can see the effect of.

It is deliberately NOT a timing assertion. A wall-clock threshold measured on
this Mac would fail on a slower machine and on a busy one, and the first false
alarm is what gets a check switched off (L36). What is asserted is the setting
that produced the measurement.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
PYPROJECT = REPO_ROOT / "pyproject.toml"
MAKEFILE = REPO_ROOT / "Makefile"
WORKFLOWS = REPO_ROOT / ".github" / "workflows"

#: Schedulers that let an idle worker take work from a busy one.
#:
#: A set rather than one name, because the property that matters is the
#: stealing, not the spelling. xdist has exactly one such scheduler today; a
#: second would satisfy this on the day it landed rather than on the day
#: somebody remembered to edit this line.
STEALING = {"worksteal"}


def addopts() -> str:
    """What every pytest invocation in this repo starts with."""
    match = re.search(r'^addopts\s*=\s*"([^"]*)"', PYPROJECT.read_text(encoding="utf-8"),
                      re.M)
    assert match, (
        "pyproject.toml declares no addopts, so nothing sets the scheduler and "
        "every check below is reading an empty string")
    return match.group(1)


def pytest_commands() -> list[tuple[str, str]]:
    """Every pytest command line in the Makefile and the workflows, with its source.

    Raises on finding nothing, for the reason `ci_workflow.py` gives: a scan that
    has stopped matching would report that no command overrides the scheduler at
    the moment it cannot see any command at all (L98, L100).
    """
    found: list[tuple[str, str]] = []
    for path in [MAKEFILE, *sorted(WORKFLOWS.glob("*.yml"))]:
        for line in path.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith("#") or "pytest" not in stripped:
                continue
            found.append((path.name, stripped))
    assert len(found) >= 3, (
        f"only {found} look like pytest commands across the Makefile and the "
        "workflows, which is not this repo. The scan has stopped matching.")
    return found


def test_the_scheduler_lets_an_idle_worker_take_work():
    dist = re.search(r"--dist[= ](\S+)", addopts())

    assert dist, (
        f"addopts is {addopts()!r}, which sets no --dist, so `-n auto` falls "
        "back to `load`. That deals each worker a contiguous chunk of the "
        "collection, so one expensive file lands on one worker and the run "
        "takes that worker's share: measured at 224s against 121s with "
        "worksteal on 2026-08-21 (#783).")
    assert dist.group(1) in STEALING, (
        f"the scheduler is `{dist.group(1)}`, which does not let an idle worker "
        f"take work from a busy one. Only {sorted(STEALING)} does.")


def test_nothing_overrides_the_scheduler_back():
    """A setting undone somewhere else is a setting with no visible effect.

    The Makefile's targets and the CI legs all reach pytest through addopts, and
    a `--dist` on one of those command lines would win over it silently: the
    comment in pyproject would go on describing a scheduler that command does not
    use (L103, L210).
    """
    overriding = [
        (source, command)
        for source, command in pytest_commands()
        for match in [re.search(r"--dist[= ](\S+)", command)]
        if match and match.group(1) not in STEALING
    ]

    assert not overriding, (
        "these commands set their own --dist, which overrides the one in "
        f"pyproject.toml: {overriding}. Remove it, or move the decision there.")


#: The local targets that run pytest, both of which have to be parallel.
#:
#: The fast one was NOT, until #766, and had never been: the full target has been
#: parallel since #497 and this one was simply missed. It cost 138s against 34.7s
#: on the same 3168 tests, measured on this Mac on 2026-08-21, on the target
#: whose entire reason for existing is being quick.
PARALLEL_TARGETS = ("test-python", "test-python-fast")


@pytest.mark.parametrize("name", PARALLEL_TARGETS)
def test_the_local_targets_are_parallel_at_all(name):
    """The measurement above is about how the parallelism is DEALT OUT.

    None of it means anything on a target that never asked for workers: the
    scheduler would then be a setting on a run with one process, and the tail
    this issue is about would be the entire run.
    """
    makefile = MAKEFILE.read_text(encoding="utf-8")
    target = re.search(rf"^{re.escape(name)}:\n((?:\t.*\n)+)", makefile, re.M)

    assert target, f"there is no {name} target in the Makefile"
    assert re.search(r"-n\s+\S+", target.group(1)), (
        f"the {name} target runs pytest with no -n, so it is serial: "
        f"{target.group(1).strip()}")
