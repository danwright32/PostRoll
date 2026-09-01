"""#1133: all three blog paths answer for the repair, each in its own way.

The pass was wired into generation alone. That leaves the other two paths
emitting findings that read as NEVER ATTEMPTED, which renders exactly like
today's findings, which is the one thing rule 2 forbids.

The three paths are genuinely different and must not be made to look alike:

  * generation stages every photograph, so it repairs;
  * a photo SWAP stages them too, so it repairs;
  * a REVISION has no photograph at all. Its manifest carries `photo_filenames`
    and never paths, so alt text cannot be rewritten there. Those findings are
    `unavailable`, which says "regenerate or swap photos to have these
    rewritten" rather than pretending nothing was tried.

`unavailable` is not a nicety. It is why that state exists at all (#1132), and a
revision that reported never-attempted would be asserting something untrue about
a path that structurally cannot do the work.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from PIL import Image

from postroll.ai import revise_blog as rb
from postroll.ai import swap_blog_photos as swap


PROSE = "It's a night that started late and the room didn't empty early."
BAD = "A male performer sings"
GOOD = ("Kate DiGangi sings into a microphone at The Green Room 42 with one "
        "hand raised and the band lit blue behind her")
PROGRAM = {"performers": [{"name": "Kate DiGangi"}], "pieces": []}
VENUE = "The Green Room 42"


@pytest.fixture(autouse=True)
def never_reach_a_model(monkeypatch):
    """Every test here stubs `run_json_prompt`, and that is NOT enough.

    `_fix_second_person` and `_fix_missing_contractions` call `run_prompt`, a
    different function, once per offending paragraph. A fixture whose prose
    happens to break one of those rules therefore reaches the live API through a
    door the test never opened, and it does not fail: it just takes 43 seconds
    and spends money, which is how this was found (L2).

    Refused rather than stubbed, so the test says which door was left open
    instead of quietly answering through it.
    """
    def refuse(*args, **kwargs):
        raise AssertionError(
            "this test reached run_prompt, which no test may do. Give the "
            "fixture prose a contraction and no second person, or stub the "
            "specific backstop this is about.")

    for module in (rb, swap):
        monkeypatch.setattr(module, "run_prompt", refuse, raising=False)
    from postroll.ai import generate_blog as gb
    monkeypatch.setattr(gb, "run_prompt", refuse)


@pytest.fixture
def photo(tmp_path):
    path = tmp_path / "DSC0001.jpg"
    Image.new("RGB", (40, 30), (1, 2, 3)).save(path)
    return str(path)


# --- the swap repairs -------------------------------------------------------

def test_the_swap_repairs_an_alt_text_its_own_check_refused(photo):
    """It has the photographs staged, so rule 4 licenses it here too."""
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {BAD}]\n\n{PROSE}"
    seen = {"repairs": 0}

    def fake(prompt, timeout=300, image_paths=None, image_labels=None, **k):
        if "Rewrite the alt text" in prompt:
            seen["repairs"] += 1
            return {"alt": GOOD}
        return {"body": body, "photo_count": 1}

    with patch.object(swap, "run_json_prompt", side_effect=fake):
        result = swap.swap_blog_photos(
            body=f"{PROSE}\n\n[PHOTO: old.jpg | old alt]", photo_paths=[photo],
            program=PROGRAM, venue=VENUE)

    assert seen["repairs"] == 1, "the swap emitted a bad alt text and never tried"
    assert GOOD in result["body"]
    codes = [f["code"] for f in result["findings"]]
    assert "alt_text_appearance_descriptor" not in codes


def test_the_swap_reports_that_its_pass_ran(photo):
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {GOOD}]\n\n{PROSE}"
    with patch.object(swap, "run_json_prompt",
                      side_effect=lambda *a, **k: {"body": body, "photo_count": 1}):
        result = swap.swap_blog_photos(
            body=f"{PROSE}\n\n[PHOTO: old.jpg | old alt]", photo_paths=[photo],
            program=PROGRAM, venue=VENUE)

    assert result["repair_pass"]["ran"] is True


def test_a_repair_the_swap_could_not_make_says_tried(photo):
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {BAD}]\n\n{PROSE}"

    def fake(prompt, timeout=300, image_paths=None, image_labels=None, **k):
        if "Rewrite the alt text" in prompt:
            return {"alt": "A male performer still sings"}
        return {"body": body, "photo_count": 1}

    with patch.object(swap, "run_json_prompt", side_effect=fake):
        result = swap.swap_blog_photos(
            body=f"{PROSE}\n\n[PHOTO: old.jpg | old alt]", photo_paths=[photo],
            program=PROGRAM, venue=VENUE)

    assert any(f["repair"] == "tried" for f in result["findings"]), result["findings"]


# --- the revision says it cannot ------------------------------------------

def test_a_revisions_alt_text_findings_say_they_are_not_repairable_here():
    """The reason `unavailable` exists (#1132).

    A revision has no photograph: its manifest carries filenames and never
    paths. Reporting never-attempted would assert something untrue about a path
    that structurally cannot do the work.
    """
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {BAD}]\n\n{PROSE}"

    with patch.object(rb, "run_json_prompt",
                      side_effect=lambda *a, **k: {"title": "T", "body": body}):
        result = rb.revise_blog(
            event="E", org="O", venue=VENUE, date="2026-04-05",
            program=PROGRAM, existing={"title": "T", "body": body},
            feedback="tighten it", skip_humanizer=True, skip_voice_pass=True)

    alt = [f for f in result["findings"] if f["code"].startswith("alt_text_")]
    assert alt, "the fixture produced no alt text finding to check"
    for finding in alt:
        assert finding["repair"] == "unavailable", finding


def test_a_revisions_NON_alt_text_findings_are_left_as_never_attempted():
    """The control. Marking everything `unavailable` would be as wrong as
    marking nothing: only the alt text rules need a photograph (L159)."""
    # Carries a contraction on purpose: a paragraph without one sends the
    # deterministic contraction backstop out to the model for a focused
    # rewrite, which is a paid call this test has no business making.
    body = (f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {GOOD}]\n\n"
            "There's no arguing with 47 people in the room that night.")

    with patch.object(rb, "run_json_prompt",
                      side_effect=lambda *a, **k: {"title": "T", "body": body}):
        result = rb.revise_blog(
            event="E", org="O", venue=VENUE, date="2026-04-05",
            program=PROGRAM, existing={"title": "T", "body": body},
            feedback="f", skip_humanizer=True, skip_voice_pass=True)

    numbers = [f for f in result["findings"] if f["code"] == "invented_number"]
    assert numbers, "the fixture produced no prose finding to check"
    for finding in numbers:
        assert finding["repair"] == "", finding


def test_a_revision_never_makes_a_repair_call(photo):
    """It has nothing to attach, so it must not spend one finding out."""
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {BAD}]\n\n{PROSE}"
    calls = []

    def fake(prompt, timeout=600, **k):
        calls.append(prompt)
        return {"title": "T", "body": body}

    with patch.object(rb, "run_json_prompt", side_effect=fake):
        rb.revise_blog(event="E", org="O", venue=VENUE, date="2026-04-05",
                       program=PROGRAM, existing={"title": "T", "body": body},
                       feedback="f", skip_humanizer=True, skip_voice_pass=True)

    assert not any("Rewrite the alt text" in p for p in calls)


def test_a_revision_says_its_pass_did_not_run():
    """Honest: it did not, and it never can. The panel's own line says so."""
    body = f"{PROSE}\n\n[PHOTO: DSC0001.jpg | {GOOD}]\n\n{PROSE}"

    with patch.object(rb, "run_json_prompt",
                      side_effect=lambda *a, **k: {"title": "T", "body": body}):
        result = rb.revise_blog(
            event="E", org="O", venue=VENUE, date="2026-04-05",
            program=PROGRAM, existing={"title": "T", "body": body},
            feedback="f", skip_humanizer=True, skip_voice_pass=True)

    assert result["repair_pass"]["ran"] is False
