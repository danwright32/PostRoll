"""#163: catch a template that renders successfully while looking broken.

Twice in one session a template shipped visibly broken with a fully green suite.
The collage was slicing 3:2 frames into 0.32-aspect slivers, and the Tuesday
edit reels rendered white RAW/Edit labels onto the new cream mat (invisible)
plus a divider drop-shadow streaking the mat. Pixel-equality assertions on a
background colour cannot see a contrast or legibility regression, because the
background really is the colour they check.

So each template gets a reference frame, committed under
`tests/fixtures/goldens/`, and every change is diffed against it.

Two rules this file is built around:

1. **For the reels the reference is pulled OUT of an encoded video**, never
   hand-composited from the same helpers the template uses. The hand-composited
   still path is exactly what hid the last regression: it agreed with the code
   rather than with the file Dan posts. h.264 shifts the brand cream from
   252,250,247 to about 250,249,245, so the comparison carries a per-channel
   tolerance rather than demanding equality.

2. **A recording defends whatever it captured**, including a blank canvas or a
   half-rendered frame if the harness never fed the template its inputs. So
   every golden is also checked in words against the state it claims to show:
   it must carry real photographic content, and the templates whose regression
   was a legibility one assert legibility directly. A golden that cannot state
   what it shows is a photograph of a bug.

To re-record after a deliberate design change, run with
POSTROLL_UPDATE_GOLDENS=1 and commit the new PNGs. Read them before committing:
that flag is the one way a broken frame becomes the expectation.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest
from PIL import Image, ImageChops

from conftest import needs_ffmpeg, needs_mac_fonts as requires_mac_fonts
from postroll.media import design_tokens as tokens
from postroll.media import frame_legibility as legibility
from postroll.media import generate_before_after as ba_mod
from postroll.media import generate_collage as collage_mod
from postroll.media import generate_reel_morph as morph_mod
from postroll.media import program_plate as plate_mod
from postroll.media import generate_reel_screen as screen_mod
from postroll.media import generate_reel_scroll as scroll_mod
from postroll.media import generate_reel_slider as slider_mod
from postroll.media import generate_story as story_mod

# Every check in this file renders a real reel and reads pixels back, which is
# where the suite's time goes. `make test-python-fast` deselects it; CI and
# `make test-python` still run it (#413).
pytestmark = pytest.mark.slow



GOLDEN_DIR = Path(__file__).resolve().parent / "fixtures" / "goldens"

#: The real shipping wordmark, not a stand-in. The logo is the element with the
#: worst history in this repo: a white mark on a cream surface has shipped
#: invisibly three times, and a reference frame recorded without one cannot see
#: that happen again.
LOGO = str(Path(__file__).resolve().parent.parent / "postroll" / "assets" / "logo-black.png")

#: The reference photographs' size. Named once: the print rectangle is a
#: function of it, and a fixture that changed shape without the bands following
#: would move the render out from under every band in this file.
PHOTO_SIZE = (2000, 1332)

UPDATING = os.environ.get("POSTROLL_UPDATE_GOLDENS") == "1"

#: Per-channel difference treated as codec and resampling noise rather than a
#: change. Measured against the brand cream's own h.264 shift (252,250,247 to
#: about 250,249,245, a worst channel delta of 2) with headroom.
CHANNEL_TOLERANCE = 6

#: Share of pixels allowed past that tolerance. A moved element, a label that
#: has lost its contrast, or a shadow streaking the mat all cover far more of
#: the frame than this; anti-aliasing along unchanged edges covers less.
MAX_CHANGED_FRACTION = 0.005


# ── comparison ────────────────────────────────────────────────────────────────

def _changed_mask(actual: Image.Image, golden: Image.Image) -> Image.Image:
    """A 1-bit mask of pixels differing by more than the tolerance on any channel."""
    difference = ImageChops.difference(actual.convert("RGB"), golden.convert("RGB"))
    bands = difference.split()
    worst = bands[0]
    for band in bands[1:]:
        worst = ImageChops.lighter(worst, band)
    return worst.point(lambda v: 255 if v > CHANNEL_TOLERANCE else 0)


def assert_matches_golden(actual: Image.Image, name: str, tmp_path: Path) -> None:
    """Diff `actual` against the committed reference frame for `name`."""
    golden_path = GOLDEN_DIR / f"{name}.png"

    if UPDATING:
        GOLDEN_DIR.mkdir(parents=True, exist_ok=True)
        actual.convert("RGB").save(golden_path)
        pytest.skip(f"re-recorded {golden_path.name}; unset POSTROLL_UPDATE_GOLDENS to check it")

    assert golden_path.is_file(), (
        f"no reference frame for {name}. Record one with "
        f"POSTROLL_UPDATE_GOLDENS=1 and LOOK at it before committing")

    golden = Image.open(golden_path)
    assert actual.size == golden.size, (
        f"{name}: rendered {actual.size}, reference is {golden.size}")

    mask = _changed_mask(actual, golden)
    changed = mask.histogram()[255]
    total = actual.width * actual.height
    fraction = changed / total

    if fraction > MAX_CHANGED_FRACTION:
        # Write the evidence out rather than only reporting a number, because a
        # percentage cannot tell a moved logo from an invisible label.
        rendered_path = tmp_path / f"{name}-rendered.png"
        actual.convert("RGB").save(rendered_path)
        mask.save(tmp_path / f"{name}-changed.png")
        pytest.fail(
            f"{name}: {fraction:.2%} of pixels moved (limit "
            f"{MAX_CHANGED_FRACTION:.2%}), changed region {mask.getbbox()}.\n"
            f"  rendered: {rendered_path}\n"
            f"  reference: {golden_path}\n"
            f"  changed pixels: {tmp_path / f'{name}-changed.png'}")


# ── what the frame must actually show ─────────────────────────────────────────

def assert_shows_real_content(frame: Image.Image, name: str) -> None:
    """Refuse a frame that is blank, flat, or otherwise not a rendered template.

    Without this a reference recorded from a failed render, an unfed template or
    an all-cream canvas would pass its own diff forever and defend the failure
    as correct.
    """
    colours = frame.convert("RGB").getcolors(maxcolors=1 << 20)
    assert colours is not None and len(colours) > 500, (
        f"{name}: only {0 if colours is None else len(colours)} distinct colours, "
        f"which is not a rendered template; the reference would be a photograph "
        f"of a broken render")

    dominant = max(count for count, _ in colours)
    assert dominant < 0.92 * frame.width * frame.height, (
        f"{name}: one colour covers {dominant / (frame.width * frame.height):.0%} "
        f"of the frame, so almost nothing rendered")


def assert_ink_reads_against_its_background(
    frame: Image.Image, box: tuple[int, int, int, int], name: str, min_contrast: int = 40
) -> None:
    """The darkest and lightest pixels in `box` must be far enough apart to see.

    This is the regression itself: white labels on the cream mat rendered as a
    correct, present, entirely invisible element, and every colour assertion in
    the suite passed because the mat really was cream.
    """
    region = frame.convert("L").crop(box)
    darkest, lightest = region.getextrema()
    assert lightest - darkest >= min_contrast, (
        f"{name}: text region {box} spans only {lightest - darkest} levels of "
        f"brightness, so whatever is drawn there cannot be read")


# ── inputs ────────────────────────────────────────────────────────────────────

def _patterned_photo(path: Path, seed: int) -> str:
    """A deterministic stand-in with structure, not a flat colour block.

    A flat photo hides every framing regression: a crop that moves, a cell that
    collapses to a sliver and a photo pasted at the wrong offset all render the
    same single colour. The bright band near the top is what a top-anchored
    crop is supposed to keep.
    """
    width, height = PHOTO_SIZE
    photo = Image.new("RGB", (width, height))
    pixels = photo.load()
    for y in range(height):
        for x in range(0, width, 4):
            shade = ((x // 40) + (y // 40) + seed) % 3
            colour = [(150, 96, 74), (66, 52, 48), (196, 158, 120)][shade]
            for dx in range(4):
                pixels[x + dx, y] = colour
    for y in range(90, 190):          # the bright band a top-anchored crop keeps
        for x in range(width):
            pixels[x, y] = (242, 232, 214)
    photo.save(path, "JPEG", quality=92)
    return str(path)


@pytest.fixture
def photos(tmp_path) -> list[str]:
    return [_patterned_photo(tmp_path / f"p{i}.jpg", seed=i) for i in range(10)]


def _broad_photo(path: Path, seed: int) -> str:
    """Structure at a scale h.264 reproduces the same way on any machine.

    For the closing graphic only. The patterned photo above draws a 40px check,
    which is fine as one large print but lands near the encoder's limit once the
    graphic scales it into two or three strips: CI disagreed with this machine
    on 5.4% of those pixels while every other reference matched, because the two
    encoders quantise a near-Nyquist pattern differently. Loosening the
    tolerance would have hidden that rather than fixed it, and would have
    loosened every other reference with it.

    The bands here are wide and the gradient is smooth, so the reference is
    decided by the chrome and the layout it exists to defend rather than by
    whether two encoders round a checkerboard the same way. It keeps the bright
    top band and plenty of distinct colours, so a moved crop or an unrendered
    print is as visible as before.
    """
    width, height = PHOTO_SIZE
    photo = Image.new("RGB", (width, height))
    pixels = photo.load()
    for y in range(height):
        band = ((y // 220) + seed) % 3
        base = [(150, 96, 74), (96, 76, 68), (196, 158, 120)][band]
        for x in range(width):
            lift = 0.72 + 0.28 * (x / width)
            pixels[x, y] = (int(base[0] * lift), int(base[1] * lift),
                            int(base[2] * lift))
    for y in range(90, 190):          # the bright band a top-anchored crop keeps
        for x in range(width):
            pixels[x, y] = (242, 232, 214)
    photo.save(path, "JPEG", quality=92)
    return str(path)


@pytest.fixture
def broad_photos(tmp_path) -> list[str]:
    return [_broad_photo(tmp_path / f"b{i}.jpg", seed=i) for i in range(3)]


@pytest.fixture
def screen_recording(tmp_path) -> str:
    """A stand-in for a Lightroom screen capture (#263).

    Synthesised rather than committed: a real capture is tens of megabytes of
    somebody's actual screen, and what the template does with it (speed it up,
    scale it, put chrome round it) does not depend on what it shows. It does
    depend on the shape, so this is a real 16:9 desktop aspect at the frame
    rate the template expects, carrying structure rather than a flat colour so
    a scaling or placement regression has something to move.

    Deliberately a STILL held for six seconds rather than moving footage. The
    reel speeds the recording up, so the exact frame a sample lands on shifts
    with any difference in the encoder's timing, and the first version of this
    used ffmpeg's testsrc2, whose burnt-in timecode and moving diagonals made
    the reference frame different on CI from the one recorded here. A recording
    whose every frame is identical cannot do that.
    """
    still = _patterned_photo(tmp_path / "screen-still.jpg", seed=163)
    path = tmp_path / "recording.mov"
    subprocess.run(
        ["ffmpeg", "-y", "-loop", "1", "-i", still,
         "-t", "6", "-r", str(screen_mod.FPS),
         "-vf", "scale=1920:1080", "-c:v", "libx264", "-pix_fmt", "yuv420p",
         str(path)],
        check=True, capture_output=True)
    return str(path)


@pytest.fixture
def silent_audio(tmp_path) -> str:
    """A local silent track.

    The reel generators fetch a Jamendo track when handed no audio, so a test
    that passed None would make a network call to a third-party service on every
    run and render against whatever it happened to return.
    """
    path = tmp_path / "silence.m4a"
    subprocess.run(
        ["ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
         "-t", "45", "-c:a", "aac", str(path)],
        check=True, capture_output=True)
    return str(path)


def _frame_from_encoded_video(video: str, at_seconds: float, out: Path) -> Image.Image:
    """Pull a single frame back OUT of the encoded file.

    Not composited from the template's own helpers: the reference has to be what
    the encoder produced, which is the file Dan posts, or it agrees with the
    code rather than with reality.
    """
    subprocess.run(
        ["ffmpeg", "-y", "-ss", str(at_seconds), "-i", video,
         "-frames:v", "1", str(out)],
        check=True, capture_output=True)
    assert out.is_file(), f"ffmpeg produced no frame at {at_seconds}s of {video}"
    return Image.open(out).convert("RGB")


# ── still templates ───────────────────────────────────────────────────────────

@requires_mac_fonts
def test_collage_matches_its_reference_frame(photos, tmp_path):
    out = tmp_path / "collage.png"
    collage_mod.generate_collage(
        photo_paths=photos, output_path=str(out),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        seed=163, write_layout_sidecar=False, logo_path=LOGO)

    frame = Image.open(out).convert("RGB")
    assert_shows_real_content(frame, "collage")
    assert_matches_golden(frame, "collage", tmp_path)


@requires_mac_fonts
def test_story_matches_its_reference_frame(photos, tmp_path):
    out = tmp_path / "story.png"
    story_mod.generate_story(
        photo_path=photos[0], event_name="Reference Event",
        org="Reference Org", venue="Reference Venue", output_path=str(out),
        logo_path=LOGO)

    frame = Image.open(out).convert("RGB")
    assert_shows_real_content(frame, "story")
    assert_matches_golden(frame, "story", tmp_path)


@requires_mac_fonts
def test_before_after_matches_its_reference_frame(photos, tmp_path):
    out = tmp_path / "before_after.png"
    ba_mod.generate_before_after(
        raw_path=photos[0], edit_path=photos[1], output_path=str(out),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        logo_path=LOGO)

    frame = Image.open(out).convert("RGB")
    assert_shows_real_content(frame, "before_after")
    assert_matches_golden(frame, "before_after", tmp_path)


# ── reels, sampled from the encoded file ──────────────────────────────────────

def _closing_graphic(photos, tmp_path, *, bw: str | None) -> str:
    """The before/after graphic a Tuesday reel ends on (#341).

    Rendered by the shipped generator rather than stood in for, because the reel
    dissolves into THIS image and holds on it for three seconds. Recorded
    without one, the last four and a half seconds of each reel are a held plate,
    which is a shape the app never produces: `generate_media` always passes a
    closing graphic. A reference frame photographs whatever the surface was
    showing when it was taken, so it would defend that shape indefinitely (L84).

    `bw` is what makes the pairing honest. `generate_media` hands the SAME
    `bw_path` to the graphic and to the reel, so a three photo reel closes on a
    three strip graphic and a two photo reel on a two strip one. Giving both
    reels the two photo graphic would record the slider ending on a pairing the
    app never produces, which is the defect this issue is about, one layer down.
    """
    path = tmp_path / ("closing_bw.png" if bw else "closing.png")
    ba_mod.generate_before_after(
        raw_path=photos[0], edit_path=photos[1], output_path=str(path),
        event_name="Reference Event", org="Reference Org",
        venue="Reference Venue", logo_path=LOGO, bw_path=bw)
    return str(path)


@pytest.fixture
def closing_graphic(photos, tmp_path) -> str:
    """The two photo graphic, which is what the morph reel closes on."""
    return _closing_graphic(photos, tmp_path, bw=None)


@pytest.fixture
def closing_graphic_bw(photos, tmp_path) -> str:
    """The three photo graphic, which is what the slider reel closes on."""
    return _closing_graphic(photos, tmp_path, bw=photos[2])


@needs_ffmpeg
@requires_mac_fonts
def test_slider_reel_matches_its_reference_frame(photos, silent_audio,
                                                 closing_graphic_bw, tmp_path):
    # 0.6s lands in the opening hold on the RAW, where the plate's chrome and
    # its caption placard sit on the cream mat. That is the frame the
    # invisible-label regression shipped on.
    #
    # A B&W is required now: this reel renders three states, and nothing in the
    # app reaches it without one (#164, #324). The reference recorded before
    # that was a photograph of the two-photo path, which the product cannot
    # produce.
    video = slider_mod.generate_reel_slider(
        raw_path=photos[0], edit_path=photos[1], bw_path=photos[2],
        audio_path=silent_audio,
        output_path=str(tmp_path / "slider.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        closing_frame_path=closing_graphic_bw, logo_path=LOGO)

    frame = _frame_from_encoded_video(video, 0.6, tmp_path / "slider.png")
    assert_shows_real_content(frame, "slider_reel")
    _, print_top, _, print_h = slider_mod.print_rect(PHOTO_SIZE)
    caption_top = print_top + print_h + slider_mod.PLACARD_TOP_GAP
    assert_ink_reads_against_its_background(
        frame,
        (slider_mod.MAT, caption_top,
         slider_mod.CANVAS_W - slider_mod.MAT,
         caption_top + slider_mod.PLACARD_BLOCK_H),
        "slider_reel")
    assert_matches_golden(frame, "slider_reel", tmp_path)


@needs_ffmpeg
@requires_mac_fonts
def test_morph_reel_matches_its_reference_frame(photos, silent_audio,
                                                closing_graphic, tmp_path):
    video = morph_mod.generate_reel_morph(
        raw_path=photos[0], edit_path=photos[1], audio_path=silent_audio,
        output_path=str(tmp_path / "morph.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        closing_frame_path=closing_graphic, logo_path=LOGO)

    frame = _frame_from_encoded_video(video, 0.6, tmp_path / "morph.png")
    assert_shows_real_content(frame, "morph_reel")
    # The placard under the print is the element that has to stay readable.
    #
    # Its band is derived from the FIXTURE's own dimensions through the same
    # pure function the renderer uses, rather than read back off the module
    # after the render. Reading it back made the expected position and the drawn
    # position one value, so a wrong print height moved both together and this
    # passed hardest exactly when the layout was wrong (L70, #323).
    _, print_top, _, print_h = morph_mod.print_rect(PHOTO_SIZE)
    assert_ink_reads_against_its_background(
        frame,
        (plate_mod.MAT, print_top + print_h + 20,
         morph_mod.CANVAS_W - plate_mod.MAT, print_top + print_h + 80),
        "morph_reel")
    assert_matches_golden(frame, "morph_reel", tmp_path)


#: Which module each Tuesday reel's closing check runs against. The window is
#: read off the module's own timeline rather than written here, so moving the
#: timings moves the sampling point with them.
CLOSING_REELS = {"morph_reel_closing": morph_mod, "slider_reel_closing": slider_mod}

#: Mean per-channel difference below which two frames are the same picture.
#: Measured, not guessed (#339): the closing hold reads 3.5 against the
#: graphic handed in and 59.6 against the reel's own plate frame.
SAME_PICTURE = 15.0


@needs_ffmpeg
@requires_mac_fonts
@pytest.mark.parametrize("name", sorted(CLOSING_REELS))
def test_the_closing_hold_matches_its_reference_frame(
        name, photos, broad_photos, silent_audio, tmp_path):
    """The three seconds every Tuesday reel ends on (#341).

    A reference of its own, because it is a different design from the one the
    0.6s frames record: the plate holds ONE print and the graphic holds three,
    and the caption moves from left-aligned below the print to centred above
    each strip. Nothing photographed that, so nothing would notice it breaking.
    """
    module = CLOSING_REELS[name]
    # The graphic is built here, on photographs whose structure survives the
    # encoder identically on any machine (see `_broad_photo`). The reel itself
    # still runs on the ordinary fixture; only the frame being photographed for
    # the reference needs that property.
    closing = _closing_graphic(broad_photos, tmp_path, bw=None)
    closing_bw = _closing_graphic(broad_photos, tmp_path, bw=broad_photos[2])
    if module is morph_mod:
        video = morph_mod.generate_reel_morph(
            raw_path=photos[0], edit_path=photos[1], audio_path=silent_audio,
            output_path=str(tmp_path / "morph_closing.mp4"),
            event_name="Reference Event", org="Reference Org",
            venue="Reference Venue",
            closing_frame_path=closing, logo_path=LOGO)
    else:
        video = slider_mod.generate_reel_slider(
            raw_path=photos[0], edit_path=photos[1], bw_path=photos[2],
            audio_path=silent_audio,
            output_path=str(tmp_path / "slider_closing.mp4"),
            event_name="Reference Event", org="Reference Org",
            venue="Reference Venue",
            closing_frame_path=closing_bw, logo_path=LOGO)

    # Half a second into the hold: past the dissolve, and clear of the last
    # frame, where a seek decodes nothing.
    stamp = (module.CLOSING_CROSSFADE_START + module.TRANSITION_DURATION + 0.5)
    frame = _frame_from_encoded_video(video, stamp, tmp_path / f"{name}.png")
    source = Image.open(closing_bw if module is slider_mod else closing).convert("RGB")

    assert_shows_real_content(frame, name)

    # Checked against the GRAPHIC IT WAS GIVEN rather than against a committed
    # PNG, and this is a deliberate departure from every other reference here.
    #
    # A pixel reference works for the other frames because they are mostly flat
    # cream: the codec moves that by 2 per channel and almost nothing crosses
    # the tolerance. This frame is roughly three quarters photograph, and two
    # ffmpeg builds do not agree on it. Measured on CI against this machine:
    # 5.4% of pixels with the checkerboard fixture, and still 1.0% after that
    # was replaced with smooth bands, where every plate frame sits under 0.5%.
    #
    # Loosening MAX_CHANGED_FRACTION to admit it would have loosened all seven
    # other references by the same amount, to hide a disagreement about
    # photographs nobody is checking. So the frame is compared to its own source
    # image, which is what #339 already proved holds across machines, and the
    # chrome this reference exists to defend is asserted directly below.
    difference = legibility.mean_difference(frame, source)
    assert difference < SAME_PICTURE, (
        f"{name}: the closing hold differs from the graphic it was given by "
        f"{difference:.1f} of 255, so it is holding on something else")

    # The two elements with real regression history on this template: the
    # masthead, and the wordmark that has shipped invisible three times.
    assert_ink_reads_against_its_background(
        frame, (0, 120, frame.width, 380), f"{name} masthead")
    assert_ink_reads_against_its_background(
        frame, (0, frame.height - 200, frame.width, frame.height),
        f"{name} colophon")


@needs_ffmpeg
@requires_mac_fonts
def test_scroll_reel_matches_its_reference_frame(photos, silent_audio, tmp_path):
    # A short scroll rather than the shipping 40 seconds: the frame under test
    # is the gallery mat and its chrome, which the duration does not change,
    # and a full-length encode would cost the suite about 40 seconds to look at
    # one frame. `scroll_duration` is a real parameter of the generator, not a
    # seam opened for the test.
    video = scroll_mod.generate_reel_scroll(
        photo_paths=photos, audio_path=silent_audio,
        output_path=str(tmp_path / "scroll.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        seed=163, scroll_duration=4.0, logo_path=LOGO)

    frame = _frame_from_encoded_video(video, 1.0, tmp_path / "scroll.png")
    assert_shows_real_content(frame, "scroll_reel")
    assert_matches_golden(frame, "scroll_reel", tmp_path)


@needs_ffmpeg
@requires_mac_fonts
def test_screen_reel_matches_its_reference_frame(photos, silent_audio, screen_recording, tmp_path):
    """#263: the last template without a reference frame.

    It was left out because it takes a screen recording as an input and the
    harness had none. That made it the only template where a contrast or
    legibility regression could still ship unseen, which is exactly the failure
    #163 was written for: the last two of those passed a fully green suite.

    The recording is synthesised by ffmpeg rather than checked in: a real
    Lightroom capture would be tens of megabytes of somebody's actual screen,
    and what the template does with it (speed it up, scale it, put chrome
    round it) does not depend on what it shows.
    """
    # A short edit rather than the shipping 20 seconds. `target_duration` is a
    # real parameter of the generator, not a seam opened for the test, and the
    # frame under test is the chrome, which the duration does not change.
    video = screen_mod.generate_reel_screen(
        recording_path=screen_recording,
        raw_path=photos[0], edit_path=photos[1], audio_path=silent_audio,
        output_path=str(tmp_path / "screen.mp4"),
        event_name="Reference Event", org="Reference Org", venue="Reference Venue",
        logo_path=LOGO, target_duration=2.0)

    frame = _frame_from_encoded_video(video, 0.6, tmp_path / "screen.png")
    assert_shows_real_content(frame, "screen_reel")
    # The title band on the cream header. This template draws dark text on
    # cream with no rule lines, so the header is where an invisible-ink
    # regression would land, the same one the slider reel shipped.
    assert_ink_reads_against_its_background(
        frame,
        (0, screen_mod.TITLE_TOP_Y,
         screen_mod.CANVAS_W, screen_mod.TITLE_TOP_Y + 90),
        "screen_reel")
    assert_matches_golden(frame, "screen_reel", tmp_path)


# ── the guards on the guards ──────────────────────────────────────────────────

GOLDEN_NAMES = {
    "collage", "story", "before_after",
    "slider_reel", "morph_reel", "scroll_reel", "screen_reel",
}


def test_every_reference_frame_is_claimed_by_a_test():
    # An orphan reference is one whose test was deleted or renamed, so nothing
    # compares against it and it reads as coverage that does not exist.
    if not GOLDEN_DIR.is_dir():
        pytest.skip("no references recorded yet")
    on_disk = {p.stem for p in GOLDEN_DIR.glob("*.png")}
    assert on_disk - GOLDEN_NAMES == set(), \
        f"reference frames nothing compares against: {sorted(on_disk - GOLDEN_NAMES)}"


def test_the_reel_references_come_from_an_encoded_video():
    # The rule that makes this suite worth having. Hand-compositing a still from
    # the template's own helpers is what hid the last regression, so the reel
    # tests must go through ffmpeg rather than through PIL.
    source = Path(__file__).read_text()
    for reel in ("slider_reel", "morph_reel", "scroll_reel", "screen_reel"):
        block = source.split(f'"{reel}", tmp_path)')[0].rsplit("def test_", 1)[1]
        assert "_frame_from_encoded_video" in block, (
            f"{reel} builds its frame without decoding the encoded file")
    # The closing references share one parametrized test, so they are named
    # through a variable rather than a literal and the split above cannot find
    # them. Checked on the block that renders them instead.
    closing = source.rsplit("def test_the_closing_hold_matches_its_reference_frame", 1)[1]
    assert "_frame_from_encoded_video" in closing.split("def test_")[0], (
        "the closing references are built without decoding the encoded file")


def test_the_cream_tolerance_covers_what_the_codec_actually_does_to_it():
    # The tolerance exists for one measured reason. If someone tightens it below
    # the codec's own shift of the brand cream, every reel test goes red for a
    # change nobody made.
    encoded_cream = (250, 249, 245)  # h.264 round trip of the brand cream
    worst = max(abs(a - b) for a, b in zip(tokens.CREAM, encoded_cream))
    assert CHANNEL_TOLERANCE > worst, (
        f"the codec moves brand cream by {worst} per channel; a tolerance of "
        f"{CHANNEL_TOLERANCE} would fail on an unchanged frame")


# ── the wordmark fits on the page ─────────────────────────────────────────────

LOGO_BEARING_GOLDENS = ("before_after", "story", "morph_reel", "scroll_reel")


@pytest.mark.parametrize("name", LOGO_BEARING_GOLDENS)
def test_the_wordmark_is_not_clipped_by_the_canvas_edge(name):
    """No template may run the brand mark off the bottom of the page.

    Checked as a class rather than on the one template it was found on: the
    footers are laid out independently, so whatever cuts one can cut another.

    The existing legibility test measures the mark's horizontal extent, which a
    mark cut in half across the middle satisfies perfectly, so it could never
    have said anything about this.
    """
    path = GOLDEN_DIR / f"{name}.png"
    if not path.is_file():
        pytest.skip("no reference recorded yet")

    frame = Image.open(path).convert("L")
    bottom = frame.crop((0, frame.height - 1, frame.width, frame.height))
    darkest, _ = bottom.getextrema()
    assert darkest > 120, (
        f"{name}: ink at brightness {darkest} sits on the very last row of the "
        f"canvas, so something (the wordmark, in every case so far) is running "
        f"off the bottom of the page")
