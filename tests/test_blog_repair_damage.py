"""#1129: the damage gate, one test per reason it can give.

Dan's rule 1 is that repairs are SILENT, so nothing on the review panel invites
him to check one. Every human check the design used to rest on is gone, and this
gate is what replaces it. It is built and proven red before the first repairer
exists.

Each test produces ONE reason and asserts no other fires, because a reason that
can only be produced alongside four others is a reason nobody can act on (L11).
The positive controls at the bottom are what say the gate is not simply refusing
everything, and the gate is not allowed to gate anything until the husk control
has been seen red (L159, L142).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.ai.blog_quality import _PHOTO_MARKER, _fold_filename, _markers
from postroll.ai.blog_repair_damage import Touched, blog_repair_damage


VENUE = "The Green Room 42"
PROGRAM = {"performers": [{"name": "Kate DiGangi"}, {"name": "Ryan Cavanagh"}],
           "pieces": []}
ORG = "Green Room Presents"

P1 = "It's a night that started late and ran long, and the room stayed full."
P2 = "The band set up at the back and didn't move for the whole first set."
P3 = "I'd been in this room before, but never with the lights hung that low."

GOOD_A = ("Kate DiGangi sings into a microphone at The Green Room 42 with one "
          "hand raised and the band lit blue behind her")
GOOD_B = ("Ryan Cavanagh plays an upright bass at The Green Room 42, leaning "
          "back with his eyes on the drummer across the stage")


def _body(*blocks: str) -> str:
    return "\n\n".join(blocks)


def _post(alt_a: str = GOOD_A, alt_b: str = GOOD_B, *, p1=P1, p2=P2, p3=P3) -> str:
    return _body(p1, f"[PHOTO: a.jpg | {alt_a}]", p2,
                 f"[PHOTO: b.jpg | {alt_b}]", p3)


def _damage(prior, revised, touched=None, **kw):
    return blog_repair_damage(prior, revised, program=PROGRAM, venue=VENUE,
                              org=ORG, photo_filenames=["a.jpg", "b.jpg"],
                              touched=touched, **kw)


def _only(reasons, needle):
    """One reason, matching, and nothing else riding along."""
    assert reasons, f"nothing was refused; expected a reason mentioning {needle!r}"
    assert any(needle in r for r in reasons), reasons
    assert len(reasons) == 1, f"more than one reason fired: {reasons}"


# --- 1. a finding the repair introduced --------------------------------------

def test_a_second_finding_of_a_code_already_present_is_refused():
    """A multiset, not a set: the commonest way a whole body repair gets worse."""
    prior = _post(alt_a="Too short")                    # one alt_text_length
    revised = _post(alt_a="Too short", alt_b="Also short")  # now two
    reasons = _damage(prior, revised, Touched.marker("a.jpg", "b.jpg"))

    assert any("alt_text_length" in r and "b.jpg" in r for r in reasons), reasons


def test_a_repair_that_removes_a_finding_is_not_refused_for_it():
    prior = _post(alt_a="Too short")
    revised = _post(alt_a=GOOD_A)

    assert _damage(prior, revised, Touched.marker("a.jpg")) == []


# --- 2. the ordered marker sequence ------------------------------------------

def test_reordering_two_untouched_markers_is_refused():
    prior = _post()
    revised = _body(P1, f"[PHOTO: b.jpg | {GOOD_B}]", P2,
                    f"[PHOTO: a.jpg | {GOOD_A}]", P3)

    reasons = _damage(prior, revised, Touched())
    assert any("order or the membership" in r for r in reasons), reasons


def test_a_swap_replacing_a_licensed_marker_is_not_a_reorder():
    """Scoped by touched. Unscoped, this refused every photo swap (L159)."""
    prior = _post()
    revised = _body(P1, f"[PHOTO: c.jpg | {GOOD_A}]", P2,
                    f"[PHOTO: b.jpg | {GOOD_B}]", P3)

    reasons = blog_repair_damage(
        prior, revised, program=PROGRAM, venue=VENUE, org=ORG,
        photo_filenames=["c.jpg", "b.jpg"],
        touched=Touched.marker("a.jpg", "c.jpg"),
        expected_marker_keys=["c.jpg", "b.jpg"])
    assert reasons == [], reasons


def test_a_swap_that_does_not_place_what_it_was_asked_for_is_refused():
    prior = _post()
    revised = _body(P1, f"[PHOTO: c.jpg | {GOOD_A}]", P2,
                    f"[PHOTO: b.jpg | {GOOD_B}]", P3)

    reasons = blog_repair_damage(
        prior, revised, program=PROGRAM, venue=VENUE, org=ORG,
        photo_filenames=["d.jpg", "b.jpg"],
        touched=Touched.marker("a.jpg", "c.jpg", "d.jpg"),
        expected_marker_keys=["d.jpg", "b.jpg"])
    assert any("does not place the photographs" in r for r in reasons), reasons


# --- 3. an untouched marker changed by one byte ------------------------------

@pytest.mark.parametrize("changed", [
    GOOD_B + ".",                       # one character added
    GOOD_B.replace(" plays", "  plays"),  # one space added, nothing else
])
def test_a_retained_marker_differing_by_one_byte_is_refused(changed):
    """Byte for byte, whitespace included.

    The whitespace case is the one that matters and the one a "tidy up the
    comparison" change removes first: a retained marker is supposed to be
    SPLICED BACK from the input, so any drift at all, including a doubled
    space, means the model's version was kept instead of the original's.
    """
    assert changed != GOOD_B
    prior = _post()
    revised = _post(alt_b=changed)

    _only(_damage(prior, revised, Touched.marker("a.jpg")),
          "altered the marker for b.jpg")


# --- 4. an untouched prose paragraph -----------------------------------------

def test_a_prose_paragraph_the_repair_rewrote_is_refused():
    """The swap prompt says 'Do NOT change any prose' and nothing verified it."""
    prior = _post()
    # Keeps a contraction, so only the untouched-prose reason can fire.
    revised = _post(p2="The band set up at the back and didn't move all night.")

    _only(_damage(prior, revised, Touched.marker("a.jpg")),
          "rewrote prose paragraph 1")


def test_a_deleted_prose_paragraph_is_refused():
    prior = _post()
    revised = _body(P1, f"[PHOTO: a.jpg | {GOOD_A}]",
                    f"[PHOTO: b.jpg | {GOOD_B}]", P3)

    reasons = _damage(prior, revised, Touched.marker("a.jpg"))
    assert any("prose paragraph" in r for r in reasons), reasons


def test_an_added_prose_paragraph_is_refused():
    prior = _post()
    revised = _post() + "\n\nAnd there's one more thing I didn't say."

    reasons = _damage(prior, revised, Touched.marker("a.jpg"))
    assert any("added 1 prose paragraph" in r for r in reasons), reasons


# --- 5. the husk ------------------------------------------------------------

#: The husk, and the original it replaces, sized so that only the ABSOLUTE
#: floor refuses it.
#:
#: Deliberate. An earlier version of this control used a husk whose share was
#: 0.11, which the share clause refuses on its own, so the control passed with
#: check 5's real mechanism switched off, and the guard mutation that removes
#: that mechanism SURVIVED. The control now asserts the sizing itself, so it
#: cannot quietly stop exercising the thing it exists to prove (L159, L142).
HUSK_ORIGINAL = ("Kate DiGangi grips a trumpet, elbows out, head tipped back "
                 "in red wash at The Green Room 42")
HUSK = ("Kate DiGangi grips a trumpet at The Green Room 42 during the "
        "performance on stage in the room with the others")


def test_the_husk_control_the_gate_may_not_gate_without():
    """The check the earlier draft did not have (L283, L278).

    This alt text keeps the venue and the performer, is inside the word band,
    fires zero findings, and describes nothing the camera recorded. Every other
    check passes it. Until this is seen red, the gate is not allowed to gate.
    """
    from postroll.ai.blog_quality import check_blog
    from postroll.ai.blog_repair_damage import (
        _RETENTION_FLOOR, _identity_tokens, _retained_share)

    share, kept, total = _retained_share(HUSK_ORIGINAL, HUSK,
                                         drop=_identity_tokens(PROGRAM, VENUE))
    assert share > _RETENTION_FLOOR, (
        f"the husk scores {share:.2f}, which the share clause refuses on its "
        "own, so this control would pass with check 5's absolute floor deleted")
    assert kept < 3 and total >= 8, (share, kept, total)

    husked = _post(alt_a=HUSK)
    assert not [f for f in check_blog(husked, program=PROGRAM, venue=VENUE,
                                      photo_filenames=["a.jpg", "b.jpg"])
                if f.code.startswith("alt_text_") and "a.jpg" in f.detail], (
        "the fixture is not a husk: the ordinary checks already refuse it, so "
        "this test would pass without check 5 existing")

    reasons = _damage(_post(alt_a=HUSK_ORIGINAL), husked, Touched.marker("a.jpg"))
    assert any("describes the picture less" in r for r in reasons), reasons


def test_a_rewrite_shorter_than_the_minimum_is_refused():
    prior = _post()
    revised = _post(alt_a="Kate DiGangi at The Green Room 42")

    reasons = _damage(prior, revised, Touched.marker("a.jpg"))
    assert any("shorter than the" in r for r in reasons), reasons


def test_an_honest_rewrite_of_the_same_photograph_passes():
    prior = _post(alt_a="Kate DiGangi sings at The Green Room 42 hand raised blue")
    revised = _post(alt_a=("Kate DiGangi sings into a microphone at The Green "
                           "Room 42, one hand raised, lit blue from behind"))

    assert _damage(prior, revised, Touched.marker("a.jpg")) == []


# --- 6. a credit lost, or a handle introduced --------------------------------

def test_dropping_a_performer_name_is_refused():
    prior = _post()
    revised = _post(p1=P1, alt_a=GOOD_A.replace("Kate DiGangi", "the singer"),
                    p3=P3.replace("I'd", "I had"))
    # Scope the paragraph edit out of it so only the credit reason can fire.
    revised = _post(alt_a=("The singer sings into a microphone at The Green "
                           "Room 42 with one hand raised, band lit blue"))
    reasons = _damage(prior, revised, Touched.marker("a.jpg"))
    assert any("dropped the required credit Kate DiGangi" in r for r in reasons), reasons


def test_dropping_the_organisation_name_is_refused():
    prior = _post(p1=f"{P1} {ORG} put the night on.")
    revised = _post(p1=f"{P1} The promoter put the night on.")

    reasons = _damage(prior, revised, Touched(paragraphs=frozenset({0})))
    assert any(f"dropped the required credit {ORG}" in r for r in reasons), reasons


def test_introducing_a_handle_the_post_did_not_have_is_refused():
    """Proves the introduced-handle branch is live at all."""
    prior = _post()
    revised = _post(alt_a=("Kate DiGangi sings into a microphone at The Green "
                           "Room 42 for @someone with one hand raised high"))

    reasons = _damage(prior, revised, Touched.marker("a.jpg"))
    assert any("introduced the handle @someone" in r for r in reasons), reasons


def test_an_unchanged_handle_in_a_marker_filename_does_not_fire():
    body = _body(P1, f"[PHOTO: Show @dwphotony-12.jpg | {GOOD_A}]", P2)
    assert blog_repair_damage(body, body, program=PROGRAM, venue=VENUE,
                              org=ORG, touched=Touched()) == []


# --- 7. an unaccountable capitalised name ------------------------------------

def test_introducing_a_name_the_source_data_cannot_account_for_is_refused():
    prior = _post()
    revised = _post(alt_a=("Kate DiGangi sings with Sarah Vaughan at The Green "
                           "Room 42, one hand raised and the band behind"))

    reasons = _damage(prior, revised, Touched.marker("a.jpg"))
    assert any("Sarah" in r and "nowhere" in r for r in reasons), reasons


def test_a_word_capitalised_only_because_it_opens_the_span_is_not_a_name():
    """The over-match that made the un-narrowed form fire on 16 of 20 posts."""
    prior = _post(alt_a="Kate DiGangi at The Green Room 42 sings with one hand raised high")
    revised = _post(alt_a=("Wide view of Kate DiGangi at The Green Room 42 "
                           "singing with one hand raised high above her"))

    assert _damage(prior, revised, Touched.marker("a.jpg")) == []


# --- 8. second person and contractions put back ------------------------------

def test_reintroducing_second_person_is_refused():
    prior = _post()
    revised = _post(p2="The band set up at the back, and you didn't see them move.")

    reasons = _damage(prior, revised, Touched(paragraphs=frozenset({1})))
    assert any("addresses the reader" in r for r in reasons), reasons


def test_reintroducing_a_contraction_free_paragraph_is_refused():
    prior = _post()
    revised = _post(p2="The band set up at the back and stayed for the whole set.")

    reasons = _damage(prior, revised, Touched(paragraphs=frozenset({1})))
    assert any("no contraction" in r for r in reasons), reasons


# --- 9. dashes and emoji -----------------------------------------------------

# Escapes, not the characters: the pre push style gate would otherwise catch
# this line, which is the gate working correctly.
@pytest.mark.parametrize("mark", ["\u2014", "\u2013", "\U0001F600"])
def test_introducing_a_dash_or_an_emoji_is_refused(mark):
    prior = _post()
    revised = _post(alt_a=("Kate DiGangi sings at The Green Room 42 " + mark +
                           " one hand raised and the band lit blue behind her"))

    reasons = _damage(prior, revised, Touched.marker("a.jpg"))
    assert any("dash or emoji" in r for r in reasons), reasons


# --- 10. a paragraph holding an inline marker --------------------------------

def test_licensing_a_paragraph_that_holds_an_inline_marker_is_refused():
    inline = f"{P2} [PHOTO: b.jpg | {GOOD_B}] and it went on from there."
    prior = _body(P1, f"[PHOTO: a.jpg | {GOOD_A}]", inline, P3)

    reasons = blog_repair_damage(prior, prior, program=PROGRAM, venue=VENUE,
                                 org=ORG, photo_filenames=["a.jpg", "b.jpg"],
                                 touched=Touched(paragraphs=frozenset({1})))
    assert any("holds a photo marker inline" in r for r in reasons), reasons


# --- positive controls -------------------------------------------------------

def test_an_unchanged_post_is_never_refused():
    assert _damage(_post(), _post(), Touched.marker("a.jpg")) == []


def _apply_corrections(draft: str, corrected: str) -> str:
    """Dan's corrected alt text, spliced into his own draft prose.

    Exactly what the repair pass would produce if it did as well as he did: v1
    rewrites alt text and nothing else, so the prose stays byte for byte.
    """
    by_key = {_fold_filename(k): v for k, v in _markers(corrected)}

    def swap(match):
        name = match.group(1).strip()
        alt = by_key.get(_fold_filename(name))
        return f"[PHOTO: {name} | {alt}]" if alt is not None else match.group(0)

    return _PHOTO_MARKER.sub(swap, draft)


@pytest.mark.parametrize("fixture", ["bludline", "one_man_odyssey"])
def test_no_alt_text_correction_dan_made_himself_is_refused(fixture):
    """The 14 corrected markers, judged as one pass. An over-match is a failure
    here, not a discovery (L147).

    Judged as ONE pass rather than one marker at a time, and that is not a
    convenience. `alt_text_repeated_opening` is a fact about the RELATIONSHIP
    between markers, so applying his corrections one at a time passes through a
    state he never shipped: measured while writing this, correcting a single
    `one_man_odyssey` marker makes it open the way two others already do, the
    gate refuses it, and his finished post does not carry that finding at all.

    Scoped to alt text because that is all v1 rewrites. His corrections also
    add a prose paragraph and leave two without a contraction, and the gate
    refuses both, correctly: no v1 repairer can produce a prose change, so a
    control that licensed one would be asserting about code that does not exist.

    The two fixtures only. The stored events hold 41 more differing pairs, and a
    test reading them would change every time Dan finishes a post (L130). All 55
    are measured by tools/measure_alt_text_retention.py, which is what the
    retention floor is calibrated against.
    """
    data = json.loads((Path(__file__).parent / "fixtures" / "blog_corrections"
                       / f"{fixture}.json").read_text(encoding="utf-8"))
    draft = data["draft"]
    revised = _apply_corrections(draft, data["corrected"])
    assert revised != draft, "the fixture changed no alt text, so this proves nothing"

    names = [k for k, _ in _markers(draft)]
    reasons = blog_repair_damage(
        draft, revised, program=data["program"], venue=data["venue"],
        photo_filenames=names,
        touched=Touched.marker(*names))
    assert reasons == [], f"refused Dan's own corrections: {reasons}"


def test_the_correction_control_would_notice_a_husk():
    """The control is only worth running if it can fail (L159).

    Same fixture, same call, with one of Dan's corrections replaced by a husk.
    """
    data = json.loads((Path(__file__).parent / "fixtures" / "blog_corrections"
                       / "bludline.json").read_text(encoding="utf-8"))
    draft = data["draft"]
    revised = _apply_corrections(draft, data["corrected"])
    first = _markers(revised)[0]
    husked = revised.replace(
        f"[PHOTO: {first[0]} | {first[1]}]",
        f"[PHOTO: {first[0]} | " + " ".join(
            [data["venue"]] + ["the"] * 14) + "]", 1)

    names = [k for k, _ in _markers(draft)]
    reasons = blog_repair_damage(
        draft, husked, program=data["program"], venue=data["venue"],
        photo_filenames=names, touched=Touched.marker(*names))
    assert any("describes the picture less" in r for r in reasons), reasons


# --- what the retention floor rests on, pinned ------------------------------

def _fixture_minimum_share() -> float:
    """The lowest retention among Dan's own corrections in this repo."""
    from postroll.ai.blog_repair_damage import _identity_tokens, _retained_share

    lowest = 1.0
    for name in ("bludline", "one_man_odyssey"):
        data = json.loads((Path(__file__).parent / "fixtures" / "blog_corrections"
                           / f"{name}.json").read_text(encoding="utf-8"))
        known = _identity_tokens(data["program"], data["venue"])
        draft = {_fold_filename(k): v for k, v in _markers(data["draft"])}
        for marker, alt in _markers(data["corrected"]):
            key = _fold_filename(marker)
            if key not in draft or draft[key].strip() == alt.strip():
                continue
            share, _kept, total = _retained_share(draft[key], alt, drop=known)
            if total:
                lowest = min(lowest, share)
    return lowest


