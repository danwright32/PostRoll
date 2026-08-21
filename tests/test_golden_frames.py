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
import re
import subprocess
from pathlib import Path

import pytest
from PIL import Image, ImageChops, ImageStat

import golden_drift

from conftest import needs_ffmpeg, needs_mac_fonts as requires_mac_fonts
from postroll.media.ffmpeg_check import ffmpeg_versions
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
from postroll.media import generate_title_card as card_mod
from postroll.media import render_clip_reel as clip_mod
from postroll.ai import generate_media as media_mod

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

#: The worst reading an UNCHANGED design produces on the CI runner (#787).
#:
#: Measured, not assumed, and it is the number the limit below is chosen from.
#: Every reference-frame comparison writes its reading down now, so this came
#: off two independent macos-15 jobs on 2026-08-21, `Tests / macos` and
#: `macOS / reference-frames (goldens)`, against frames recorded on Dan's Mac.
#: The two agree to the pixel:
#:
#:     nine of the ten frames    0 of 2073600 px    0.0000%
#:     clip_reel                26 of 2073600 px    0.0013%
#:
#: So the runner's own ffmpeg, which is the entire reason a share is allowed at
#: all rather than demanding an exact match, costs 26 pixels on one template and
#: nothing on the other nine. Reproducible to the pixel across two runs, so it is
#: a stable property of that template's encode rather than randomness; why it is
#: that template and not the others is not established and does not need to be
#: for this to be the floor.
#:
#: On this Mac the reading is 0 for all ten, which is why the limit could not be
#: chosen here (L177).
UNCHANGED_ON_CI = 26 / (1080 * 1920)

#: The ffmpeg that produced the reading above (#792).
#:
#: The share exists only because of the runner's ffmpeg, so the number the limit
#: was derived from can move without a commit here: both jobs that take the
#: reading pin the runner image, deliberately, since the frames were recorded
#: against its fonts, and neither pins ffmpeg. `brew install ffmpeg` takes
#: whatever Homebrew has that day.
#:
#: Read off the `Install ffmpeg` step of `macOS / reference-frames (goldens)`,
#: run 32526414536 on 2026-08-21, the same run the 26 above came from:
#: `Pouring ffmpeg--8.1.2_1.arm64_sequoia.bottle.tar.gz`. Dan's Mac was on 8.1
#: for the recording, so the 26 pixels are already the difference between two
#: builds of the same major version, which is what the tolerance is for.
#:
#: At the old limit of 0.005 there was 385x of headroom and none of this
#: mattered. At 0.0002 there is 16x, which is deliberate and correct against
#: this reading, and it means an ffmpeg that renders a few hundred pixels
#: differently fails every reference frame at once. The check below turns that
#: into one failure naming ffmpeg rather than ten reading as a design
#: regression on ten templates.
MEASURED_AGAINST_FFMPEG = "8.1.2_1"


def ffmpeg_major(version: str) -> int | None:
    """The major version of an ffmpeg version string, or None if it has none.

    None rather than a guess: `8.1.2_1`, `6.1.1-3ubuntu5` and `n7.0` are all
    real spellings this repo has seen, and a parser that fell back to a number
    on an unfamiliar one would compare two things it had made up (L11).
    """
    match = re.match(r"n?(\d+)\.", version.strip())
    return int(match.group(1)) if match else None

#: The smallest change the reference frames actually have to CATCH (#787).
#:
#: Also measured: lifting `program_plate.FOOTER_RULE_Y` by `SAFE_BOTTOM` moves
#: the entire footer colophon of both plate reels, the rose-gold rule and the
#: wordmark under it, 160 pixels up the frame. That is 7336 pixels, 0.3538% of
#: the canvas, and it is the whole signature block of a template.
#:
#: It is the smallest REAL defect there is a reading for, so the limit has to sit
#: under it. It did not: the limit was 0.005, fourteen times this, and both reels
#: passed their reference frames unchanged while their colophon moved a tenth of
#: the frame's height. That is #787.
SMALLEST_REAL_MOVE = 7336 / (1080 * 1920)

