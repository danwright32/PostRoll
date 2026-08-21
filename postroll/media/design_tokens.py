"""PostRoll brand design tokens.

The one home for the colours, type and mat scale the media generators share.
Before this module each generator carried its own copies, so a brand change had
to be found and applied by hand in every file and a missed one shipped an
off-brand asset (#162).

`PostRollApp/Sources/DesignTokens.swift` mirrors the shared colours for the
app's own chrome, because Swift cannot import this file. `tests/
test_design_tokens.py` asserts the two agree, since nothing else keeps that
seam honest.

Deliberately NOT here: per-template geometry. Logo width, title baselines and
the row rhythm differ by template on purpose (the scroll reel's colophon logo
is 800px because it sits under a full-width strip; the collage plate's is 240px
because it sits in a 90px caption plate). Those stay in the generator that owns
them. What belongs here is anything two templates are supposed to agree on.
"""

from __future__ import annotations

from dataclasses import dataclass

from PIL import ImageFont


# ── Colour ────────────────────────────────────────────────────────────────────

#: Which generation of the collage design a rendered PNG came from (#160).
#:
#: Bumped whenever the collage's tokens or geometry change enough that an
#: already-rendered PNG no longer looks like a fresh one. Cached collages carry
#: this in their layout sidecar, so the app can badge a day whose collage
#: predates the current design instead of it silently rendering the old look
#: forever. `DesignTokens.collageDesignVersion` mirrors it; nothing but the
#: parity test keeps the two in step.
#:
#: 1 is the gallery redesign (c65a0d6: gallery mat, caption plate, shape-aware
#: layout). Anything rendered before that is unstamped, which reads as older
#: rather than as version 0.
COLLAGE_DESIGN_VERSION = 1


