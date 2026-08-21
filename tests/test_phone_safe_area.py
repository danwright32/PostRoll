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
from postroll.media.design_tokens import (
    SAFE_BOTTOM,
    SAFE_RIGHT,
    SAFE_RIGHT_FROM,
    SAFE_SIDE,
    SAFE_TOP,
)
from postroll.media.generate_before_after import generate_before_after
from postroll.media.generate_collage import generate_collage
from postroll.media.generate_reel_screen import build_chrome_overlay
from postroll.media.generate_reel_morph import draw_branded_chrome as morph_chrome
from postroll.media.generate_reel_scroll import draw_branded_chrome
from postroll.media.generate_reel_slider import draw_branded_chrome as slider_chrome
from postroll.media.generate_reel_slider import hang_the_states
from postroll.media.generate_story import generate_story
from postroll.media.program_plate import load_logo as plate_logo

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
    return _branding_pixels(with_text, without_text,
                            (0, 0, with_text.width, inset))


def _branding_pixels(with_text: Image.Image, without_text: Image.Image,
                     box: tuple[int, int, int, int]) -> int:
    """How many pixels inside `box` this template's own branding changed.

    The difference of two renders of one template, one carrying its event name,
    org, venue and wordmark and one carrying none of them. Whatever changed is
    what this template put there, which is the only thing a covered band is
    about: the photograph underneath is Dan's, and Instagram covering part of it
    is a fact of the platform rather than a defect (L146).
    """
    assert with_text.size == without_text.size, "two sizes cannot be differenced"
    a = with_text.convert("RGB").crop(box)
    b = without_text.convert("RGB").crop(box)
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
    """The scroll reel's fixed chrome, with no wordmark, which is how the reel
    renders it: every call site in `generate_reel_scroll` passes None here. Its
    colophon is baked into the scrolling strip instead, and rides with it, so it
    is not a fixed band and `test_the_scroll_reels_colophon_is_measured_elsewhere`
    says where it IS measured rather than leaving the gap unnamed."""
    frame = Image.new("RGB", CANVAS, (128, 128, 128))
    return draw_branded_chrome(frame, EVENT if named else "",
                               ORG if named else "", VENUE if named else "", None)


def _reel_screen_chrome(tmp_path: Path, named: bool) -> Image.Image:
    """With the wordmark, which its render passes: measuring this chrome without
    one would measure a frame the product never makes (L48)."""
    return build_chrome_overlay(EVENT if named else "", ORG if named else "",
                                VENUE if named else "", LOGO if named else None)


def _reel_morph_chrome(tmp_path: Path, named: bool) -> Image.Image:
    """One frame of the morph reel's chrome, drawn by the render's own call.

    #759: these two were checked only against the coordinates declared in
    `text_regions.py`, which is a check of what those files SAY rather than of
    what the template draws. #752 found exactly that failure one file over,
    where `scroll_regions` carried its own copy of the old y=35 and would have
    gone on measuring a band the title had left.
    """
    frame = Image.new("RGB", CANVAS, (128, 128, 128))
    return morph_chrome(frame, EVENT if named else "", ORG if named else "",
                        VENUE if named else "", plate_logo(LOGO) if named else None)


def _reel_slider_chrome(tmp_path: Path, named: bool) -> Image.Image:
    """The same for the slider, through the rect its own layout produces.

    The rect only positions the placards, which sit far below the band, but it
    is taken from `hang_the_states` rather than invented so that this renders
    the arrangement the reel actually renders (L48).
    """
    photos = [Image.open(_photo(tmp_path / f"s{i}.jpg", 90 + i * 30))
              for i in range(3)]
    rect, _ = hang_the_states(*photos)
    frame = Image.new("RGB", CANVAS, (128, 128, 128))
    return slider_chrome(frame, EVENT if named else "", ORG if named else "",
                         VENUE if named else "", plate_logo(LOGO) if named else None,
                         rect, "RAW", "Edit", 0.0)


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
    "reel_morph": _reel_morph_chrome,
    "reel_slider": _reel_slider_chrome,
    "story": _story,
}


