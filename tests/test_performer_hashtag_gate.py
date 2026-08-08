"""Ordinary performer names must never become hashtags (#199).

Decided 2026-06-16 and written into brand-voice.md, and it kept happening
anyway, because the caption prompt restated the hashtag rules twice with the
fame gate stripped out, and a third rule turned every tagged handle into a
name tag regardless. "Music from Inside" (Decoda at Weill) shipped
`#bradballiett` for a bassoonist listed as `role: ensemble`.

A rule that lives only in a prompt is a hope, so this is the deterministic
backstop: the prompt is fixed AND the output is filtered against the program
data the caller already holds.

The gate covers people (performers, cast, conductors, choreographers). It does
NOT cover composers, playwrights or bands: repertoire search behaves
differently from people search, and those tags stay required.
"""

from __future__ import annotations

from postroll.ai.performer_hashtags import (
    GATED_ROLES,
    gated_names,
    strip_performer_hashtags,
)


def _program(performers):
    return {"performers": performers}


# ── the case that actually shipped ────────────────────────────────────────────

def test_a_performer_with_a_handle_does_not_become_a_hashtag():
    program = _program([
        {"name": "Brad Balliett", "role": "ensemble", "handle": "bradballiett"},
    ])

    kept = strip_performer_hashtags(
        ["#dwphotony", "#weillmusicroom", "#decoda", "#bradballiett", "#bassoon"],
        program=program,
        tag_handles=["@bradballiett"],
    )

    assert "#bradballiett" not in kept
    assert kept == ["#dwphotony", "#weillmusicroom", "#decoda", "#bassoon"]


def test_the_name_is_gated_even_without_a_handle():
    program = _program([{"name": "Jane Smith", "role": "cast"}])

    kept = strip_performer_hashtags(["#dwphotony", "#janesmith"], program=program)

    assert kept == ["#dwphotony"]


def test_matching_ignores_case_spacing_and_punctuation():
    program = _program([{"name": "Mary-Jane O'Connor", "role": "soloist"}])

    kept = strip_performer_hashtags(
        ["#MaryJaneOConnor", "#maryjaneoconnor", "#dwphotony"], program=program)

    assert kept == ["#dwphotony"]


# ── the gate must not overshoot ───────────────────────────────────────────────

def test_composers_playwrights_and_bands_keep_their_tags():
    program = _program([
        {"name": "Ludwig van Beethoven", "role": "composer"},
        {"name": "Lynn Nottage", "role": "playwright"},
        {"name": "The Beths", "role": "band"},
    ])

    kept = strip_performer_hashtags(
        ["#ludwigvanbeethoven", "#lynnnottage", "#thebeths", "#dwphotony"],
        program=program)

    assert kept == ["#ludwigvanbeethoven", "#lynnnottage", "#thebeths", "#dwphotony"]


def test_organization_and_venue_handles_still_become_hashtags():
    program = _program([{"name": "Jane Smith", "role": "ensemble"}])

    kept = strip_performer_hashtags(
        ["#decoda", "#weillmusicroom", "#janesmith"],
        program=program,
        tag_handles=["@decoda", "@weillmusicroom", "@janesmith"],
    )

    assert kept == ["#decoda", "#weillmusicroom"], (
        "scoping the handle rule to orgs and venues must not strip the org tag"
    )


def test_a_person_the_model_marked_famous_keeps_their_tag():
    program = _program([{"name": "Yo-Yo Ma", "role": "soloist"}])

    kept = strip_performer_hashtags(
        ["#yoyoma", "#dwphotony"], program=program, famous=["Yo-Yo Ma"])

    assert kept == ["#yoyoma", "#dwphotony"]


# ── the role subtlety ─────────────────────────────────────────────────────────

def test_someone_who_is_both_a_performer_and_an_arranger_is_still_gated():
    # Brad Balliett is exactly this: a bassoonist in the ensemble who also
    # arranges. Keying off the name alone would let the arranger credit
    # un-gate the performer.
    program = _program([
        {"name": "Brad Balliett", "role": "ensemble"},
        {"name": "Brad Balliett", "role": "arranger"},
        {"name": "Ludwig van Beethoven", "role": "composer"},
    ])

    kept = strip_performer_hashtags(
        ["#bradballiett", "#ludwigvanbeethoven"], program=program)

    assert kept == ["#ludwigvanbeethoven"], (
        "the performer is gated; the work's composer tag survives"
    )


