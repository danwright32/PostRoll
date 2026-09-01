"""#1136: the whole pass, against Dan's real corrections, end to end.

Every seam is set once for the suite, or deliberately left real by the section
that tests it (L284). The pass honours four:

  * the MODEL RUNNER, stubbed everywhere. A test that reaches `run_prompt` or
    `run_json_prompt` is a defect, not a slow test, and one in this milestone
    already made a real paid call and passed by stubbing only one of the two;
  * the CLOCK, injected, and advanced by the section that produces `not_reached`;
  * the FILESYSTEM, real against `tmp_path`, because the retention key is what
    that section is testing;
  * the JOURNAL, pointed at `tmp_path` through `POSTROLL_DATA_DIR`.

**The harness needs photographs, and the fixtures structurally cannot have
them.** Both correction fixtures carry exactly `event, venue, program, draft,
corrected` and no photo files, and the existing suite calls `check_blog` with no
`photo_filenames` at all, so the filename rules are OFF in the only regression
evidence this repo has. The repairer needs a real photograph per marker, and the
collision refusal, the retention key and the splice are all unreachable without
one, so this ships a fixture BUILDER.

The builder asserts the count of files it created, because a builder that
silently made none would leave the harness green and blind (L98).
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest
from PIL import Image

from postroll.ai.blog_findings import RepairState
from postroll.ai.blog_quality import (_fold_filename, _markers, check_blog,
                                      repair_marker_filenames)
from postroll.ai.blog_repair import repair_alt_text
from postroll.ai.blog_repair_damage import Touched, blog_repair_damage
from postroll.ai.repair_log import RepairLog, read_records

FIXTURES = Path(__file__).parent / "fixtures" / "blog_corrections"
FIXTURE_NAMES = ("bludline", "one_man_odyssey")

#: What the two fixtures hold between them. Asserted, so a builder that made
#: none leaves this red rather than green and blind.
EXPECTED_PHOTO_COUNT = 14


def _fixture(name: str) -> dict:
    return json.loads((FIXTURES / f"{name}.json").read_text(encoding="utf-8"))


def build_photographs(body: str, into: Path) -> dict[str, str]:
    """One small real JPEG per marker filename in `body`.

    A real file, not a stub: `Path.is_file` decides whether a repair is
    attempted at all, and the retention key stats it.
    """
    into.mkdir(parents=True, exist_ok=True)
    made: dict[str, str] = {}
    for index, (name, _alt) in enumerate(_markers(body)):
        path = into / name
        Image.new("RGB", (40, 30), (10 + index, 20, 30)).save(path, "JPEG")
        made[name] = str(path)
    return made


class Clock:
    def __init__(self, start: float = 0.0):
        self.now = start

    def __call__(self) -> float:
        return self.now


@pytest.fixture(autouse=True)
def every_seam_is_set(monkeypatch, tmp_path):
    """Enumerated in ONE place and each one set, rather than leaving an unset
    one to run for real (L284). The real ones are the slow and dangerous ones.
    """
    def refuse(*args, **kwargs):
        raise AssertionError(
            "this test reached a model runner. Every call in this harness is "
            "stubbed; an unstubbed one spends money and reaches the network")

    from postroll.ai import (claude_client, generate_blog, revise_blog,
                             swap_blog_photos)
    for module in (generate_blog, revise_blog, swap_blog_photos, claude_client):
        for attr in ("run_prompt", "run_json_prompt"):
            monkeypatch.setattr(module, attr, refuse, raising=False)

    # The journal, into tmp_path. The filesystem stays REAL: the retention key
    # is what parts of this are testing.
    monkeypatch.setenv("POSTROLL_DATA_DIR", str(tmp_path / "data"))


def _run(fixture: str, tmp_path, *, answers, clock=None, deadline=1_000_000.0,
         max_rounds=2):
    data = _fixture(fixture)
    body = data["draft"]
    photos = build_photographs(body, tmp_path / fixture)
    log = RepairLog(event=fixture, script="harness")

    def runner(prompt, *, timeout, image_paths, image_labels, step):
        answer = answers(image_labels[0]) if callable(answers) else answers
        return {"alt": answer}

    outcome = repair_alt_text(
        body, program=data["program"], venue=data["venue"],
        photo_paths=photos, runner=runner, now=clock or Clock(),
        deadline=deadline, max_rounds=max_rounds, log=log)
    return data, outcome, photos, log


# --- the builder ------------------------------------------------------------

def test_the_builder_creates_a_photograph_for_every_marker(tmp_path):
    total = 0
    for name in FIXTURE_NAMES:
        made = build_photographs(_fixture(name)["draft"], tmp_path / name)
        assert made, f"{name}: the builder created no photographs"
        for path in made.values():
            assert Path(path).is_file()
        total += len(made)

    assert total == EXPECTED_PHOTO_COUNT, (
        f"the builder made {total} photographs and the fixtures hold "
        f"{EXPECTED_PHOTO_COUNT} markers between them; a builder that quietly "
        f"made fewer would leave this harness green and blind")


def test_the_filename_rules_are_ON_in_this_harness(tmp_path):
    """The existing suite calls check_blog with NO photo_filenames, so both
    filename rules are off in the only regression evidence this repo has."""
    data = _fixture("bludline")
    photos = build_photographs(data["draft"], tmp_path / "b")

    with_names = check_blog(data["draft"], program=data["program"],
                            venue=data["venue"], photo_filenames=list(photos))
    without = check_blog(data["draft"], program=data["program"],
                         venue=data["venue"])

    assert len(with_names) >= len(without)


# --- the pass shrinks the findings ------------------------------------------

@pytest.mark.parametrize("fixture", FIXTURE_NAMES)
def test_the_findings_shrink_toward_the_corrected_post(fixture, tmp_path):
    data = _fixture(fixture)
    corrected = {_fold_filename(n): a for n, a in _markers(data["corrected"])}

    def answer(marker: str) -> str:
        return corrected.get(_fold_filename(marker), "")

    _data, outcome, _photos, _log = _run(fixture, tmp_path, answers=answer)

    before = check_blog(data["draft"], program=data["program"],
                        venue=data["venue"])
    after = check_blog(outcome.body, program=data["program"],
                       venue=data["venue"])

    assert len(after) < len(before), (
        f"{fixture}: {len(before)} findings before, {len(after)} after; the "
        f"pass did not move the post toward the correction at all")


@pytest.mark.parametrize("fixture", FIXTURE_NAMES)
def test_the_ordered_golden_still_holds_where_nothing_was_repaired(fixture,
                                                                   tmp_path):
    """5a's golden, over the untouched fixture, inside the harness."""
    golden = json.loads(
        (Path(__file__).parent / "fixtures" / "blog_findings_golden.json")
        .read_text(encoding="utf-8"))["goldens"][f"{fixture}.draft"]
    data = _fixture(fixture)

    found = check_blog(data["draft"], program=data["program"],
                       venue=data["venue"])
    assert [[f.code, f.message, f.detail] for f in found] == golden