#: Templates allowed to draw in the covered band, by name and by issue.
#:
#: Empty since #756 put a floor under the story's title, which was the one
#: entry. `test_every_exemption_is_still_needed` is what emptied it: the story
#: started clearing the band and that test went red naming itself, which is
#: exactly what #760 added it to do.
#:
#: A template named here is excused from the check written to cover it, so the
#: entry has to say which issue will end it, and that issue has to be open. A
#: template simply MISSING from RENDERERS would be excused with nobody able to
#: see that it is (L129, L96); `test_every_full_frame_template_is_accounted_for`
#: below holds the two lists together.
EXEMPT: dict[str, str] = {}

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


#: The other two bands, measured on the same day from the same posts (#753).
#:
#: Instagram lays its account row and caption over the foot of the frame, and
#: its like, comment, share and save rail down the right of the lower half.
#:
#: The bottom band is enforced: what it covers is the signature, which is the
#: reason the chrome exists at all. The rail is measured and NOT enforced, for
#: the reason `test_the_action_rail_is_measured_but_not_enforced` gives.
BOTTOM_BAND = (0, CANVAS[1] - SAFE_BOTTOM, CANVAS[0], CANVAS[1])
RAIL_BAND = (CANVAS[0] - SAFE_RIGHT, int(CANVAS[1] * SAFE_RIGHT_FROM),
             CANVAS[0], CANVAS[1])

#: Templates whose branding is inside the bottom band and has not been moved
#: yet, by name and by issue.
#:
#: Measured on real renders of a real show on 2026-08-20. Moving a colophon
#: costs photograph, which makes it a layout decision rather than a nudge, and
#: Dan takes those one at a time: he took the story's on the night, and these
#: four are still his to take. Named here rather than left out, so each one is
#: measured and visible, and `test_every_bottom_exemption_is_still_needed`
#: below turns any of them red the moment it stops being true (L129, #760).
EXEMPT_BOTTOM = {
    "before_after": "#753, the wordmark sits in the band",
    "reel_morph": "#753, the plate's footer colophon sits in the band",
    "reel_slider": "#753, the plate's footer colophon sits in the band",
    "reel_screen": "#753, the wordmark sits in the band",
}

MEASURED_BOTTOM = sorted(set(RENDERERS) - set(EXEMPT_BOTTOM))


#: The two columns the phone never shows at all (#768).
#:
#: Not covered, CROPPED: Instagram scales the frame wider than the screen, so
#: these pixels are not drawn anywhere. That makes this the strictest of the
#: bands, and the cheapest to satisfy, since every template centres what it
#: draws.
SIDE_BANDS = {
    "left": (0, 0, SAFE_SIDE, CANVAS[1]),
    "right": (CANVAS[0] - SAFE_SIDE, 0, CANVAS[0], CANVAS[1]),
}


#: How much branding may fall off a side before it counts.
#:
#: Not zero, and the reason is measured. Three templates run a decorative
#: rose-gold hairline from their mat edge, which is 48 or 50px in, so its first
#: ten pixels are cropped: 20 and 22 for the story's inline title rules, 35 for
#: the plate reels' masthead rule. A hairline losing its last ten pixels at the
#: screen edge is not something anybody can see, and a rule that failed on it
#: would fail every correct render, which is what gets a check switched off
#: (L36, L104).
#:
#: 500 is far above those and far below anything that carries meaning: a
#: wordmark or a line of type reaching this far measures in the thousands. The
#: gap between the real readings and the floor is more than an order of
#: magnitude in both directions, which is what keeps it out of the dense middle
#: where a small shift would carry templates across it (L172).
SIDE_ALLOWANCE = 500


