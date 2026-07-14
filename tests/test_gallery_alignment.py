"""Gallery-style alignment across the templates (2026-07-14).

Dan made gallery style a standing brand direction. The universal cleanup is: no
rose-gold rule lines, and the small detail text in the heavier Light weight
instead of the spindly Thin. These tests pin both across the reel chrome and the
two still templates. The retired Friday clip reel and the title-flanking rose-gold
motif are intentionally out of scope.
"""

from __future__ import annotations

import pytest
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


# morph is intentionally excluded from the no-rules cleanup: it is now the
# program-plate reel, which uses rose-gold rules as part of its design (see the
# program-plate tests below).


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


def _landscape(color=(20, 60, 140), size=(300, 200)):
    return Image.new("RGB", size, color)


def test_before_after_background_is_flat_cream(sample_photo_dark, tmp_output):
    # On a dark event the old semi-transparent cream over a blurred photo read
    # grey. Flat cream must render true cream in the header band.
    out = str(tmp_output / "ba_cream.png")
    ba_mod.generate_before_after(
        str(sample_photo_dark), str(sample_photo_dark), out,
        event_name="Event", org="Org", venue="Venue",
    )
    img = Image.open(out).convert("RGB")
    assert img.getpixel((20, 20)) == ba_mod.CREAM, "before/after header is not flat cream"


def test_morph_background_is_cream_not_blurred_photo():
    # The letterbox above/below the centred photo must be cream, not a blurred
    # copy of the (blue) edit photo.
    canvas = morph_mod.prepare_photo(_landscape(), _landscape())
    assert canvas.convert("RGB").getpixel((10, 10)) == morph_mod.CREAM


def test_slider_background_is_cream_not_blurred_photo():
    canvas, _ = slider_mod.prepare_photo_simple(_landscape(), _landscape())
    assert canvas.convert("RGB").getpixel((10, 10)) == slider_mod.CREAM


def test_slider_stacked_after_background_is_cream():
    canvas = slider_mod.prepare_stacked_after(_landscape(), _landscape(), _landscape())
    assert canvas.convert("RGB").getpixel((10, 10)) == slider_mod.CREAM


def test_screen_background_is_cream():
    bg = screen_mod.build_background()
    assert bg.convert("RGB").getpixel((10, 10)) == screen_mod.CREAM


# ── Labels and dividers must survive the cream background ──────────────────
#
# Caught by rendering a real reel: the RAW/Edit labels were white and the slider's
# divider carried a dark shadow, both of which only worked because they sat on a
# dark blurred backdrop. On cream the labels vanished and the shadow left a stray
# dark line through the mat.

def _slider_frame(divider_x=540):
    photo = _landscape(size=(1500, 1000))          # 3:2, so it letterboxes onto cream
    raw_canvas, photo_y = slider_mod.prepare_photo_simple(photo, photo)
    edit_canvas, _ = slider_mod.prepare_photo_simple(photo, photo)
    font = slider_mod.load_font(
        slider_mod.FONT_DETAIL, slider_mod.LABEL_FONT_SIZE,
        index=slider_mod.FONT_DETAIL_BOLD,
    )
    frame = slider_mod.generate_frame(raw_canvas, edit_canvas, divider_x, font)
    return frame.convert("RGB"), photo_y


def _darkest_in(img, box):
    x0, y0, x1, y1 = box
    return min(min(img.getpixel((x, y))) for x in range(x0, x1, 2) for y in range(y0, y1, 2))


def test_slider_labels_are_dark_enough_to_read_on_cream():
    frame, _ = _slider_frame()
    label_y = int(slider_mod.CANVAS_H * 0.75)
    box = (slider_mod.LABEL_MARGIN, label_y, slider_mod.LABEL_MARGIN + 180, label_y + 40)
    assert _darkest_in(frame, box) < 120, "the Edit label is not legible on the cream mat"


