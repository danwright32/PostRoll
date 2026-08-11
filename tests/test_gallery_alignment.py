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
from postroll.media import program_plate as plate_mod
from postroll.media import generate_reel_slider as slider_mod
from postroll.media import generate_reel_screen as screen_mod
from postroll.media import generate_story as story_mod
from postroll.media import generate_before_after as ba_mod


THIN_FACES = {"Thin", "Thin Italic", "UltraLight", "UltraLight Italic"}


def _mac_fonts_available() -> bool:
    """Whether the macOS system fonts the templates render with can be opened.

    The app is macOS-only, so these are always present on Dan's machine, but the
    Linux CI runner has no HelveticaNeue or SignPainter. Tests that assert on real
    font rendering (weight, laid-out ink) cannot mean anything without them, so
    they skip there rather than erroring on a missing resource.
    """
    try:
        ImageFont.truetype(scroll_mod.FONT_DETAIL, 12, index=scroll_mod.FONT_DETAIL_LIGHT)
        ImageFont.truetype(scroll_mod.FONT_SCRIPT, 12)
        return True
    except OSError:
        return False


requires_mac_fonts = pytest.mark.skipif(
    not _mac_fonts_available(),
    reason="renders with macOS system fonts (HelveticaNeue/SignPainter), absent on Linux CI",
)


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


# The slider is deliberately absent from this group. It draws the program plate
# now (#164), and the plate's rose-gold rules are the design rather than a
# leftover, so the assertion that used to sit here is inverted and lives with
# the other plate checks below.


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


@requires_mac_fonts
def test_all_templates_use_a_non_thin_detail_weight():
    # The morph draws its detail line through the shared plate, so that is
    # the module carrying the weight it uses (#164).
    for mod in (scroll_mod, plate_mod, screen_mod, ba_mod, story_mod):
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
    assert canvas.convert("RGB").getpixel((10, 10)) == plate_mod.CREAM


def test_slider_background_is_cream_not_blurred_photo():
    _, canvases = slider_mod.hang_the_states(_landscape(), _landscape(), _landscape())
    assert canvases[0].convert("RGB").getpixel((10, 10)) == plate_mod.CREAM


def test_screen_background_is_cream():
    bg = screen_mod.build_background()
    assert bg.convert("RGB").getpixel((10, 10)) == screen_mod.CREAM


# ── Labels and dividers must survive the cream background ──────────────────
#
# Caught by rendering a real reel: the RAW/Edit labels were white and the slider's
# divider carried a dark shadow, both of which only worked because they sat on a
# dark blurred backdrop. On cream the labels vanished and the shadow left a stray
# dark line through the mat.

def _slider_frame(progress=0.5, rightward=True):
    """A mid-sweep frame of the 3-photo Tuesday reel, with its chrome."""
    photo = _landscape(size=(1500, 1000))          # 3:2
    rect, canvases = slider_mod.hang_the_states(photo, photo, photo)
    frame = slider_mod.swept(canvases[0], canvases[1], rect, progress, rightward)
    before, after = slider_mod.placard_alphas(progress)
    frame = slider_mod.draw_plate_chrome(
        frame, "Event", "Org", "The Venue", None, rect,
        [(slider_mod.STATES[0], before), (slider_mod.STATES[1], after)])
    return frame.convert("RGB"), rect


def _darkest_in(img, box):
    x0, y0, x1, y1 = box
    return min(min(img.getpixel((x, y))) for x in range(x0, x1, 2) for y in range(y0, y1, 2))


def test_slider_caption_is_dark_enough_to_read_on_cream():
    # The reel's caption placard, held at full opacity. The old RAW/Edit labels
    # this replaces shipped white once and were invisible on the mat (#163), so
    # the check is on the rendered pixels rather than on a colour constant.
    frame, rect = _slider_frame(progress=0.0)
    y = rect[1] + rect[3] + slider_mod.PLACARD_TOP_GAP
    box = (slider_mod.MAT, y, slider_mod.MAT + 200, y + slider_mod.PLACARD_BLOCK_H)

    assert _darkest_in(frame, box) < 160, "the caption is not legible on the cream mat"