def test_the_share_alone_cannot_separate_a_husk_from_a_real_rewrite():
    """The measurement that decided check 5's shape, kept as a test (L316).

    The plan asked for a SHARE floor and said a husk's retention is "near
    zero". Measured, it is not, and this exhibits why: a husk that keeps two
    content words of a nine word original scores ABOVE the lowest share among
    Dan's own corrections. Any share floor low enough to pass his work is
    therefore too low to refuse this husk, at any threshold.

    What separates them is the ABSOLUTE count against a long original, which is
    what check 5 actually rests on. Pinned here so a later change that
    "simplifies" check 5 back to a share floor has to argue with the numbers
    rather than with the prose.
    """
    from postroll.ai.blog_repair_damage import (
        _RETENTION_LONG_ENOUGH, _RETENTION_MIN_KEPT, _identity_tokens,
        _retained_share)

    known = _identity_tokens(PROGRAM, VENUE)
    # Nine content words, so two kept scores 0.22: above the corpus floor.
    original = ("Kate DiGangi grips a trumpet, elbows out, head tipped back "
                "in red wash at The Green Room 42")
    husk = ("Kate DiGangi grips a trumpet at The Green Room 42 during the "
            "performance on stage in the room with the others")

    share, kept, total = _retained_share(original, husk, drop=known)
    floor = _fixture_minimum_share()

    assert total >= _RETENTION_LONG_ENOUGH, (
        f"the original is only {total} content words, so the absolute floor "
        "does not apply and this test is not about check 5")
    assert share > floor, (
        f"the husk scores {share:.2f}, below the {floor:.2f} minimum among "
        "Dan's own corrections, so a share floor WOULD separate them and this "
        "test's premise no longer holds; re-measure before trusting either")
    assert kept < _RETENTION_MIN_KEPT, (
        "the absolute count no longer refuses this husk, which would leave "
        "check 5 with nothing to rest on")

    prior, revised = _post(alt_a=original), _post(alt_a=husk)
    reasons = _damage(prior, revised, Touched.marker("a.jpg"))
    assert any("describes the picture less" in r for r in reasons), reasons


