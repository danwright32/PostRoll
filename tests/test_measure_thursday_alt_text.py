"""The re-runnable reading behind #1067's case, and #1219 (#1219).

#1067 was argued entirely from one reading of the live store: of 21 events with
a Thursday caption, 12 alt texts described a single moment rather than the
reel, and 7 were under the 25 word floor the scroll reel instruction itself
sets. Four fixes shipped. Every test written for them drives a stubbed model,
so they prove the machinery does what it says and say nothing about what the
real model now produces: a fix whose only evidence is its own unit tests is one
nobody has observed working (L3, L56).

So the reading becomes a tool rather than a script somebody wrote once. A number
with a date on it reads as MORE trustworthy the older it gets (L316), and the
answer to that is a command that re-takes it, not a comment quoting it.

## The two counts, and why they are structural

A reel takes ONE alt text describing the whole reel. More than one is the model
having written one per photograph, which is the "single moment" fault stated as
a shape rather than as a judgement about language, so nothing here has to read
the prose to decide. The word floor comes from `generate_captions._alt_word_floor`,
which parses the instruction's own stated range, rather than from 25 written out
again here: an ad hoc reimplementation beside the code is a second definition
that drifts towards whatever flatters the argument (L107).

The post type is derived with the app's own predicate for the same reason. It is
NOT stored on an event, and neither is the preset, so `DEFAULT_PRESET` is the
honest fallback.

## What this file will not do

It never reads the live store. Every test here drives a fixture built in
`tmp_path`, because a test that can reach real data is one real data can fail
(L2). The tool prints COUNTS and never alt text, since a tool that reads a live
system otherwise delivers real performer names straight into a transcript by a
route no repository scan can see (L222).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from tools.measure_thursday_alt_text import Reading, read_store, render

REPO_ROOT = Path(__file__).resolve().parent.parent


def store(tmp_path: Path, events: list[dict]) -> Path:
    path = tmp_path / "events.json"
    path.write_text(json.dumps(events), encoding="utf-8")
    return path


def event(alt_texts: list[str], *, photos: int = 8, day: str = "thursday") -> dict:
    """One event shaped the way the live store shapes them.

    Day captions hang off `weekResult`, one key per day, and the shoot inputs
    off `days`, which is a different object. Getting that wrong reads zero of
    everything and reports a clean pass (L98).
    """
    return {
        "date": "2026-08-27",
        "days": {day: {"photoPaths": [f"p{i}.jpg" for i in range(photos)]}},
        "weekResult": {day: {"alt_texts": alt_texts}},
    }


LONG = " ".join(["word"] * 30)
SHORT = " ".join(["word"] * 10)


# ── the two counts ───────────────────────────────────────────────────────────


def test_a_reel_with_one_long_alt_text_is_clean(tmp_path):
    reading = read_store(store(tmp_path, [event([LONG])]))

    assert reading.reels == 1
    assert reading.per_frame == 0
    assert reading.under_floor == 0


def test_a_reel_given_one_alt_text_per_photo_is_counted(tmp_path):
    """The 'single moment' fault, stated as a shape. A reel takes ONE alt text
    describing the whole reel, so more than one is the model having written one
    per photograph."""
    reading = read_store(store(tmp_path, [event([LONG, LONG, LONG])]))

    assert reading.per_frame == 1, "a reel with three alt texts was not counted"


def test_an_alt_text_under_the_instruction_s_own_floor_is_counted(tmp_path):
    reading = read_store(store(tmp_path, [event([SHORT])]))

    assert reading.under_floor == 1


def test_the_floor_is_the_instruction_s_and_not_a_number_written_here(tmp_path):
    """The floor has to come from the same place the model is told it, or the
    reading measures a rule nothing enforces (L107, L144)."""
    from postroll.ai.generate_captions import _alt_word_floor

    floor = _alt_word_floor("scroll_reel")
    assert floor, "scroll_reel states no word floor, so this measures nothing"

    just_under = " ".join(["word"] * (floor - 1))
    just_on = " ".join(["word"] * floor)

    assert read_store(store(tmp_path, [event([just_under])])).under_floor == 1
    assert read_store(store(tmp_path, [event([just_on])])).under_floor == 0


# ── it counts the right population ───────────────────────────────────────────


def test_a_day_that_is_not_a_reel_is_not_counted(tmp_path):
    """The post type is derived with the app's own predicate, not by mapping
    days by hand. A carousel legitimately takes one alt text per photograph, so
    counting it as a reel would report the fault on every one of them."""
    carousel = event([LONG, LONG, LONG], day="friday")

    reading = read_store(store(tmp_path, [carousel]))

    assert reading.reels == 0, (
        "a day that is not a scroll reel was measured against the reel rule")


def test_an_event_with_no_thursday_result_is_not_counted(tmp_path):
    reading = read_store(store(tmp_path, [{"date": "2026-08-27", "days": {},
                                           "weekResult": {}}]))

    assert reading.reels == 0
    assert reading.events == 1


def test_a_store_that_holds_nothing_is_refused_rather_than_reported_as_clean(tmp_path):
    """Zero of everything is what a wrong key produces, and it is
    indistinguishable from a store where every alt text is correct (L98). The
    first pass over this store read `program` instead of `ocrResult` and
    reported a rule as never firing.
    """
    with pytest.raises(SystemExit, match="no events"):
        read_store(store(tmp_path, []))


# ── what it prints ───────────────────────────────────────────────────────────


def test_it_prints_counts_and_never_an_alt_text(tmp_path):
    """A privacy guard that scans the REPOSITORY cannot see what a tool PRINTS,
    so a reading over the live store otherwise puts real performer names into a
    transcript by a route nothing inspects (L222)."""
    secret = "Jane Doe dances " + " ".join(["word"] * 30)

    out = render(read_store(store(tmp_path, [event([secret])])))

    assert "Jane Doe" not in out and "dances" not in out, (
        f"the reading printed the alt text it read: {out}")
    assert "1" in out


def test_the_length_count_states_the_baseline_it_can_be_compared_against(tmp_path):
    """A rate with nothing to compare it against cannot say whether the fixes
    moved anything, which is the whole question #1219 asks. The word floor is
    the half of #1067's reading that is reproducible, so it carries #1067's
    number and the denominator that number was in."""
    out = render(read_store(store(tmp_path, [event([SHORT])])))

    assert "7 of 21" in out, (
        f"the length count does not state #1067's baseline, so nothing says "
        f"whether it is better or worse: {out}")
    assert "reels" in out, (
        "the length count is not also given per reel, so it cannot be compared "
        f"against a baseline that was in reels: {out}")


def test_the_shape_count_is_not_set_beside_an_incomparable_baseline(tmp_path):
    """#1067's '12 of 21 described a single moment rather than the reel' was a
    judgement about the PROSE of individual alt texts. Nothing here reads prose.

    Printing a structural count beside it would invite exactly the comparison
    that cannot be made, and a number set beside a baseline is read as being in
    the same units whatever the words around it say (L118). This is the guard
    on that, because the first version of this tool did it: it reported 1 of 21
    against 12 of 21 and read as a tenfold improvement that had not happened.
    """
    out = render(read_store(store(tmp_path, [event([LONG, LONG])])))

    shape = out[out.index("SHAPE"):out.index("LENGTH")]
    assert "12" not in shape, (
        f"the shape count is printed against #1067's prose judgement, which is "
        f"a different measure in different units: {shape}")
    assert "first taken" in shape, (
        f"the shape count carries no reading of its own to be compared "
        f"against, so the next run has nothing to say whether it moved: {shape}")
