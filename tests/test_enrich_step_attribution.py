"""#480 and #481: what a step spends, and whether a handle matches its URL.

Two defects in the same file, both invisible to anything that reads only the
output.

The per-step spend attribution was swapped between the two most expensive
enrichment calls, so every cost report, and the per-step comparison the
subscription-switch judgement rests on, credited each call to the other's work.
A number measured to justify a decision has to come from the code's own
predicate, not from something written beside it (L107); here the label itself
was wrong, which is the same failure one step earlier.

The handle suggester's prompt asserts a verification step and grants high
confidence on the model's claim to have performed it. A rule that lives only in
a prompt is a hope (L27), and there is one cheap deterministic check available:
the handle and the profile URL come back side by side and were never compared,
so a mismatched pair normalised cleanly and reached Dan as one coherent
suggestion.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from postroll.ai import enrich_program


REPO_ROOT = Path(__file__).resolve().parent.parent
SOURCE = REPO_ROOT / "postroll" / "ai" / "enrich_program.py"


def _step_recorded_by(function_name: str) -> str:
    """The `step=` a function passes to `run_json_prompt`.

    Read out of the source rather than by running the call, because running it
    means paying for a Claude request. Comment lines are stripped first, so
    prose naming a step cannot answer for the code (L103).
    """
    text = "\n".join(
        line for line in SOURCE.read_text().split("\n")
        if not line.strip().startswith("#")
    )
    marker = f"\ndef {function_name}("
    assert marker in text, f"{function_name} is not in {SOURCE.name}"
    body = text.split(marker, 1)[1].split("\ndef ", 1)[0]
    found = re.findall(r'step="([^"]+)"', body)
    assert found, f"{function_name} records no step at all"
    assert len(found) == 1, f"{function_name} records several steps: {found}"
    return found[0]


# ── #480: each call is charged to its own work ───────────────────────────────

def test_the_handle_suggester_is_charged_to_handles():
    assert _step_recorded_by("suggest_handles") == "enrich:handles"


def test_the_piece_note_fetcher_is_charged_to_piece_notes():
    assert _step_recorded_by("fetch_piece_notes") == "enrich:piece_notes"


def test_the_two_are_not_charged_to_the_same_step():
    # Both pointing at one label would hide the swap while satisfying each
    # assertion above if either were written loosely.
    assert _step_recorded_by("suggest_handles") != _step_recorded_by("fetch_piece_notes")


# ── #481: a handle and its profile URL have to agree ─────────────────────────

@pytest.mark.parametrize("url,handle", [
    ("https://www.instagram.com/danwrightphoto/", "@danwrightphoto"),
    ("https://instagram.com/danwrightphoto", "danwrightphoto"),
    ("http://www.instagram.com/danwrightphoto/?hl=en", "@DanWrightPhoto"),
])
def test_a_handle_matching_its_profile_url_is_kept(url, handle):
    assert enrich_program.handle_matches_profile(handle, url) is True


def test_a_handle_that_does_not_match_its_profile_url_is_caught():
    assert enrich_program.handle_matches_profile(
        "@someoneelse", "https://www.instagram.com/danwrightphoto/") is False


def test_no_url_cannot_contradict_the_handle():
    # Nothing to check against is not a mismatch. Treating it as one would
    # throw away every suggestion the model did not give a URL for.
    assert enrich_program.handle_matches_profile("@danwrightphoto", "") is True
    assert enrich_program.handle_matches_profile("@danwrightphoto", None) is True


def test_a_url_that_is_not_a_profile_link_cannot_confirm_anything():
    # A search results page, or a post, says nothing about whose handle this is.
    assert enrich_program.handle_matches_profile(
        "@danwrightphoto", "https://www.instagram.com/p/Cabc123/") is False


def test_a_mismatched_suggestion_is_dropped_rather_than_shown_as_coherent():
    kept = enrich_program._normalise_handle_suggestions([
        {"name": "Real Person", "handle": "@realperson",
         "profile_url": "https://www.instagram.com/realperson/",
         "confidence": "high"},
        {"name": "Wrong Pair", "handle": "@oneperson",
         "profile_url": "https://www.instagram.com/anotherperson/",
         "confidence": "high"},
    ])

    names = [s["name"] for s in kept]
    assert "Real Person" in names
    assert "Wrong Pair" not in names, (
        "a handle and a profile URL naming different people reached Dan as one "
        f"coherent suggestion: {kept}"
    )


def test_a_suggestion_with_no_url_still_reaches_dan():
    kept = enrich_program._normalise_handle_suggestions([
        {"name": "No Link", "handle": "@nolink", "confidence": "low"},
    ])

    assert [s["name"] for s in kept] == ["No Link"]


def test_a_suggestion_whose_handle_is_not_a_handle_is_dropped(capsys):
    """#899. `handle_matches_profile` returns true whenever no `profile_url`
    came back, so an unlinked suggestion of ANY shape was accepted and written
    straight into the performer's handle field by `PerformerLookupManager`."""
    kept = enrich_program._normalise_handle_suggestions([
        {"name": "DPR Dance", "handle": "DPR Dance"},
        {"name": "Safa", "handle": "@safa.wav"},
    ])

    assert [k["handle"] for k in kept] == ["@safa.wav"]
    assert "DPR Dance" in capsys.readouterr().err


def test_a_dropped_suggestion_says_which_one_and_why(capsys):
    """A discard nobody can see is a suggestion that silently never arrives,
    and the row is then left blank with no reason (L11)."""
    enrich_program._normalise_handle_suggestions([
        {"name": "DPR Dance", "handle": "DPR Dance"},
    ])

    complaint = capsys.readouterr().err
    assert "DPR Dance" in complaint
    assert "handle" in complaint
