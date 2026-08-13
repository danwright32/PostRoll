"""#209: the Vision text layer is the spelling authority for OCR output.

`ProgramPDFBuilder.drawTextLayer` already runs Apple Vision text recognition at
full native resolution over every program page at upload time and bakes the
strings invisibly into the PDF. On the real BLUDLINE program that layer holds
"Safa @safa.wav" verbatim and correct, which is the exact character Claude got
wrong. The machine already had the right answer, on device, free, in a file that
already existed.

So Vision is used as a character-level authority for SPELLING ONLY. Claude still
does layout and structure, because the Vision reading order is scrambled across
columns and cannot say who is a soloist and who is a composer. Anything Claude
returns that does not appear in the Vision text goes into the OCR review loop
that already exists, as an ordinary flag.

The rules these pin:

- Matching is per TOKEN, not per whole name, because the scrambled reading order
  routinely splits a name across lines and columns. Requiring the full string
  would flag every correct name in a two-column program.
- A missing token carries the closest Vision spelling as its suggestion, so the
  flag says what to do rather than only that something is wrong.
- A missing, empty or unbuilt text layer FAILS rather than quietly returning no
  flags. Silence there is indistinguishable from a clean program, which would
  turn the whole check off the first time the async bake had not finished.
"""

from __future__ import annotations

import pytest

from postroll.ai.vision_cross_check import (
    VisionTextUnavailable,
    cross_check_against_vision,
)

from tests.source_text import swift_without_comments


# The shape of a real page as Vision reads it: correct spellings, but the order
# is scrambled across columns and a name is split over two lines.
BLUDLINE_VISION_TEXT = """
BLUDLINE
Safa
@safa.wav
vocals
Marguerite
Dubois
violin
Presented by Greenwich House
Yefim Kolodkin, conductor
"""


def _ocr(*names: str) -> dict:
    return {"performers": [{"name": n, "role": "soloist"} for n in names]}


# ── the spelling authority ────────────────────────────────────────────────────

def test_a_name_spelled_as_vision_read_it_is_not_flagged():
    flags = cross_check_against_vision(_ocr("Safa"), BLUDLINE_VISION_TEXT)
    assert flags == []


def test_a_name_split_across_lines_by_the_column_scramble_is_not_flagged():
    # "Marguerite Dubois" never appears as one string in the text layer. A
    # whole-string match would flag a perfectly correct name.
    flags = cross_check_against_vision(_ocr("Marguerite Dubois"), BLUDLINE_VISION_TEXT)
    assert flags == []


def test_a_misread_character_is_flagged_with_the_vision_spelling():
    # The measured failure: Claude read "Safa" as "5afa" while Vision had it right.
    flags = cross_check_against_vision(_ocr("5afa"), BLUDLINE_VISION_TEXT)

    assert len(flags) == 1
    flag = flags[0]
    assert flag["field_path"] == ["performers", 0, "name"]
    assert flag["current_value"] == "5afa"
    assert flag["suggested_value"] == "Safa"
    assert "Safa" in flag["program_context"]


def test_a_name_absent_from_the_program_entirely_is_flagged_with_no_guess():
    flags = cross_check_against_vision(_ocr("Hildegard Ferrant"), BLUDLINE_VISION_TEXT)

    assert len(flags) == 1
    # Nothing in the text layer is close, so there is nothing honest to suggest.
    # An invented suggestion would be the same fabrication being guarded against.
    assert flags[0]["suggested_value"] == ""


def test_only_the_unmatched_token_of_a_name_is_reported():
    flags = cross_check_against_vision(_ocr("Marguerite Dubwah"), BLUDLINE_VISION_TEXT)

    assert len(flags) == 1
    assert "Dubwah" in flags[0]["concern"]
    assert "Marguerite" not in flags[0]["concern"], \
        "the token Vision confirms should not be reported as missing"


def test_case_and_punctuation_do_not_make_a_correct_name_look_wrong():
    # Vision prints "Yefim Kolodkin, conductor"; the trailing comma is layout,
    # not spelling.
    assert cross_check_against_vision(_ocr("YEFIM KOLODKIN"), BLUDLINE_VISION_TEXT) == []


# ── handles ───────────────────────────────────────────────────────────────────

def test_a_handle_vision_confirms_is_not_flagged():
    data = {"performers": [{"name": "Safa", "voice_or_instrument": "vocals @safa.wav"}]}
    assert cross_check_against_vision(data, BLUDLINE_VISION_TEXT) == []


