"""#1133 (Phase 5e): the repair runs, and the findings describe what shipped.

The repair mutates `final_body` AFTER the point where `findings` and
`findings_body` were built, so both have to be re-derived from the repaired
text. #974's contract refuses any payload reporting findings without pinning the
text they were measured against, and
`tests/test_blog_findings_pin_their_body.py` already exists to catch it.

Stated honestly: this is not protecting live behaviour, it is producing it for
the first time. All 21 stored blogs carry a `findings_body` of length 0
(measured), so `FindingsDisplay.isStale` is false everywhere today and #974's
pin exists only in code. The first blog to carry a real one will be the first
ever, so the test here is a first-use guard, not a regression guard.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PIL import Image

from postroll.ai import generate_blog as gb


PROSE = "It's a night that started late and ran long, and the room stayed full."
BAD = "A male performer sings"
GOOD = ("Kate DiGangi sings into a microphone at The Green Room 42 with one "
        "hand raised and the band lit blue behind her")
PROGRAM = {"performers": [{"name": "Kate DiGangi"}], "pieces": []}


@pytest.fixture
def photo(tmp_path):
    path = tmp_path / "DSC0001.jpg"
    Image.new("RGB", (40, 30), (10, 20, 30)).save(path)
    return str(path)


def _generate(photo, *, drafted, repaired=None, **kw):
    """One generation with the model stubbed on both the draft and the repair."""
    seen = {"repair_calls": 0}

    def fake_json(prompt, timeout=600, image_paths=None, image_labels=None, **k):
        if k.get("step") == "blog_repair_alt_text" or "Rewrite the alt text" in prompt:
            seen["repair_calls"] += 1
            seen["repair_images"] = list(image_paths or [])
            # Stat'ed HERE, not after the run: the staging directory is deleted
            # on the way out, so a check afterwards would fail even when the
            # photograph was correctly attached.
            seen["images_on_disk"] = [Path(p).is_file()
                                      for p in (image_paths or [])]
            return {"alt": repaired}
        return {"body": drafted, "photo_count": 1}

    with patch.object(gb, "run_json_prompt", side_effect=fake_json):
        seen["result"] = gb.generate_blog(
            event="E", org="O", venue="The Green Room 42", date="2026-04-05",
            program=PROGRAM, photo_paths=[photo],
            skip_humanizer=True, skip_voice_pass=True, **kw)
    return seen


def test_a_failing_alt_text_is_repaired_on_the_generate_path(photo):
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {BAD}]\n\n{PROSE}"
    seen = _generate(photo, drafted=body, repaired=GOOD)

    assert seen["repair_calls"] == 1
    assert GOOD in seen["result"]["body"]


def test_the_repair_has_the_photograph_on_disk_when_it_runs(photo):
    """Phase 0b's move is what makes this possible: the staging directory used
    to be gone by this point."""
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {BAD}]\n\n{PROSE}"
    seen = _generate(photo, drafted=body, repaired=GOOD)

    assert seen["repair_images"], "no photograph was attached to the repair call"
    assert seen["images_on_disk"] == [True], (
        "the photograph was not on disk when the repair call was made, so the "
        "rewrite would have been made from nothing")


def test_the_findings_describe_the_body_that_shipped(photo):
    """Re-measured after the repair, not before it."""
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {BAD}]\n\n{PROSE}"
    result = _generate(photo, drafted=body, repaired=GOOD)["result"]

    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_appearance_descriptor" not in codes, (
        "the findings still report the alt text the repair replaced, so the "
        "panel names a problem that is not in the post")


def test_findings_body_is_pinned_to_the_repaired_text(photo):
    """#974's contract: a payload may not report findings without pinning the
    text they were measured against."""
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {BAD}]\n\n{PROSE}"
    result = _generate(photo, drafted=body, repaired=GOOD)["result"]

    assert result["findings_body"] == result["body"], (
        "findings_body points at the pre-repair text, so the panel would read "
        "as stale the moment the post was opened")


def test_a_finding_the_repair_could_not_fix_says_so(photo):
    """Rule 2: a repair that was tried and failed still shows, marked tried."""
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {BAD}]\n\n{PROSE}"
    result = _generate(photo, drafted=body, repaired="A male performer still")["result"]

    tried = [f for f in result["findings"] if f["repair"] == "tried"]
    assert tried, (
        f"the repair failed and every finding still reads as never attempted, "
        f"which renders exactly like today's: {result['findings']}")


def test_a_clean_draft_costs_no_repair_call(photo):
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {GOOD}]\n\n{PROSE}"
    seen = _generate(photo, drafted=body, repaired=None)

    assert seen["repair_calls"] == 0


def test_the_pass_reports_that_it_ran_even_with_nothing_to_do(photo):
    """A clean post and a pass that never started must not read the same."""
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {GOOD}]\n\n{PROSE}"
    result = _generate(photo, drafted=body, repaired=None)["result"]

    assert result["repair_pass"]["ran"] is True
    assert result["repair_pass"]["selected"] == 0
    assert result["repair_pass"]["attempted"] == 0
