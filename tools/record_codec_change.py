"""Re-record a reference frame that moved by codec fidelity, not by design (#818).

`tests/test_media_design_fingerprint.py` offers two ways out when a template's
source moves:

  * it renders differently, so bump `MEDIA_DESIGN_VERSIONS`, which is
    `make record-design-change`, and
  * it renders identically, so record the fingerprint alone, which is
    `make record-fingerprints`.

#811 was neither. Dropping `-preset veryfast` from the clip reel's last encode
moved 0.27% of its pixels as low amplitude difference spread over the frame,
which fails the reference frame, so `make record-fingerprints` correctly
refuses. But the design did not change and the two frames are indistinguishable
side by side. The version bump was the only door left, and a bump tells the app
every cached asset of that template is out of date, which is a false alarm for a
change nobody can see (L36).

This is the third door. It re-records the reference frames of a template whose
render moved WITHOUT touching its design version, and it refuses when the
evidence says the render moved because something was drawn differently.

The evidence is the reading every comparison already takes, extended in #818 to
carry amplitude: how far the changed pixels moved on their worst channel, and
how much of their own box they fill. `tests/golden_drift.py` owns both the
thresholds and the readings they were chosen from, so the numbers judged here
are the numbers the comparison actually took rather than a second measurement
beside it (L107).

It refuses, by name, in every case where re-recording would be wrong:

  * nothing moved, so this is not the tree the guard failed in;
  * a template whose design version moved too, which is the other door;
  * `POSTROLL_UPDATE_GOLDENS` already set, which would make the measuring run
    re-record and skip, answering the question with a run that measured nothing;
  * reference frames with uncommitted changes, so what moved cannot be told from
    what was already lying around;
  * a template no reference frame photographs, or one the registry has never
    heard of;
  * a check that skipped, reported nothing, or wrote no reading;
  * a check that failed with its frame unchanged, which is a failure of
    something other than the comparison;
  * a reading whose shape says an element was moved or redrawn.

What it does NOT claim: that a codec-shaped difference is invisible. A change
that is low amplitude AND sparse in its own box AND local to one element reads
exactly like an encoder rounding, and this cannot tell them apart. That is why
it re-records and stops, handing the frames back to be LOOKED at, rather than
recording anything itself.

    venv/bin/python tools/record_codec_change.py    # or: make record-codec-change
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from xml.etree import ElementTree

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))
# The readings and the thresholds live with the checks that take them, and this
# reads them rather than keeping a second copy that would drift (L41).
sys.path.insert(0, str(REPO_ROOT / "tests"))

import golden_drift  # noqa: E402

from postroll.media import design_fingerprint as fp  # noqa: E402
from postroll.media import design_tokens as tokens  # noqa: E402
from tools.record_design_fingerprints import (  # noqa: E402
    RECORD_PATH,
    REFERENCE_TESTS,
    UNPHOTOGRAPHED,
    _dirty_goldens,
    _reference_run_env,
    _tail,
    case_key,
    templates_to_record,
    verdicts,
)

#: Where a run's readings are collected. The comparison writes one line per
#: frame into whatever this names, which is the only way to get the numbers out
#: of a pytest process (`tests/golden_drift.py`).
DRIFT_VARIABLE = golden_drift.LOG_VARIABLE


@dataclass(frozen=True)
class Run:
    """What one template's reference checks reported, and what their frames did.

    The readings are held as a LIST rather than matched up with the node ids
    that produced them. Nothing in a pytest run says which case wrote which
    line, and pairing them by position would attribute a reading to whichever
    check happened to be next once one of them failed before reaching its frame,
    which is the case this tool exists to judge (L100). So every reading in the
    run has to answer for itself, and a run that produced fewer readings than it
    has checks is refused rather than read.
    """

    node_ids: tuple[str, ...]
    outcomes: dict[str, str | None]
    readings: tuple[golden_drift.Reading, ...]
    output: str

    @property
    def moved(self) -> tuple[golden_drift.Reading, ...]:
        return tuple(r for r in self.readings if r.box is not None)


def run_reference_tests(node_ids: tuple[str, ...], report_path: Path,
                        drift_path: Path, env: dict[str, str],
                        repo_root: Path) -> tuple[int, str]:
    """Run the checks with their readings collected, and hand back what happened.

    A non-zero exit is expected here rather than refused: the frames this exists
    for are frames that FAIL. What the exit code cannot say is why, so the
    caller judges the readings and the junit outcomes instead.
    """
    completed = subprocess.run(
        [sys.executable, "-m", "pytest", *node_ids, "-q", "--no-header",
         "-p", "no:cacheprovider", f"--junit-xml={report_path}"],
        cwd=repo_root, env={**env, DRIFT_VARIABLE: str(drift_path)},
        capture_output=True, text=True)
    return completed.returncode, completed.stdout + completed.stderr


def look_at(node_ids: tuple[str, ...], report_path: Path, drift_path: Path,
            returncode: int, output: str) -> tuple[Run | None, str | None]:
    """What the run reported, or why it cannot be read at all."""
    if not report_path.is_file():
        return None, (f"the reference run wrote no report and exited {returncode}, "
                      f"so nothing here knows what it did. What it said:\n"
                      f"{_tail(output)}")
    try:
        reported = verdicts(report_path)
    except ElementTree.ParseError as exc:
        return None, (f"the reference run's report could not be read ({exc}), so "
                      f"its result is unknown rather than good. What the run "
                      f"said:\n{_tail(output)}")

    return Run(node_ids=tuple(node_ids),
               outcomes={node: reported.get(case_key(node)) for node in node_ids},
               readings=tuple(golden_drift.readings(drift_path)),
               output=output), None


def why_it_cannot_be_rerecorded(run: Run) -> str | None:
    """Why this template's frames must not be re-recorded, or None if they may."""
    for node, outcome in run.outcomes.items():
        if outcome is None:
            return (f"{node} reported nothing at all. A check pytest could not "
                    f"find exits green having run it zero times, which is "
                    f"indistinguishable from a pass.")
        if outcome == "skipped":
            return (f"{node} skipped rather than ran, so nothing measured what "
                    f"its frame does.")

    if not run.readings:
        return (f"the run wrote no readings at all, so nothing measured what "
                f"any of these frames did. Either every check failed before it "
                f"reached its frame, or the readings were never collected, "
                f"which is {DRIFT_VARIABLE} not reaching the run. Those are "
                f"different repairs and this cannot tell them apart from here. "
                f"What the run said:\n{_tail(run.output)}")
    if len(run.readings) < len(run.node_ids):
        return (f"{len(run.node_ids)} reference check(s) ran and only "
                f"{len(run.readings)} wrote a reading, so at least one failed "
                f"before it reached its frame and nothing measured what moved. "
                f"What the run said:\n{_tail(run.output)}")

    if all(outcome == "passed" for outcome in run.outcomes.values()):
        return ("every reference frame passed, so this template's render did not "
                "move and there is nothing here to re-record. Its source moved "
                "without moving a pixel, which is `make record-fingerprints`.")

    if not run.moved:
        return (f"a reference check failed with every frame unchanged, so what "
                f"failed is not the comparison and re-recording would record a "
                f"frame nobody has read. What the run said:\n{_tail(run.output)}")

    for reading in run.moved:
        design = golden_drift.why_it_is_not_codec_fidelity(reading)
        if design:
            return f"{reading.name} moved by design, not by the encoder: {design}"
    return None