@pytest.mark.parametrize("fixture", FIXTURE_NAMES)
def test_no_name_marker_or_paragraph_is_lost(fixture, tmp_path):
    """The gate, run over the whole pair rather than per attempt."""
    data = _fixture(fixture)
    corrected = {_fold_filename(n): a for n, a in _markers(data["corrected"])}
    _d, outcome, photos, _log = _run(
        fixture, tmp_path,
        answers=lambda m: corrected.get(_fold_filename(m), ""))

    reasons = blog_repair_damage(
        data["draft"], outcome.body, program=data["program"],
        venue=data["venue"], photo_filenames=list(photos),
        touched=Touched.marker(*photos))
    assert reasons == [], reasons


def test_the_husk_control_is_refused_end_to_end(tmp_path):
    """Refused by the whole pass, not only in the gate's unit test."""
    data = _fixture("one_man_odyssey")
    venue = data["venue"]
    performer = data["program"]["performers"][0]["name"]
    husk = f"{performer} at {venue} during the performance on stage in the room"

    _d, outcome, _photos, _log = _run("one_man_odyssey", tmp_path,
                                      answers=lambda _m: husk)

    assert husk not in outcome.body, "a gutted rewrite reached the post"
    assert set(outcome.states.values()) <= {RepairState.TRIED,
                                            RepairState.REPAIRED}


# --- the off by one this design is most exposed to --------------------------

def test_each_call_names_which_photograph_and_which_marker(tmp_path):
    """`_reinsert_skipped` records the danger in as many words: an off by one
    attaches a real alt text to the wrong photograph, which reads as correct."""
    data = _fixture("bludline")
    photos = build_photographs(data["draft"], tmp_path / "b")
    seen: list[tuple[str, str]] = []

    def runner(prompt, *, timeout, image_paths, image_labels, step):
        seen.append((image_labels[0], image_paths[0]))
        return {"alt": ""}

    repair_alt_text(data["draft"], program=data["program"], venue=data["venue"],
                    photo_paths=photos, runner=runner, now=Clock(),
                    deadline=1_000_000.0, max_rounds=1, log=None)

    assert seen, "no call was made, so this asserts nothing"
    for marker, path in seen:
        assert len(_markers(f"[PHOTO: {marker} | x]")) == 1
        assert Path(path).name == marker, (
            f"the call for {marker} attached {Path(path).name}")


