"""#1245: a recorded duration has to say which machine produced it.

`.github/workflows/swift.yml` recorded the Swift suite as "294s of test bodies
serially and 106s wall in parallel". That reading came from the 12 core Mac this
repo is written on. The comment sat in a job that runs on a GitHub macOS runner
reporting THREE cores, where the same suite takes 212s.

#1103 reasoned from the 106s figure and concluded the test run was the small
remainder of `swift-unit`, with roughly 400 of 528 seconds spent compiling. On
the runner's own reading the test run is the largest single phase of the job. So
one bare number sent a whole milestone's planning at the wrong half of the job.

#1243 fixed that line. This is the sweep for the others, and the guard that
stops a new one being written: a duration written as a bare assertion reads as
measured fact, and the reader has no way to tell a local reading from a runner
one (L316).

## What this checks, and what it does not

That every stated duration in this repo's PROSE has something nearby saying
where it was taken. Not that the reading is still true: nothing here can know
that, and re-measuring means dispatching the workflow.

Prose only. A number in code is a value the code USES, and changing it changes
behaviour. A number in a comment is a claim about the world.

## Why the attribution vocabulary is generous

Any nearby phrase that says where: a runner label, a core count, "locally",
"this Mac", "in CI", a run id. What makes a figure checkable is that the reader
can tell, not that a particular wording was used, and a rule that fired on every
honest comment here would stop being read (L36, L273).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools"))

from unattributed_timings import (  # noqa: E402
    EXEMPTIONS, MACHINE, MEASUREMENT, exempt, scanned_files, unattributed)


def test_no_recorded_duration_is_missing_its_machine():
    """One assertion rather than one per site, so the zero case is a PASS
    rather than an empty parameter set pytest reports as a skip (L98)."""
    reasons = exempt()
    missing = [f"{site['file']}:{site['line']}: {site['text']}"
               for site in unattributed() if site["text"] not in reasons]

    assert not missing, (
        "these state a duration with nothing nearby saying where it was "
        "measured, so a reader cannot tell a local reading from a runner one "
        "and nobody knows what to compare a new reading against (#1245, L316). "
        "Either name the machine in the same comment block, or add the line to "
        f"{EXEMPTIONS.name} with the reason it states no machine:\n"
        + "\n".join(missing))


def test_the_matcher_still_finds_a_duration():
    """The positive control. A matcher that had stopped matching would report a
    clean repository and every check here would pass on an empty answer (L98,
    L159)."""
    assert MEASUREMENT.search("# the suite takes 212s on the runner")
    assert MEASUREMENT.search("# it ran on 3 workers")
    assert not MEASUREMENT.search("# the cache holds 19 GB"), (
        "a byte size is not a duration: it does not change with the machine, "
        "which is the whole reason this rule exists")
    assert not MEASUREMENT.search("# 2.3x p90"), (
        "a ratio between two costs on ONE machine survives the move to "
        "another, which is exactly what an absolute duration does not")


def test_the_attribution_matcher_tells_the_two_apart():
    """Both directions, because one that matched everything would exempt the
    whole repository while reading as a guard (L159)."""
    assert MACHINE.search("measured on the macos-26 runner")
    assert MACHINE.search("locally a warm build took 72s")
    assert MACHINE.search("the 12 core Mac this repo is written on")
    assert not MACHINE.search("measured over 28 runs on 2026-08-30"), (
        "a date and a run COUNT say when and how often, never where, and "
        "accepting them would exempt the exact sentence #1243 was filed about")


def test_the_sweep_actually_reads_the_files():
    """The other positive control, and the one that matters most, because the
    check above PASSES when the sweep reads nothing at all (L98, L100).

    Asked of the sweep's own file selection rather than of a list rebuilt here,
    because two derivations of the same list drift and this would then agree
    with itself while the sweep looked at nothing (L70)."""
    read = scanned_files()
    names = {path.name for path in read}

    assert len(read) > 20, (
        f"the sweep resolved only {len(read)} files, which is not this "
        f"repository: it would report every duration in it as attributed")
    for expected in ("guards.yml", "swift.yml", "check_guards.py", "Makefile"):
        assert expected in names, (
            f"{expected} is not among the files the sweep reads, so every "
            f"figure in it is exempt by accident (L96)")

    from unattributed_timings import _comment_lines
    workflow = REPO_ROOT / ".github" / "workflows" / "guards.yml"
    assert len(_comment_lines(workflow)) > 50, (
        f"only {len(_comment_lines(workflow))} comment lines were found in "
        f"{workflow.name}, so the comment reader has stopped reading")


def test_every_exemption_names_a_line_that_is_still_there():
    """A stale entry excuses a real failure silently, and it is invisible
    because the entry itself still reads as a considered decision (L217, L233)."""
    present = {site["text"] for site in unattributed()}
    stale = sorted(text for text in exempt() if text not in present)

    assert not stale, (
        f"these exemptions name no line that still states an unattributed "
        f"duration: {stale}. Either it was attributed and the entry should go, "
        f"or the line was reworded and the entry now excuses nothing while "
        f"looking like it does")


def test_every_exemption_carries_a_reason():
    """An entry with no reason is evidence nobody reasoned about it (L233)."""
    thin = {text: reason for text, reason in exempt().items()
            if len(reason.split()) < 12}

    assert not thin, (
        f"these exemptions say too little to be a reason: {list(thin)}. Say "
        f"what the number IS, not that it is fine")


def test_the_exemptions_file_is_readable_json():
    """It is hand edited, and a file that will not parse would make `exempt`
    raise from inside every check above rather than reporting a bad entry."""
    assert json.loads(EXEMPTIONS.read_text(encoding="utf-8"))
