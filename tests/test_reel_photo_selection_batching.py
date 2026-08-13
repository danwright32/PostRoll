"""#470: the selector built for 50+ photo days must survive 50+ photo days.

`select_reel_photos` attached the entire photo set to one API request with no
measurement against either real ceiling: the roughly 32 MB request body the OCR
path already batches for, and the per-request image count. So the one feature
that exists specifically for large shows was the one most likely to be refused
outright on them (L87, the same shape as #216 fixed for OCR and never swept to
this sibling). Both callers catch the failure and degrade quietly, so at scale
it simply stopped running.

Sharding a SELECTION request is not the same as sharding an OCR request, and
getting that wrong is its own defect. The prompt's first rule is a cross-item
one: cover the full arc of the show, and do not take ten near-identical frames
from one section. Split naively, each call sees a fraction of the night, tries
to cover "the whole arc" from inside it, and the merged result over-samples
whichever fraction happened to be busiest. Nothing errors and the output looks
complete, which is exactly the failure #219 was.

So the batches here are CONTIGUOUS CHRONOLOGICAL SLICES with a PROPORTIONAL
share of the total, and each call is told it is looking at one slice. Coverage
of the whole show then holds by construction rather than by asking a model that
cannot see the rest of the night to guarantee it.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from PIL import Image

from postroll.ai import select_reel_photos as srp
from postroll.ai.ocr_batching import batch_images


@pytest.fixture
def photos(tmp_path):
    def _make(count: int) -> list[str]:
        made = []
        for i in range(count):
            p = tmp_path / f"{i:04d}.jpg"
            Image.new("RGB", (48, 32), (i % 255, 90, 140)).save(p)
            made.append(str(p))
        return made
    return _make


def _run(paths, count, *, max_images=None):
    """Select, capturing every request the selector made."""
    calls: list[dict] = []

    def fake_run_json(prompt, timeout=600, image_paths=None, image_labels=None,
                      step=None, **kw):
        calls.append({"prompt": prompt, "images": list(image_paths or [])})
        # Take the first N of whatever this call was shown, by the index the
        # prompt labelled them with.
        wanted = srp._count_asked_for(prompt)
        return {"selected_indices": list(range(wanted)),
                "rationale": "first few"}

    with patch("postroll.ai.select_reel_photos.run_json_prompt",
               side_effect=fake_run_json):
        if max_images is not None:
            with patch.object(srp, "MAX_REQUEST_IMAGES", max_images):
                selected = srp.select_reel_photos(paths, count=count)
        else:
            selected = srp.select_reel_photos(paths, count=count)
    return selected, calls


# ── the small case must not get more expensive ────────────────────────────────

def test_a_set_that_fits_is_still_one_request(photos):
    _, calls = _run(photos(30), 20)

    assert len(calls) == 1


def test_a_set_smaller_than_the_target_makes_no_request_at_all(photos):
    paths = photos(5)
    selected, calls = _run(paths, 20)

    assert calls == []
    assert [str(p) for p in selected] == paths


# ── the ceilings are respected ────────────────────────────────────────────────

def test_a_set_over_the_image_cap_is_split(photos):
    _, calls = _run(photos(30), 10, max_images=10)

    assert len(calls) == 3


def test_no_request_carries_more_images_than_the_cap(photos):
    _, calls = _run(photos(30), 10, max_images=10)

    for call in calls:
        assert len(call["images"]) <= 10


def test_batch_images_caps_on_count_as_well_as_bytes(photos):
    # The byte limit alone lets a hundred small photos through, and the count
    # ceiling is a separate refusal.
    batches = batch_images(photos(25), limit_bytes=25_000_000, max_images=10)

    assert [len(b) for b in batches] == [10, 10, 5]


def test_batch_images_without_a_count_cap_is_unchanged(photos):
    # OCR's existing callers pass no count, and must keep behaving as they did.
    batches = batch_images(photos(25), limit_bytes=25_000_000)

    assert len(batches) == 1


# ── the split preserves what the prompt promised ──────────────────────────────

def test_the_batches_are_contiguous_slices_of_the_evening(photos):
    # Not interleaved and not shuffled: each call must see one continuous
    # stretch of the night, or "cover this stretch" means nothing.
    paths = photos(30)
    _, calls = _run(paths, 10, max_images=10)

    from pathlib import Path

    seen = [Path(p).name for call in calls for p in call["images"]]
    # Staged copies are named NNNN_original.jpg, so the leading number is the
    # photo's position in the evening.
    order = [int(name.split("_", 1)[0]) for name in seen]
    assert order == sorted(order), order
    assert order == list(range(len(order))), "a photo was dropped or repeated"


def test_exactly_the_requested_number_comes_back(photos):
    selected, _ = _run(photos(30), 10, max_images=10)

    assert len(selected) == 10


def test_the_shares_asked_for_sum_to_the_target(photos):
    _, calls = _run(photos(30), 10, max_images=10)

    assert sum(srp._count_asked_for(c["prompt"]) for c in calls) == 10


def test_a_share_is_proportional_to_the_slice(photos):
    # 25 photos, cap 10, so slices of 10, 10, 5 and a target of 10 means
    # 4, 4, 2 rather than an even split that over-samples the short tail.
    _, calls = _run(photos(25), 10, max_images=10)

    assert [srp._count_asked_for(c["prompt"]) for c in calls] == [4, 4, 2]


def test_the_result_stays_in_chronological_order(photos):
    # The reel is cut in this order, so a scrambled merge re-cuts the evening
    # out of sequence.
    paths = photos(30)
    selected, _ = _run(paths, 10, max_images=10)

    assert [str(p) for p in selected] == sorted(str(p) for p in selected)


def test_every_selected_photo_came_from_the_input(photos):
    paths = photos(30)
    selected, _ = _run(paths, 10, max_images=10)

    assert set(str(p) for p in selected) <= set(paths)


def test_no_photo_is_selected_twice(photos):
    selected, _ = _run(photos(30), 10, max_images=10)

    assert len(set(selected)) == len(selected)


# ── each call is told what it is actually looking at ──────────────────────────

def test_a_split_call_is_told_it_is_seeing_one_stretch(photos):
    # Otherwise it tries to cover the whole evening from inside a fifth of it,
    # and the merged result over-samples whichever fifth was busiest.
    _, calls = _run(photos(30), 10, max_images=10)

    assert "stretch" in calls[0]["prompt"].lower()


def test_a_single_call_is_still_asked_to_cover_the_whole_show(photos):
    _, calls = _run(photos(30), 20)

    assert "full arc" in calls[0]["prompt"]
    assert "stretch of the evening" not in calls[0]["prompt"]


def test_a_split_call_says_which_stretch_it_is(photos):
    _, calls = _run(photos(30), 10, max_images=10)

    assert "1 of 3" in calls[0]["prompt"]
    assert "3 of 3" in calls[2]["prompt"]
