"""The blog generate path keeps a review pass and repairs its markers (#1218).

`generate_blog` ran its voice and humanizer passes with a validator, and
`run_review_pass` answers a validator failure by DISCARDING the whole pass and
keeping the prior draft. So a model that touched one `[PHOTO:]` marker cost a
paid review pass and returned none of its prose improvements, and the humanizer
is the pass this repo calls non-negotiable.

The revise and swap paths do not pay that. Both run
`blog_marker_splice.splice_retained_markers`, which puts every retained marker
back verbatim, keeps the pass's writing, counts the drift and reports it. That
module was written as a leaf precisely so more than one caller could take it.

#1141 widened the generate path's validator from three faults to five, adding
reorder and any alt text change, so it is strictly MORE likely to refuse than
it was and the cost of the refusal branch went up. A guard that avoids a wrong
action by falling back to a different action has only chosen which defect to
ship (L93), and the fallback here ships a blog with no humanizer pass at all.

So the validator keeps the one fault a splice cannot repair, a DROPPED marker,
which cannot be put back without inventing a position for it, and everything
else is repaired. That is the same split the revise path uses.

The drift is REPORTED because the splice destroys the evidence it was needed: a
model that rewrote every marker and one that reproduced them all produce a byte
identical body afterwards (L340).
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from PIL import Image

from postroll.ai import generate_blog

MARKER = "[PHOTO: DSC0001.jpg | Dancers mid turn under a blue wash]"
REWRITTEN = "[PHOTO: DSC0001.jpg | A completely different description]"
#: Every prose paragraph carries a contraction and no generic "you", so the
#: per-paragraph backstops have nothing to fix. They make their own focused
#: model calls, and a fixture that trips them fails on the stub that refuses a
#: live call rather than on anything this file is about.
DRAFT = f"It's been a long night.\n\n{MARKER}\n\nShe'd held the last note."
IMPROVED_PROSE = "It's been a long night, and I'd stayed to the end."


@pytest.fixture
def humanizer(tmp_path):
    """A humanizer skill file, so the pass this issue is about actually runs.

    Without one `is_humanizer_available` is false and the pass is skipped, and
    a test of the humanizer that never runs it passes by finding nothing (L98).
    """
    path = tmp_path / "SKILL.md"
    path.write_text("Remove AI tells. Keep every [PHOTO: ...] marker exactly.")
    return path


@pytest.fixture
def photo(tmp_path):
    path = tmp_path / "DSC0001.jpg"
    Image.new("RGB", (60, 40), (40, 60, 80)).save(path)
    return path


def run_with(passes, photo, **kwargs):
    """Drive a generate run whose model returns `passes` in order."""
    replies = list(passes)

    def fake_run_json(prompt, **_):
        return replies.pop(0) if replies else {"body": DRAFT, "photo_count": 1}

    def refuse(*a, **k):
        raise AssertionError("a live prompt call; stub it rather than paying for it")

    with patch("postroll.ai.generate_blog.run_json_prompt", side_effect=fake_run_json), \
         patch("postroll.ai.generate_blog.run_prompt", side_effect=refuse):
        return generate_blog.generate_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []}, photo_paths=[str(photo)],
            **kwargs)


def a_run(photo, humanizer, second_pass_body):
    """A draft, then a humanizer pass returning `second_pass_body`."""
    return run_with(
        [{"body": DRAFT, "photo_count": 1},
         {"body": second_pass_body, "photo_count": 1}],
        photo, skip_voice_pass=True, humanizer_path=humanizer)


def test_a_pass_that_rewrote_an_alt_text_keeps_its_prose(photo, humanizer):
    """The case the issue is about. The humanizer improved the prose AND
    rewrote one alt text; today both are thrown away."""
    result = a_run(photo, humanizer,
                   f"{IMPROVED_PROSE}\n\n{REWRITTEN}\n\nShe'd held the last note.")

    body = result["body"]
    assert "I'd stayed to the end" in body, (
        f"the humanizer's prose was discarded over a marker the splice can "
        f"repair, so a paid pass returned nothing:\n{body}")


def test_the_draft_s_own_alt_text_is_what_ships(photo, humanizer):
    """The other half. Keeping the pass must not mean keeping its alt text:
    the marker is Dan's, and the alt text is judged against the photograph."""
    result = a_run(photo, humanizer,
                   f"{IMPROVED_PROSE}\n\n{REWRITTEN}\n\nShe'd held the last note.")

    assert "Dancers mid turn under a blue wash" in result["body"], (
        f"the review pass's rewritten alt text shipped:\n{result['body']}")
    assert "A completely different description" not in result["body"]


def test_the_drift_is_reported_rather_than_silently_repaired(photo, humanizer, capsys):
    """The splice DESTROYS the evidence it was needed: a model that rewrote
    every marker and one that reproduced them all produce the same body
    afterwards (L340)."""
    a_run(photo, humanizer,
          f"{IMPROVED_PROSE}\n\n{REWRITTEN}\n\nShe'd held the last note.")

    said = capsys.readouterr().err
    assert "RESTORED" in said or "restored" in said, (
        f"a marker was repaired with nothing saying so, so a model that "
        f"rewrites every marker looks identical to one that behaves:\n{said}")


def test_a_pass_that_dropped_a_marker_is_still_discarded(photo, humanizer):
    """The one fault a splice cannot repair: a dropped marker cannot be put
    back without inventing a position for it, so the validator keeps it and
    the prior draft stands entire."""
    result = a_run(photo, humanizer,
                   f"{IMPROVED_PROSE}\n\nShe'd held the last note.")

    assert MARKER in result["body"], (
        f"a review pass dropped a photo marker and the draft did not stand, "
        f"so a photograph Dan chose is silently gone:\n{result['body']}")