#: Which generation of each template's design this build renders (#286).
#:
#: #160 gave only the collage a version, so a cached Thursday scroll reel,
#: Tuesday reel, before/after or story rendered before the same gallery
#: redesign kept rendering the old look indefinitely with nothing saying so.
#: The reels are the worst of it: re-rendering one is expensive enough that
#: nobody does it speculatively, so a stale one survives longest.
#:
#: Keyed by the filename stem the generator writes into a day folder, because
#: that is what `tests/test_media_design_version.py` reads back out of
#: generate_media.py to check nothing new escaped the table. Bump an entry
#: whenever that template's tokens or geometry change enough that an
#: already-rendered asset no longer looks like a fresh one; bumping one does
#: not badge the others, which is the point of a table rather than one number.
#:
#: 1 is the gallery redesign (c65a0d6) throughout. Anything rendered before it
#: is unstamped, which reads as older rather than as version 0.
#:
#: `DesignTokens.mediaDesignVersions` mirrors this; nothing but the parity test
#: keeps the two in step.
#:
#: Bumping it is still a decision, but no longer one that can be forgotten:
#: `postroll/media/design_fingerprint.py` hashes what each template is drawn
#: from, and `tests/test_media_design_fingerprint.py` fails until a change to a
#: template is reconciled with the number here (#294).
MEDIA_DESIGN_VERSIONS: dict[str, int] = {
    # Derived, not restated: the layout sidecar #160 shipped still carries the
    # collage's number, and two copies maintained by hand drift the moment one
    # is bumped.
    "collage": COLLAGE_DESIGN_VERSION,
    # 2 is the wordmark lifted clear of Instagram's caption band (#753).
    #
    # Its ink ended at y=1780 against a band starting at 1760, measured on a
    # published post on 2026-08-20, so the last line of the signature,
    # PHOTOGRAPHY.COM, was under Instagram's own words on every story ever
    # made. Every one of them looks different now.
    #
    # Which is why this moves where #756 deliberately did not, four commits
    # earlier on the same template. That fix put a floor under the title, and
    # the floor only ever moves anything for an upright photograph, which Dan
    # does not shoot. This one moves every story.
    "story": 2,
    # Rendered through generate_story's exact template, so it moves with the
    # story rather than carrying a number of its own.
    "cover": 2,
    # 2 is the colophon lifted clear of Instagram's caption band (#753).
    #
    # Its whole footer block, the rose-gold rule and the mark under it, sat
    # inside the strip Instagram lays its account row and caption over: 31587
    # pixels of branding measured in the band on 2026-08-20. The photographs
    # shrink by SAFE_BOTTOM to pay for it, so every before/after ever made looks
    # different and is badged.
    #
    # It waited on #777 and #779, which is what the lift broke rather than the
    # design: two checks were reading the wrong part of the frame.
    "before_after": 2,
    # 2 is the same move on this template: its cream footer sits above the band
    # now rather than at the very foot of the frame.
    "reel_screen": 2,
    # 3 is the colophon lifted clear of Instagram's caption band (#753), the
    # last two templates to move.
    #
    # It waited on nothing in this file. The reason recorded here for months,
    # that lifting the footer rule shrinks MAX_PRINT_H and pushes the placard
    # caption up into the photograph's zoom, was wrong in both halves: the zoom
    # is disabled on the morph (ZOOM_START == ZOOM_END) and the slider has none
    # at all, and the 1.76 to 1 contrast reading that was blamed on it came from
    # a check reading the closing before/after graphic through this reel's bands
    # (#777, fixed). Measured after that fix: lifting the rule leaves every
    # legibility band green.
    #
    # The print does shrink by SAFE_BOTTOM, but only for a photograph tall
    # enough to be clamped, and the caption of a 3:2 landscape does not move at
    # all. program_plate.MAX_PRINT_H carries that reading.
    "reel_morph": 3,
    "reel_slider": 3,
    # 2 is the taller header that keeps the title out of the band the phone
    # covers (#752): it drew at y=35, under the status bar, on every reel.
    "reel_scroll": 2,
    # The still the Thursday crop editor draws over. Same layout maths as the
    # reel it previews, so a redesign of one dates the other.
    "reel_preview": 2,
    # Friday's auto-cut clip reel. The feature is retired (2026-07-09) but the
    # renderer is still reachable, and an asset that can still be produced
    # still needs to say which design produced it.
    "reel_clip": 1,
}


#: Files a day folder can hold that carry no design of their own (#286).
#:
#: Declared rather than silently skipped, so that adding a new file to a day
#: folder is a decision between "this is a design surface" and "this is not"
#: instead of an omission nobody sees. The parity test refuses anything in
#: neither table.
UNVERSIONED_DAY_FILES: frozenset[str] = frozenset({
    # Friday's winning cover candidate, copied out of the temp dir the frame
    # extraction wrote it to. A source photograph, not a rendered template:
    # regenerating the day cannot make it look newer.
    "cover_frame",
})


# ── Phone safe area ───────────────────────────────────────────────────────────

