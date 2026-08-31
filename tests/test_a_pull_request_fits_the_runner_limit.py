"""A pull request asks for no more macOS runners than GitHub runs at once (#1095).

GitHub allows five concurrent macOS jobs per ACCOUNT, not per repository. This
repository asked for SIX on every pull request, so one always waited even with
nothing else happening, and two pull requests meant twelve jobs against five.

Measured on 2026-08-31, timing every job on #1093 from when its run was created:

    swift-unit                          queued    5s   ran 523s   done at 528s
    reference-frames (thursday-reel)    queued  163s   ran 178s   done at 341s
    macos                               queued    5s   ran 194s   done at 199s
    reference-frames (goldens)          queued   23s   ran 160s   done at 183s
    python                              queued    4s   ran 179s   done at 183s
    changed                             queued    4s   ran 171s   done at 175s
    reference-frames (legibility)       queued   28s   ran 132s   done at 160s

The sixth job waited 163 seconds. On a run with a guard sweep in flight the same
shape cost 18 minutes 22 seconds, measured on the sweep's own sixth shard.

WHAT THIS DOES NOT CLAIM. Fitting under the limit does not make a lone pull
request finish sooner: `swift-unit` is the critical path at 528s and the whole
reference-frame leg is done by 341s, so the queueing lands on a job with 187
seconds of slack. What it buys is that pull requests stop starving each other,
and that the account has room for another repository's macOS job. Half of
`swift-unit` is compiling rather than testing, and that is where wall clock
lives; it is not what this file is about.

Counted from the workflows rather than from a number typed here, so a job added
later is counted without anyone remembering to (L41, L96).
"""

from __future__ import annotations

import re
from pathlib import Path

from tools.wait_for_checks import _under, expected_checks

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"

#: How many macOS jobs GitHub runs at once, per account, on this plan.
#:
#: Not a preference and not a target: it is the platform's number, and every job
#: asked for past it waits for one of these to finish (L307).
CONCURRENT_MACOS_RUNNERS = 5


#: Which workflow each macOS job lives in, and the job key that declares its
#: `runs-on`. Derived below rather than listed: this maps a CHECK name back to
#: the job block that produced it, which is the only part `expected_checks`
#: does not already answer.
def job_key(check_name: str) -> str:
    """The workflow job a check name came from.

    A matrix job's checks are named `job (entry)`, so the job is everything
    before the first bracket. A plain job's check IS its job name.
    """
    return check_name.split(" (")[0]


def runs_on_macos(workflow_text: str, job: str) -> bool:
    """Whether `job` in this workflow runs on a macOS runner.

    Read out of the job's own block, bounded by indentation, so a `runs-on`
    belonging to the NEXT job cannot answer for this one.
    """
    _, body = _under(workflow_text, rf"^  {re.escape(job)}:\s*$")
    return bool(re.search(r"^\s+runs-on:\s*macos", body, re.M))


def macos_checks_on_a_pull_request() -> dict[str, list[str]]:
    """Every macOS check a pull request produces, by workflow file.

    Built on `expected_checks`, which is the repository's one derivation of what
    a pull request actually reports and is calibrated against a recorded reply
    from a real green pull request (L41, L52). Writing a second parser here is
    how two derivations of one thing drift apart (L263).
    """
    found: dict[str, list[str]] = {}
    texts = {p.name: p.read_text(encoding="utf-8")
             for p in sorted(WORKFLOWS.glob("*.yml"))}
    by_workflow = {}
    for name, text in texts.items():
        title = re.search(r"^name:\s*(.+)$", text, re.M)
        if title:
            by_workflow[title.group(1).strip()] = name

    for check in expected_checks(WORKFLOWS):
        if check.skips_on_pull_request:
            continue
        filename = by_workflow.get(check.workflow)
        assert filename, (
            f"the check {check.name!r} says it comes from a workflow called "
            f"{check.workflow!r}, and no file under "
            f"{WORKFLOWS.relative_to(REPO_ROOT)} declares that name")
        if runs_on_macos(texts[filename], job_key(check.name)):
            found.setdefault(filename, []).append(check.name)
    return found


def test_a_matrix_job_counts_once_per_entry():
    """The defect the count exists for: three of the six came from one block."""
    found = macos_checks_on_a_pull_request()
    frames = [n for names in found.values() for n in names
              if n.startswith("reference-frames")]
    assert len(frames) > 1, (
        "the reference-frame job is counted once rather than once per shard, so "
        "the total below understates what a pull request asks for")


def test_a_job_a_pull_request_never_starts_is_not_counted():
    """`full` in guards.yml runs only off a pull request, so it takes none of
    the five slots a pull request competes for."""
    found = {n for names in macos_checks_on_a_pull_request().values() for n in names}
    assert "full" not in found


def test_a_linux_job_is_not_counted():
    found = {n for names in macos_checks_on_a_pull_request().values() for n in names}
    assert "python" not in found, (
        "the Linux job was counted as a macOS one, so the total is of something "
        "other than the runners that are scarce")


def test_the_reader_finds_a_job_s_own_runs_on():
    """Bounded by indentation, so the NEXT job's runs-on cannot answer for this
    one, which is how a whole-file search would read it."""
    text = "name: X\n\njobs:\n  a:\n    runs-on: ubuntu-latest\n  b:\n    runs-on: macos-15\n"
    assert runs_on_macos(text, "b")
    assert not runs_on_macos(text, "a")


def test_a_pull_request_fits_the_concurrent_runner_limit():
    found = macos_checks_on_a_pull_request()
    per_file = {name: len(checks) for name, checks in sorted(found.items())}
    total = sum(per_file.values())
    assert total > 0, (
        "no macOS job was counted on any pull request workflow, so this passes "
        "for the wrong reason")
    assert total <= CONCURRENT_MACOS_RUNNERS, (
        f"a pull request starts {total} macOS jobs and GitHub runs "
        f"{CONCURRENT_MACOS_RUNNERS} at once, so {total - CONCURRENT_MACOS_RUNNERS} "
        f"of them wait for a slot before doing anything: {per_file}. The limit is "
        "per ACCOUNT, so this also takes the room another repository's macOS job "
        "would need. Fold jobs together or move one off macOS."
    )