@needs_mac_fonts
@pytest.mark.parametrize("side", sorted(SIDE_BANDS))
@pytest.mark.parametrize("name", sorted(RENDERERS))
def test_no_template_draws_words_off_the_side_of_the_screen(name, side, tmp_path):
    render = RENDERERS[name]
    marked = _branding_pixels(render(tmp_path, True), render(tmp_path, False),
                              SIDE_BANDS[side])

    assert marked <= SIDE_ALLOWANCE, (
        f"{name} puts {marked} pixels of its own branding in the {side} "
        f"{SAFE_SIDE}px, over the {SIDE_ALLOWANCE} a cropped hairline accounts "
        "for. The phone crops that column off entirely: Instagram scales a 1080 "
        "wide frame to 1476 screen px in a 1320 px window, so those pixels are "
        "not drawn anywhere at all (#768). This is not something a viewer has "
        "to read past; it is something no viewer ever sees.")


@needs_mac_fonts
def test_the_side_measurement_can_still_see_something_there(tmp_path):
    """The control.

    Every reading above is under an allowance, and a measurement that had
    stopped seeing anything would report every template clear while sitting
    comfortably under it (L98, L159). This puts a wordmark's worth of ink in the
    cropped column and checks the reading rises past the allowance.
    """
    from PIL import ImageDraw

    plain = Image.new("RGB", CANVAS, (128, 128, 128))
    marked = plain.copy()
    ImageDraw.Draw(marked).rectangle([0, 400, SAFE_SIDE - 1, 1400],
                                     fill=(20, 20, 20))

    reading = _branding_pixels(marked, plain, SIDE_BANDS["left"])

    assert reading > SIDE_ALLOWANCE, (
        f"a solid block filling the cropped column measures {reading}, under "
        f"the {SIDE_ALLOWANCE} allowance, so the check above could not fail")


@needs_mac_fonts
@pytest.mark.parametrize("name", MEASURED_BOTTOM)
def test_no_template_draws_branding_under_instagrams_caption(name, tmp_path):
    render = RENDERERS[name]
    marked = _branding_pixels(render(tmp_path, True), render(tmp_path, False),
                              BOTTOM_BAND)

    assert marked == 0, (
        f"{name} puts {marked} pixels of its own branding in the bottom "
        f"{SAFE_BOTTOM}px, which is where Instagram lays its account row and "
        "its caption. Whatever is there is printed under Instagram's own words "
        "and nobody reads it (#753). Move it above "
        "design_tokens.SAFE_BOTTOM rather than nudging a number.")


@needs_mac_fonts
@pytest.mark.parametrize("name", sorted(RENDERERS))
def test_the_action_rail_is_measured_but_not_enforced(name, tmp_path):
    """The rail is drawn on the app preview and is deliberately not a rule.

    Every template here centres its wordmark and its detail lines, so any of
    them wide enough runs into the right 240px column somewhere below 54% of the
    height. Measured: before_after puts 42290 pixels there and the story 34550,
    and both are simply the ends of centred type, not branding hidden in a
    corner.

    A rule of "no branding under the rail" would therefore fail every correct
    render, and the first false alarm is what gets a check switched off (L36,
    L104). There is no evidence of harm either: on the published post this was
    measured from, what the rail covers is photograph.

    So the token exists, #758 draws it on the preview where Dan can see it, and
    this records the measurement rather than pretending to a rule. What IS
    asserted is that the reading can still be taken at all: a measurement that
    had silently stopped working would report every template clear, and this
    file would then be enforcing the bottom band on renders nothing had checked.
    """
    render = RENDERERS[name]
    under_rail = _branding_pixels(render(tmp_path, True), render(tmp_path, False),
                                  RAIL_BAND)
    whole_frame = _branding_pixels(render(tmp_path, True), render(tmp_path, False),
                                   (0, 0, CANVAS[0], CANVAS[1]))

    assert whole_frame > 0, (
        f"{name} drew none of its branding anywhere, so this measurement is of "
        "nothing at all")
    assert 0 <= under_rail <= whole_frame, (
        f"{name} measures {under_rail} pixels under the rail out of "
        f"{whole_frame} on the whole frame, which is not a possible reading")


