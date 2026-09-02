"""Record a media template's design fingerprint, but only once it is proven (#660).

`tests/test_media_design_fingerprint.py` fails whenever a template's source
moves, and offers two ways out:

  * the change altered what gets rendered, so bump `MEDIA_DESIGN_VERSIONS`, and
  * it did not, so record the new fingerprint alone and say why in the commit.

Only the first was ever implemented. The reference frames have a re-record path
(`POSTROLL_UPDATE_GOLDENS=1`) and this had none, so the second was done with a
script written on the spot, which is what happened in #656 when consolidating
`load_font` moved all ten templates without changing a pixel. The two outcomes
are one keystroke apart and only one of them is safe: a hand written re-record
will just as happily bless a template whose rendering genuinely DID change,
which is the single thing the guard exists to prevent.

So this records a fingerprint only for a template whose rendering has been SEEN
to be unchanged, by running the reference frames that photograph it and reading
the result. It refuses, by name, in every case where the evidence is not real:

  * nothing moved, so this is not the tree the guard failed in;
  * a template no reference frame photographs, so nothing here can vouch for it;
  * a reference frame with uncommitted changes, because a golden regenerated in
    this working tree was produced by the very code in question;
  * `POSTROLL_UPDATE_GOLDENS` set, which would make every check re-record and
    skip, answering the gate with a run that checked nothing;
  * a check that skipped, failed, or reported nothing at all.

What it does NOT claim: that a passing reference frame proves a template renders
identically. It proves the frames that were photographed are the same within the
codec tolerance. Everything outside those frames is still the honest limit the
guard's own docstring states. Every template has a frame since #665; a template
that loses one, or arrives without one, is refused rather than assumed.

    venv/bin/python tools/record_design_fingerprints.py     # or: make record-fingerprints
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from xml.etree import ElementTree

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from postroll.media import design_fingerprint as fp  # noqa: E402
from postroll.media import design_tokens as tokens  # noqa: E402


#: The record this writes, and the reference frames that have to vouch for it.
#: Repo-relative, so the whole tool can be pointed at a copy of the tree.
RECORD_PATH = "tests/fixtures/media_design_fingerprints.json"
GOLDEN_DIR = "tests/fixtures/goldens"


#: Which reference-frame checks photograph each template.
#:
#: Written by hand, and held to the real file in both directions by
#: `tests/test_record_design_fingerprints.py`: every node id here is checked
#: against pytest's own collection, and every template in `TEMPLATE_MODULES` has
#: to appear either here or in `UNPHOTOGRAPHED`. A registry nobody holds to the
#: code exempts whatever is missing from it from the very gate it implements
#: (L96), and a node id that matches nothing is handed back by pytest as a clean
#: run of zero tests (L98).
REFERENCE_TESTS: dict[str, tuple[str, ...]] = {
    "collage": (
        "tests/test_golden_frames.py::test_collage_matches_its_reference_frame",),
    "story": (
        "tests/test_golden_frames.py::test_story_matches_its_reference_frame",),
    "before_after": (
        "tests/test_golden_frames.py::test_before_after_matches_its_reference_frame",),
    "reel_screen": (
        "tests/test_golden_frames.py::test_screen_reel_matches_its_reference_frame",),
    "reel_scroll": (
        "tests/test_golden_frames.py::test_scroll_reel_matches_its_reference_frame",),
    # Both Tuesday reels carry a second reference for the three seconds they end
    # on, which is a different design from the one the 0.6s frame records (#341).
    # A re-record that ran only the first would be blind to exactly the half
    # that reference was added for.
    "reel_morph": (
        "tests/test_golden_frames.py::test_morph_reel_matches_its_reference_frame",
        "tests/test_golden_frames.py::"
        "test_the_closing_hold_matches_its_reference_frame[morph_reel_closing]"),
    # A third reference, PART WAY THROUGH the first sweep (#1073). Both of the
    # others are holds, so between them they could not see the easing change at
    # all, and this door recorded a rewritten curve as an unchanged render.
    "reel_slider": (
        "tests/test_golden_frames.py::test_slider_reel_matches_its_reference_frame",
        "tests/test_golden_frames.py::"
        "test_the_sliders_divider_matches_its_reference_frame_mid_sweep",
        "tests/test_golden_frames.py::"
        "test_the_closing_hold_matches_its_reference_frame[slider_reel_closing]"),
    # The three that had no reference of their own until #665. The cover is
    # photographed through the app's own cover path rather than through the
    # story template it shares, because what is different about it (the sticky
    # gate, the wordmark it is handed) lives there.
    "cover": (
        "tests/test_golden_frames.py::test_the_cover_matches_its_reference_frame",),
    "reel_preview": (
        "tests/test_golden_frames.py::"
        "test_the_reel_preview_matches_its_reference_frame",),
    # Both variants (#825). The title card is optional in both directions, so
    # what `render_clip_reel` hands over is itself a delivered file, and #819
    # established it is a distinct encode rather than the titled frame with the
    # type taken off. A re-record that ran only the titled one would be blind to
    # exactly the half the second reference was added for.
    "reel_clip": (
        "tests/test_golden_frames.py::test_the_clip_reel_matches_its_reference_frame",
        "tests/test_golden_frames.py::"
        "test_the_delivered_clip_reel_matches_its_reference_frame"),
}


#: Templates no reference frame photographs, and why.
#:
#: Empty since #665, and kept rather than deleted: it is the half of the pair
#: that makes a NEW template a decision rather than an oversight. A template in
#: neither list is refused too, so nothing is silently exempt either way, but a
#: refusal that names the reason is worth more than one that says a registry is
#: incomplete.
#:
#: A template listed here is refused: nothing can show its rendering is
#: unchanged, so recording it would be the hand written re-record wearing a
#: tool's name. The fix is always the same, a reference frame in
#: `tests/test_golden_frames.py`.
UNPHOTOGRAPHED: dict[str, str] = {}


# ── what has to be recorded ──────────────────────────────────────────────────


def templates_to_record(current: dict[str, str],
                        record: dict[str, dict]) -> list[str]:
    """Templates whose fingerprint or shipping version differs from the record.

    The version counts as well as the fingerprint: the guard holds both, so a
    bump landing without the record following it fails there too, and this is
    the path that fixes it.
    """
    moved = []
    for template in sorted(current):
        entry = record.get(template, {})
        if (entry.get("fingerprint") != current[template]
                or entry.get("version") != tokens.MEDIA_DESIGN_VERSIONS[template]):
            moved.append(template)
    return moved


# ── reading the reference run ────────────────────────────────────────────────


def case_key(node_id: str) -> tuple[str, str]:
    """A pytest node id as junit spells it: (classname, name).

    Measured from a real `pytest --junit-xml` run rather than assumed (L52):
    `tests/test_golden_frames.py::test_x[y]` is written as
    `classname="tests.test_golden_frames" name="test_x[y]"`.
    """
    path, _, name = node_id.partition("::")
    return path.removesuffix(".py").replace("/", "."), name


def verdicts(report_path: Path) -> dict[tuple[str, str], str]:
    """Every case the run reported, as passed, skipped, failed or errored.

    Raises rather than returning nothing when the report cannot be read: an
    unreadable answer is not an empty one, and a caller that could not tell them
    apart would read a run that never started as a run that found no problems
    (L105).
    """
    root = ElementTree.parse(report_path).getroot()
    found: dict[tuple[str, str], str] = {}
    for case in root.iter("testcase"):
        outcome = "passed"
        for state in ("skipped", "failure", "error"):
            if case.find(state) is not None:
                outcome = {"failure": "failed"}.get(state, state)
        found[(case.get("classname", ""), case.get("name", ""))] = outcome
    return found


def refusal_for(node_ids: tuple[str, ...], report_path: Path,
                returncode: int, output: str) -> str | None:
    """Why this run cannot vouch for the template, or None if it can."""
    if not report_path.is_file():
        return (f"the reference run wrote no report and exited {returncode}, so "
                f"nothing here knows what it did. What it said:\n"
                f"{_tail(output)}")
    try:
        reported = verdicts(report_path)
    except ElementTree.ParseError as exc:
        return (f"the reference run's report could not be read ({exc}), so its "
                f"result is unknown rather than good. What the run said:\n"
                f"{_tail(output)}")

    for node in node_ids:
        outcome = reported.get(case_key(node))
        if outcome is None:
            return (f"{node} reported nothing at all. A check pytest could not "
                    f"find exits green having run it zero times, which is "
                    f"indistinguishable from a pass.")
        if outcome == "skipped":
            return (f"{node} skipped rather than passed. A skipped reference "
                    f"check says nothing about how the template renders.")
        if outcome != "passed":
            return (f"{node} {outcome}, so this template's rendering changed. If "
                    f"the DESIGN changed, bump MEDIA_DESIGN_VERSIONS and use "
                    f"`make record-design-change`; if an encode setting moved "
                    f"the pixels while the design stood still, that is the third "
                    f"door, `make record-codec-change` (#818).")

    if returncode != 0:
        return (f"every reference check reported a pass and the run still "
                f"exited {returncode}, so something failed outside them:\n"
                f"{_tail(output)}")
    return None


def _tail(output: str, lines: int = 15) -> str:
    text = "\n".join(output.strip().splitlines()[-lines:])
    return text or "(it said nothing at all)"


# ── running them for real ────────────────────────────────────────────────────


def run_reference_tests(node_ids: tuple[str, ...], report_path: Path,
                        env: dict[str, str], repo_root: Path) -> tuple[int, str]:
    completed = subprocess.run(
        [sys.executable, "-m", "pytest", *node_ids, "-q", "--no-header",
         "-p", "no:cacheprovider", f"--junit-xml={report_path}"],
        cwd=repo_root, env=env, capture_output=True, text=True)
    return completed.returncode, completed.stdout + completed.stderr


def _reference_run_env(env: dict[str, str]) -> dict[str, str]:
    """The environment the checks have to run in to mean anything.

    Both externals they need are absent on some machines, and both make the
    checks SKIP, which is indistinguishable from passing (L98). These two flags
    are conftest's own way of turning that into a loud failure.
    """
    prepared = {k: v for k, v in env.items() if k != "POSTROLL_UPDATE_GOLDENS"}
    prepared["POSTROLL_REQUIRE_GOLDENS"] = "1"
    prepared["POSTROLL_REQUIRE_FFMPEG"] = "1"
    return prepared


def _dirty_goldens(repo_root: Path) -> tuple[list[str], str | None]:
    """Reference frames with uncommitted changes, and why the answer is unknown.

    A failed git is reported rather than read as a clean tree: the two are the
    same empty string on stdout, and one of them is the state this refuses (L11).
    """
    completed = subprocess.run(
        ["git", "status", "--porcelain", "--", GOLDEN_DIR],
        cwd=repo_root, capture_output=True, text=True)
    if completed.returncode != 0:
        return [], (completed.stderr.strip()
                    or f"git exited {completed.returncode} without saying why")
    return [line.strip() for line in completed.stdout.splitlines() if line.strip()], None


# ── the tool ─────────────────────────────────────────────────────────────────


def record(repo_root: Path, *, runner=run_reference_tests,
           env: dict[str, str] | None = None, log=print) -> int:
    """Record what can be proven, refuse the rest by name, and say which."""
    environment = dict(os.environ if env is None else env)
    record_file = repo_root / RECORD_PATH
    existing = json.loads(record_file.read_text(encoding="utf-8"))
    moved = templates_to_record(fp.fingerprints(repo_root), existing)

    if not moved:
        log("Nothing to record: every template's fingerprint and version "
            "already match the record.")
        log("If the guard just failed, this is not the tree it failed in.")
        return 1

    log(f"Moved since the record: {', '.join(moved)}")

    if environment.get("POSTROLL_UPDATE_GOLDENS"):
        log("Refusing: POSTROLL_UPDATE_GOLDENS is set, which makes every "
            "reference check re-record and skip. The gate would be answered by "
            "a run that checked nothing. Record the frames, LOOK at them, "
            "commit them, then run this.")
        return 1

    dirty, git_failed = _dirty_goldens(repo_root)
    if git_failed:
        log(f"Refusing: git could not say whether the reference frames have "
            f"uncommitted changes, so this cannot tell a committed frame from "
            f"one just regenerated here. {git_failed}")
        return 1
    if dirty:
        log("Refusing: these reference frames have uncommitted changes, so they "
            "were produced by the very code being recorded and can vouch for "
            "nothing:")
        for line in dirty:
            log(f"  {line}")
        log("Commit them (after LOOKING at them) and run this again.")
        return 1

    refused = {t: UNPHOTOGRAPHED[t] for t in moved if t in UNPHOTOGRAPHED}
    provable = [t for t in moved if t in REFERENCE_TESTS]
    unknown = [t for t in moved if t not in REFERENCE_TESTS and t not in UNPHOTOGRAPHED]
    for template in unknown:
        refused[template] = ("nothing says which reference frames photograph "
                             "this template; add it to REFERENCE_TESTS or "
                             "UNPHOTOGRAPHED in this tool")

    proven: list[str] = []
    with tempfile.TemporaryDirectory() as workspace:
        run_env = _reference_run_env(environment)
        for template in provable:
            node_ids = REFERENCE_TESTS[template]
            log(f"Checking {template} against {len(node_ids)} reference "
                f"frame(s); this renders.")
            report = Path(workspace) / f"{template}.xml"
            returncode, output = runner(node_ids, report, run_env, repo_root)
            reason = refusal_for(node_ids, report, returncode, output)
            if reason:
                refused[template] = reason
            else:
                proven.append(template)

    if proven:
        for template in proven:
            existing[template] = {
                "fingerprint": fp.fingerprint(template, repo_root),
                "version": tokens.MEDIA_DESIGN_VERSIONS[template],
            }
        record_file.write_text(
            json.dumps(existing, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        log(f"Recorded, on reference frames that passed: {', '.join(proven)}")

    for template, reason in sorted(refused.items()):
        log(f"NOT recorded, {template}: {reason}")
    if refused:
        log("Nothing above was written for those. Either they render "
            "differently, in which case bump MEDIA_DESIGN_VERSIONS and mirror "
            "it in PostRollApp/Sources/DesignTokens.swift, or they need a "
            "reference frame before anything can say.")
        return 1
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT,
                        help="the tree to record for (default: this checkout)")
    args = parser.parse_args(argv)
    return record(args.repo_root.resolve())


if __name__ == "__main__":
    raise SystemExit(main())