#: How much of the top of a full-frame asset the phone itself covers (#752).
#:
#: Every template here is 1080 by 1920, which is what Instagram shows full
#: screen as a story or a reel, and the phone draws its own furniture over the
#: top of that: the status bar with the clock, the signal and the battery, and
#: on a modern iPhone the Dynamic Island cut out of the display. Measured
#: against a 1080 wide frame, that furniture occupies roughly the top 120px;
#: 170 is that plus breathing room, so a title does not sit tight against the
#: island either.
#:
#: The number is not new. `generate_reel_screen` and `generate_before_after`
#: have both cleared exactly this band since they were written, each with its
#: own copy of it and a comment explaining why. The scroll reel and the story
#: were written without it: the scroll reel drew its title at y=35, printed
#: under the clock on every reel published, and the story anchors its title to
#: the photograph with no floor at all (#756). A rule that lives in a comment
#: in the two files that honour it is a rule the next two files do not have
#: (L96), so it lives here, and `tests/test_phone_safe_area.py` holds every
#: template to it by rendering the frame rather than by reading the source.
#:
#: Confirmed by measurement on 2026-08-20 (#761), from two published reels
#: photographed on Dan's iPhone 16 Pro Max, screen 1320 by 2868.
#:
#: Instagram displays the 1080 wide frame at 1476 screen px. That scale, 1.3667,
#: was fitted on seven landmarks in the rendered chrome and puts the title's
#: centre at canvas x 541.5 against a true centre of 540, so the mapping is good
#: to about a pixel. At that scale the iOS clock, signal and battery occupy
#: canvas y 54 to 86. The Dynamic Island covers canvas y 24 to 105; its geometry
#: comes from the device rather than from the screenshot, because it is a
#: physical cut out and a screenshot renders app content there.
#:
#: So the lowest phone furniture ends at canvas y 105 and this clears it by
#: 65px. The estimate this number started as was close, and it is a reading now.
SAFE_TOP = 170

#: How much of the FOOT of a full-frame asset Instagram covers (#753).
#:
#: Measured the same way, the same day, from the same two posts. Instagram lays
#: its account row and the caption over the bottom of a reel: its text begins at
#: canvas y 1770 and runs to the bottom edge, so 150px of the frame carries
#: Instagram's words rather than ours. A gradient scrim fades in above that,
#: faintly readable from about canvas y 1660 and reaching a darkening of 50 in
#: 255 at the foot.
#:
#: 160 is the measured text band plus a little. Deliberately not the scrim: it
#: reduces contrast without hiding anything, and holding every template to 260
#: to escape a gradient would cost the photograph a seventh of the frame to buy
#: very little.
#:
#: What WAS inside it, measured on real renders of a real show rather than on
#: fixtures: before_after's wordmark, the two plate reels' footer colophon, the
#: screen reel's wordmark, and the last line of the story's wordmark. The scroll
#: reel and the collage always cleared it.
#:
#: All four have been moved above it now, the plate reels last (#778). Nothing
#: is exempt: `tests/test_phone_safe_area.py` measures every template against
#: this band, and its exemption table is empty.
SAFE_BOTTOM = 160

#: How much of the RIGHT EDGE Instagram's action rail covers (#753).
#:
#: The like, comment, share and save column with its counts, from the same
#: posts: it occupies canvas x 847 to the right edge. 240 is that rounded up.
#:
#: Paired with SAFE_RIGHT_FROM rather than applied to the whole edge, because a
#: rail over the bottom half is what it actually is. A template putting ink in
#: the top right corner is covered by nothing, and a token that said otherwise
#: would cost every template a column it does not need to give up.
SAFE_RIGHT = 240

#: The width of a full-frame asset, which every side-crop reading is scaled to.
#:
#: Named here rather than restated inside the arithmetic below, because that
#: conversion is the whole of what a reading does and a second spelling of 1080
#: is one the two could disagree over.
FULL_FRAME_W = 1080


@dataclass(frozen=True)
class SideCropReading:
    """One phone's measurement of how much of each side Instagram cuts off (#775).

    Instagram shows a 1080 wide frame at `shown` of the phone's own pixels
    inside a window of `window` of them. Anything wider than the window is cut
    off, half from each side, and `canvas_pixels_per_side` converts that back to
    canvas pixels through the same scale.

    The raw screen figures are kept rather than only the answer, so a reading can
    be re-derived and checked. A table of bare results cannot be argued with:
    a scale fitted wrongly and a phone that really does crop that much produce
    the same number.
    """

    #: The phone, named the way Dan would name it.
    device: str
    #: The day the reading was taken, as YYYY-MM-DD.
    measured: str
    #: The phone's screen in its own pixels, recorded for context rather than
    #: used: two phones with the same screen can still show a reel differently.
    screen: tuple[int, int]
    #: Screen pixels Instagram draws the 1080 wide frame at.
    shown: int
    #: Screen pixels actually visible, which is the narrower of the two.
    window: int

    @property
    def screen_pixels_per_side(self) -> float:
        """How much of the phone's own screen is cut off at each edge."""
        return max(0, self.shown - self.window) / 2

    @property
    def canvas_pixels_per_side(self) -> float:
        """The same crop, in canvas pixels of the 1080 wide asset."""
        return self.screen_pixels_per_side * (FULL_FRAME_W / self.shown)


