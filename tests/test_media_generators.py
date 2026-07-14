"""Tests for the media generators: crop bias parity and ffmpeg command
construction.

ffmpeg is never actually run. subprocess.run is replaced with a capture
that records every command and touches the output file, so the assertions
pin exactly the flags whose absence caused real bugs: duration caps,
explicit stream selection, and atomic temp encodes.
"""

from __future__ import annotations

import json
import random
import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest
from PIL import Image

from postroll.media import generate_reel_morph as morph_mod
from postroll.media import generate_reel_screen as screen_mod
from postroll.media import generate_reel_scroll as scroll_mod
from postroll.media import generate_reel_slider as slider_mod
from postroll.media.generate_collage import (
    CANVAS_H,
    CANVAS_W,
    HAIRLINE,
    MAT,
    MIN_HEIGHT_RETENTION,
    MIN_WIDTH_RETENTION,
    STRIP_CREAM,
    STRIP_H,
    cell_retention,
    plate_detail_line,
    crop_to_fill,
    generate_collage,
    generate_collage_candidates,
    choose_collage_split,
    distinct_collage_splits,
    plan_collage_cells,
    split_fits_photos,
)
from postroll.ai import swap_reel_audio as swap_mod


# ===================================================================
# crop_to_fill — 0.5 Y bias parity with the SwiftUI editor
# ===================================================================


def _gradient_photo() -> Image.Image:
    """100x200 photo whose red channel encodes the row index, so the
    first output row reveals exactly where the crop window started."""
    img = Image.new("RGB", (100, 200))
    px = img.load()
    for y in range(200):
        for x in range(100):
            px[x, y] = (y, 0, 0)
    return img


def test_crop_centered_uses_half_overflow():
    out = crop_to_fill(_gradient_photo(), 100, 100)
    assert out.size == (100, 100)
    # overflow is 100 rows; centred crop starts at 50
    assert out.getpixel((0, 0))[0] == 50


def test_crop_full_drag_reaches_top_edge():
    out = crop_to_fill(_gradient_photo(), 100, 100, crop_offset_y=-1.0)
    assert out.getpixel((0, 0))[0] == 0


def test_crop_full_drag_reaches_bottom_edge():
    # top = overflow * (0.5 + offset * 0.5) = full 100 rows at offset 1.
    # The old 0.4 bias (the SwiftUI parity bug) would start at 90 instead,
    # so this pins the full drag range contract.
    out = crop_to_fill(_gradient_photo(), 100, 100, crop_offset_y=1.0)
    assert out.getpixel((0, 0))[0] == 100


def test_crop_x_axis_uses_same_bias():
    img = Image.new("RGB", (200, 100))
    px = img.load()
    for y in range(100):
        for x in range(200):
            px[x, y] = (x, 0, 0)
    out = crop_to_fill(img, 100, 100, crop_offset_x=1.0)
    assert out.getpixel((0, 0))[0] == 100


# ===================================================================
# Distinct gallery layouts (#70)
# ===================================================================


def test_distinct_splits_for_four_photos_are_unique_and_cover_all():
    splits = distinct_collage_splits(4)
    assert len(splits) >= 3
    keys = {(tuple(t), tuple(b)) for t, b in splits}
    assert len(keys) == len(splits), "no duplicate arrangements"
    for t, b in splits:
        assert sum(t) + sum(b) == 4


def test_distinct_splits_for_ten_photos_keep_even_halves():
    splits = distinct_collage_splits(10)
    assert len(splits) > 1
    keys = {(tuple(t), tuple(b)) for t, b in splits}
    assert len(keys) == len(splits)
    for t, b in splits:
        assert sum(t) == 5 and sum(b) == 5