def test_slider_divider_leaves_no_dark_line_across_the_cream():
    # In the cream band there is nothing to divide (both sides are the same cream),
    # so the divider must not leave a shadow streak across the mat.
    frame, photo_y = _slider_frame()
    y = photo_y // 2   # comfortably inside the cream above the photo
    darkest = min(min(frame.getpixel((x, y))) for x in range(0, slider_mod.CANVAS_W, 2))
    assert darkest > 200, "the divider's shadow is streaking through the cream mat"


def test_slider_labels_are_dark_enough_to_read_on_cream():
    assert slider_mod.LABEL_COLOR == slider_mod.TEXT_DARK


# ── morph is the program-plate Tuesday reel ─────────────────────────────────
#
# A printed-program page: masthead top-left on a rose-gold rule, the photo hung
# as a matted print, a crossfading BEFORE/AFTER placard, and a footer colophon.

def test_morph_prints_the_photo_matted_not_full_bleed():
    canvas = morph_mod.prepare_photo(_landscape(size=(1500, 1000)), _landscape())
    rgb = canvas.convert("RGB")
    assert rgb.getpixel((10, 10)) == morph_mod.CREAM, "top mat"
    # The print sits inside the side mat, hung at PRINT_Y, not filling the frame.
    assert rgb.getpixel((morph_mod.MAT // 2, morph_mod.PRINT_Y + 40)) == morph_mod.CREAM, \
        "side mat"
    mid_x = morph_mod.CANVAS_W // 2
    assert rgb.getpixel((mid_x, morph_mod.PRINT_Y + 40)) != morph_mod.CREAM, \
        "the print itself is missing"


def test_morph_has_masthead_and_footer_colophon_rules():
    frame = Image.new("RGB", (morph_mod.CANVAS_W, morph_mod.CANVAS_H), morph_mod.CREAM)
    out = morph_mod.draw_branded_chrome(frame, "Home'r Bust!", "Home'r Bust!",
                                        "David Geffen Hall Lobby", None)
    assert _row_has_color(out, morph_mod.RULE_Y, morph_mod.ROSE_GOLD), "masthead rule"
    assert _row_has_color(out, morph_mod.FOOTER_RULE_Y, morph_mod.ROSE_GOLD), "colophon rule"


def test_morph_caption_crossfades_through_empty():
    # BEFORE fades out, then AFTER fades in; they never overlap (which would garble
    # two different words in one spot).
    morph_mod.set_caption_state(0.30)
    assert morph_mod.BEFORE_ALPHA > 0.9 and morph_mod.AFTER_ALPHA < 0.05
    morph_mod.set_caption_state(0.50)
    assert morph_mod.BEFORE_ALPHA < 0.05 and morph_mod.AFTER_ALPHA < 0.05  # through empty
    morph_mod.set_caption_state(0.70)
    assert morph_mod.AFTER_ALPHA > 0.9 and morph_mod.BEFORE_ALPHA < 0.05


def test_morph_caption_wording_matches_the_friday_story():
    from postroll.media.generate_before_after import placard_text as ba_placard
    assert morph_mod.placard_text("RAW") == ba_placard("RAW")
    assert morph_mod.placard_text("Edit") == ba_placard("Edit")


# ── before/after labels must contrast with whatever is under them ───────────
#
# The RAW/Edit labels were hardcoded white. On Dan's Home'r Bust! frames they
# landed on a bright blue-and-white stage banner and vanished. The colour must be
# chosen from the pixels the label actually sits on.

def test_header_detail_lines_drops_org_when_it_equals_the_event():
    assert ba_mod.header_detail_lines("Home'r Bust!", "Home'r Bust!", "David Geffen Hall Lobby") \
        == ["David Geffen Hall Lobby"]
    assert ba_mod.header_detail_lines("Perpetual Light", "DCINY", "Carnegie Hall") \
        == ["DCINY", "Carnegie Hall"]
    assert ba_mod.header_detail_lines("A", " a ", "V") == ["V"]  # case/space insensitive


def test_before_after_subtitle_is_heavier_than_light():
    from postroll.media.generate_before_after import FONT_DETAIL, SUBTITLE_WEIGHT
    face = ImageFont.truetype(FONT_DETAIL, 15, index=SUBTITLE_WEIGHT).getname()
    assert face[1] not in ("Thin", "Thin Italic", "UltraLight", "UltraLight Italic",
                           "Light", "Light Italic")


def test_before_after_logo_is_large_enough_to_read(tmp_path):
    out = str(tmp_path / "logo.png")
    vivid = tmp_path / "v.jpg"
    Image.new("RGB", (1500, 1000), (30, 90, 200)).save(str(vivid), "JPEG")
    ba_mod.generate_before_after(str(vivid), str(vivid), out, event_name="E", org="O",
                                 venue="V", logo_path="postroll/assets/logo-black.png")
    img = Image.open(out).convert("RGB")
    # The logo sits in the bottom cream. Measure the dark-ink horizontal extent there.
    dark_x = [x for y in range(img.height - 120, img.height - 10, 2)
              for x in range(0, 1080, 2) if sum(img.getpixel((x, y))) < 300]
    assert dark_x, "no logo found in the footer"
    assert max(dark_x) - min(dark_x) > 320, "the logo is too small to read"


def test_placard_text_maps_states_to_gallery_wording():
    assert ba_mod.placard_text("RAW") == ("BEFORE", "UNEDITED CAPTURE")
    assert ba_mod.placard_text("Edit") == ("AFTER", "FINAL EDIT")
    assert ba_mod.placard_text("B&W")[0] == "B&W"


def test_before_after_is_left_aligned_program_plate(tmp_path):
    # Dan chose the left-aligned program-plate closing frame (matches the reel
    # body): masthead top-left on a rose-gold rule, left placards, footer colophon.
    vivid = tmp_path / "vivid.jpg"
    Image.new("RGB", (1500, 1000), (30, 90, 200)).save(str(vivid), "JPEG")
    out = str(tmp_path / "ba_left.png")
    ba_mod.generate_before_after(str(vivid), str(vivid), out,
                                 event_name="Event", org="Org", venue="Venue")
    img = Image.open(out).convert("RGB")

    # The masthead title's ink starts on the left, not centred.
    title_cols = [x for y in range(60, 260, 2) for x in range(0, 1080, 2)
                  if sum(img.getpixel((x, y))) < 300]
    assert title_cols and min(title_cols) < 220, "masthead title is not left-aligned"

    # A rose-gold rule under the masthead and a footer colophon rule near the bottom.
    def has_rose(y):
        return any(img.getpixel((x, y)) == ba_mod.ROSE_GOLD for x in range(0, 1080, 3))
    assert any(has_rose(y) for y in range(250, 420)), "no masthead rose-gold rule"
    assert any(has_rose(y) for y in range(img.height - 260, img.height - 60)), \
        "no footer colophon rule"

    # The caption placard word sits on the left, not centred.
    rows = _placard_word_rows(img, ba_mod.ROSE_GOLD)
    assert rows, "no caption word found"
    assert min(rows[0][1]) < 200, "the caption is not left-aligned"


def _placard_word_rows(img, rose):
    """Rows holding a caption word: rose-gold ink concentrated on the LEFT.

    Distinguishes the word from the full-width rose-gold rules (masthead/colophon),
    which span the whole frame.
    """
    rows = []
    for y in range(0, img.height, 2):
        xs = [x for x in range(0, img.width, 2) if img.getpixel((x, y)) == rose]
        if xs and max(xs) < img.width * 0.55:   # left-concentrated → a word, not a rule
            rows.append((y, xs))
    return rows


@pytest.mark.parametrize("colour", [(30, 90, 200), (238, 240, 245)])
def test_before_after_caption_reads_on_any_photo(tmp_path, colour):
    # The captions used to be drawn ON the photos, so they vanished on a busy or
    # bright frame. They now sit in a cream band above each print, in rose-gold, so
    # they are legible whether the photo is dark blue or near-white.
    photo = tmp_path / f"p{colour[0]}.jpg"
    Image.new("RGB", (1500, 1000), colour).save(str(photo), "JPEG")
    out = str(tmp_path / f"ba{colour[0]}.png")
    ba_mod.generate_before_after(str(photo), str(photo), out,
                                 event_name="E", org="O", venue="V")
    img = Image.open(out).convert("RGB")

    rows = _placard_word_rows(img, ba_mod.ROSE_GOLD)
    assert rows, "no caption word found"

    y, xs = rows[0]
    assert min(xs) < 200, "the caption is not left-aligned"

    # And it sits on cream, not on the photo.
    bg = [img.getpixel((x, y)) for x in range(0, img.width, 3)
          if img.getpixel((x, y)) != ba_mod.ROSE_GOLD]
    creamish = sum(1 for p in bg if p[0] > 230 and p[1] > 225 and p[2] > 215)
    assert creamish > len(bg) * 0.75, "the caption is on the photo, not a cream band"


# ── Thursday scroll reel: brand cream mat + hairline, like the collage ──────

def _photo_set(tmp_path, colour, n=4, size=(1500, 1000)):
    paths = []
    for i in range(n):
        p = tmp_path / f"s{colour[0]}_{i}.jpg"
        Image.new("RGB", size, colour).save(str(p), "JPEG")
        paths.append(str(p))
    return paths


def test_scroll_strip_uses_brand_cream_not_its_own_warmer_cream(tmp_path):
    # It filled the gaps with 240,235,228 while every other template used the brand
    # cream 252,250,247, so it was the one quietly off-brand surface.
    photos = _photo_set(tmp_path, (30, 90, 160), n=6)
    strip = scroll_mod.build_collage_strip(photos, seed=0)
    assert strip.convert("RGB").getpixel((5, 5)) == scroll_mod.CREAM


def test_scroll_reel_logo_reads_as_dark_ink_on_the_cream_footer():
    # The reel footer is cream (252,250,247) but the pipeline handed the reel the
    # WHITE logo, so Dan's wordmark rendered as white-on-cream: a ghost. Every other
    # template already used the black mark on cream. Measure the dark-ink extent in
    # the footer band the same way the before/after logo test does, so both the
    # colour and the size are pinned by the pixels rather than by the constant.
    from postroll.ai import generate_media as gm

    logo = scroll_mod.load_logo(gm.THURSDAY_REEL_LOGO)
    assert logo is not None, "the reel must ship with a logo asset"

    frame = scroll_mod.draw_branded_chrome(
        _blank_frame(scroll_mod), "Test Event", "Org", "Venue", logo
    )
    footer_top = scroll_mod.CANVAS_H - scroll_mod.FOOTER_H
    dark_x = [
        x
        for y in range(footer_top, scroll_mod.CANVAS_H)
        for x in range(scroll_mod.CANVAS_W)
        if sum(frame.getpixel((x, y))) < 600
    ]
    assert dark_x, "the logo is invisible on the cream footer"
    assert max(dark_x) - min(dark_x) > 320, "the logo is too small to read"


def test_scroll_photos_sit_in_an_even_mat_with_a_hairline(tmp_path):
    photos = _photo_set(tmp_path, (30, 90, 160), n=6)
    strip, cells = scroll_mod.build_collage_strip(photos, seed=0, return_layout=True)
    rgb = strip.convert("RGB")

    assert min(c["x"] for c in cells) == scroll_mod.MAT, "left mat"
    assert max(c["x"] + c["w"] for c in cells) == scroll_mod.CANVAS_W - scroll_mod.MAT, "right mat"

    top = min(cells, key=lambda c: c["y"])
    assert rgb.getpixel((top["x"] + top["w"] // 2, top["y"] - 1)) == scroll_mod.HAIRLINE, \
        "each print is framed by a hairline, as in the collage"
    assert rgb.getpixel((top["x"] + top["w"] // 2, top["y"])) != scroll_mod.HAIRLINE, \
        "the hairline must not eat into the photo"


# The before/after intentionally carries rose-gold rules again: it is now the
# left-aligned program plate (masthead rule + footer colophon), matching the reel
# body. See test_before_after_is_left_aligned_program_plate.
