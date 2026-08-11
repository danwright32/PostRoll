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
    "story": 1,
    # Rendered through generate_story's exact template, so it moves with the
    # story rather than carrying a number of its own.
    "cover": 1,
    "before_after": 1,
    "reel_screen": 1,
    "reel_morph": 1,
    "reel_slider": 1,
    "reel_scroll": 1,
    # The still the Thursday crop editor draws over. Same layout maths as the
    # reel it previews, so a redesign of one dates the other.
    "reel_preview": 1,
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


# ── Mat scale ─────────────────────────────────────────────────────────────────

#: A wall of prints hung together: the collage and the scroll reel.
MAT_GALLERY = 48

#: A single print presented on its own: before/after and the morph reel.
MAT_PRINT = 72

#: The gutter between prints hung on the gallery mat.
GUTTER = 16