def test_a_person_named_only_in_photo_tags_is_gated():
    kept = strip_performer_hashtags(
        ["#mikebono", "#dwphotony"],
        program=_program([]),
        photo_tags={"/photos/a.jpg": ["Mike Bono"]},
    )

    assert kept == ["#dwphotony"]


def test_a_person_named_only_in_name_mentions_is_gated():
    kept = strip_performer_hashtags(
        ["#jordanlangworthy", "#dwphotony"],
        program=_program([]),
        name_mentions=["Jordan Langworthy"],
    )

    assert kept == ["#dwphotony"]


def test_photo_tag_handles_are_gated_too():
    kept = strip_performer_hashtags(
        ["#mikebono", "#dwphotony"],
        program=_program([]),
        photo_tags={"/photos/a.jpg": ["@mikebono"]},
    )

    assert kept == ["#dwphotony"]


# ── the rule itself ───────────────────────────────────────────────────────────

def test_the_gated_roles_cover_people_and_not_repertoire():
    for role in ("soloist", "conductor", "ensemble", "actor", "dancer",
                 "band_member", "troupe", "accompanist", "choreographer", "cast"):
        assert role in GATED_ROLES, f"{role} is a person and must be gated"
    for role in ("composer", "playwright", "arranger", "lyricist", "band"):
        assert role not in GATED_ROLES, f"{role} is repertoire and must not be gated"


def test_gated_names_reports_who_is_covered():
    program = _program([
        {"name": "Jane Smith", "role": "ensemble"},
        {"name": "Ludwig van Beethoven", "role": "composer"},
    ])

    names = gated_names(program=program, name_mentions=["Jordan Langworthy"])

    assert "jane smith" in {n.lower() for n in names}
    assert "jordan langworthy" in {n.lower() for n in names}
    assert "ludwig van beethoven" not in {n.lower() for n in names}


def test_an_empty_program_gates_nothing():
    kept = strip_performer_hashtags(["#dwphotony", "#jazz"], program={})
    assert kept == ["#dwphotony", "#jazz"]


# ── the prompt must not contradict the rule ───────────────────────────────────

def test_the_prompt_no_longer_demands_performer_hashtags():
    from pathlib import Path

    src = (Path(__file__).resolve().parents[1]
           / "postroll/ai/generate_captions.py").read_text()

    assert "performers visible, genre" not in src, (
        "the required list still demands a hashtag per visible performer"
    )
    assert "Include performer/conductor hashtags if any are listed above." not in src, (
        "the re-stated rules still contradict the brand voice fame gate"
    )


# ── end to end through the real caption assembly ──────────────────────────────

def test_generate_caption_strips_it_even_when_the_model_returns_it(monkeypatch, sample_photo):
    """The whole point of the backstop: the model can still emit the tag, and
    the shipped result must not carry it. Uses the real `#bradballiett` case."""
    import postroll.ai.generate_captions as gc

    def fake_run_json_prompt(*args, **kwargs):
        return {
            "alt_texts": ["a bassoonist mid-phrase"],
            "scene_labels": ["first half"],
            "caption": "Decoda at Weill, with @bradballiett on bassoon.",
            "hashtags": ["#dwphotony", "#weillmusicroom", "#decoda",
                         "#bradballiett", "#bassoon"],
        }

    monkeypatch.setattr(gc, "run_json_prompt", fake_run_json_prompt)

    result = gc.generate_caption(
        event="Music from Inside", org="Decoda", venue="Weill Music Room",
        date="2026-08-01", day="wednesday", photo_paths=[str(sample_photo)],
        program={"performers": [
            {"name": "Brad Balliett", "role": "ensemble", "handle": "bradballiett"},
        ]},
        tag_handles=["@decoda", "@bradballiett"],
        skip_humanizer=True, skip_voice_pass=True,
    )

    assert "#bradballiett" not in result["hashtags"]
    assert "#decoda" in result["hashtags"], "the organization tag must survive"
    assert "@bradballiett" in result["caption"], "the credit belongs in the body"
