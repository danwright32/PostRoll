"""No full-frame template draws text in the band the phone covers (#752).

Reported from a live Instagram story on an iPhone: the show title on the
scroll reel sat directly under the status bar and Dynamic Island, so the one
part of the frame carrying the show's identity was overprinted by the clock,
the signal bars and the battery.

Two templates already cleared it and two never did, because the rule lived in
a code comment in the two that had it and nowhere else:

* `generate_reel_screen` draws its title at 170 and says why
* `generate_before_after` pads its header to 170 and says why
* `generate_reel_scroll` drew its title at 35, inside the covered band
* `generate_story` anchored its title bottom-up off the photo with no top
  clamp at all, so a two-line title started around y=33

So the fix is a token every template reads, and this is the check that holds
them all to it. Without it the next template cloned from an existing one
inherits whichever version it copied (L30, L96).

## How it measures

Each template is rendered twice, once with its real event name, org and venue
and once with all three empty, and the two renders are differenced. Whatever
changed inside the top band is text this template put there.

Rendering the difference rather than looking for ink of a known colour is
deliberate. A story's title is drawn over a photograph with a drop shadow, so
there is no flat background to compare against and no single colour to search
for: any quantity computed over the band as a whole counts the photograph too
(L146).

## Why the rendering checks are font gated

Everything measured here is the SIZE and POSITION of type set in HelveticaNeue
and SignPainter, which are macOS system faces. On a Linux runner `load_font`
degrades to Pillow's tiny default, so every title renders a fraction of its
real height, clears the band comfortably, and the check reports a clean sweep
over a rendering the app never produces (L504).

That is not hypothetical. This file shipped ungated in #752 and the Linux leg
measured Pillow's default the whole time; #760's exemption check is what said
so out loud, by reporting the story as no longer needing its exemption on a
runner where its title had never been drawn at the real size.

So the renders carry `needs_mac_fonts`, which skips them where the faces are
absent, and `tests/test_ci_runs_the_font_dependent_checks.py` then requires this
file to be named in the reference-frames matrix, so they actually run somewhere
rather than skipping everywhere (L98, L3).
"""

from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image, ImageChops

from conftest import needs_mac_fonts
from postroll.media.design_tokens import SAFE_TOP
from postroll.media.generate_before_after import generate_before_after
from postroll.media.generate_collage import generate_collage
from postroll.media.generate_reel_screen import build_chrome_overlay
from postroll.media.generate_reel_scroll import draw_branded_chrome
from postroll.media.generate_story import generate_story

#: Out of `make test-python-fast`, which deselects this marker.
#:
#: Not because these renders are expensive, they are about a second all told.
#: `test_fast_subset_stays_honest.py` derives the fast run's exclusions from the
#: reference-frames matrix rather than keeping a second list beside it, and this
#: file has to be IN that matrix, because everything it measures is the size of
#: type in the macOS system faces and those exist on no other runner. So the one
#: marker carries both meanings here. #766 is about separating them.
pytestmark = pytest.mark.slow

REPO_ROOT = Path(__file__).resolve().parent.parent
LOGO = str(REPO_ROOT / "postroll" / "assets" / "logo-black.png")

#: A name long enough to wrap to two lines in the story's script face, which is
#: the case with no floor under it at all: each extra line moves the block ~85px
#: further up. A single-line fixture would exercise the shallow branch only and
#: the deep one is where the defect lives (L101).
EVENT = "The One-Man Odyssey and Other Stories"
ORG = "A Presenting Organisation"
VENUE = "A Concert Hall"

CANVAS = (1080, 1920)


def _photo(path: Path, shade: int = 128, portrait: bool = False) -> str:
    """A flat photograph. What is being measured is the difference between two
    renders, so the picture underneath only has to be the same in both."""
    size = (1332, 2000) if portrait else (2000, 1332)
    Image.new("RGB", size, (shade, shade, shade)).save(path, "JPEG", quality=92)
    return str(path)


def _text_pixels_in_band(with_text: Image.Image, without_text: Image.Image,
                         inset: int) -> int:
    """How many pixels of the top `inset` rows this template's text changed."""
    assert with_text.size == without_text.size, "two sizes cannot be differenced"
    a = with_text.convert("RGB").crop((0, 0, with_text.width, inset))
    b = without_text.convert("RGB").crop((0, 0, without_text.width, inset))
    difference = ImageChops.difference(a, b)
    # A tolerance, because the script face is anti-aliased and its faintest
    # edge pixels are a rounding difference rather than a mark anybody sees.
    return sum(1 for pixel in difference.getdata() if max(pixel) > 12)


