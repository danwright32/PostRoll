"""#1130 (Phase 2a): two photographs cannot share one label.

Both blog scripts build `photo_filenames` by stripping the `NNN_` staging prefix
off each staged basename, so two source photos from different folders sharing a
basename produce two identical labels. `_marker_filename_findings` then folds
them into one dict key and the pair silently collapses: one photograph becomes
unreportable as never placed.

Today that is a quiet hole in a report. For the repairer it is fatal. Attaching
the photograph means resolving a marker filename back to ONE file on disk, and
under a collision it attaches the wrong one, which reads as correct and is not.

So the scripts refuse, loudly, before any paid call (L75). The message names
both full source paths, because "two photos share a name" is not something
anyone can act on without knowing which two.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image

from postroll.ai import generate_blog as gb
from postroll.ai import swap_blog_photos as swap


@pytest.fixture
def colliding(tmp_path):
    """The same basename in two folders, which is an ordinary way to shoot."""
    made = []
    for folder in ("day 1", "day 2"):
        directory = tmp_path / folder
        directory.mkdir()
        path = directory / "DSC4821.jpg"
        Image.new("RGB", (60, 40), (40, 60, 80)).save(path)
        made.append(str(path))
    return made


@pytest.fixture
def distinct(tmp_path):
    made = []
    for i, folder in enumerate(("day 1", "day 2")):
        directory = tmp_path / folder
        directory.mkdir()
        path = directory / f"DSC482{i}.jpg"
        Image.new("RGB", (60, 40), (40, 60, 80)).save(path)
        made.append(str(path))
    return made


def _refuse_paid_calls(monkeypatch, module):
    def refuse(*args, **kwargs):
        raise AssertionError(
            "a paid call was made AFTER a collision that should have refused; "
            "the refusal has to come before the money is spent (L75)")
    monkeypatch.setattr(module, "run_json_prompt", refuse)


def test_generation_refuses_two_photographs_that_share_a_name(colliding, monkeypatch):
    _refuse_paid_calls(monkeypatch, gb)

    with pytest.raises(ValueError) as caught:
        gb.generate_blog(event="E", org="O", venue="V", date="2026-04-05",
                         program={"performers": [], "pieces": []},
                         photo_paths=colliding,
                         skip_humanizer=True, skip_voice_pass=True)

    message = str(caught.value)
    for path in colliding:
        assert path in message, (
            f"the refusal does not name {path}. Two photos sharing a name is "
            f"not actionable without knowing which two: {message}")


def test_the_swap_refuses_two_photographs_that_share_a_name(colliding, monkeypatch):
    _refuse_paid_calls(monkeypatch, swap)

    with pytest.raises(ValueError) as caught:
        swap.swap_blog_photos(body="Some prose.\n\n[PHOTO: old.jpg | old alt]",
                              photo_paths=colliding)

    message = str(caught.value)
    for path in colliding:
        assert path in message, message


def test_a_name_differing_only_in_punctuation_still_collides(tmp_path, monkeypatch):
    """Folded, not compared raw.

    `repair_marker_filenames` folds typographic quotes onto ASCII ones, so two
    files whose names differ only that way resolve to the same marker and the
    repairer cannot tell which to attach. Comparing raw names would let exactly
    the pair the fold creates through.
    """
    _refuse_paid_calls(monkeypatch, swap)
    made = []
    for folder, name in (("a", 'Cast “Live”.jpg'), ("b", 'Cast "Live".jpg')):
        directory = tmp_path / folder
        directory.mkdir()
        path = directory / name
        Image.new("RGB", (60, 40), (40, 60, 80)).save(path)
        made.append(str(path))

    with pytest.raises(ValueError) as caught:
        swap.swap_blog_photos(body="Some prose.\n\n[PHOTO: old.jpg | old alt]",
                              photo_paths=made)
    assert "Cast" in str(caught.value)


@pytest.mark.parametrize("module,call", [
    ("generate", "generate"),
    ("swap", "swap"),
])
def test_distinct_names_are_not_refused(distinct, module, call, monkeypatch):
    """The control. A refusal that fires on every run refuses nothing (L159)."""
    if call == "generate":
        monkeypatch.setattr(gb, "run_json_prompt",
                            lambda *a, **k: {"body": "It's a paragraph.",
                                             "photo_count": 2})
        gb.generate_blog(event="E", org="O", venue="V", date="2026-04-05",
                         program={"performers": [], "pieces": []},
                         photo_paths=distinct,
                         skip_humanizer=True, skip_voice_pass=True)
    else:
        monkeypatch.setattr(swap, "run_json_prompt",
                            lambda *a, **k: {"body": "It's a paragraph.",
                                             "photo_count": 2})
        swap.swap_blog_photos(body="It's prose.\n\n[PHOTO: old.jpg | old alt]",
                              photo_paths=distinct)