def test_a_genuine_re_description_that_keeps_almost_no_words_is_allowed():
    """Rule 4 licenses rewriting the description; rule 9 forbids losing it."""
    prior = _post(alt_a=("A male performer in a grey t-shirt stands on a raised "
                         "platform with one arm up, holding a microphone"))
    revised = _post(alt_a=("Kate DiGangi stands on a raised platform at The Green "
                           "Room 42 with a microphone, one arm up, audience "
                           "silhouetted in the foreground"))

    assert _damage(prior, revised, Touched.marker("a.jpg")) == []


def test_the_venue_and_performer_are_not_credited_as_retained_content():
    """Every alt text has to carry both, so keeping them says nothing.

    Without stripping them, a husk consisting of the venue plus the performer
    plus filler scores as though it had kept the description.
    """
    from postroll.ai.blog_repair_damage import _identity_tokens, _retained_share

    known = _identity_tokens(PROGRAM, VENUE)
    _share, kept, _total = _retained_share(
        f"Kate DiGangi at {VENUE} holding a trumpet under a red wash",
        f"Kate DiGangi at {VENUE} during the evening", drop=known)
    assert kept == 0, (
        f"kept {kept} words, so the venue and performer are being counted as "
        "description and a husk made of them alone would score as a rewrite")


# --- #1137: the correction the un-narrowed check 7 would have refused --------