def _story(tmp_path: Path, named: bool) -> Image.Image:
    # A PORTRAIT photograph, which is the case with no room to spare: the story
    # fits a photo to the taller of the two axes, so an upright one fills the
    # band and sits at the top of its area, leaving the title the least space
    # it ever gets. A landscape photo is centred lower and hands the title
    # hundreds of pixels it cannot rely on, which is the shallow branch (L101).
    out = tmp_path / f"story-{named}.png"
    generate_story(photo_path=_photo(tmp_path / "photo.jpg", portrait=True),
                   event_name=EVENT if named else "",
                   org=ORG if named else "",
                   venue=VENUE if named else "",
                   output_path=str(out), logo_path=LOGO)
    return Image.open(out)


def _collage(tmp_path: Path, named: bool) -> Image.Image:
    out = tmp_path / f"collage-{named}.png"
    photos = [_photo(tmp_path / f"c{i}.jpg", 100 + i * 10) for i in range(4)]
    generate_collage(photo_paths=photos, output_path=str(out),
                     event_name=EVENT if named else "",
                     org=ORG if named else "",
                     venue=VENUE if named else "",
                     logo_path=LOGO, seed=7, write_layout_sidecar=False)
    return Image.open(out)


def _before_after(tmp_path: Path, named: bool) -> Image.Image:
    out = tmp_path / f"ba-{named}.png"
    generate_before_after(raw_path=_photo(tmp_path / "raw.jpg", 90),
                          edit_path=_photo(tmp_path / "edit.jpg", 150),
                          output_path=str(out),
                          event_name=EVENT if named else "",
                          org=ORG if named else "",
                          venue=VENUE if named else "",
                          logo_path=LOGO)
    return Image.open(out)


def _reel_scroll_chrome(tmp_path: Path, named: bool) -> Image.Image:
    frame = Image.new("RGB", CANVAS, (128, 128, 128))
    return draw_branded_chrome(frame, EVENT if named else "",
                               ORG if named else "", VENUE if named else "", None)


def _reel_screen_chrome(tmp_path: Path, named: bool) -> Image.Image:
    return build_chrome_overlay(EVENT if named else "", ORG if named else "",
                                VENUE if named else "", None)


#: Every template that fills a phone screen, and how to render one.
#:
#: Exempt templates are in here too, with a renderer, rather than named in a
#: list of their own with nothing able to draw them. An exemption whose
#: template cannot be rendered is an exemption nothing can ever re-measure, and
#: re-measuring it is the whole of `test_every_exemption_is_still_needed`
#: below (#760).
#:
#: The reels are their chrome function rather than a rendered video: the
#: header is drawn by a pure function, and encoding a file to read one band of
#: one frame would put a check that runs in a second behind ffmpeg.
RENDERERS = {
    "collage": _collage,
    "before_after": _before_after,
    "reel_scroll": _reel_scroll_chrome,
    "reel_screen": _reel_screen_chrome,
    "story": _story,
}


#: The story, exempted by name and by issue (#756).
#:
#: Its title hangs off the top of the photograph with no floor under it, so an
#: UPRIGHT photograph puts it in the covered band. Deferred on Dan's call: he
#: does not shoot upright photos for stories, and with a landscape photograph
#: the photo is centred lower and the title clears the band by hundreds of
#: pixels. Named here rather than left out, because a template that is simply
#: absent from the table is exempt from the check written to cover it and
#: nobody can see that it is (L129, L96). `test_every_full_frame_template_is_
#: accounted_for` below holds the two lists together.
EXEMPT = {"story": "#756, deferred: only upright photographs reach it"}

#: What the measurement actually holds to the token, derived rather than
#: written out beside RENDERERS: a second hand-kept list is a second place for
#: a template to go missing from (L41).
MEASURED = sorted(set(RENDERERS) - set(EXEMPT))