#: Share of pixels allowed past the per-channel tolerance.
#:
#: Chosen from the two measurements above rather than picked round, and it sits
#: at their geometric middle: 415 pixels, sixteen times the worst unchanged
#: reading and eighteen times under the smallest real move. Out of the dense
#: part of the distribution in both directions, so neither a slightly noisier
#: encode nor a slightly smaller layout change lands anywhere near it (L172).
#:
#: The comment that stood here said a moved element covers far more of the frame
#: than the limit. That was the claim, never a reading, and it was wrong by a
#: factor of fourteen in the direction that matters.
#:
#: `test_the_limit_sits_between_the_noise_and_the_defect` holds the gap open, so
#: a new reading that closes it from either side asks for the limit to be chosen
#: again rather than letting it drift.
MAX_CHANGED_FRACTION = 0.0002


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

    # Written down on EVERY comparison, not only the failing ones (#787). A
    # reading taken only when a check fails says nothing about where the healthy
    # ones sit, and that is the whole distribution MAX_CHANGED_FRACTION has to
    # be chosen from (L172). See tests/golden_drift.py for what is wrong with
    # the number today and why it cannot be fixed from this Mac.
    # The box comes off the mask the comparison already built, so it costs
    # nothing (#793). A count alone cannot tell scattered codec noise from a
    # moved element, which is the one thing not established about `clip_reel`.
    golden_drift.report(name, changed, total, box=mask.getbbox())

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


# ── the tool the reading was taken against ───────────────────────────────────

@needs_ffmpeg
@requires_mac_fonts
def test_the_frames_are_compared_by_the_ffmpeg_the_limit_was_measured_against():
    """One failure naming ffmpeg, rather than ten reading as a redesign (#792).

    `MAX_CHANGED_FRACTION` is chosen from a reading taken on a runner whose
    ffmpeg nothing pins. A Homebrew update that renders a few hundred pixels
    differently would fail every reference frame at once, and the first symptom
    is ten templates reporting a design regression that did not happen.

    Judged on the MAJOR version alone, which is what the evidence supports.
    The 26 pixels are already the gap between 8.1 on Dan's Mac and 8.1.2_1 on
    the runner, so a patch release is inside what the tolerance was measured
    across; a major release is not, and nothing here has ever measured one.

    Gated the same way the comparisons are, so it runs exactly where they run
    and skips where they skip. The Linux leg carries ffmpeg 6 and renders none
    of these frames; failing there would be a false alarm about a tool that
    compares nothing (L144).
    """
    running = ffmpeg_versions().get("ffmpeg")

    assert running, (
        "ffmpeg is on PATH for the frames to render and would not say what "
        "version it is, so nothing can say whether the limit's reading applies "
        "to this run")
    here, measured = ffmpeg_major(running), ffmpeg_major(MEASURED_AGAINST_FFMPEG)
    assert measured is not None, (
        f"MEASURED_AGAINST_FFMPEG is {MEASURED_AGAINST_FFMPEG!r}, which has no "
        "major version in it, so this check can compare nothing")
    # Its own message, not folded into the comparison below. An unreadable
    # version and a version a major apart are different situations with
    # different remedies, and reporting the first as the second would send
    # somebody to re-measure a limit that is fine (L11).
    assert here is not None, (
        f"ffmpeg reports its version as {running!r}, which this does not know "
        "how to read, so nothing can say whether the reading "
        "MAX_CHANGED_FRACTION rests on applies to this run. Teach "
        "`ffmpeg_major` the new spelling rather than widening the comparison.")
    assert here == measured, (
        f"these frames are being compared by ffmpeg {running} and the reading "
        f"MAX_CHANGED_FRACTION was chosen from was taken against "
        f"{MEASURED_AGAINST_FFMPEG}. A major version apart is outside anything "
        "measured here, and at 16x of headroom the limit is tight enough that "
        "a different encoder fails all ten frames at once, which reads as a "
        "design regression rather than as a new toolchain.\n"
        "  This run publishes its own drift readings; take the new numbers from "
        "them, re-choose MAX_CHANGED_FRACTION from UNCHANGED_ON_CI and "
        "SMALLEST_REAL_MOVE, and record the version here.")


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