def test_the_battery_dance_correction_is_not_refused():
    """The control #1137 was filed for.

    Dan corrected "the outdoor Wagner Park stage" to "the outdoor stage at
    Robert F. Wagner Jr. Park", which is the venue's real full name. The plan's
    check 7, as specified, refuses it: the name is absent from the program
    performers and from the prior alt text, and the plan's known set was built
    from `venue`, which on that event is an EMPTY STRING. The real venue lives
    in `venueContext` and in every marker filename, and neither was consulted.

    Two things fix it and both are asserted here: the known set reads
    `venue_context` and the photo filenames, and the prior BODY is what check 7
    compares against rather than the prior alt text alone.
    """
    venue_context = "Robert F. Wagner Jr. Park"
    program = {"performers": [{"name": "DPR Dance"}], "pieces": []}
    marker = f"Battery Dance Festival ({venue_context}) @dwphotony-61.jpg"
    prose = ("It's an open-air stage and the sky did most of the work that "
             "night, so I didn't touch the white balance.")
    before = ("Four DPR Dance performers on the outdoor Wagner Park stage at "
              "dusk, one dancer centred with both arms extended wide")
    after = ("Four DPR Dance performers on the outdoor stage at Robert F. "
             "Wagner Jr. Park at dusk, one centred with both arms wide")

    prior = _body(prose, f"[PHOTO: {marker} | {before}]", prose)
    revised = _body(prose, f"[PHOTO: {marker} | {after}]", prose)

    reasons = blog_repair_damage(
        prior, revised, program=program, venue="", venue_context=venue_context,
        org="Battery Dance", photo_filenames=[marker],
        touched=Touched.marker(marker))
    assert reasons == [], f"refused Dan's own venue correction: {reasons}"