def test_an_invented_handle_is_flagged_wherever_it_appears():
    # Handles have no field of their own in the schema, so they are checked
    # wherever they turn up rather than at one expected path.
    data = {"other": "follow @safa.music for more"}
    flags = cross_check_against_vision(data, BLUDLINE_VISION_TEXT)

    assert len(flags) == 1
    assert flags[0]["current_value"] == "@safa.music"
    assert flags[0]["suggested_value"] == "@safa.wav"


def test_a_handle_is_matched_on_its_exact_characters_not_its_stem():
    # "@safa" is a different account from "@safa.wav". Accepting it because the
    # stem matches is exactly the substitution that sends a credit to the wrong
    # person.
    flags = cross_check_against_vision({"other": "@safa"}, BLUDLINE_VISION_TEXT)
    assert len(flags) == 1


# ── failing loudly ────────────────────────────────────────────────────────────

@pytest.mark.parametrize("text", ["", "   \n  ", None])
def test_a_missing_or_empty_text_layer_raises_rather_than_passing(text):
    # The whole check would otherwise switch itself off, silently, the first
    # time the async bake had not finished, and report a clean program.
    with pytest.raises(VisionTextUnavailable):
        cross_check_against_vision(_ocr("Safa"), text)


def test_a_text_layer_too_thin_to_be_a_program_raises():
    # A PDF whose text layer failed to bake can still carry a stray word or two.
    # Treating that as authority would flag every correct name in the program.
    with pytest.raises(VisionTextUnavailable):
        cross_check_against_vision(_ocr("Safa"), "BLUDLINE")


# ── flag shape ────────────────────────────────────────────────────────────────

def test_flags_carry_the_fields_the_review_loop_reads():
    flags = cross_check_against_vision(_ocr("5afa"), BLUDLINE_VISION_TEXT)
    assert set(flags[0]) == {
        "id", "field_path", "current_value", "suggested_value",
        "concern", "program_context",
    }


def test_ids_are_unique_so_two_flags_cannot_collapse_into_one():
    data = {"performers": [{"name": "5afa"}, {"name": "Marguerite Dubwah"}]}
    flags = cross_check_against_vision(data, BLUDLINE_VISION_TEXT)
    assert len({f["id"] for f in flags}) == len(flags) == 2


# ── standing down without taking the review with it ───────────────────────────

def test_a_program_too_thin_to_check_does_not_stop_the_rest_of_the_review():
    """Found after shipping: a sparse program killed ALL flagging.

    A one-page flyer or a poster has a real text layer with very few words in
    it. Treating that as an authority would flag every correct name, so the
    spelling check stands down. But it was standing down by raising out of the
    whole flagging step, so Dan lost the ordinary review too, which has nothing
    to do with spelling, and got no flags at all.

    Standing down and taking everything else with it is not failing loudly, it
    is failing wide.
    """
    from postroll.ai.flag_issues import vision_flags_or_reason

    flags, reason = vision_flags_or_reason(_ocr("Safa"), "BLUDLINE Greenwich House")
    assert flags == []
    assert reason and "authority" in reason.lower(), (
        f"the reason must survive so it can be shown, got {reason!r}")


def test_a_usable_layer_reports_no_reason_to_stand_down():
    from postroll.ai.flag_issues import vision_flags_or_reason

    flags, reason = vision_flags_or_reason(_ocr("5afa"), BLUDLINE_VISION_TEXT)
    assert reason is None
    assert len(flags) == 1


def test_no_layer_at_all_is_not_a_stand_down_reason():
    # Nothing was asked of it, so there is nothing to report.
    from postroll.ai.flag_issues import vision_flags_or_reason

    assert vision_flags_or_reason(_ocr("Safa"), None) == ([], None)


def test_the_swift_mirror_of_the_thinness_rule_agrees():
    """Swift judges thinness too, so the reason reaches Dan on screen (#209).

    A drift here is silent and one-sided: Swift would hand over a layer Python
    then refuses, and the only trace would be a log line nobody reads.
    """
    from pathlib import Path

    from postroll.ai.vision_cross_check import MIN_VISION_WORDS

    # Read without comments, so a doc comment quoting the old number cannot
    # keep this green while the real constant drifts (#436, L103).
    swift = swift_without_comments(
        (Path(__file__).resolve().parent.parent / "PostRollApp" / "Sources"
         / "Services" / "VisionTextLayer.swift").read_text())
    assert f"static let minimumWords = {MIN_VISION_WORDS}" in swift, (
        f"Swift no longer mirrors MIN_VISION_WORDS ({MIN_VISION_WORDS})")
