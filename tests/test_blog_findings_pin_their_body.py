"""#974: every blog path sends the text its findings were measured against.

The findings panel greys out and says the checks ran against the draft as
generated once the text moves under it. On blog posts that had never fired, on
any post: `BlogOutput.findingsBody` decodes from a `findings_body` key that no
Python blog path emitted, so the pin was empty and
`FindingsDisplay.isStale` compared the current body against an empty string
forever. Measured in the live store on 2026-08-31: 21 events, 21 blogs, 2 of
them carrying findings, and not one with a pinned body.

That is the exact failure the stale wording exists to prevent, stated at the
top of `FindingsDisplay.swift`: a report that keeps asserting itself after the
correction is worse than none, because it trains him to ignore the panel.

The caption paths have sent their `findings_caption` since #201, and the
comment beside it named `findings_body` as the reason it exists, so the gap was
written down at the moment it was created and nothing checked it.

The contract fixture now carries the key, which stops it being dropped, and
`test_bridge_payload_contract.py` refuses a payload that reports findings
without pinning what they describe. This file is the other half: the key has to
hold the body the checks actually ran on, not merely exist. A pin present but
empty, or a pin holding the body from before the last rewrite, passes every
contract check and reproduces the whole defect (L63).
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from PIL import Image

from postroll.ai import generate_blog as gb
from postroll.ai import revise_blog as rb
from postroll.ai import swap_blog_photos as swap


PROSE = "A paragraph of prose about the evening and the room."


def _body(marker: str) -> str:
    return f"{PROSE}\n\n{marker}"


@pytest.fixture(scope="module")
def photo(tmp_path_factory):
    p = tmp_path_factory.mktemp("blog-pin") / "DSC4821.jpg"
    Image.new("RGB", (60, 40), (40, 60, 80)).save(p)
    return p


def _generated(photo):
    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None,
                      image_paths=None, image_labels=None, **kwargs):
        return {"body": _body("[PHOTO: DSC4821.jpg | Alt text for the opening number.]"),
                "photo_count": 1}

    def refuse(*args, **kwargs):
        raise AssertionError("a live prompt call; stub it rather than paying for it")

    # Both prose passes stubbed to the identity. They call the model when the
    # draft has no contraction, and the one thing this file must never do is
    # reach a live prompt (L2).
    with patch.object(gb, "run_json_prompt", side_effect=fake_run_json), \
         patch.object(gb, "_fix_second_person", side_effect=lambda b: b), \
         patch.object(gb, "_fix_missing_contractions", side_effect=lambda b: b), \
         patch.object(gb, "run_prompt", side_effect=refuse):
        return gb.generate_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []}, photo_paths=[str(photo)],
            skip_humanizer=True, skip_voice_pass=True)


def _revised():
    returned = _body("[PHOTO: DSC4821.jpg | Alt text for the opening number.]")
    with patch.object(rb, "run_json_prompt",
                      side_effect=lambda *a, **k: {"title": "T", "body": returned}), \
         patch.object(rb, "_fix_second_person", side_effect=lambda b: b), \
         patch.object(rb, "_fix_missing_contractions", side_effect=lambda b: b):
        return rb.revise_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            existing={"title": "T", "body": _body("[PHOTO: DSC4821.jpg | alt]")},
            feedback="tighten it", skip_humanizer=True, skip_voice_pass=True)


def _swapped(photo):
    returned = _body("[PHOTO: DSC4821.jpg | Alt text for the opening number.]")
    with patch.object(swap, "run_json_prompt",
                      side_effect=lambda *a, **k: {"body": returned, "photo_count": 1}):
        return swap.swap_blog_photos(body=_body("[PHOTO: old.jpg | old alt]"),
                                     photo_paths=[photo])


@pytest.fixture(scope="module")
def paths(photo):
    """Every path that produces blog findings, by name.

    Enumerated in one place so a fourth path is one line rather than a test
    somebody remembers to write. Every one of them rewrites the body after
    Claude answers (em dashes stripped, marker filenames repaired, names
    corrected), which is why the pin cannot be the text that was sent.

    Module scoped: the three runs are the cost of this file and none of the
    cases below changes them, so they are paid once rather than once per case.
    """
    return {"generate_blog": _generated(photo),
            "revise_blog": _revised(),
            "swap_blog_photos": _swapped(photo)}


def test_every_blog_path_is_actually_exercised_here(paths):
    # A dict that came out short passes every case below while checking less
    # than it appears to (L98).
    assert sorted(paths) == ["generate_blog", "revise_blog", "swap_blog_photos"]


@pytest.mark.parametrize("name", ["generate_blog", "revise_blog", "swap_blog_photos"])
def test_the_pin_is_the_body_the_checks_actually_ran_on(name, paths):
    result = paths[name]
    assert result["findings_body"] == result["body"], (
        f"{name} pins a different text from the one it returns, so the panel "
        f"would report a fresh draft as already edited")
    assert result["findings_body"], f"{name} pins an empty body, which reads as no record at all"


def test_a_rewrite_after_the_answer_is_inside_the_pin(photo):
    """The pin has to be taken AFTER the last rewriter, not from what Claude said.

    Every one of these paths edits the body after the model answers. Pinning
    the model's text would report every post as edited the moment it appeared,
    which is the same panel nobody can trust wearing the opposite fault.
    """
    curly = "Cast Party “Live”-12.jpg"
    straight = 'Cast Party "Live"-12.jpg'
    on_disk = photo.parent / curly
    Image.new("RGB", (60, 40), (40, 60, 80)).save(on_disk)

    returned = _body(f"[PHOTO: {straight} | Alt text for the opening number.]")
    with patch.object(swap, "run_json_prompt",
                      side_effect=lambda *a, **k: {"body": returned, "photo_count": 1}):
        result = swap.swap_blog_photos(body=_body("[PHOTO: old.jpg | old alt]"),
                                       photo_paths=[on_disk])

    assert curly in result["body"], "the near miss repair did not run, so this proves nothing"
    assert result["findings_body"] == result["body"]
    assert straight not in result["findings_body"]
