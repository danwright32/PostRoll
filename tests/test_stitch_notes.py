"""#219: program notes must still reach their works after a program is split.

The OCR prompt tells the model to find a piece-specific paragraph in a separate
Program Notes section, "even on a later page", and attach it to the matching
work. Batching a large program into several requests (#216) means no single
call sees the work listing and the notes section together, so on programs of
roughly eight pages or more those notes go unmatched.

A quality regression, not a failure, introduced as a side effect of fixing the
request size limit and not flagged at the time.
"""

from __future__ import annotations

import pytest

from postroll.ai.stitch_notes import needs_stitch, stitch_notes


def _data(**over):
    base = {
        "pieces": [
            {"title": "Sonata in A", "composer": "Franck", "notes": None},
            {"title": "Nocturne", "composer": "Chopin", "notes": None},
        ],
        "program_notes": (
            "Franck wrote the Sonata in A as a wedding present in 1886.\n\n"
            "The Nocturne dates from Chopin's Paris years."
        ),
    }
    base.update(over)
    return base


# ── when it is worth a call ───────────────────────────────────────────────────


def test_a_program_that_was_not_split_needs_nothing():
    """A single call already saw both, so the prompt's own instruction worked."""
    assert not needs_stitch(_data(), batch_count=1)


def test_a_split_program_with_unmatched_works_needs_it():
    assert needs_stitch(_data(), batch_count=2)


def test_works_that_all_have_notes_need_nothing():
    data = _data(pieces=[{"title": "Sonata in A", "notes": "already matched"}])
    assert not needs_stitch(data, batch_count=3)


def test_no_notes_prose_means_there_is_nothing_to_match():
    assert not needs_stitch(_data(program_notes=""), batch_count=3)
    assert not needs_stitch(_data(program_notes=None), batch_count=3)


def test_no_works_means_nothing_to_match_to():
    assert not needs_stitch(_data(pieces=[]), batch_count=3)


# ── the match ─────────────────────────────────────────────────────────────────


def test_each_paragraph_reaches_its_own_work():
    def fake(prompt, **kw):
        return {
            "Sonata in A": "Franck wrote the Sonata in A as a wedding present in 1886.",
            "Nocturne": "The Nocturne dates from Chopin's Paris years.",
        }

    out = stitch_notes(_data(), batch_count=2, runner=fake)
    assert out["pieces"][0]["notes"].startswith("Franck wrote")
    assert out["pieces"][1]["notes"].startswith("The Nocturne")


def test_a_note_found_during_the_page_read_is_never_overwritten():
    """That read saw the work and its paragraph together, which is better
    evidence than a text-only match after the fact."""
    data = _data()
    data["pieces"][0]["notes"] = "read straight off the page"

    out = stitch_notes(data, batch_count=2,
                       runner=lambda p, **kw: {"Sonata in A": "a worse guess"})

    assert out["pieces"][0]["notes"] == "read straight off the page"


def test_a_work_with_no_matching_paragraph_is_left_alone():
    out = stitch_notes(_data(), batch_count=2,
                       runner=lambda p, **kw: {"Sonata in A": "matched"})
    assert out["pieces"][1]["notes"] is None


def test_matching_is_not_case_sensitive_on_the_title():
    out = stitch_notes(_data(), batch_count=2,
                       runner=lambda p, **kw: {"sonata in a": "matched"})
    assert out["pieces"][0]["notes"] == "matched"


def test_an_empty_match_does_not_replace_a_missing_note_with_nothing():
    out = stitch_notes(_data(), batch_count=2,
                       runner=lambda p, **kw: {"Sonata in A": "   "})
    assert out["pieces"][0]["notes"] is None


def test_a_title_the_model_invented_is_ignored():
    out = stitch_notes(_data(), batch_count=2,
                       runner=lambda p, **kw: {"A Work That Is Not In The Program": "x"})
    assert [p["notes"] for p in out["pieces"]] == [None, None]


# ── it must never cost the read ──────────────────────────────────────────────


def test_a_failed_match_returns_the_program_unchanged():
    """The program has already been read successfully at this point. A work
    with unmatched notes is a far smaller problem than no program."""
    def boom(prompt, **kw):
        raise RuntimeError("rate limited")

    data = _data()
    assert stitch_notes(data, batch_count=2, runner=boom) == data


def test_a_non_dict_answer_returns_the_program_unchanged():
    data = _data()
    assert stitch_notes(data, batch_count=2,
                        runner=lambda p, **kw: ["not", "an", "object"]) == data


def test_no_call_is_made_when_it_could_not_help():
    calls = []

    def counting(prompt, **kw):
        calls.append(prompt)
        return {}

    stitch_notes(_data(), batch_count=1, runner=counting)
    assert calls == [], "an unsplit program must not pay for a repair call"


def test_the_prompt_carries_no_images():
    """The whole point is that this pass cannot approach the size limit that
    forced the split."""
    seen = {}

    def capture(prompt, **kw):
        seen.update(kw)
        return {}

    stitch_notes(_data(), batch_count=2, runner=capture)
    assert "image_paths" not in seen