@needs_mac_fonts
@pytest.mark.parametrize("name", MEASURED)
def test_no_template_draws_text_under_the_phone_chrome(name, tmp_path):
    render = RENDERERS[name]
    marked = _text_pixels_in_band(render(tmp_path, True), render(tmp_path, False),
                                  SAFE_TOP)

    assert marked == 0, (
        f"{name} draws {marked} pixels of text in the top {SAFE_TOP}px, which "
        "is the band the iPhone status bar and Dynamic Island cover on a story "
        "or reel. Whatever is there is printed under the clock and the battery "
        "and nobody can read it (#752). Move it below "
        "design_tokens.SAFE_TOP rather than nudging a number.")


@needs_mac_fonts
def test_every_exemption_is_still_needed(tmp_path):
    """An exemption dies with the defect it was written about (#760).

    `EXEMPT` says a template is allowed to draw in the covered band, and gives
    the issue that will one day stop that being true. Nothing noticed when an
    exemption stopped being NEEDED: #756 lands, the story clears the band, and
    the exemption sits on unmeasured, which is exactly the hole naming it here
    rather than leaving it out was written to make visible (L129).

    So each exemption is held to its own reason: the template it names must
    still FAIL the measurement it is excused from. Fixing the template turns
    this red, naming itself and asking to be deleted.
    """
    if not EXEMPT:
        # Skipped rather than passed, because a check with nothing to check
        # reports exactly what a check that found nothing wrong reports (L98).
        pytest.skip("no template is exempt, so no exemption can have outlived "
                    "its reason")

    outlived = []
    for name in sorted(EXEMPT):
        render = RENDERERS[name]
        marked = _text_pixels_in_band(render(tmp_path, True),
                                      render(tmp_path, False), SAFE_TOP)
        if marked == 0:
            outlived.append(name)

    assert not outlived, (
        f"these templates are exempt from the top-band check and no longer "
        f"need to be: {outlived}. Whatever put text under the phone's chrome "
        "is gone, so the exemption now excuses nothing and hides the template "
        "from the check. Delete its entry from EXEMPT (and close the issue it "
        f"names: {[EXEMPT[name] for name in outlived]}).")


def test_an_exemption_names_a_template_that_can_be_rendered():
    """An exemption for a template nothing can draw is one nothing can ever
    re-measure, so the test above would report it as still needed forever."""
    unrenderable = sorted(set(EXEMPT) - set(RENDERERS))

    assert not unrenderable, (
        f"these templates are exempt but have no renderer in RENDERERS: "
        f"{unrenderable}, so nothing can ever check whether the exemption is "
        "still needed. Add a renderer beside the others.")


def test_every_full_frame_template_is_accounted_for():
    """Measured or exempted, never simply missing.

    The versions table is the list of templates this project renders, and a
    template that appears in neither list here would be exempt from the check
    without anyone deciding that it should be (L96).
    """
    from postroll.media.design_tokens import MEDIA_DESIGN_VERSIONS

    # The video-only templates draw their chrome through functions this file
    # cannot call without encoding a file; their bands are declared in
    # text_regions.py and measured by the reel legibility suites instead.
    ELSEWHERE = {"reel_morph", "reel_slider", "reel_clip", "reel_preview", "cover"}

    covered = set(RENDERERS) | set(EXEMPT) | ELSEWHERE
    missing = sorted(set(MEDIA_DESIGN_VERSIONS) - covered)

    assert not missing, (
        f"these templates render a full phone screen and nothing here measures "
        f"or exempts them: {missing}. Add a renderer to RENDERERS, or name the "
        "reason and the issue in EXEMPT.")


def test_the_measurement_can_still_see_text_in_the_band(tmp_path):
    """The control. A difference that had stopped seeing anything would report
    every template clean, which is the shape a green sweep hides (L1, L98)."""
    from PIL import ImageDraw

    plain = Image.new("RGB", CANVAS, (128, 128, 128))
    marked = plain.copy()
    ImageDraw.Draw(marked).text((100, 40), "UNDER THE NOTCH", fill=(20, 20, 20))

    assert _text_pixels_in_band(marked, plain, SAFE_TOP) > 0


def test_the_measurement_ignores_text_below_the_band(tmp_path):
    """The other direction: a rule that fired on text anywhere would fail every
    template for drawing its title at all (L104)."""
    from PIL import ImageDraw

    plain = Image.new("RGB", CANVAS, (128, 128, 128))
    marked = plain.copy()
    ImageDraw.Draw(marked).text((100, SAFE_TOP + 40), "SAFELY BELOW", fill=(20, 20, 20))

    assert _text_pixels_in_band(marked, plain, SAFE_TOP) == 0