def test_gallery_candidates_have_distinct_layouts(tmp_path):
    # With auto seeds, the gallery must show structurally different arrangements,
    # and each candidate's seed must reproduce its arrangement. The seed now
    # resolves against the photos' own aspect ratios, exactly as the final render
    # does, so a gallery thumbnail can't disagree with the collage it produces.
    photos = []
    ratios = []
    for i in range(4):
        p = tmp_path / f"p{i}.jpg"
        Image.new("RGB", (800, 600), (120, 140, 150)).save(str(p), "JPEG")
        photos.append(str(p))
        ratios.append(800 / 600)
    results = generate_collage_candidates(
        photo_paths=photos, output_dir=str(tmp_path / "cand"), count=5, event_name="Test"
    )
    # Map each candidate's stored seed back to the arrangement it renders.
    arrangements = {
        tuple(tuple(p) for p in choose_collage_split(4, random.Random(r["seed"]), ratios))
        for r in results
    }
    assert len(arrangements) == len(results), "every gallery candidate is a distinct layout"


# ===================================================================
# Collage split selection (#67 — dynamic 4-photo layouts)
# ===================================================================


def test_four_photo_split_offers_dynamic_layouts():
    # A 4-photo collage must offer more than the flat 2x2 grid: across seeds it
    # should produce varied arrangements including a single hero row.
    seen = set()
    for s in range(60):
        top, bottom = choose_collage_split(4, random.Random(s))
        seen.add((tuple(top), tuple(bottom)))
        # Every layout must cover all four photos.
        assert sum(top) + sum(bottom) == 4
    assert len(seen) > 1, "4-photo layout should vary, not always 2x2"
    top_sums = {sum(t) for t, _ in seen}
    assert 1 in top_sums, "a hero-over-trio style layout (1 photo on top) should appear"


def test_non_four_split_uses_even_halves():
    # Other counts keep the original near-even split.
    top, bottom = choose_collage_split(10, random.Random(0))
    assert sum(top) == 5 and sum(bottom) == 5
    top, bottom = choose_collage_split(6, random.Random(1))
    assert sum(top) == 3 and sum(bottom) == 3


# ===================================================================
# Collage layout candidates (the in-app layout gallery, #57)
# ===================================================================


def test_collage_candidates_render_distinct_files(tmp_path):
    photos = []
    for i in range(4):
        p = tmp_path / f"p{i}.jpg"
        Image.new("RGB", (800, 600), (100, 140, 160)).save(str(p), "JPEG")
        photos.append(str(p))
    out_dir = tmp_path / "cand"

    results = generate_collage_candidates(
        photo_paths=photos, output_dir=str(out_dir), count=5, event_name="Test"
    )
    # The gallery offers exactly the layouts that fit these photos' shape, capped
    # at `count`. It must never pad itself back up to `count` with layouts that
    # breach the crop budget. For a landscape set that is fewer than 5.
    expected = distinct_collage_splits(4, [800 / 600] * 4)[:5]
    assert len(results) == len(expected)
    assert 0 < len(results) <= 5
    # Distinct seeds and one PNG per candidate, all on disk.
    assert len({r["seed"] for r in results}) == len(results)
    for r in results:
        assert Path(r["path"]).exists()


def test_collage_candidates_accept_crop_offsets(tmp_path):
    # #62: candidates render with the day's crop offsets so the gallery matches
    # the final collage. Just assert it renders cleanly with offsets supplied.
    photos = []
    for i in range(4):
        p = tmp_path / f"p{i}.jpg"
        Image.new("RGB", (800, 600), (130, 110, 90)).save(str(p), "JPEG")
        photos.append(str(p))
    offsets = [(0.2, -0.1, 1.2), (0.0, 0.0, 1.0), (-0.3, 0.1, 1.1), (0.0, 0.0, 1.0)]
    results = generate_collage_candidates(
        photo_paths=photos, output_dir=str(tmp_path / "c"), count=3,
        event_name="Test", seeds=[1, 2, 3], crop_offsets=offsets,
    )
    assert len(results) == 3
    for r in results:
        assert Path(r["path"]).exists()