def assert_the_title_reads_against_the_footage(
    frame: Image.Image, event_name: str, tmp_path: Path, min_contrast: float = 40.0
) -> None:
    """Friday's title measured against the footage immediately around it (#665).

    Through the card's OWN alpha rather than over a box, because a box is
    answered by whatever else is inside it. Measured, not suspected: the first
    version of this check took the darkest against the lightest pixel in a box
    around the title and passed with the type drawn in the colour of the footage
    behind it, because the card also draws a blurred shadow and two rose gold
    rules and those cleared the threshold on their own (L141).

    So the card is rendered separately, its fully opaque pixels are the type
    itself, and the pixels it did not touch at all are the footage. The
    comparison is between those two populations inside the same band, which is
    the question a person asks looking at the frame: can I read the title.
    """
    card = Image.open(
        card_mod.render_title_card_image(event_name, tmp_path / "title_card.png")
    ).convert("RGBA")
    assert card.size == frame.size, (
        f"the card is {card.size} and the frame is {frame.size}, so the alpha "
        f"does not line up with what was drawn")

    band = (0, card_mod.TITLE_CARD_ANCHOR_Y - 140,
            frame.width, card_mod.TITLE_CARD_ANCHOR_Y + 40)
    alpha = card.getchannel("A").crop(band)
    grey = frame.convert("L").crop(band)

    # The type: fully opaque. The shadow is blurred to a fraction of that and
    # the rules are drawn at 170, so neither can be mistaken for it.
    type_mask = alpha.point(lambda a: 255 if a >= 250 else 0)
    footage_mask = alpha.point(lambda a: 255 if a == 0 else 0)

    # A measurement over nothing is not a measurement (L98): an empty mask makes
    # every mean below meaningless, and the assertion would pass on it.
    type_pixels = type_mask.histogram()[255]
    footage_pixels = footage_mask.histogram()[255]
    assert type_pixels > 500, (
        f"only {type_pixels} pixels of type were drawn in the title band, so "
        f"there is nothing here to measure")
    assert footage_pixels > 500, (
        f"only {footage_pixels} untouched pixels in the title band, so there is "
        f"nothing to measure the type against")

    on_type = ImageStat.Stat(grey, mask=type_mask).mean[0]
    on_footage = ImageStat.Stat(grey, mask=footage_mask).mean[0]

    assert abs(on_type - on_footage) >= min_contrast, (
        f"the title reads {on_type:.0f} against footage at {on_footage:.0f}, a "
        f"difference of {abs(on_type - on_footage):.0f}, so it is drawn in "
        f"roughly the colour of what is behind it and cannot be read")


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
def scroll_photos(tmp_path) -> list[str]:
    """Enough photographs that the strip is TALLER than the frame (#665).

    The ten the other tests use produce a 1760px strip against a 1920px frame,
    which is the size where the scroll has nothing to scroll and the generator
    collapses it to a still. A fixture is minimal by construction, so the mode
    that actually ships is the one nothing exercises (L101). Fourteen puts the
    strip past the frame, which is where every Thursday reel Dan makes lives.
    """
    return [_patterned_photo(tmp_path / f"s{i}.jpg", seed=i) for i in range(14)]


