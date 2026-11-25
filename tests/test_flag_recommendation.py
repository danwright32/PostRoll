"""Every review flag says what Claude would do about it (#1653).

On 2026-11-25 five of the eight flags on a real program arrived with the OCR
text copied into `suggested_value`, which the prompt forbade and nothing
checked. Three of the five were duplicate entries, whose remedy is a removal
that a text value cannot say, so the model had nothing valid to write there.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai import flag_issues as flag_issues_mod
from postroll.ai.flag_recommendation import (
    NONE, REMOVE, REPLACE, UNPRINTED, recommendation_for,
)
from postroll.ai.vision_cross_check import cross_check_against_vision


def _flag(**over):
    flag = {
        "id": "f",
        "field_path": ["performers", 3, "name"],
        "current_value": "Jon Smth",
        "suggested_value": "Jon Smith",
        "concern": "c",
        "program_context": "p",
    }
    flag.update(over)
    return flag


def _run(sample_photo, raw_flags):
    with patch("postroll.ai.flag_issues.run_json_prompt", return_value=raw_flags):
        return flag_issues_mod.flag_issues({"performers": []}, [sample_photo])


# === the rule ===


def test_a_value_that_differs_from_the_ocr_text_is_a_replacement():
    assert recommendation_for(["pieces", 8, "composer"], "A / B", "A") == REPLACE


@pytest.mark.parametrize("suggested", ["Jon Smth", "  Jon Smth\n", "", None])
def test_the_ocr_text_handed_back_recommends_nothing(suggested):
    assert recommendation_for(["performers", 3, "name"], "Jon Smth", suggested) == NONE


def test_a_removal_is_recommended_for_an_entry_in_a_list():
    path = ["performers", 13, "name"]
    assert recommendation_for(path, "Dup", "Dup", asked="remove") == REMOVE
    assert recommendation_for(["performers", 13], "{...}", "", asked="remove") == REMOVE


def test_a_removal_outside_any_list_recommends_nothing():
    # There is no entry to take out, and the app offers no Remove there.
    assert recommendation_for(["venue_notes"], "x", "", asked="remove") == NONE


def test_a_claimed_replacement_is_judged_by_the_values_not_the_claim():
    # The model wrote the label; the two values are what the app will act on.
    assert recommendation_for(["performers", 3, "name"], "Same", "Same", asked="replace") == NONE


# === the model pass ===


def test_each_model_flag_carries_its_recommendation(sample_photo):
    result = _run(sample_photo, [
        _flag(id="fix"),
        _flag(id="dup", suggested_value="Jon Smth", recommendation="remove"),
        _flag(id="echo", suggested_value="Jon Smth"),
    ])
    assert [f["recommendation"] for f in result] == [REPLACE, REMOVE, NONE]


def test_flags_recommending_nothing_are_counted_out_loud(sample_photo, capsys):
    _run(sample_photo, [
        _flag(id="fix"),
        _flag(id="echo_one", suggested_value="Jon Smth"),
        _flag(id="echo_two", suggested_value=""),
    ])
    err = capsys.readouterr().err
    assert "2 of 3 review flags recommend nothing" in err
    assert "echo_one" in err and "echo_two" in err


def test_a_run_where_every_flag_recommends_something_says_nothing(sample_photo, capsys):
    _run(sample_photo, [_flag(id="fix")])
    err = capsys.readouterr().err
    assert "recommend nothing" not in err
    assert "withdrew" not in err


def test_a_flag_the_model_withdrew_never_reaches_the_review(sample_photo, capsys):
    """Measured on a real program, 2026-11-25: four of twelve flags ended "this
    matches, no error. Withdrawing." and were shown to Dan all the same."""
    result = _run(sample_photo, [
        _flag(id="fix"),
        _flag(id="second_thoughts", suggested_value="Jon Smth", recommendation="withdraw"),
    ])
    assert [f["id"] for f in result] == ["fix"]
    err = capsys.readouterr().err
    assert "the model withdrew 1 of 2 review flags" in err
    assert "second_thoughts" in err
    # Withdrawn is a considered answer, not a broken instruction.
    assert "recommend nothing" not in err