def test_collage_candidates_honor_explicit_seeds(tmp_path):
    photos = []
    for i in range(4):
        p = tmp_path / f"p{i}.jpg"
        Image.new("RGB", (800, 600), (120, 120, 120)).save(str(p), "JPEG")
        photos.append(str(p))
    results = generate_collage_candidates(
        photo_paths=photos, output_dir=str(tmp_path / "c"), count=2,
        event_name="Test", seeds=[111, 222],
    )
    assert [r["seed"] for r in results] == [111, 222]


# ===================================================================
# Crop budget: landscape sources must never be sliced into slivers
#
# Dan shoots every frame in 3:2 landscape. The old layout forced each half of
# the canvas to exactly 911px, so a half holding a single 3-across row stretched
# that row ~4x past its natural height and crop_to_fill paid for it by throwing
# away ~78% of each frame's WIDTH (a 295x911 slot fed from a 3:2 frame).
#
# The budget is deliberately asymmetric: trimming a landscape frame's top and
# bottom is a normal photographic crop, but cutting into its sides destroys the
# composition. So height may be trimmed hard, width may barely be touched.
# ===================================================================


LANDSCAPE = 3 / 2


def _ratios(n: int, ratio: float = LANDSCAPE) -> list[float]:
    return [ratio] * n


def test_cell_retention_reports_the_cropped_axis():
    # A 3:2 frame in a square cell loses width; in a wide cell it loses height.
    assert cell_retention(100, 100, LANDSCAPE) == pytest.approx(1 / 1.5)
    assert cell_retention(300, 100, LANDSCAPE) == pytest.approx(1.5 / 3.0)
    # A cell that matches the photo crops nothing.
    assert cell_retention(150, 100, LANDSCAPE) == pytest.approx(1.0)


def test_the_sliver_layout_that_shipped_is_now_rejected():
    # ([1], [3]), "hero over trio", is exactly the layout in Dan's Home'r Bust!
    # collage. Three 3:2 frames in a single 911px-tall row keep ~22% of their
    # width. It must not survive the budget for a landscape set.
    assert not split_fits_photos(([1], [3]), _ratios(4))
    assert not split_fits_photos(([3], [1]), _ratios(4))
    # The flat 2x2 grid is nearly as bad: ~0.6-aspect cells from 1.5 frames.
    assert not split_fits_photos(([2], [2]), _ratios(4))


def test_four_landscape_photos_still_have_valid_layouts():
    valid = distinct_collage_splits(4, _ratios(4))
    assert len(valid) >= 3, "a landscape set must still get a real layout gallery"
    for split in valid:
        assert split_fits_photos(split, _ratios(4))


def test_no_landscape_cell_loses_more_than_the_width_budget():
    # The real invariant, checked against the cells that actually get rendered.
    for n in (4, 6, 10):
        ratios = _ratios(n)
        for split in distinct_collage_splits(n, ratios):
            cells, _ = plan_collage_cells(ratios, split[0], split[1], random.Random(0))
            assert len(cells) == n
            for cell in cells:
                keep = cell_retention(cell["w"], cell["h"], LANDSCAPE)
                cropped_width = (cell["w"] / cell["h"]) < LANDSCAPE
                floor = MIN_WIDTH_RETENTION if cropped_width else MIN_HEIGHT_RETENTION
                assert keep >= floor, (
                    f"n={n} split={split} cell {cell['w']}x{cell['h']} keeps "
                    f"only {keep:.0%} of the frame's "
                    f"{'width' if cropped_width else 'height'}"
                )


def test_the_budget_is_shape_aware_not_a_ban_on_layouts():
    # The same arrangement is judged on the photos it has to hold. A 2x2 grid
    # hands each cell a ~0.6 aspect: fine for a portrait frame, ruinous for a
    # landscape one. The budget must reject it for Dan's 3:2 set and allow it for
    # a portrait set, rather than banning the layout outright.
    assert not split_fits_photos(([2], [2]), _ratios(4))
    assert split_fits_photos(([2], [2]), [2 / 3] * 4)