# --- reachable only here ----------------------------------------------------

def test_two_photographs_sharing_a_basename_refuse_with_both_paths_named(tmp_path):
    """Phase 2a's collision refusal, unreachable without real files."""
    from postroll.ai.blog_quality import refuse_colliding_filenames

    made = []
    for folder in ("day 1", "day 2"):
        directory = tmp_path / folder
        directory.mkdir(parents=True)
        path = directory / "DSC4821.jpg"
        Image.new("RGB", (20, 20), (1, 2, 3)).save(path)
        made.append(str(path))

    with pytest.raises(ValueError) as caught:
        refuse_colliding_filenames(["DSC4821.jpg", "DSC4821.jpg"], made)

    for path in made:
        assert path in str(caught.value)


def test_a_curly_quoted_near_miss_is_repaired_before_the_repairer_runs(tmp_path):
    """Synthesized DELIBERATELY: it does not arrive with the fixture names.

    Verified: every marker filename in both fixtures is pure ASCII. The
    typographic quotes that produced #962 live in the DiGangi event in the live
    store, not here, so this is the only way the harness exercises
    `repair_marker_filenames`'s fold path at all.
    """
    curly = 'Cast Party “Live”.jpg'
    straight = 'Cast Party "Live".jpg'
    path = tmp_path / curly
    Image.new("RGB", (20, 20), (1, 2, 3)).save(path, "JPEG")

    body = f"Prose.\n\n[PHOTO: {straight} | an alt text]\n\nMore prose."
    repaired, corrections = repair_marker_filenames(body, [curly])

    assert corrections == [(straight, curly)]
    assert curly in repaired


# --- the partition, produced by advancing the clock -------------------------

def test_the_five_way_partition_is_total_when_the_deadline_bites(tmp_path):
    from postroll.ai.blog_repair import CALL_TIMEOUT

    data = _fixture("bludline")
    photos = build_photographs(data["draft"], tmp_path / "b")
    clock = Clock()

    def runner(prompt, *, timeout, image_paths, image_labels, step):
        clock.now += 100
        return {"alt": ""}

    outcome = repair_alt_text(
        data["draft"], program=data["program"], venue=data["venue"],
        photo_paths=photos, runner=runner, now=clock,
        deadline=CALL_TIMEOUT + 201.0, max_rounds=1, log=None)

    assert set(outcome.states) == set(outcome.selected)
    assert RepairState.NOT_REACHED in outcome.states.values()
    for state in outcome.states.values():
        assert state is not RepairState.NEVER


# --- the journal is what survives -------------------------------------------

def test_the_pass_leaves_a_readable_record_of_what_it_changed(tmp_path):
    data = _fixture("bludline")
    corrected = {_fold_filename(n): a for n, a in _markers(data["corrected"])}
    _d, _outcome, _photos, log = _run(
        "bludline", tmp_path,
        answers=lambda m: corrected.get(_fold_filename(m), ""))

    records = read_records(log.path)
    assert [r for r in records if r["kind"] == "attempt"]
    assert [r for r in records if r["kind"] == "pass"]
    assert str(log.path).startswith(str(tmp_path)), (
        "the harness wrote its journal outside tmp_path, so a test run is "
        "editing the app's real data")


def test_the_checkers_honest_residue_is_not_tuned_away():
    """`accepted_on_corrected` records findings that still fire on a post Dan
    considered finished. They are pinned rather than tuned away, so the
    checker's false positive rate stays visible (L182)."""
    expectations = json.loads(
        (FIXTURES / "expectations.json").read_text(encoding="utf-8"))

    for pair in expectations["pairs"]:
        data = _fixture(pair["fixture"].removesuffix(".json"))
        codes = {f.code for f in check_blog(data["corrected"],
                                            program=data["program"],
                                            venue=data["venue"])}
        accepted = set(pair["accepted_on_corrected"])
        assert codes == accepted, (
            f"{pair['fixture']}: the corrected post now fires {sorted(codes)} "
            f"and expectations.json accepts {sorted(accepted)}. If a check got "
            f"better, record it; if it got worse, that is a regression.")
