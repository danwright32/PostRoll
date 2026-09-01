"""#1128 (Phase 0b): the staged photographs are still on disk when the checks run.

Both blog scripts stage every photograph into a `TemporaryDirectory`, send them
to the model, and then close the block. Everything after it, the dash strip, the
name and second-person and contraction fixes, the near-miss filename repair and
`check_blog` itself, runs with the staging directory already deleted.

That is invisible today because none of those steps opens a photograph. The alt
text repairer does: rule 4 is a rewrite with the photograph ATTACHED, so it
needs one file per marker on disk at the moment it runs. Moving the tail inside
the block is the move nothing else in this milestone works without.

The check is written as a spy on `check_blog` rather than as a source shape
assertion, because what has to hold is a property of the RUN (the files exist
when the checks run) and not of the indentation. Re-outdenting the tail turns
this red; that is the registered guard mutation.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest
from PIL import Image

from postroll.ai import generate_blog as gb
from postroll.ai import swap_blog_photos as swap


PROSE = "It's a paragraph about the evening in the room."


@pytest.fixture
def photos(tmp_path):
    made = []
    for i in range(2):
        p = tmp_path / f"DSC{i:04d}.jpg"
        Image.new("RGB", (60, 40), (40 + i, 60, 80)).save(p)
        made.append(str(p))
    return made


def _spies():
    """Capture the staged paths the model was sent, and re-stat them later.

    `image_paths` IS `resolved`: the staged copies inside the tempdir. Asserting
    they still exist when `check_blog` is called is exactly the property the
    repairer needs, and it cannot be satisfied by a body that happens to parse.
    """
    seen: dict[str, list[str]] = {"staged": [], "alive_at_check": [], "checked": []}

    def watch_check(real):
        def _spy(body, **kwargs):
            seen["checked"].append(body)
            seen["alive_at_check"] = [p for p in seen["staged"] if Path(p).exists()]
            return real(body, **kwargs)
        return _spy

    return seen, watch_check


def test_generate_still_has_every_photograph_when_check_blog_runs(photos):
    seen, watch_check = _spies()

    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None,
                      image_paths=None, image_labels=None, **kwargs):
        seen["staged"] = list(image_paths or [])
        return {"body": PROSE, "photo_count": len(image_paths or [])}

    def refuse(*a, **k):
        raise AssertionError("live prompt call; stub it rather than paying for it")

    with patch.object(gb, "run_json_prompt", side_effect=fake_run_json), \
         patch.object(gb, "run_prompt", side_effect=refuse), \
         patch.object(gb, "check_blog_targeted",
                      side_effect=watch_check(gb.check_blog_targeted)):
        gb.generate_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            photo_paths=photos, skip_humanizer=True, skip_voice_pass=True,
        )

    assert seen["checked"], "check_blog was never reached, so this proves nothing"
    assert seen["staged"], "no staged photographs were captured"
    assert seen["alive_at_check"] == seen["staged"], (
        "the staged photographs were deleted before check_blog ran: "
        f"{len(seen['alive_at_check'])} of {len(seen['staged'])} survived. The "
        "finalisation tail runs outside the TemporaryDirectory block, so the "
        "alt text repairer would have no photograph to attach."
    )


def test_the_swap_still_has_every_photograph_when_check_blog_runs(photos):
    seen, watch_check = _spies()

    def fake_run_json(prompt, timeout=300, image_paths=None, image_labels=None,
                      **kwargs):
        seen["staged"] = list(image_paths or [])
        return {"body": PROSE, "photo_count": len(image_paths or [])}

    with patch.object(swap, "run_json_prompt", side_effect=fake_run_json), \
         patch.object(swap, "check_blog_targeted",
                      side_effect=watch_check(swap.check_blog_targeted)):
        swap.swap_blog_photos(body=f"{PROSE}\n\n[PHOTO: old.jpg | old alt]",
                              photo_paths=photos)

    assert seen["checked"], "check_blog was never reached, so this proves nothing"
    assert seen["staged"], "no staged photographs were captured"
    assert seen["alive_at_check"] == seen["staged"], (
        "the staged photographs were deleted before check_blog ran: "
        f"{len(seen['alive_at_check'])} of {len(seen['staged'])} survived."
    )