def test_three_across_survives_where_the_row_is_naturally_short():
    # A trio row is not banned either. In a 10-photo layout the trio row is only
    # ~136px tall, which three landscape frames fill happily. It is only the
    # 4-photo case, where one trio row has to absorb half the canvas, that turns
    # them into slivers.
    assert split_fits_photos(([1, 3, 1], [2, 2, 1]), _ratios(10))
    assert not split_fits_photos(([1], [3]), _ratios(4))


def test_default_layout_is_full_width_pair_full_width(tmp_path):
    # Dan's chosen default for a landscape set. With no stored seed the collage
    # must land on it every time, not draw one of the three at random.
    ratios = _ratios(4)
    assert distinct_collage_splits(4, ratios)[0] == ([1], [2, 1])

    photos = []
    for i in range(4):
        p = tmp_path / f"p{i}.jpg"
        Image.new("RGB", (1500, 1000), (90, 120, 150)).save(str(p), "JPEG")
        photos.append(str(p))

    layouts = set()
    for i in range(5):
        out = tmp_path / f"c{i}.png"
        generate_collage(photo_paths=photos, output_path=str(out), event_name="Test")
        cells = json.loads((tmp_path / f"c{i}_layout.json").read_text())
        layouts.add(tuple((c["w"], c["h"]) for c in cells))
    assert len(layouts) == 1, "an unseeded collage must be deterministic"

    # ...and it is the hero / pair / hero shape: one full-width row, then a pair.
    widths = [w for w, _ in next(iter(layouts))]
    assert widths[0] == CANVAS_W - 2 * MAT
    assert widths[1] != widths[0] and widths[2] != widths[0]
    assert widths[3] == CANVAS_W - 2 * MAT


def test_six_photo_collage_has_a_safe_layout():
    # Regression: TOP/BOTTOM_PATTERNS only ever covered the 5-photo half of a
    # 10-photo collage, so a 6-photo set fell through to a single [3] row per
    # half: trio-over-trio, the same sliver crop as the 4-photo bug.
    valid = distinct_collage_splits(6, _ratios(6))
    assert valid, "a 6-photo landscape collage must have at least one safe layout"
    for split in valid:
        assert split_fits_photos(split, _ratios(6))
    assert (([3], [3]) not in [(tuple(t), tuple(b)) for t, b in valid])


def test_rows_are_not_stretched_past_their_natural_height():
    # The root cause: each half was forced to a fixed height, so a half holding a
    # single row stretched it to ~911px whatever shape its photos were. Rows are
    # now sized from the real photo shapes under one shared scale, so every cell
    # in a 4-photo layout stays in the neighbourhood of the frame's proportions.
    # The old ([1], [3]) produced 0.32-aspect cells, 0.21x the frame.
    ratios = _ratios(4)
    cells, _ = plan_collage_cells(ratios, [1], [2, 1], random.Random(0))
    for cell in cells:
        assert 0.7 < (cell["w"] / cell["h"]) / LANDSCAPE < 2.0


def test_branded_strip_stays_near_the_middle():
    # The strip is the thing a re-sharer cannot crop out, so it must not drift to
    # the top or bottom edge once it is allowed to float between rows.
    for n in (4, 6, 10):
        ratios = _ratios(n)
        for split in distinct_collage_splits(n, ratios):
            _, strip_y = plan_collage_cells(ratios, split[0], split[1], random.Random(0))
            assert 0.30 * CANVAS_H <= strip_y <= 0.70 * CANVAS_H, (
                f"n={n} split={split} put the branded strip at "
                f"{strip_y / CANVAS_H:.0%} of the canvas"
            )


def test_cells_fill_the_canvas_without_overlap():
    # A shared scale must exactly consume the space inside the mat: no dead band
    # at the bottom, no row running off the edge.
    ratios = _ratios(10)
    split = distinct_collage_splits(10, ratios)[0]
    cells, _ = plan_collage_cells(ratios, split[0], split[1], random.Random(0))
    bottom = max(c["y"] + c["h"] for c in cells)
    assert abs(bottom - (CANVAS_H - MAT)) <= 2, f"layout ends at {bottom}"
    for cell in cells:
        assert cell["x"] >= MAT and cell["x"] + cell["w"] <= CANVAS_W - MAT


