"""A rendered frame names the show it was generated for (#754).

Every other check in this suite measures a frame's APPEARANCE. `frame_legibility`
asks whether the ink in a declared region is there and how far it is from what
sits behind it; `test_phone_safe_area` asks whether any of it lands under the
phone's chrome. None of them can tell a story rendered for "The One-Man Odyssey"
from one that rendered a blank title, the previous day's title, or a truncated
one. Each of those passes everything we have and reports a clean run.

That is not a hypothetical gap. #752 was found by Dan seeing a published post on
his phone, and so were both defects `frame_legibility` was written for. Every
layer measures how the frame LOOKS; nothing tied it back to the show.

So each template is rendered for a named show and the words are read back out of
the frame with Apple's Vision, through `postroll/media/frame_text.py`.

## Why the negative cases are here

The four defects the check exists to catch are rendered and asserted to FAIL, in
the same fixture and against the same matcher as the passing renders. A guard is
only real once it has been seen to fail (L1), and a negative assertion is
satisfied by a fixture where the thing could not have happened at all (L159), so
the failing cases live in the suite permanently rather than in a commit message.

## Calibration

Measured on real renders in the real script face on 2026-08-20, which is the
issue's own precondition for letting this block anything. Similarity of what was
read to the name it was rendered for:

    story, collage, before/after, scroll reel header, all correct   1.000
    the title truncated to "The One-Man Odysse"                     0.968
    one character misread, "Odysscy"                                0.938
    the title truncated to "The One-Man Odyss"                      0.933
    the title truncated to "The One-Man Ody"                        0.857
    a different show rendered                                       0.296
    the title left blank                                            0.273

A truncation and a misread are the same edit distance, so the match is by
containment of the whole name rather than by a threshold, which could only ever
forgive both or neither. Every correct render contains the name outright, so the
strict reading costs nothing and the generous one would wave through the defect.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image

from conftest import needs_mac_fonts
from postroll.media import frame_text
from postroll.media.frame_text import Reading, names_the_show, read_frame
from postroll.media.generate_before_after import generate_before_after
from postroll.media.generate_collage import generate_collage
from postroll.media.generate_reel_scroll import draw_branded_chrome
from postroll.media.generate_story import generate_story
from postroll.media.text_regions import scroll_regions

# Deliberately NOT marked slow: 6.2s, measured 2026-08-21. It is in the
# reference-frames matrix for needing the macOS system faces, which #766
# separated from being expensive.

REPO_ROOT = Path(__file__).resolve().parent.parent
LOGO = str(REPO_ROOT / "postroll" / "assets" / "logo-black.png")

#: A name with a hyphen and mixed case, because those are what the script face
#: sets in ways an OCR pass reports inconsistently, and normalising them away is
#: a decision this fixture has to actually exercise.
EVENT = "The One-Man Odyssey"
ORG = "Decoda"
VENUE = "Green Room"

CANVAS = (1080, 1920)


def _photo(path: Path, shade: int = 128) -> str:
    """A flat photograph, so what is read back is the type and nothing else."""
    Image.new("RGB", (2000, 1332), (shade, shade, shade)).save(path, "JPEG", quality=92)
    return str(path)


def _story(tmp_path: Path, name: str) -> Path:
    out = tmp_path / f"story-{len(name)}.png"
    generate_story(photo_path=_photo(tmp_path / "photo.jpg"), event_name=name,
                   org=ORG, venue=VENUE, output_path=str(out), logo_path=LOGO)
    return out


def _collage(tmp_path: Path, name: str) -> Path:
    out = tmp_path / "collage.png"
    photos = [_photo(tmp_path / f"c{i}.jpg", 100 + i * 12) for i in range(4)]
    generate_collage(photo_paths=photos, output_path=str(out), event_name=name,
                     org=ORG, venue=VENUE, logo_path=LOGO, seed=7,
                     write_layout_sidecar=False)
    return out


def _before_after(tmp_path: Path, name: str) -> Path:
    out = tmp_path / "before-after.png"
    generate_before_after(raw_path=_photo(tmp_path / "raw.jpg", 90),
                          edit_path=_photo(tmp_path / "edit.jpg", 160),
                          output_path=str(out), event_name=name, org=ORG,
                          venue=VENUE, logo_path=LOGO)
    return out


def _reel_scroll_header(tmp_path: Path, name: str) -> Path:
    out = tmp_path / "reel-scroll-header.png"
    frame = Image.new("RGB", CANVAS, (128, 128, 128))
    draw_branded_chrome(frame, name, ORG, VENUE).save(out)
    return out


#: Every template that prints the show's name on the frame, and how to render
#: one for a given name.
TEMPLATES = {
    "story": _story,
    "collage": _collage,
    "before_after": _before_after,
    "reel_scroll": _reel_scroll_header,
}


def _reason(path: Path, name: str = EVENT,
            box: tuple[int, int, int, int] | None = None) -> str | None:
    return names_the_show(read_frame(path, box=box), name)


# ── The frame names its show ─────────────────────────────────────────────────

@needs_mac_fonts
@pytest.mark.parametrize("template", sorted(TEMPLATES))
def test_every_template_names_the_show_it_was_generated_for(template, tmp_path):
    reason = _reason(TEMPLATES[template](tmp_path, EVENT))

    assert reason is None, f"{template}: {reason}"


@needs_mac_fonts
def test_the_reels_declared_title_band_names_the_show(tmp_path):
    """The band `frame_legibility` already measures for contrast, read for its
    words as well, so the two ask about the same rectangle rather than one
    asking about the frame at large."""
    title = scroll_regions()[0]

    reason = _reason(_reel_scroll_header(tmp_path, EVENT), box=title.box)

    assert reason is None, f"{title.name}: {reason}"


# ── The defects it exists to catch, rendered and caught ──────────────────────

@needs_mac_fonts
def test_a_blank_title_is_caught(tmp_path):
    reason = _reason(_story(tmp_path, ""))

    assert reason is not None, (
        "a story that rendered no title at all reported as naming its show")
    assert EVENT in reason


@needs_mac_fonts
def test_another_shows_title_is_caught(tmp_path):
    # The previous day's title, which is the case that would look entirely
    # normal to every other check: the ink is there, in the right band, at full
    # contrast, and it is the wrong show.
    reason = _reason(_story(tmp_path, "An Evening of Baroque Song"))

    assert reason is not None, (
        "a story carrying another show's title reported as naming this one")


@needs_mac_fonts
def test_a_truncated_title_is_caught(tmp_path):
    # Measured at 0.857 similarity against a misread character's 0.938, which
    # is why the match is by containment of the whole name rather than by a
    # threshold that would have to sit between two numbers that close.
    reason = _reason(_story(tmp_path, "The One-Man Ody"))

    assert reason is not None, (
        "a story whose title lost its last four characters reported as naming "
        "the whole show")


def test_reading_nothing_is_a_failure_rather_than_a_pass():
    """The empty answer, in its own words.

    A reader that saw nothing and a frame with no words on it report the same
    way from outside, and the reassuring reading is the wrong one (L98). This
    needs no render and no fonts, so it runs everywhere the suite does.
    """
    reason = names_the_show([], EVENT)

    assert reason is not None
    assert "nothing at all could be read" in reason


def test_a_frame_with_no_name_to_check_is_refused():
    with pytest.raises(ValueError):
        names_the_show([Reading(1.0, "The One-Man Odyssey")], "")


# ── The matcher itself ───────────────────────────────────────────────────────

def test_a_misread_character_is_reported_rather_than_forgiven():
    """The cost of the strict match, recorded rather than left to be discovered.

    Vision does misread: it read the wordmark as "DN/DAN WRICHT" in every frame
    measured on 2026-08-20. A misread title would be reported here as a frame
    that does not name its show.

    That is the direction to be wrong in. A misread and a truncation are the
    same edit distance, so any allowance wide enough to forgive this one also
    forgives "The One-Man Odyss", which is the defect. This costs a person a
    look at a real frame; the other way costs a published post.
    """
    reason = names_the_show([Reading(1.0, "The One-Man Odysscy")], EVENT)

    assert reason is not None
    assert "look at the frame rather than loosening the match" in reason


def test_punctuation_and_case_are_not_the_question():
    assert names_the_show([Reading(1.0, "the one man odyssey")], EVENT) is None


def test_the_name_may_sit_among_the_rest_of_the_frames_words():
    assert names_the_show([Reading(1.0, "The One-Man Odyssey"),
                           Reading(1.0, "Decoda"),
                           Reading(1.0, "Green Room")], EVENT) is None


def test_a_name_split_across_two_readings_still_counts():
    """A two-line title arrives as two readings, which is the ordinary case for
    a long show name and not a defect."""
    assert names_the_show([Reading(1.0, "The One-Man"),
                           Reading(1.0, "Odyssey")], EVENT) is None


def test_the_reader_is_refused_rather_than_silently_absent(monkeypatch, tmp_path):
    """A machine without the reader has to say so.

    Returning no readings would be indistinguishable from a frame with no words
    on it, and every check above would then report the frame as unreadable
    rather than the machine as unequipped (L11).
    """
    monkeypatch.setattr(frame_text, "READER", tmp_path / "not-here.swift")

    ready, why = frame_text.available()
    assert not ready
    assert "missing" in why
    with pytest.raises(frame_text.ReaderUnavailable):
        read_frame(tmp_path / "anything.png")