#: Every side-crop reading taken, one per phone, newest last (#775).
#:
#: A table rather than prose, because this is the one safe-area token that is
#: genuinely device dependent: how much is cropped follows from the phone's
#: aspect ratio against the asset's 9:16, so a 16:9 screen crops nothing and
#: letterboxes instead, and a taller screen crops more. The other three tokens
#: describe furniture whose size barely moves between phones.
#:
#: So the token below has to be the widest crop SEEN rather than the only crop
#: measured. Add a phone here as it becomes available, measured the same way
#: (fit the scale on landmarks in the rendered chrome, then convert), and leave
#: the readings already here alone: `tests/test_side_crop_readings.py` raises
#: the floor rather than letting a wider reading sit beside the token doing
#: nothing.
SIDE_CROP_READINGS: tuple[SideCropReading, ...] = (
    # The reading SAFE_SIDE was set from, taken off two published reels (#768).
    # 78 screen pixels a side, which is 57 canvas pixels a side, so the visible
    # canvas is x 57 to 1023 rather than 0 to 1080.
    SideCropReading(device="iPhone 16 Pro Max", measured="2026-08-20",
                    screen=(1320, 2868), shown=1476, window=1320),
)


def widest_side_crop(
    readings: tuple[SideCropReading, ...] | None = None,
) -> float:
    """The largest crop any recorded phone showed, in canvas pixels.

    Takes the table rather than reading the module's own, so the guard that
    holds SAFE_SIDE to it can be shown failing on a phone that crops more
    without the committed readings being edited (L1).
    """
    return max(reading.canvas_pixels_per_side
               for reading in (SIDE_CROP_READINGS if readings is None
                               else readings))


#: How much of EACH SIDE of a full-frame asset the phone never shows (#768).
#:
#: The widest reading in SIDE_CROP_READINGS above, rounded up: 57.1 canvas
#: pixels on the only phone measured so far, so 60. Not computed from the table,
#: because a token that moved on its own would change what every template is
#: held to the moment a phone was added, and that is a decision rather than an
#: arithmetic result. What IS enforced is that it can never be NARROWER than the
#: widest reading, which is the direction that would quietly declare a column
#: safe while a phone in use cuts it off.
#:
#: What it already tells us, which nothing recorded before: MAT_GALLERY is 48,
#: so the gallery mat down the left and right of the collage and the scroll reel
#: is entirely off screen. The prints run edge to edge on the phone, which is
#: not what the layout draws and not what any local render shows. Whether that
#: is a problem is a design question; that it is happening is now written down.
SAFE_SIDE = 60

#: Where the action rail starts, as a fraction of the frame's height (#753).
#:
#: Measured at canvas y 1045 of 1920, so 0.54. Held as a fraction rather than a
#: pixel because it is the only one of these that is naturally proportional: the
#: rail is anchored to the bottom of the screen and grows upward with however
#: many controls Instagram is showing.
SAFE_RIGHT_FROM = 0.54


#: The gallery mat and every cream surface. The one background colour.
CREAM = (252, 250, 247)

#: The hairline around a matted print in the before/after and morph templates.
CREAM_EDGE = (212, 201, 192)

#: The hairline around a collage cell and a scroll-reel print.
#:
#: Two units warmer and lighter than CREAM_EDGE above, which is drift rather
#: than intent: the two pairs of templates were written at different times and
#: each picked its own value for the same idea. Both are preserved here so the
#: consolidation does not change a single rendered pixel; unifying them is a
#: brand decision for Dan, not a refactor. See #162.
HAIRLINE = (214, 208, 200)

