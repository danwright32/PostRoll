"""#283: the SEO description and details block are deterministic, and shared.

Every generated post ships `<meta name="description" content="">`. Squarespace
falls back to `og:description`, which takes the opening prose, so the summary
search engines and AI crawlers see for the Whitacre post is "The hall wasn't
open yet. Singers in black were already out on 57th Street...". Good writing,
useless as a summary.

Both strings are pure functions of the event, computed here and mirrored in
`PostRollApp/Sources/Services/BlogMeta.swift`, with
`tests/fixtures/blog_meta.json` stating the cases once so neither side can
drift (#104, #186).

The failure paths are the point, so they are tested as such: an out-of-band
length is raised rather than shipped, a dash reaching the string is stripped
(the pre-push style hook only ever sees source, never runtime output), and a
missing org or venue drops its clause instead of leaving a hole.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.blog_meta import (
    SEO_MAX_CHARS,
    SEO_MIN_CHARS,
    DescriptionOutOfBand,
    check_description,
    details_block,
    format_date,
    seo_description,
    shoot_type_label,
)


REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURE = REPO_ROOT / "tests" / "fixtures" / "blog_meta.json"

#: The two characters the global writing rule bans, held as escapes so this
#: file itself has nothing for the pre-push style hook to catch.
BANNED_DASHES = ("\u2014", "\u2013")


def _fixture() -> dict:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def _vectors() -> list[dict]:
    vectors = _fixture()["vectors"]
    assert len(vectors) >= 9, "a gutted fixture would let both suites pass vacuously"
    return vectors


@pytest.mark.parametrize("vector", _vectors(), ids=lambda v: v["_what"])
def test_python_description_satisfies_the_shared_contract(vector):
    facts = {k: v for k, v in vector["event"].items() if k != "event_url"}
    assert seo_description(**facts) == vector["description"]


@pytest.mark.parametrize("vector", _vectors(), ids=lambda v: v["_what"])
def test_python_details_satisfy_the_shared_contract(vector):
    assert details_block(**vector["event"]) == vector["details"]


@pytest.mark.parametrize("vector", _vectors(), ids=lambda v: v["_what"])
def test_every_description_lands_inside_squarespaces_band(vector):
    # Squarespace shows 50 to 300. Outside it the field is either rejected or
    # truncated mid-sentence, and neither is visible from inside the app.
    length = len(vector["description"])
    assert SEO_MIN_CHARS <= length <= SEO_MAX_CHARS, f"{length} characters"


@pytest.mark.parametrize("vector", _vectors(), ids=lambda v: v["_what"])
def test_no_banned_dash_survives_into_either_string(vector):
    # The style hook reads source, not runtime output, so an event name Dan
    # typed with an em dash would otherwise ship one into the page metadata.
    for dash in BANNED_DASHES:
        assert dash not in vector["description"]
        assert dash not in vector["details"]


def test_a_name_carrying_a_dash_is_stripped_rather_than_passed_through():
    text = seo_description(
        name="Sing\u2014Play \u2014 A Winter Program",
        org="",
        venue="Merkin Hall",
        venue_context="",
        date="2026-11-07",
        shoot_type="performance",
    )
    for dash in BANNED_DASHES:
        assert dash not in text
    # Stripped, not deleted: the words either side survive.
    assert "Sing Play, A Winter Program" in text


def test_an_out_of_band_description_is_raised_not_returned():
    """The guard fails loud rather than defaulting to a shipped-anyway string."""
    with pytest.raises(DescriptionOutOfBand):
        check_description("Too short.")
    with pytest.raises(DescriptionOutOfBand):
        check_description("x" * (SEO_MAX_CHARS + 1))


def test_the_guard_names_the_length_it_measured():
    # "The description is wrong" is not an actionable message.
    with pytest.raises(DescriptionOutOfBand) as raised:
        check_description("Too short.")
    assert "10" in str(raised.value)


def test_a_very_long_event_name_is_brought_inside_the_band():
    text = seo_description(
        name="A " + "Very Long " * 60 + "Program",
        org="Distinguished Concerts International New York",
        venue="Carnegie Hall",
        venue_context="Stern Auditorium",
        date="2026-10-18",
        shoot_type="performance",
    )
    assert len(text) <= SEO_MAX_CHARS
    # Cut at a word boundary, so the summary does not end mid-word.
    assert "Ver at" not in text
    # The date and venue survive the trim: they are the facts worth keeping.
    assert "October 18, 2026" in text
    assert "Carnegie Hall" in text


def test_a_missing_org_and_venue_leave_no_hole_in_the_sentence():
    text = seo_description(
        name="Open Rehearsal",
        org="",
        venue="",
        venue_context="",
        date="2026-02-28",
        shoot_type="rehearsal",
    )
    assert " at ," not in text
    assert ", ," not in text
    assert "presented by" not in text
    assert len(text) >= SEO_MIN_CHARS


def test_a_details_block_omits_a_line_it_has_no_value_for():
    text = details_block(
        name="Open Rehearsal",
        org="",
        venue="",
        venue_context="",
        date="2026-02-28",
        shoot_type="rehearsal",
        event_url="",
    )
    # A label with nothing after it is worse than no label: it reads as a
    # missing fact rather than an absent one.
    for line in text.splitlines():
        label, _, value = line.partition(": ")
        assert value.strip(), f"empty line: {line!r}"
    assert "Presented by" not in text
    assert "Venue" not in text
    assert "Program" not in text


def test_an_unknown_shoot_type_is_refused_rather_than_silently_labelled():
    # A new ShootType case added on the Swift side and not mirrored here would
    # otherwise print a raw enum value into the page metadata.
    with pytest.raises(ValueError):
        seo_description(
            name="Winter Concert",
            org="",
            venue="Merkin Hall",
            venue_context="",
            date="2026-11-07",
            shoot_type="dress_rehearsal_matinee",
        )


def test_a_malformed_date_is_refused_rather_than_printed_raw():
    with pytest.raises(ValueError):
        seo_description(
            name="Winter Concert",
            org="",
            venue="Merkin Hall",
            venue_context="",
            date="not a date",
            shoot_type="performance",
        )


def test_neither_string_can_reach_the_ai_round_trip():
    """The whole reason these are separate fields (#283).

    A fact block inside `body` gets LLM-rewritten by `_fix_missing_contractions`
    (it never has a contraction), pushes the CTA out of last place so the
    second-person guard starts rewriting the closing line, and is counted as
    prose by `blog_quality`, whose invented-number check then flags the date.

    Derived from the source rather than asserted about one call site, so an
    import added later is caught on the day it lands.
    """
    ai_dir = REPO_ROOT / "postroll" / "ai"
    offenders = [
        path.name
        for path in sorted(ai_dir.rglob("*.py"))
        if "blog_meta" in path.read_text(encoding="utf-8")
    ]
    assert not offenders, (
        f"these modules pull post metadata into the AI round trip: {offenders}")

def _dates() -> list[dict]:
    dates = _fixture()["dates"]
    assert len(dates) >= 5, "a gutted fixture would let both suites pass vacuously"
    return dates


@pytest.mark.parametrize("case", _dates(), ids=lambda c: c["iso"])
def test_python_renders_every_shared_date(case):
    """#1106: `format_date` and `BlogMeta.formatDate` are twins, found by name
    rather than by anybody declaring them.

    They were covered only THROUGH the details block, so a disagreement about
    one date surfaced as a whole block mismatch and read as a details bug."""
    assert format_date(case["iso"]) == case["formatted"]


@pytest.mark.parametrize("iso", _fixture()["unreadable_dates"])
def test_python_refuses_a_date_it_cannot_read(iso):
    """Where the two halves deliberately DIFFER, and the difference is the
    point (L542). Python generates the post, and a malformed date reaching the
    description would be published as the summary, so it raises. Swift renders
    a screen, where a trap takes the app down, so it returns an empty string.

    Recorded rather than reconciled: making them agree would either publish a
    bad date or crash the app."""
    with pytest.raises(ValueError):
        format_date(iso)


def test_python_labels_every_shared_shoot_type():
    """The same map written twice, and nothing compared the two. A shoot type
    added to one and not the other puts a raw `rehearsal_and_performance` on a
    published page (L113)."""
    labels = _fixture()["shoot_types"]
    assert len(labels) >= 4, "a gutted fixture would pass vacuously"

    for value, label in labels.items():
        assert shoot_type_label(value) == label


def test_the_shared_shoot_types_are_every_one_python_knows():
    """Both directions. A fixture naming a subset would let a type be added to
    Python alone and go unchecked, which is the drift this exists to catch
    (L96)."""
    from postroll.blog_meta import SHOOT_TYPE_LABELS

    assert set(_fixture()["shoot_types"]) == set(SHOOT_TYPE_LABELS), (
        "the shared list and Python's own map name different shoot types, so "
        "one of them is checking a set nobody uses")