# ===================================================================
# Gallery style: cream mat, even on all four sides
#
# The photos used to bleed off the top and bottom of the canvas with a 40px side
# border, so nothing read as matted, and the mat colour was blended toward the
# photos' average (a blue stage greyed it, a dark room dirtied it). The mat is
# now an even border of fixed brand cream, and the branded strip sits inside it
# as a caption plate rather than running edge to edge.
# ===================================================================


def _photo_set(tmp_path, colour, n=4, size=(1500, 1000)):
    paths = []
    for i in range(n):
        p = tmp_path / f"{colour[0]}_{i}.jpg"
        Image.new("RGB", size, colour).save(str(p), "JPEG")
        paths.append(str(p))
    return paths


def test_photos_are_matted_evenly_on_all_four_sides():
    ratios = _ratios(4)
    split = distinct_collage_splits(4, ratios)[0]
    cells, _ = plan_collage_cells(ratios, split[0], split[1], random.Random(0))
    assert min(c["y"] for c in cells) == MAT, "top mat"
    assert abs(max(c["y"] + c["h"] for c in cells) - (CANVAS_H - MAT)) <= 2, "bottom mat"
    assert min(c["x"] for c in cells) == MAT, "left mat"
    assert max(c["x"] + c["w"] for c in cells) == CANVAS_W - MAT, "right mat"


def test_mat_colour_is_fixed_brand_cream_whatever_the_photos(tmp_path):
    # The regression that started this: a blue stage pulled the mat to grey-blue
    # and a dark room pulled it to muddy grey. Two wildly different photo sets
    # must now produce byte-identical mat colour.
    blue = tmp_path / "blue.png"
    dark = tmp_path / "dark.png"
    generate_collage(photo_paths=_photo_set(tmp_path, (20, 90, 200)),
                     output_path=str(blue), event_name="A", write_layout_sidecar=False)
    generate_collage(photo_paths=_photo_set(tmp_path, (25, 22, 20)),
                     output_path=str(dark), event_name="A", write_layout_sidecar=False)

    corner_blue = Image.open(blue).convert("RGB").getpixel((4, 4))
    corner_dark = Image.open(dark).convert("RGB").getpixel((4, 4))
    assert corner_blue == STRIP_CREAM
    assert corner_dark == STRIP_CREAM


