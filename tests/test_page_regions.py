"""Split a program page so its small print survives the trip (#208, #200).

Measured on the real BLUDLINE page (#207, five runs per build): the shipped
path sends a 3024x4032 page capped to a 1568px long edge, which puts the
performer "Safa" exactly on the boundary of legibility. It reads as "5afa" on
every run. The same band of the page, sent as its own image, reads "Safa" on
every run.

The arithmetic behind the fix: a piece is capped by ITS OWN long edge. A
3024x4032 page scales by 1568/4032 = 0.389. Any full-width band of it scales by
1568/3024 = 0.518, a third more resolution on the same type, because the width
is now the long edge. That is the entire mechanism, and it means the useful
number of bands is the fewest that makes each band no taller than it is wide.
More bands buy nothing and cost a call each.

Two things this must not do, both learned the expensive way on #207:

* it must not cut a line of text, and a fixed grid does. A 2x2 grid scored
  21/28 where sending the page whole scored 28/28, because it sliced a
  two-column name list down the middle.
* it must not be keyed to a constant. The per-image budget belongs to the
  resolved model, and a fix pinned to 1568 would silently become a no-op the
  day the app moves to a model with a larger one.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from PIL import Image, ImageDraw

from postroll.media import page_regions as pr


def _page(tmp_path: Path, width=3024, height=4032, name="page.png",
          gutters=(0.5,)) -> Path:
    """A page of text lines with blank gutters at the given height fractions."""
    img = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(img)
    line_h, gap = max(2, height // 120), max(2, height // 90)
    y = gap
    while y < height - line_h:
        frac = y / height
        if not any(abs(frac - g) < 0.035 for g in gutters):
            draw.rectangle([width * 0.1, y, width * 0.9, y + line_h], fill="black")
        y += line_h + gap
    path = tmp_path / name
    img.save(path)
    return path


def _ink_rows(path: Path) -> set[int]:
    img = Image.open(path).convert("L")
    px = img.load()
    rows = set()
    step = max(1, img.width // 200)
    for y in range(img.height):
        for x in range(0, img.width, step):
            if px[x, y] < 128:
                rows.add(y)
                break
    return rows


# ── the budget belongs to the model ───────────────────────────────────────────

def test_the_budget_comes_from_the_resolved_model():
    assert pr.image_budget_for("claude-sonnet-4-6") == 1568


def test_a_more_capable_model_gets_a_bigger_budget():
    """Pinned to a constant, this fix silently becomes a no-op the day the app
    moves to a model that accepts more."""
    small = pr.image_budget_for("claude-sonnet-4-6")
    large = pr.image_budget_for("claude-opus-4-7")

    assert large > small, "the budget is hardcoded rather than read off the model"


def test_an_alias_resolves_before_the_budget_is_looked_up():
    from postroll.ai.claude_client import _resolve_model

    assert pr.image_budget_for("sonnet") == pr.image_budget_for(_resolve_model("sonnet"))


def test_an_unknown_model_falls_back_to_the_smallest_known_budget():
    """Guessing high would send images that get silently reduced again, which
    is the defect this exists to fix."""
    assert pr.image_budget_for("claude-not-a-real-model") == 1568


def test_every_model_the_app_actually_pins_declares_its_own_budget():
    """The sibling of test_the_model_the_app_actually_pins_is_priced (#359).

    Pricing has had this guard for a while; the budget table had none, and the
    fallback for a model nobody listed is the SMALL tier. So repinning to a
    high-resolution model without touching this file silently shrinks every
    program page before it is sent, which is exactly the no-op the module
    docstring says must not be allowed to happen, with no error and nothing
    failing.

    The nearby alias check cannot catch it: both sides of that assertion come
    from the same lookup, so it passes just as happily when both fall through
    to the default (L70).
    """
    from postroll.ai.claude_client import _MODEL_ALIASES, _resolve_model

    for alias in _MODEL_ALIASES:
        model = _resolve_model(alias)
        assert pr.explicit_image_budget(model) is not None, (
            f"{alias} resolves to {model}, which has no declared image budget, "
            f"so it would quietly use the {pr.DEFAULT_IMAGE_BUDGET}px small tier"
        )


def test_one_implementation_decides_what_a_dated_model_id_reduces_to():
    """#361: this rule lived in two files, as a regex here and a slice there.

    They agree on every id in use today and are free to disagree on the next
    one, and a disagreement surfaces as a wrong cost figure or a wrongly sized
    image rather than as an error, so nothing would flag it.
    """
    from postroll.ai import usage_log

    assert pr.base_model is usage_log.base_model


# ── when splitting is worth it ────────────────────────────────────────────────

def test_a_page_already_within_the_budget_is_left_alone(tmp_path):
    page = _page(tmp_path, width=1200, height=1400)

    regions = pr.split_page(page, tmp_path / "out", budget=1568)

    assert regions == [page], "a page that needs no help was re-encoded anyway"


def test_a_tall_page_is_split_into_bands(tmp_path):
    page = _page(tmp_path, width=3024, height=4032)

    regions = pr.split_page(page, tmp_path / "out", budget=1568)

    assert len(regions) == 2, "3024x4032 needs exactly two bands to be square-ish"


def test_splitting_actually_raises_the_delivered_resolution(tmp_path):
    """The guard against a fix that ships, passes, and changes nothing."""
    page = _page(tmp_path, width=3024, height=4032)
    whole = 1568 / 4032

    regions = pr.split_page(page, tmp_path / "out", budget=1568)

    for r in regions:
        w, h = Image.open(r).size
        assert 1568 / max(w, h) > whole * 1.2, \
            f"{r.name} delivers no more resolution than sending the whole page"


def test_a_wide_page_is_split_the_other_way(tmp_path):
    page = _page(tmp_path, width=4032, height=3024, gutters=(0.5,))

    regions = pr.split_page(page, tmp_path / "out", budget=1568)

    assert len(regions) == 2
    for r in regions:
        w, h = Image.open(r).size
        assert w < 4032, "a wide page was banded along the wrong axis"


# ── the splits must not damage the text ───────────────────────────────────────

def test_a_split_lands_in_the_gutter_not_just_any_line_gap(tmp_path):
    """Asserting only "the seam is not on ink" is vacuous: ordinary text has a
    blank row between every line, so a midpoint split satisfies it by accident
    and the test passes with the seam search deleted. What has to be true is
    that the seam finds the WIDE gap, since a one-line gap plus overlap still
    clips a descender.

    The gutter is deliberately off-centre so the ideal midpoint is not already
    the right answer.
    """
    height = 4032
    page = _page(tmp_path, width=3024, height=height, gutters=(0.44,))
    gutter_lo, gutter_hi = int(0.405 * height), int(0.475 * height)

    bounds = pr.band_bounds(page, count=2)
    seam = bounds[0][1] - int((height / 2) * pr.BAND_OVERLAP)

    assert gutter_lo <= seam <= gutter_hi, (
        f"seam at {seam} ignored the gutter at {gutter_lo}-{gutter_hi} "
        f"and split at the midpoint instead"
    )


def test_no_ink_is_lost_between_the_bands(tmp_path):
    page = _page(tmp_path, width=3024, height=4032)
    ink = _ink_rows(page)

    covered: set[int] = set()
    for start, end in pr.band_bounds(page, count=2):
        covered |= set(range(start, end))

    assert ink <= covered, "rows of text fell into the gap between two bands"


def test_consecutive_bands_overlap_so_a_seam_line_survives_whole(tmp_path):
    page = _page(tmp_path, width=3024, height=4032)

    bounds = pr.band_bounds(page, count=2)

    for (a_start, a_end), (b_start, b_end) in zip(bounds, bounds[1:]):
        assert b_start < a_end, "a line sitting on the seam is cut in both bands"


def test_a_page_with_no_whitespace_at_all_still_splits(tmp_path):
    """Solid ink has no good seam. Refusing to split would quietly leave the
    page on the failing path, so it splits evenly and accepts the risk."""
    solid = tmp_path / "solid.png"
    Image.new("RGB", (3024, 4032), "black").save(solid)

    bounds = pr.band_bounds(solid, count=2)

    assert len(bounds) == 2
    assert bounds[0][1] > 0


# ── the regions are usable ────────────────────────────────────────────────────

def test_each_region_is_written_and_readable(tmp_path):
    page = _page(tmp_path, width=3024, height=4032)

    regions = pr.split_page(page, tmp_path / "out", budget=1568)

    for r in regions:
        assert r.exists()
        Image.open(r).verify()


def test_regions_are_named_in_reading_order(tmp_path):
    page = _page(tmp_path, width=3024, height=4032)

    regions = pr.split_page(page, tmp_path / "out", budget=1568)

    assert regions == sorted(regions), "an out-of-order page confuses the model"


# ── wired into the shipping OCR path ──────────────────────────────────────────

def test_the_ocr_path_actually_sends_bands_for_an_oversized_page(tmp_path, monkeypatch):
    """Built is not wired. Without this the splitter can be correct, tested and
    never once reached by a real program upload."""
    import postroll.ai.ocr_program as op

    page = _page(tmp_path, width=3024, height=4032, name="program.png")
    sent: list[list[str]] = []

    def fake_run_json(prompt, timeout=600, image_paths=None, **kwargs):
        sent.append(list(image_paths or []))
        return {"performers": [], "pieces": []}

    monkeypatch.setattr(op, "run_json_prompt", fake_run_json)
    op.extract_program([str(page)])

    assert sent, "the OCR path made no call at all"
    assert len(sent[0]) == 2, (
        f"a 3024x4032 page reached the model as {len(sent[0])} image(s); "
        "the whole-page path is the one that misreads names"
    )


def test_the_ocr_path_leaves_a_small_page_alone(tmp_path, monkeypatch):
    import postroll.ai.ocr_program as op

    page = _page(tmp_path, width=1200, height=1400, name="small.png")
    sent: list[list[str]] = []

    def fake_run_json(prompt, timeout=600, image_paths=None, **kwargs):
        sent.append(list(image_paths or []))
        return {"performers": [], "pieces": []}

    monkeypatch.setattr(op, "run_json_prompt", fake_run_json)
    op.extract_program([str(page)])

    assert len(sent[0]) == 1, "a page that needs no splitting was split anyway"


def test_a_page_that_cannot_be_split_is_still_read_and_says_so(tmp_path, monkeypatch, capsys):
    """A page we cannot split is still a page we can read, just on the path
    that misreads small type. Failing the whole upload would lose the program;
    staying silent would hide that the names on it are less trustworthy."""
    import postroll.ai.ocr_program as op

    page = _page(tmp_path, width=3024, height=4032, name="broken.png")

    def boom(*a, **kw):
        raise OSError("cannot write band")

    monkeypatch.setattr(op, "split_page", boom)
    sent: list[list[str]] = []

    def fake_run_json(prompt, timeout=600, image_paths=None, **kwargs):
        sent.append(list(image_paths or []))
        return {"performers": [], "pieces": []}

    monkeypatch.setattr(op, "run_json_prompt", fake_run_json)
    op.extract_program([str(page)])

    assert len(sent[0]) == 1, "the page was dropped instead of being sent whole"
    err = capsys.readouterr().err.lower()
    assert "misread" in err, "the reader is not told the small print is less reliable"
