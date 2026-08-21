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
    # 2 is the top clamp #756 put under the title. It hung off the top edge of
    # the print with no floor, so an upright photograph put it inside the band
    # the phone covers. #752 left this deliberately and said the number would
    # move with the fix rather than badging every story for a change nobody had
    # made; this is that move. A landscape story renders pixel for pixel as it
    # did, which is every story shot so far, but the geometry is not the same
    # geometry and an asset cannot say which one drew it without this.
    "story": 2,
    # Rendered through generate_story's exact template, so it moves with the
    # story rather than carrying a number of its own.
    "cover": 2,
    "before_after": 1,
    "reel_screen": 1,
    "reel_morph": 2,
    "reel_slider": 2,
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
#: Deliberately NOT paired with a bottom inset yet. Instagram draws its caption,
#: its account row and its right hand action rail over the foot of the frame
#: too, and nobody has measured how much: #753 is that measurement, and a
#: number invented here to look symmetrical would be a made up one that every
#: template would then be held to.
SAFE_TOP = 170


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
