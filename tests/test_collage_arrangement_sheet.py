"""#923: the sheet shows the POOL, not the one arrangement that was drawn.

`PhoneChromeOverlay` draws the phone's chrome over the collage that WAS
rendered, so it answers "is this frame safe". It cannot answer "is every
arrangement the chooser might hand me safe", because the pool the arrangement
came from is never drawn at all. That is why #921 survived despite the overlay
existing: the collage on screen looked fine, and the one that buried three of
seven photographs was one press of "New layout" away.

What has to be true of the sheet, and is checked here rather than looked at:

  * it draws every arrangement the crop budget OFFERS, including the ones the
    chrome filter rejects, because a sheet of survivors cannot show what the
    filter does and would look exactly like a filter that rejects nothing;
  * its verdicts are the filter's own, not a second opinion computed beside it;
  * the tiles are real, so a run that quietly drew nothing does not read as a
    clean sheet.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

from postroll.media.generate_collage import (
    MOSTLY_HIDDEN,
    chrome_safe_collage_splits,
    fitting_collage_splits,
    hidden_by_the_caption,
)

REPO_ROOT = Path(__file__).resolve().parent.parent


def _tool():
    """The tool, imported from its path: `tools/` is not a package."""
    spec = importlib.util.spec_from_file_location(
        "render_collage_arrangements",
        REPO_ROOT / "tools" / "render_collage_arrangements.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


#: Seven 3:2 landscapes, the set #921 was measured on and the shape Dan shoots.
RATIOS = [1.5] * 7


def test_the_pool_this_is_drawn_from_still_contains_a_rejected_arrangement():
    """The precondition. Every check below is satisfied by a pool where nothing
    is rejected, and that pool would make the sheet's whole purpose invisible
    while every assertion passed (L159)."""
    offered = fitting_collage_splits(7, RATIOS)
    kept = chrome_safe_collage_splits(7, RATIOS)

    assert offered, "the crop budget offers nothing for seven photographs"
    assert len(kept) < len(offered), (
        "no arrangement for seven photographs is rejected any more, so this "
        "sheet cannot show the filter doing anything")


def test_the_sheet_draws_every_arrangement_the_chooser_could_offer():
    sheet, entries = _tool().build_sheet(RATIOS, [])

    offered = fitting_collage_splits(7, RATIOS)
    assert len(entries) == len(offered), (
        f"the sheet drew {len(entries)} arrangement(s) and the chooser can "
        f"offer {len(offered)}, so what is missing is exactly what nobody sees")
    assert [entry["split"] for entry in entries] == list(offered)

    assert sheet.width > 0 and sheet.height > 0
    assert len(sheet.convert("RGB").getcolors(maxcolors=1 << 20) or []) > 20, (
        "the sheet is nearly one colour, so it is a picture of nothing")


def test_the_rejected_arrangements_are_drawn_too():
    """A sheet of survivors would look identical to a filter that rejects
    nothing, which is the thing this exists to make visible."""
    _, entries = _tool().build_sheet(RATIOS, [])

    rejected = [entry for entry in entries if not entry["kept"]]
    assert rejected, "no rejected arrangement is on the sheet"
    assert any(entry["hidden"] > MOSTLY_HIDDEN for entry in rejected)


def test_the_verdicts_are_the_filters_own():
    """Not a second opinion computed beside it. A sheet whose labels came from
    a reimplementation would eventually disagree with the code that actually
    chooses, and it would disagree silently (L107)."""
    _, entries = _tool().build_sheet(RATIOS, [])

    kept = {repr(split) for split in chrome_safe_collage_splits(7, RATIOS)}
    for entry in entries:
        assert entry["kept"] == (repr(entry["split"]) in kept), entry["split"]
        assert entry["hidden"] == hidden_by_the_caption(entry["split"], RATIOS)


def test_every_verdict_agrees_with_the_line_it_is_drawn_from():
    _, entries = _tool().build_sheet(RATIOS, [])

    for entry in entries:
        if entry["kept"]:
            assert entry["hidden"] <= MOSTLY_HIDDEN, entry["split"]
        else:
            assert entry["hidden"] > MOSTLY_HIDDEN, entry["split"]


def test_a_label_says_the_verdict_the_reading_and_the_shape():
    """All three, because the sheet is read by looking: a tile that showed only
    a percentage would leave the reader working out which arrangement it was
    about, and one showing only the split would not say why it was rejected."""
    tool = _tool()
    split = next(s for s in fitting_collage_splits(7, RATIOS)
                 if hidden_by_the_caption(s, RATIOS) > MOSTLY_HIDDEN)

    verdict_line, split_line = tool.label_for(split, RATIOS, kept=False)

    assert "REJECTED" in verdict_line
    assert "%" in verdict_line
    assert str(list(split[0])) in split_line and str(list(split[1])) in split_line

    kept_line, _ = tool.label_for(split, RATIOS, kept=True)
    assert "KEPT" in kept_line, "the two verdicts have to read differently"


def test_a_count_with_no_arrangements_at_all_refuses_rather_than_writing_nothing():
    """An empty sheet is indistinguishable from a pool with nothing wrong in it
    (L98), so the tool says there is no pool rather than saving a blank.

    Eleven 3:2 landscapes is a real one: the crop budget admits no arrangement
    for that count at that shape, which is worth knowing when the sheet is
    reached for and answers nothing.
    """
    tool = _tool()
    impossible = [1.5] * 11

    assert not fitting_collage_splits(11, impossible), (
        "eleven landscapes now have a pool, so this no longer drives the "
        "refusal and needs a count that does")

    with pytest.raises(SystemExit, match="no arrangement"):
        tool.build_sheet(impossible, [])


def test_the_tiles_come_from_the_planner_the_renderer_uses(tmp_path):
    """A tile drawn by geometry written beside the tool would show a layout the
    collage does not draw, and the sheet would be reassuring about a pool that
    does not exist (L107)."""
    tool = _tool()
    split = fitting_collage_splits(7, RATIOS)[0]

    tile = tool.draw_arrangement(split, RATIOS, [])

    from postroll.media.generate_collage import CANVAS_H, CANVAS_W

    assert tile.size == (CANVAS_W, CANVAS_H), (
        "the tile is not the canvas the collage is rendered on, so what it "
        "shows about the chrome bands is about a different frame")