def test_a_withdrawn_flags_note_is_kept_in_the_run_log(sample_photo, capsys):
    # Nothing else records why a flag was withdrawn, and the same flag was
    # withdrawn in one measured run and offered as a fix in three others.
    _run(sample_photo, [_flag(id="second_thoughts", recommendation="withdraw",
                              concern="The page prints Jon Smth after all.")])
    assert "second_thoughts: The page prints Jon Smth after all." in capsys.readouterr().err


# === a suggestion the program does not print ===
#
# Measured 2026-11-25 on real programs: four of seven suggested replacements
# used a word printed nowhere in the program, each prefilled with Save one click
# away. Dan chose (#1653) that such a flag still shows, with nothing prefilled.

PROGRAM_TEXT = " ".join([
    "Hannukah, Oh Hannukah", "Traditional", "Rockin' Underneath the Tree",
    "Johnny Marks / Kelly Clarkson", "Tomas Muller", "Ernő Dohnányi",
    "Jianfen Gu", "soloists", "conductor", "the choir", "tonight's program",
])


def _run_with_text(sample_photo, raw_flags, vision_text=PROGRAM_TEXT):
    with patch("postroll.ai.flag_issues.run_json_prompt", return_value=raw_flags):
        return flag_issues_mod.flag_issues(
            {"performers": []}, [sample_photo], vision_text=vision_text)


@pytest.mark.parametrize("path,current,suggested", [
    (["pieces", 11, "title"], "Hannukah, Oh Hannukah", "Hanukkah, Oh Hanukkah"),
    (["pieces", 8, "composer"], "Johnny Marks / Kelly Clarkson", "Kelly Clarkson / Greg Kurstin"),
    (["pieces", 15, "composer"], "Jianfen Gu", "Jian-Fen Gu"),
])
def test_a_suggestion_the_program_does_not_print_is_not_a_replacement(
        sample_photo, path, current, suggested):
    [flag] = _run_with_text(sample_photo, [
        _flag(field_path=path, current_value=current, suggested_value=suggested)])
    assert flag["recommendation"] == UNPRINTED
    # Kept, so the row can still show what Claude proposed.
    assert flag["suggested_value"] == suggested


@pytest.mark.parametrize("path,current,suggested", [
    (["pieces", 6, "composer"], "Ernö Dohnányi", "Ernő Dohnányi"),
    (["performers", 22, "name"], "Tomas Mueller", "Tomas Muller"),
])
def test_a_suggestion_the_program_prints_stays_a_replacement(
        sample_photo, path, current, suggested):
    [flag] = _run_with_text(sample_photo, [
        _flag(field_path=path, current_value=current, suggested_value=suggested)])
    assert flag["recommendation"] == REPLACE


def test_only_the_words_a_suggestion_changes_are_held_to_the_text(sample_photo):
    # The text layer is machine read too. A word it missed, which the
    # suggestion merely carries over from the data, is not the suggestion's.
    [flag] = _run_with_text(sample_photo, [_flag(
        field_path=["performers", 22, "name"],
        current_value="Zzyzx Mueller", suggested_value="Zzyzx Muller")])
    assert flag["recommendation"] == REPLACE


def test_only_fields_copied_from_the_page_are_held_to_its_text(sample_photo):
    # A role or an instrument is Claude's description, not a transcription.
    [flag] = _run_with_text(sample_photo, [_flag(
        field_path=["performers", 7, "voice_or_instrument"],
        current_value="ensemble", suggested_value="vocalist")])
    assert flag["recommendation"] == REPLACE


def test_without_the_programs_text_a_suggestion_is_not_judged(sample_photo):
    # No text layer means no authority, and a check that cannot run must not
    # demote every suggestion as though it had failed one.
    [flag] = _run(sample_photo, [_flag(
        field_path=["pieces", 11, "title"],
        current_value="Hannukah, Oh Hannukah", suggested_value="Hanukkah, Oh Hanukkah")])
    assert flag["recommendation"] == REPLACE