def _clip_from_photo(photo: str, path: Path, seconds: float = 3.0) -> str:
    """A landscape video clip, the shape Friday's reel is cut from.

    Built from `_broad_photo`'s smooth bands rather than the 40px check, for the
    reason the closing hold already established: this frame is almost entirely
    photograph, and two ffmpeg builds do not agree on a near-Nyquist pattern
    once it has been scaled and cropped.

    Landscape and larger than the portrait canvas, so the crop-to-fill the
    renderer performs is actually exercised rather than being a no-op.
    """
    subprocess.run(
        ["ffmpeg", "-y", "-loop", "1", "-i", photo,
         "-t", str(seconds), "-r", "30", "-vf", "scale=1920:1280",
         "-c:v", "libx264", "-pix_fmt", "yuv420p", str(path)],
        check=True, capture_output=True)
    return str(path)


@pytest.fixture
def source_clips(broad_photos, tmp_path) -> list[str]:
    return [_clip_from_photo(photo, tmp_path / f"clip{i}.mp4")
            for i, photo in enumerate(broad_photos[:2])]


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
    # The colophon band, taken from the template's own FOOTER_RULE_Y rather
    # than as a distance from the bottom of the frame (#753). It used to be the
    # last 200 rows, which was where the colophon sat until it was lifted clear
    # of the strip Instagram lays its caption over. A literal here would have
    # gone on measuring the band the mark had LEFT, which is plain cream, and
    # reported that as unreadable: exactly the failure #752 found one file over
    # (L107).
    from postroll.media.program_plate import FOOTER_RULE_Y
    assert_ink_reads_against_its_background(
        frame, (0, FOOTER_RULE_Y, frame.width, FOOTER_RULE_Y + 200),
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


# ── the three that had no reference of their own (#665) ───────────────────────
#
# Seven templates were photographed and three were not, and those three were
# where a contrast or legibility regression could still ship unseen, which is
# the exact failure this file was written for. It also cost something concrete:
# `make record-fingerprints` (#660) records a design fingerprint only for a
# template whose reference frames have been seen to pass, so a change moving any
# of these three ended with somebody editing the record by hand.


@requires_mac_fonts
def test_the_cover_matches_its_reference_frame(photos, tmp_path):
    """Through the app's own cover path, not through the template directly.

    The cover is `generate_story` applied to one chosen photograph, so a
    reference built by calling that function would photograph the story test
    again under a second name. Going through `_render_cover` covers what is
    actually different about the cover: the sticky gate that reuses a persisted
    pick, and the wordmark the app hands it.

    `build_candidates` fails rather than returning: picking a cover fresh is a
    paid Claude call, and a reference frame must be structurally unable to make
    one (L2).
    """
    day_dir = tmp_path / "thursday"
    day_dir.mkdir()
    result: dict = {}

    media_mod._render_cover(
        day_name="thursday", day_dir=day_dir,
        day_info={"cover_source": photos[0]},
        build_candidates=lambda: pytest.fail(
            "the reference frame must never pick a cover, which is a paid call"),
        event="Reference Event", org="Reference Org", venue="Reference Venue",
        day_result=result, errors={})

    assert "cover" in result, f"no cover was rendered: {result}"
    frame = Image.open(result["cover"]).convert("RGB")
    assert_shows_real_content(frame, "cover")
    assert_matches_golden(frame, "cover", tmp_path)


@requires_mac_fonts
def test_the_reel_preview_matches_its_reference_frame(scroll_photos, tmp_path):
    """The still the Thursday crop editor draws over.

    Not a frame of the scroll reel: this is the whole strip, at the size the
    editor pans and zooms inside, and the cell rects in its sidecar are what
    every crop offset is expressed against. A cell that collapsed to a sliver
    here would move every crop the editor applied.
    """
    out = tmp_path / "reel_preview.png"
    scroll_mod.build_reel_preview(
        photo_paths=scroll_photos, output_path=str(out), seed=163)

    frame = Image.open(out).convert("RGB")
    assert frame.height > scroll_mod.CANVAS_H, (
        f"the strip is {frame.height}px against a {scroll_mod.CANVAS_H}px frame, "
        f"so this reference records the collapsed case rather than the one that "
        f"ships (L101)")
    assert_shows_real_content(frame, "reel_preview")
    assert_matches_golden(frame, "reel_preview", tmp_path)


@needs_ffmpeg
@requires_mac_fonts
def test_the_clip_reel_matches_its_reference_frame(source_clips, silent_audio,
                                                   tmp_path):
    """Friday's reel with its title card, sampled while the card is up.

    Sampled inside the hold rather than at the start: the card fades in over
    TITLE_CARD_FADE_SECONDS, so a frame taken at zero would photograph a
    half-transparent title and defend that as correct.

    The title is drawn in WHITE script over whatever the footage happens to
    show, which is the element with the worst history in this repo: a light mark
    on a light surface has shipped invisible three times. So the reference
    asserts the title reads against its own background as well as matching.
    """
    reel = clip_mod.render_clip_reel(
        [{"clip_path": clip, "trim_in": 0.0, "trim_out": 2.0,
          "transition_after": "cut"} for clip in source_clips],
        tmp_path / "clip_reel.mp4", audio_path=silent_audio)

    titled = card_mod.apply_title_card(
        reel, "Reference Event", tmp_path / "clip_reel_titled.mp4")

    # Half a second into the hold: past the fade, and well clear of its end.
    at = card_mod.TITLE_CARD_FADE_SECONDS + 0.5
    frame = _frame_from_encoded_video(titled, at, tmp_path / "clip_reel.png")

    assert_shows_real_content(frame, "clip_reel")
    assert_the_title_reads_against_the_footage(frame, "Reference Event", tmp_path)
    assert_matches_golden(frame, "clip_reel", tmp_path)


@requires_mac_fonts
def test_the_title_card_type_is_drawn_light_enough_to_sit_over_footage(tmp_path):
    """The rule the reference frame above rests on, checked without rendering.

    Here rather than beside the card's other tests, because it renders real
    script type and is therefore font-gated, and a font-gated file has to be in
    a macOS shard or it runs nowhere while CI stays green. This file is already
    that shard.

    The card is transparent, so nothing measured on its own can say whether it
    is legible: that is decided when it is composited, which the clip reel's
    reference frame checks on a real encoded frame. What this checks is the rule
    the design rests on, that the type is LIGHT, because it is laid over
    photographic footage whose mid tones are dark. It is the half a text edit can
    break, so it is the half the mutation sweep can prove.

    Measured on the type's own pixels: the card also draws a blurred black
    shadow and two rose gold rules, and either would drag a whole-image average
    down while the type stayed white.
    """
    out = tmp_path / "title.png"
    card_mod.render_title_card_image("Reference Event", out)

    card = Image.open(out).convert("RGBA")
    alpha = card.getchannel("A")
    type_mask = alpha.point(lambda a: 255 if a >= 250 else 0)

    drawn = type_mask.histogram()[255]
    assert drawn > 500, (
        f"only {drawn} fully opaque pixels, so there is no type here to measure "
        f"and this check would pass on an empty card")

    brightness = ImageStat.Stat(card.convert("L"), mask=type_mask).mean[0]
    assert brightness > 200, (
        f"the type is drawn at brightness {brightness:.0f}, which is not light "
        f"enough to read over footage; this card carries no background of its "
        f"own, so a dark title is invisible wherever it lands")


# ── the guards on the guards ──────────────────────────────────────────────────

GOLDEN_NAMES = {
    "collage", "story", "before_after",
    "slider_reel", "morph_reel", "scroll_reel", "screen_reel",
    "cover", "reel_preview", "clip_reel",
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
    for reel in ("slider_reel", "morph_reel", "scroll_reel", "screen_reel",
                 "clip_reel"):
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

LOGO_BEARING_GOLDENS = ("before_after", "story", "morph_reel", "scroll_reel",
                        "cover", "reel_preview")


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