def test_slider_divider_never_touches_the_cream_mat():
    # Stronger than the old assertion, and true by construction now: the sweep
    # is clipped to the print, so there is no row of mat it can reach. The old
    # divider ran the full height of the canvas and its shadow streaked the mat.
    frame, rect = _slider_frame(progress=0.5)

    # Rows that are bare mat: between the masthead rule and the top of the
    # print, and below the caption but above the colophon rule. Sampling higher
    # would cross the masthead's own dark text, which is chrome doing its job.
    bare_mat = ((slider_mod.RULE_Y + rect[1]) // 2, rect[1] + rect[3] + 200)
    for y in bare_mat:
        darkest = min(min(frame.getpixel((x, y)))
                      for x in range(0, slider_mod.CANVAS_W, 2))
        assert darkest > 200, f"something dark crosses the mat at y={y}"


def test_the_slider_draws_the_plate_rules_like_every_tuesday_reel():
    # The point of #164. The old chrome had no rose-gold rules at all, and a
    # test here asserted their absence; the plate draws two, and a 3-photo
    # Tuesday reel now looks like every other one.
    frame, _ = _slider_frame(progress=0.0)

    assert _row_has_color(frame, slider_mod.RULE_Y, plate_mod.ROSE_GOLD), "masthead rule"
    assert _row_has_color(frame, slider_mod.FOOTER_RULE_Y, plate_mod.ROSE_GOLD), "colophon rule"


# ── morph is the program-plate Tuesday reel ─────────────────────────────────
#
# A printed-program page: masthead top-left on a rose-gold rule, the photo hung
# as a matted print, a crossfading BEFORE/AFTER placard, and a footer colophon.

def test_morph_prints_the_photo_matted_not_full_bleed():
    canvas = morph_mod.prepare_photo(_landscape(size=(1500, 1000)), _landscape())
    rgb = canvas.convert("RGB")
    assert rgb.getpixel((10, 10)) == plate_mod.CREAM, "top mat"
    # The print sits inside the side mat, hung at PRINT_Y, not filling the frame.
    assert rgb.getpixel((plate_mod.MAT // 2, morph_mod.PRINT_Y + 40)) == plate_mod.CREAM, \
        "side mat"
    mid_x = morph_mod.CANVAS_W // 2
    assert rgb.getpixel((mid_x, morph_mod.PRINT_Y + 40)) != plate_mod.CREAM, \
        "the print itself is missing"


def test_morph_has_masthead_and_footer_colophon_rules():
    frame = Image.new("RGB", (morph_mod.CANVAS_W, morph_mod.CANVAS_H), plate_mod.CREAM)
    out = morph_mod.draw_branded_chrome(frame, "Home'r Bust!", "Home'r Bust!",
                                        "David Geffen Hall Lobby", None)
    assert _row_has_color(out, morph_mod.RULE_Y, plate_mod.ROSE_GOLD), "masthead rule"
    assert _row_has_color(out, morph_mod.FOOTER_RULE_Y, plate_mod.ROSE_GOLD), "colophon rule"


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


@requires_mac_fonts
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


@requires_mac_fonts
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


@requires_mac_fonts
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


def _colophon_ink(strip, cells):
    """Bounding box of the wordmark's dark ink in the cream below the photos.

    Returns (min_x, max_x, min_y, last_photo_bottom) or None when nothing dark
    sits below the photos.
    """
    rgb = strip.convert("RGB")
    last_photo_bottom = max(c["y"] + c["h"] for c in cells)
    dark = [
        (x, y)
        for y in range(last_photo_bottom, strip.height)
        for x in range(0, scroll_mod.CANVAS_W, 2)
        if sum(rgb.getpixel((x, y))) < 300
    ]
    if not dark:
        return None
    xs = [p[0] for p in dark]
    ys = [p[1] for p in dark]
    return min(xs), max(xs), min(ys), last_photo_bottom


def test_scroll_reel_colophon_is_dark_and_fills_the_width(tmp_path):
    # The reel shipped the WHITE mark on a cream footer, so it rendered as a ghost,
    # and even once black it was a timid 200px mark. Dan wants it big enough to fill
    # the space under the photos. It is the black mark scaled to the photo strip
    # width, so its ink spans most of the frame. Measure the ink, not the box: the
    # asset carries transparent side margins.
    photos = _photo_set(tmp_path, (30, 90, 160), n=6)
    strip, cells = scroll_mod.build_collage_strip(photos, seed=0, return_layout=True)
    ink = _colophon_ink(strip, cells)
    assert ink is not None, "the colophon is invisible below the photos"
    min_x, max_x, _, _ = ink
    assert max_x - min_x > 600, "the colophon is too small to fill the space"


def test_scroll_reel_colophon_tucks_right_under_the_photos(tmp_path):
    # It used to be pinned to the very bottom of the frame with a big empty cream
    # band above it. Dan wants it right under the last photo, not floating at the
    # bottom. The gap between the last print and the top of the mark stays small.
    photos = _photo_set(tmp_path, (30, 90, 160), n=6)
    strip, cells = scroll_mod.build_collage_strip(photos, seed=0, return_layout=True)
    ink = _colophon_ink(strip, cells)
    assert ink is not None, "the colophon is missing"
    _, _, ink_top, last_photo_bottom = ink
    assert ink_top - last_photo_bottom < 90, \
        "the colophon is not tucked right under the photos"


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