#: Primary text on cream. Warm near-black, never true black.
TEXT_DARK = (60, 55, 50)

#: Quiet secondary text, such as a placard subtitle.
WARM_MID = (122, 104, 96)

#: The one accent, on cream: rules, dividers, the live state word.
ROSE_GOLD = (160, 105, 95)

#: The accent on a blurred photograph, where the on-cream value goes muddy.
#: Used by the story template only.
ROSE_GOLD_LIGHT = (196, 135, 122)

#: The split divider drawn over photography, where cream would disappear.
DIVIDER_WHITE = (255, 255, 255)


# ── Type ──────────────────────────────────────────────────────────────────────

#: Display script, for the event name.
FONT_SCRIPT = "/System/Library/Fonts/Supplemental/SignPainter.ttc"

#: Everything else. The weight is chosen by face index into the .ttc below.
FONT_DETAIL = "/System/Library/Fonts/HelveticaNeue.ttc"

FONT_DETAIL_BOLD = 1
#: Reads at phone size where Light starts to thin out (state words, labels).
FONT_DETAIL_MEDIUM = 10
#: The default detail weight. Thin renders spindly at these sizes.
FONT_DETAIL_LIGHT = 7
FONT_DETAIL_THIN = 12

#: How text is shaped, named rather than left to Pillow to choose (#656).
#:
#: Pillow uses the advanced shaper (raqm) whenever it can find one, and whether
#: it can is decided by what is installed on the machine doing the drawing, not
#: by anything in this project. Measured on 2026-08-17, same Pillow version and
#: the same wheel name throughout:
#:
#:     this Mac, Python 3.9 venv    raqm absent    BASIC
#:     this Mac, Python 3.11 venv   raqm present   RAQM
#:     CI, Python 3.11              raqm absent    BASIC
#:
#: The two renderings differ: the before/after title band sits about four pixels
#: across under one against the other, which is 0.64% of that frame and enough
#: to fail its reference. So rebuilding a virtualenv could change what Dan's
#: graphics look like, and the reference frames were the only thing that would
#: have noticed.
#:
#: BASIC is chosen because it is what CI, the committed references and the
#: shipping app already produce, so naming it changes nothing about today's
#: output and takes the installed-package lottery out of it. Moving to raqm is
#: then a deliberate design change carrying a reference re-record, rather than
#: something that happens to somebody.
FONT_LAYOUT_ENGINE = ImageFont.Layout.BASIC


def load_font(path: str, size: int, index: int = 0) -> ImageFont.FreeTypeFont:
    """Load a face at a size, shaped by the engine this project chose.

    One implementation, imported by every generator. There were six identical
    copies of this, each omitting the layout engine, so pinning it in one of
    them would have left the other five deciding by whatever was installed.

    A font that cannot be read degrades to Pillow's default rather than taking
    the whole render down, which is the behaviour all six copies had.

    It SAYS so, which only two of them did. The other four swapped the brand
    face for Pillow's default silently, so whether a missing font was reported
    depended on which template you happened to be rendering, and the quiet ones
    produced an off-brand asset with nothing anywhere naming why (L11).
    """
    try:
        return ImageFont.truetype(path, size, index=index,
                                  layout_engine=FONT_LAYOUT_ENGINE)
    except (OSError, IOError):
        print(f"Warning: Could not load font {path}, using default")
        return ImageFont.load_default()


# ── Mat scale ─────────────────────────────────────────────────────────────────

#: A wall of prints hung together: the collage and the scroll reel.
MAT_GALLERY = 48

#: A single print presented on its own: before/after and the morph reel.
MAT_PRINT = 72

#: The gutter between prints hung on the gallery mat.
GUTTER = 16