def test_each_print_gets_a_hairline_just_outside_its_cell(tmp_path):
    # The hairline is the 1px ring IMMEDIATELY OUTSIDE each cell, never inside it,
    # so it frames the print without eating a row of the photograph. Swift strokes
    # the same ring after it repaints the gutters (CollageGeometry.hairlineRect);
    # if the two disagree by a pixel you get a doubled or offset line on export.
    out = tmp_path / "hair.png"
    photos = _photo_set(tmp_path, (10, 200, 10))   # vivid green, unmistakable vs cream
    generate_collage(photo_paths=photos, output_path=str(out), event_name="A",
                     write_layout_sidecar=False)
    img = Image.open(out).convert("RGB")

    ratios = [1500 / 1000] * 4
    split = distinct_collage_splits(4, ratios)[0]
    cells, _ = plan_collage_cells(ratios, split[0], split[1], random.Random(0))
    top = cells[0]
    mid_x = top["x"] + top["w"] // 2

    assert img.getpixel((mid_x, top["y"] - 1)) == HAIRLINE, "ring sits just above the cell"
    assert img.getpixel((top["x"] - 1, top["y"] + top["h"] // 2)) == HAIRLINE, "and just left"
    # The cell's own first pixel row is still photograph, not hairline.
    assert img.getpixel((mid_x, top["y"])) != HAIRLINE, "hairline must not eat into the photo"


def test_plate_detail_line_drops_org_when_it_equals_the_event():
    # When the org and the event name are the same, the org is already the big
    # script title, so repeating it on the detail line is noise. The detail line
    # becomes just the venue.
    assert plate_detail_line("Home'r Bust!", "Home'r Bust!", "David Geffen Hall Lobby") \
        == "David Geffen Hall Lobby"
    # Case and surrounding whitespace should not defeat the match.
    assert plate_detail_line("Home'r Bust!", " home'r bust! ", "Weill") == "Weill"


def test_plate_detail_line_keeps_both_when_org_differs():
    assert plate_detail_line("Perpetual Light", "DCINY", "Carnegie Hall") \
        == "DCINY  ·  Carnegie Hall"


def test_plate_detail_line_handles_missing_pieces():
    assert plate_detail_line("A", "A", "") == ""          # org==event, no venue
    assert plate_detail_line("A", "", "Carnegie") == "Carnegie"
    assert plate_detail_line("A", "DCINY", "") == "DCINY"


def test_collage_detail_uses_a_heavier_weight_than_thin():
    # The venue line rendered spindly because it used Helvetica Neue Thin, the
    # lightest weight. It must now load a heavier face so it renders cleanly.
    from postroll.media.generate_collage import PLATE_DETAIL_WEIGHT, FONT_DETAIL, load_font
    face = load_font(FONT_DETAIL, 18, index=PLATE_DETAIL_WEIGHT).getname()
    assert face[1] not in ("Thin", "Thin Italic", "UltraLight", "UltraLight Italic")


def test_branded_strip_is_inset_as_a_caption_plate(tmp_path):
    # The strip used to run the full canvas width. It now sits inside the mat, so
    # the mat colour still shows to the left and right of it.
    out = tmp_path / "plate.png"
    photos = _photo_set(tmp_path, (30, 30, 30))
    generate_collage(photo_paths=photos, output_path=str(out), event_name="A",
                     write_layout_sidecar=False)
    img = Image.open(out).convert("RGB")

    ratios = [1500 / 1000] * 4
    split = distinct_collage_splits(4, ratios)[0]
    _, strip_y = plan_collage_cells(ratios, split[0], split[1], random.Random(0))
    mid = strip_y + STRIP_H // 2

    assert img.getpixel((MAT // 2, mid)) == STRIP_CREAM, "mat shows left of the plate"
    assert img.getpixel((CANVAS_W - MAT // 2, mid)) == STRIP_CREAM, "and right of it"


# ===================================================================
# ffmpeg command construction
# ===================================================================


class FFmpegCapture:
    """Stands in for subprocess.run: records commands, touches the output
    file for ffmpeg calls, and answers ffprobe queries with fixed values."""

    def __init__(self):
        self.commands: list[list[str]] = []

    def __call__(self, cmd, **kwargs):
        self.commands.append(list(cmd))
        if cmd[0] == "ffmpeg":
            Path(cmd[-1]).touch()
            return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")
        if cmd[0] == "ffprobe":
            joined = " ".join(cmd)
            if "width,height" in joined:
                return subprocess.CompletedProcess(cmd, 0, stdout="640,480\n", stderr="")
            return subprocess.CompletedProcess(cmd, 0, stdout="10.0\n", stderr="")
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")


def _photo(path: Path, size=(400, 300)) -> Path:
    Image.new("RGB", size, (90, 70, 60)).save(path)
    return path


def _assert_audio_fit_pass(commands: list[list[str]]):
    """Every reel mux is now preceded by an audio-fit pass that renders the
    track to the reel's exact length (looping short clips with crossfaded
    seams). Returns the ffmpeg commands for further assertions."""
    ffmpeg = [c for c in commands if c[0] == "ffmpeg"]
    assert any(c[-1].endswith(".wav") for c in ffmpeg), \
        "expected an audio-fit pass rendering a fitted .wav before the mux"
    return ffmpeg


def _assert_mux_contract(cmd: list[str], *, requires_t: bool):
    """The contract every reel mux must satisfy."""
    # Explicit stream selection so MP3 cover art can't become the video
    assert "-map" in cmd
    assert "0:v:0" in cmd
    assert "1:a:0" in cmd
    # Bounded duration: -t or -shortest, never open ended
    if requires_t:
        assert "-t" in cmd
    else:
        assert "-t" in cmd or "-shortest" in cmd
    # Atomic encode: write to a temp name, rename into place on success
    assert cmd[-1].endswith(".tmp.mp4")


def test_scroll_reel_ffmpeg_command(tmp_path, monkeypatch):
    photos = [_photo(tmp_path / f"p{i}.jpg") for i in range(2)]
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"fake mp3")
    out = tmp_path / "reel.mp4"

    monkeypatch.setattr(scroll_mod, "FPS", 2)
    cap = FFmpegCapture()
    with patch("subprocess.run", new=cap):
        result = scroll_mod.generate_reel_scroll(
            [str(p) for p in photos], str(audio), str(out),
            event_name="Ev", org="Org", venue="Venue",
            scroll_duration=2.0,
        )

    ffmpeg_cmds = [c for c in cap.commands if c[0] == "ffmpeg"]
    # Two ffmpeg passes now: fit/loop the audio to the reel length, then encode.
    assert len(ffmpeg_cmds) == 2
    # The audio-fit pass renders a WAV; the final pass is the reel mux.
    assert ffmpeg_cmds[0][-1].endswith("audio_fit.wav")
    _assert_mux_contract(ffmpeg_cmds[-1], requires_t=True)
    assert out.exists()
    assert result == str(out)


def test_slider_reel_ffmpeg_command(tmp_path, monkeypatch):
    raw = _photo(tmp_path / "raw.jpg")
    edit = _photo(tmp_path / "edit.jpg")
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"fake mp3")
    out = tmp_path / "reel.mp4"

    monkeypatch.setattr(slider_mod, "FPS", 1)
    cap = FFmpegCapture()
    with patch("subprocess.run", new=cap):
        slider_mod.generate_reel_slider(
            str(raw), str(edit), str(audio), str(out),
            event_name="Ev", org="Org", venue="Venue",
        )

    ffmpeg = _assert_audio_fit_pass(cap.commands)
    final = ffmpeg[-1]
    _assert_mux_contract(final, requires_t=True)
    # Fitted audio is the exact reel length, so the reel is bounded by -t and
    # no longer relies on -shortest (which would cut the reel to a short track).
    assert "-shortest" not in final
    assert out.exists()


def test_morph_reel_ffmpeg_command(tmp_path, monkeypatch):
    raw = _photo(tmp_path / "raw.jpg")
    edit = _photo(tmp_path / "edit.jpg")
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"fake mp3")
    out = tmp_path / "reel.mp4"

    monkeypatch.setattr(morph_mod, "FPS", 1)
    cap = FFmpegCapture()
    with patch("subprocess.run", new=cap):
        morph_mod.generate_reel_morph(
            str(raw), str(edit), str(audio), str(out),
            event_name="Ev", org="Org", venue="Venue",
        )

    ffmpeg = _assert_audio_fit_pass(cap.commands)
    final = ffmpeg[-1]
    _assert_mux_contract(final, requires_t=True)
    assert "-shortest" not in final
    assert out.exists()


def test_scroll_reel_short_strip_pads_instead_of_black_band(tmp_path, monkeypatch):
    """With a handful of photos the strip is shorter than the canvas. The
    crop must not read past the strip bottom (black band), and a 40 second
    motionless scroll must collapse to a short hold."""
    photos = [_photo(tmp_path / f"p{i}.jpg", size=(1200, 400)) for i in range(2)]
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"fake mp3")
    out = tmp_path / "reel.mp4"

    monkeypatch.setattr(scroll_mod, "FPS", 2)
    sampled = {}

    class FrameInspectingCapture(FFmpegCapture):
        def __call__(self, cmd, **kwargs):
            if cmd[0] == "ffmpeg":
                # Frames still exist while ffmpeg runs; sample the band
                # between the content bottom and the footer chrome.
                from PIL import Image as PILImage

                pattern = next(a for a in cmd if "frame_%05d" in a)
                frames = sorted(Path(pattern).parent.glob("frame_*.png"))
                with PILImage.open(frames[-1]) as f:
                    sampled["pixel"] = f.getpixel(
                        (scroll_mod.CANVAS_W // 2,
                         scroll_mod.CANVAS_H - scroll_mod.FOOTER_H - 10)
                    )
            return super().__call__(cmd, **kwargs)

    cap = FrameInspectingCapture()
    with patch("subprocess.run", new=cap):
        scroll_mod.generate_reel_scroll(
            [str(p) for p in photos], str(audio), str(out),
            event_name="Ev", org="Org", venue="Venue",
        )

    # No black band: the padded area is the cream background
    assert sampled["pixel"] != (0, 0, 0)
    # The scroll phase collapsed (4s hold + 1s end hold + 5s closing slot),
    # far below the default 40s scroll plus tail
    cmd = [c for c in cap.commands if c[0] == "ffmpeg"][0]
    t_value = float(cmd[cmd.index("-t") + 1])
    assert t_value <= 10.0


def test_screen_reel_closing_path_caps_duration(tmp_path):
    """The closing frame branch shipped without -t once: the container ran
    for the whole music track. Pin the cap and the mux contract."""
    rec = tmp_path / "rec.mp4"
    rec.write_bytes(b"fake video")
    raw = _photo(tmp_path / "raw.jpg")
    edit = _photo(tmp_path / "edit.jpg")
    closing = tmp_path / "closing.png"
    Image.new("RGB", (1080, 1920), (240, 230, 215)).save(closing)
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"fake mp3")
    out = tmp_path / "reel.mp4"

    cap = FFmpegCapture()
    with patch("subprocess.run", new=cap):
        screen_mod.generate_reel_screen(
            str(rec), str(raw), str(edit), str(audio), str(out),
            event_name="Ev", org="Org", venue="Venue",
            closing_frame_path=str(closing),
            target_duration=5.0,
        )

    ffmpeg = _assert_audio_fit_pass(cap.commands)
    final = ffmpeg[-1]
    assert "concat" in final  # the closing branch's final encode
    _assert_mux_contract(final, requires_t=True)
    assert out.exists()


def test_screen_reel_simple_path_drops_shortest_with_fitted_audio(tmp_path):
    """The non-closing branch used -shortest, which truncates the reel to a
    short track. With the audio fitted to length it must be bounded by -t and
    drop -shortest."""
    rec = tmp_path / "rec.mp4"
    rec.write_bytes(b"fake video")
    raw = _photo(tmp_path / "raw.jpg")
    edit = _photo(tmp_path / "edit.jpg")
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"fake mp3")
    out = tmp_path / "reel.mp4"

    cap = FFmpegCapture()
    with patch("subprocess.run", new=cap):
        screen_mod.generate_reel_screen(
            str(rec), str(raw), str(edit), str(audio), str(out),
            event_name="Ev", org="Org", venue="Venue",
            target_duration=5.0,
        )

    ffmpeg = _assert_audio_fit_pass(cap.commands)
    final = ffmpeg[-1]
    _assert_mux_contract(final, requires_t=True)
    assert "-shortest" not in final
    assert out.exists()


def test_swap_reel_audio_fits_user_audio_to_video(tmp_path):
    """Swapping in a user-provided track fits it to the video length first
    (looping short clips), then re-muxes with the video stream copied."""
    reel = tmp_path / "reel.mp4"
    reel.write_bytes(b"fake video")
    audio = tmp_path / "user.mp3"
    audio.write_bytes(b"fake mp3")

    cap = FFmpegCapture()
    with patch("subprocess.run", new=cap):
        result = swap_mod.swap_reel_audio(
            str(reel), shoot_type="performance", pieces=[], audio_file=str(audio),
        )

    ffmpeg = _assert_audio_fit_pass(cap.commands)
    final = ffmpeg[-1]
    # Video stream copied, fitted audio mapped in, bounded by -t.
    assert "copy" in final
    assert "1:a:0" in final
    assert "-t" in final
    assert result["reel"] == str(reel.resolve())