@needs_mac_fonts
def test_every_bottom_exemption_is_still_needed(tmp_path):
    """The same rule #760 wrote for the top band, applied to this one.

    An exemption dies with the defect it was written about. Fixing a template
    turns this red, naming itself and asking to be deleted, so the four above
    cannot sit on unmeasured after Dan has taken the layout decision each of
    them is waiting for.
    """
    if not EXEMPT_BOTTOM:
        pytest.skip("nothing is exempt from the bottom band, so no exemption "
                    "can have outlived its reason")

    outlived = []
    for name in sorted(EXEMPT_BOTTOM):
        render = RENDERERS[name]
        if _branding_pixels(render(tmp_path, True), render(tmp_path, False),
                            BOTTOM_BAND) == 0:
            outlived.append(name)

    assert not outlived, (
        f"these templates are exempt from the bottom band check and no longer "
        f"need to be: {outlived}. Whatever put branding under Instagram's "
        "caption is gone, so the exemption now excuses nothing and hides the "
        "template from the check. Delete its entry from EXEMPT_BOTTOM.")


def test_every_bottom_exemption_names_a_template_that_can_be_rendered():
    unrenderable = sorted(set(EXEMPT_BOTTOM) - set(RENDERERS))

    assert not unrenderable, (
        f"these templates are exempt from the bottom band but have no renderer: "
        f"{unrenderable}, so nothing can ever check whether the exemption is "
        "still needed.")


def test_the_scroll_reels_colophon_is_measured_elsewhere():
    """Named rather than silently uncovered (L129).

    `_reel_scroll_chrome` draws the reel's FIXED chrome, and that chrome carries
    no wordmark: every call site in the render passes None. The reel's colophon
    is baked into the scrolling strip under the last print, so it rides with the
    strip and is not a fixed band at all. This check cannot see it.

    Measured by hand on 2026-08-20 on a 20 photo strip: at the end of the scroll
    its lowest ink is at y=1714 against a band starting at 1760, so it clears by
    46px. That is a reading on one photo count, and the strip's height moves with
    the number of photos, which is why it is written down here as a gap rather
    than left to look like coverage.
    """
    from postroll.media import generate_reel_scroll as scroll
    import inspect

    source = inspect.getsource(scroll.generate_reel_scroll)

    assert "draw_branded_chrome(frame, event_name, org, venue, None)" in source, (
        "the scroll reel now passes a logo to its fixed chrome, so its footer "
        "carries a wordmark inside the band Instagram covers, and this file's "
        "renderer measures the chrome without one. Either take the logo back "
        "out or render this template with it here.")


@needs_mac_fonts
@pytest.mark.parametrize("name", sorted(RENDERERS))
def test_every_render_actually_draws_its_words(name, tmp_path):
    """The control for the band check, one per template.

    The measurement above asks whether anything changed inside the top band. A
    renderer that drew NO words at all changes nothing there either, and reports
    exactly what a template that clears the band reports (L98, L159). So each
    render is first proved to put its words somewhere on the page.

    It earns its keep on the two plate reels #759 added: their titles sit at
    MASTHEAD_Y=176, six pixels below a 170px band, so their band reading is zero
    whether the chrome drew a masthead or drew nothing at all.
    """
    render = RENDERERS[name]
    marked = _text_pixels_in_band(render(tmp_path, True), render(tmp_path, False),
                                  CANVAS[1])

    assert marked > 0, (
        f"{name} renders identically with its event name, org and venue and "
        "without them, so it drew none of them anywhere on the frame. Every "
        "measurement of this template is then a measurement of nothing.")


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

    # What is measured somewhere else, and why. The two plate reels came OUT of
    # this list in #759: they draw their chrome through a pure function like
    # every other template here, so they are rendered and differenced above
    # rather than trusted to the coordinates text_regions.py declares.
    ELSEWHERE = {"reel_clip", "reel_preview", "cover"}

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
