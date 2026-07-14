"""Gallery-style alignment across the templates (2026-07-14).

Dan made gallery style a standing brand direction. The universal cleanup is: no
rose-gold rule lines, and the small detail text in the heavier Light weight
instead of the spindly Thin. These tests pin both across the reel chrome and the
two still templates. The retired Friday clip reel and the title-flanking rose-gold
motif are intentionally out of scope.
"""

from __future__ import annotations

from PIL import Image, ImageFont

from postroll.media import generate_reel_scroll as scroll_mod
from postroll.media import generate_reel_morph as morph_mod
from postroll.media import generate_reel_slider as slider_mod
from postroll.media import generate_reel_screen as screen_mod
from postroll.media import generate_story as story_mod
from postroll.media import generate_before_after as ba_mod


THIN_FACES = {"Thin", "Thin Italic", "UltraLight", "UltraLight Italic"}


def _row_has_color(img, y, color):
    px = img.convert("RGB")
    return any(px.getpixel((x, y)) == color for x in range(0, px.width, 3))


# ── Reel chrome: scroll / morph / slider share draw_branded_chrome ──────────

def _blank_frame(mod):
    return Image.new("RGB", (mod.CANVAS_W, mod.CANVAS_H), (40, 40, 40))


def _assert_no_chrome_rules(mod, *extra):
    frame = mod.draw_branded_chrome(
        _blank_frame(mod), "Test Event", "Org", "Venue", None, *extra
    )
    assert not _row_has_color(frame, mod.HEADER_H - 1, mod.ROSE_GOLD), \
        f"{mod.__name__}: rose-gold rule still at header boundary"
    assert not _row_has_color(frame, mod.CANVAS_H - mod.FOOTER_H, mod.ROSE_GOLD), \
        f"{mod.__name__}: rose-gold rule still at footer boundary"


def test_scroll_chrome_has_no_rose_gold_rules():
    _assert_no_chrome_rules(scroll_mod)


def test_morph_chrome_has_no_rose_gold_rules():
    _assert_no_chrome_rules(morph_mod)


def test_slider_chrome_has_no_rose_gold_rules():
    # slider's chrome also takes the photo band (photo_y, photo_h) for label placement.
    _assert_no_chrome_rules(slider_mod, slider_mod.HEADER_H, 900)


def test_screen_chrome_has_no_rose_gold_rules():
    # screen builds a transparent chrome overlay; extracted to build_chrome_overlay
    # so it is testable and consistent with its siblings.
    chrome = screen_mod.build_chrome_overlay("Test Event", "Org", "Venue", None)
    assert not _row_has_color(chrome, screen_mod.HEADER_H - 1, screen_mod.ROSE_GOLD)
    assert not _row_has_color(chrome, screen_mod.CANVAS_H - screen_mod.FOOTER_H, screen_mod.ROSE_GOLD)


# ── Detail text weight: Light, not Thin, everywhere ─────────────────────────

def _assert_detail_weight_not_thin(mod):
    face = ImageFont.truetype(mod.FONT_DETAIL, 26, index=mod.FONT_DETAIL_LIGHT).getname()
    assert face[1] not in THIN_FACES, f"{mod.__name__}: detail text still {face[1]}"


def test_all_templates_use_a_non_thin_detail_weight():
    for mod in (scroll_mod, morph_mod, slider_mod, screen_mod, ba_mod, story_mod):
        _assert_detail_weight_not_thin(mod)


# ── Still templates: no rose-gold divider bar ───────────────────────────────

def test_story_has_no_rose_gold_divider_bar(sample_photo, tmp_output):
    out = str(tmp_output / "story.png")
    story_mod.generate_story(str(sample_photo), "Event", "Org", "The Venue", out)
    img = Image.open(out).convert("RGB")
    # The old divider ran across the caption band at DIVIDER_Y, mid-canvas.
    assert not _row_has_color(img, 1480, story_mod.ROSE_GOLD_DARK), \
        "story still draws the rose-gold divider bar"


def test_before_after_has_no_rose_gold_rule(sample_photo, tmp_output):
    out = str(tmp_output / "ba.png")
    ba_mod.generate_before_after(
        str(sample_photo), str(sample_photo), out,
        event_name="Event", org="Org", venue="Venue",
    )
    img = Image.open(out).convert("RGB")
    # No full-width rose-gold rule anywhere: scan a set of rows across the frame.
    for y in range(0, img.height, 20):
        assert not _row_has_color(img, y, ba_mod.ROSE_GOLD), \
            f"before/after still draws a rose-gold rule at y={y}"