def test_an_empty_venue_field_does_not_make_the_name_check_blind_or_deaf():
    """The same event, with a name nothing can account for. Proves the fix to
    the control above did not simply switch check 7 off."""
    venue_context = "Robert F. Wagner Jr. Park"
    marker = f"Battery Dance Festival ({venue_context}) @dwphotony-61.jpg"
    prose = "It's an open-air stage and the sky did most of the work that night."
    before = ("Four DPR Dance performers on the outdoor Wagner Park stage at "
              "dusk, one dancer centred with both arms extended wide")
    after = ("Four DPR Dance performers from the Alvin Ailey company on the "
             "outdoor stage at Robert F. Wagner Jr. Park at dusk, arms wide")

    reasons = blog_repair_damage(
        _body(prose, f"[PHOTO: {marker} | {before}]", prose),
        _body(prose, f"[PHOTO: {marker} | {after}]", prose),
        program={"performers": [{"name": "DPR Dance"}], "pieces": []},
        venue="", venue_context=venue_context, org="Battery Dance",
        photo_filenames=[marker], touched=Touched.marker(marker))
    assert any("Ailey" in r for r in reasons), reasons


# --- a marker that was not there before cannot be a regression ---------------

def test_a_finding_on_a_newly_placed_marker_is_not_treated_as_damage():
    """A photo swap replaces markers, so its new ones have no counterpart in
    the input and EVERY finding they carry reads as introduced.

    Left in, that refused a swap whenever the model wrote a slightly short alt
    text, and the fallback it triggered is a whole rewrite producing the same
    finding again: a refusal nothing can satisfy is worse than no refusal
    (L109). Found by the swap path's own test, not by reasoning about it.
    """
    prior = _post()
    revised = _body(P1, f"[PHOTO: c.jpg | {GOOD_A}]", P2,
                    f"[PHOTO: b.jpg | {GOOD_B}]", P3)
    # Too short, which check_blog reports and the panel shows, but it still
    # names the performer: dropping her name is a DIFFERENT reason and would
    # make this test pass or fail for something other than what it is about.
    revised = revised.replace(GOOD_A, "Kate DiGangi at The Green Room 42")

    reasons = blog_repair_damage(
        prior, revised, program=PROGRAM, venue=VENUE, org=ORG,
        photo_filenames=["c.jpg", "b.jpg"],
        touched=Touched.marker("a.jpg", "c.jpg"),
        expected_marker_keys=["c.jpg", "b.jpg"])

    assert reasons == [], (
        f"the gate refused a swap over a finding on a photograph that was not "
        f"in the post before: {reasons}")


def test_a_finding_added_to_a_marker_that_WAS_there_is_still_damage():
    """The control. The exemption above must not switch check 1 off (L159)."""
    prior = _post()
    revised = _post(alt_b="Ryan Cavanagh at The Green Room 42")

    reasons = _damage(prior, revised, Touched.marker("a.jpg", "b.jpg"))
    assert any("alt_text_length" in r and "b.jpg" in r for r in reasons), reasons