def test_a_text_layer_too_thin_to_trust_judges_nothing(sample_photo):
    [flag] = _run_with_text(sample_photo, [_flag(
        field_path=["pieces", 11, "title"],
        current_value="Hannukah, Oh Hannukah", suggested_value="Hanukkah, Oh Hanukkah")],
        vision_text="Program")
    assert flag["recommendation"] == REPLACE


def test_unprinted_suggestions_are_counted_out_loud(sample_photo, capsys):
    _run_with_text(sample_photo, [_flag(
        id="usual_spelling", field_path=["pieces", 11, "title"],
        current_value="Hannukah, Oh Hannukah", suggested_value="Hanukkah, Oh Hanukkah")])
    err = capsys.readouterr().err
    assert "1 of 1 review flags suggest words the program does not print" in err
    assert "usual_spelling (hanukkah)" in err


def test_the_examples_explain_before_they_recommend():
    """The model writes a flag's fields in order and cannot go back. Asked for
    the recommendation first, it recommended removing a performer and then
    explained that both entries were valid."""
    for e in flag_issues_mod.EXAMPLE_FLAGS:
        order = list(e)
        assert order.index("concern") < order.index("recommendation") < order.index("suggested_value")
        assert order.index("program_context") < order.index("recommendation")


# === the prompt's own examples ===


def test_the_prompts_examples_obey_the_rule_they_illustrate():
    """An example outweighs the instruction beside it (L270), so each one must
    come out of the same rule with the recommendation it claims."""
    examples = flag_issues_mod.EXAMPLE_FLAGS
    assert {e["recommendation"] for e in examples} == {REPLACE, REMOVE}
    for e in examples:
        assert recommendation_for(
            e["field_path"], e["current_value"], e["suggested_value"],
            asked=e["recommendation"],
        ) == e["recommendation"]


def test_the_replacement_example_suggests_what_its_page_prints():
    """Measured 2026-11-25: four of seven suggested replacements used words the
    program does not print (a more usual spelling, a songwriter from general
    knowledge, a hyphen added to a name the note said was right)."""
    replacements = [e for e in flag_issues_mod.EXAMPLE_FLAGS if e["recommendation"] == REPLACE]
    assert replacements
    for e in replacements:
        assert e["suggested_value"] in e["program_context"]


def test_the_prompt_does_not_ask_for_a_guess():
    # The prompt is hard wrapped, so a phrase can straddle a line break.
    prompt = " ".join(flag_issues_mod.PROMPT_TEMPLATE.split())
    assert "even when you are not certain" not in prompt
    assert "best guess" not in prompt
    assert "Never invent" in prompt


def test_the_prompt_shows_the_examples_it_is_checked_against():
    prompt = flag_issues_mod.PROMPT_TEMPLATE.format(ocr_json="{}", image_list="-")
    for e in flag_issues_mod.EXAMPLE_FLAGS:
        assert e["id"] in prompt


# === the spelling cross-check ===


def test_vision_flags_carry_a_recommendation_from_the_same_rule():
    vision_text = " ".join(
        ["Jonathan", "Smith", "piano", "violin", "cello", "program", "tonight",
         "concert", "orchestra", "conductor", "soloist", "welcome", "evening",
         "music", "hall", "director", "ensemble", "chorus", "season", "guest"])
    flags = cross_check_against_vision(
        {"performers": [{"name": "Jonathan Smth"}, {"name": "Zzyzx Qwvrt"}]},
        vision_text,
    )
    assert flags, "the fixture must raise at least one flag or this proves nothing"
    for f in flags:
        assert f["recommendation"] == recommendation_for(
            f["field_path"], f["current_value"], f["suggested_value"])
    assert REPLACE in {f["recommendation"] for f in flags}