def describe(reading: golden_drift.Reading) -> str:
    """One line of evidence, as it is shown to the person deciding."""
    if reading.box is None:
        return f"{reading.name}: no change"
    return (f"{reading.name}: {reading.changed} of {reading.total} px, "
            f"{reading.share:.4%}, {reading.fill:.2%} of its box, "
            f"median delta {reading.median_delta}")


def rerecord(node_ids: tuple[str, ...], report_path: Path, drift_path: Path,
             env: dict[str, str], repo_root: Path,
             runner) -> tuple[int, str]:
    """The same checks again with the re-record flag set."""
    return runner(node_ids, report_path, drift_path,
                  {**env, "POSTROLL_UPDATE_GOLDENS": "1"}, repo_root)


def record(repo_root: Path, *, runner=run_reference_tests,
           env: dict[str, str] | None = None, log=print) -> int:
    """Re-record what the evidence allows, refuse the rest by name, and say which."""
    environment = dict(os.environ if env is None else env)
    existing = json.loads((repo_root / RECORD_PATH).read_text(encoding="utf-8"))
    moved = templates_to_record(fp.fingerprints(repo_root), existing)

    if not moved:
        log("Nothing to record: every template's fingerprint and version "
            "already match the record.")
        log("If the guard just failed, this is not the tree it failed in.")
        return 1

    log(f"Moved since the record: {', '.join(moved)}")

    bumped = [t for t in moved
              if existing.get(t, {}).get("version") != tokens.MEDIA_DESIGN_VERSIONS.get(t)]
    if bumped:
        log(f"Refusing: these templates have a design version that moved too: "
            f"{', '.join(bumped)}.")
        log("  A bumped version says the design changed, which is the other "
            "door: `make record-design-change` re-records the frames and the "
            "stamp together.")
        log("  This door exists for a render that moved with the design "
            "standing still, so it must not be the one that badges assets.")
        return 1

    if environment.get("POSTROLL_UPDATE_GOLDENS"):
        log("Refusing: POSTROLL_UPDATE_GOLDENS is set, which makes every "
            "reference check re-record and skip. The readings this decides on "
            "would be of a run that measured nothing.")
        return 1

    dirty, git_failed = _dirty_goldens(repo_root)
    if git_failed:
        log(f"Refusing: git could not say whether the reference frames have "
            f"uncommitted changes, so what this re-records cannot be told from "
            f"what was already there. {git_failed}")
        return 1
    if dirty:
        log("Refusing: these reference frames already have uncommitted changes, "
            "so the readings below would be taken against frames somebody has "
            "already moved:")
        for line in dirty:
            log(f"  {line}")
        log("Commit or discard them first.")
        return 1

    refused: dict[str, str] = {t: UNPHOTOGRAPHED[t] for t in moved if t in UNPHOTOGRAPHED}
    for template in moved:
        if template not in REFERENCE_TESTS and template not in UNPHOTOGRAPHED:
            refused[template] = ("nothing says which reference frames photograph "
                                 "this template; add it to REFERENCE_TESTS or "
                                 "UNPHOTOGRAPHED in tools/record_design_fingerprints.py")

    provable = [t for t in moved if t in REFERENCE_TESTS]
    to_rerecord: dict[str, tuple[str, ...]] = {}
    with tempfile.TemporaryDirectory() as workspace:
        run_env = _reference_run_env(environment)
        for template in provable:
            node_ids = REFERENCE_TESTS[template]
            log(f"Reading {template} against {len(node_ids)} reference "
                f"frame(s); this renders.")
            report = Path(workspace) / f"{template}.xml"
            drift = Path(workspace) / f"{template}.drift"
            returncode, output = runner(node_ids, report, drift, run_env, repo_root)
            run, unreadable = look_at(node_ids, report, drift, returncode, output)
            if unreadable:
                refused[template] = unreadable
                continue
            for reading in run.readings:
                log(f"    {describe(reading)}")
            reason = why_it_cannot_be_rerecorded(run)
            if reason:
                refused[template] = reason
                continue
            to_rerecord[template] = node_ids

    if refused:
        for template, reason in sorted(refused.items()):
            log(f"NOT re-recorded, {template}: {reason}")
        log("Nothing was re-recorded. A frame that moved because an element "
            "moved or was redrawn is a design change: bump "
            "MEDIA_DESIGN_VERSIONS, mirror it in "
            "PostRollApp/Sources/DesignTokens.swift, and use `make "
            "record-design-change`.")
        return 1

    with tempfile.TemporaryDirectory() as workspace:
        run_env = _reference_run_env(environment)
        for template, node_ids in to_rerecord.items():
            log(f"Re-recording {template}'s reference frame(s).")
            returncode, output = rerecord(
                node_ids, Path(workspace) / f"{template}.xml",
                Path(workspace) / f"{template}.drift", run_env, repo_root, runner)
            if returncode != 0:
                log(f"Refusing: the re-record run for {template} exited "
                    f"{returncode}, so the frames it left behind are of a run "
                    f"that failed and must not be committed:\n{_tail(output)}")
                return 1

    changed, git_failed = _dirty_goldens(repo_root)
    if git_failed:
        log(f"Re-recorded, and git could not say which frames changed: {git_failed}")
        return 1
    if not changed:
        log("Refusing: the re-record left every reference frame byte for byte "
            "as it was, so nothing here moved and the readings above came from "
            "something other than these frames.")
        return 1

    log("")
    log(f"Re-recorded {len(changed)} reference frame(s):")
    for line in changed:
        log(f"    {line}")
    log("")
    log("Now, in this order:")
    log("  1. LOOK at those frames, side by side with the committed ones. This")
    log("     door rests on them being indistinguishable, and nothing")
    log("     downstream can check that.")
    log("  2. Commit them, with no version bump.")
    log("  3. Run `make record-fingerprints`, which records the fingerprint")
    log("     against frames that now pass, and refuses a frame with")
    log("     uncommitted changes, so it has to be step 3 and not step 2.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT,
                        help="the tree to record for (default: this checkout)")
    args = parser.parse_args(argv)
    return record(args.repo_root.resolve())


if __name__ == "__main__":
    raise SystemExit(main())
