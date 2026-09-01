"""#1159: markers that share an opening are ONE target, not several.

`alt_text_repeated_opening` is the only alt text rule that is a fact about the
RELATIONSHIP between markers rather than about one marker's text. Everything
else in the pass is per marker, and treating this one the same way is wrong in
two separate places.

Selection: the pass picks its targets from `check_alt_text`, which is the six
rules about ONE marker and cannot produce this code at all. So the repairer
table's claim that it is "repaired as part of a component" was answered by
nothing: no marker was ever selected for it.

The gate: rewriting one member of a group changes what the OTHER members'
findings are, because the rule is about the group. A rewrite that clears the
finding on the marker being repaired can create it on two others, the damage
gate correctly refuses a finding introduced on a marker outside `touched`, the
marker ends `tried`, and no progress is made on a post that was fixable.
`tests/test_blog_repair_damage.py::test_no_alt_text_correction_dan_made_himself_is_refused`
documents the measured case: correcting a single `one_man_odyssey` marker makes
it open the way two others already do.

The fix is that a group is one component: it is selected as one, licensed as
one, and the licence is no wider than the component.
"""

from __future__ import annotations

import pytest
from PIL import Image

from postroll.ai.blog_quality import (MAX_SHARED_OPENINGS, check_blog,
                                      shared_opening_groups)
from postroll.ai.blog_repair import repair_alt_text
from postroll.ai.blog_repair_damage import Touched, blog_repair_damage

VENUE = "The Green Room 42"
PROGRAM = {"performers": [{"name": "Kate DiGangi"}, {"name": "Ryan Cavanagh"}],
           "pieces": []}
P1 = "It's a night that started late and ran long, and the room stayed full."
P2 = "The band set up at the back and didn't move for the whole first set."

#: FOUR markers opening the same way, each otherwise clean.
#:
#: Four rather than three, and that is the whole fixture. `MAX_SHARED_OPENINGS`
#: is 2, so repairing one of THREE sharing markers leaves two, which is under
#: the threshold and clears the finding outright. The failure this file is
#: about only exists when enough markers remain to go on sharing with each
#: other after one is fixed, and a three marker fixture cannot produce it: it
#: would pass whether the component licence worked or not.
SHARED_A = ("Kate DiGangi sings into a microphone at The Green Room 42 with "
            "one hand raised and the band lit blue behind her")
SHARED_B = ("Kate DiGangi sings into a microphone at The Green Room 42 while "
            "the drummer leans forward over the kit behind her")
SHARED_C = ("Kate DiGangi sings into a microphone at The Green Room 42 as the "
            "bass player watches from the left of the low stage")
SHARED_D = ("Kate DiGangi sings into a microphone at The Green Room 42 with "
            "the stage lights low and the front row dark")

#: SHARED_A with a different opening and the SAME content words. A rewrite that
#: varies the opening by discarding what the picture showed is refused by the
#: retention floor, correctly, and would prove nothing about components.
A_VARIED = ("At The Green Room 42 Kate DiGangi sings into a microphone with "
            "one hand raised and the band lit blue behind her")

#: A marker outside the group entirely.
OUTSIDE = ("Ryan Cavanagh leans over the piano at The Green Room 42 with both "
           "hands down and the room dark past the edge of the stage")


def _body(*markers: str) -> str:
    parts = [P1]
    for marker in markers:
        parts.append(marker)
        parts.append(P2)
    return "\n\n".join(parts)


def _four_sharing() -> str:
    return _body(f"[PHOTO: a.jpg | {SHARED_A}]",
                 f"[PHOTO: b.jpg | {SHARED_B}]",
                 f"[PHOTO: c.jpg | {SHARED_C}]",
                 f"[PHOTO: d.jpg | {SHARED_D}]")


COMPONENT = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]


# --- one definition of what a group is (L263, L342) -------------------------

def test_the_group_helper_and_the_check_agree_on_the_same_body():
    """Two readings of one rule drift, and drift in this one means the pass
    licenses a component the check does not believe in."""
    body = _four_sharing()
    groups = shared_opening_groups(body)
    fired = [f for f in check_blog(body) if f.code == "alt_text_repeated_opening"]
    assert len(groups) == len(fired) == 1
    assert sorted(groups[0]) == COMPONENT


def test_a_group_needs_more_than_the_shared_opening_maximum():
    """The threshold is the check's own constant, not a second copy of it."""
    two = _body(f"[PHOTO: a.jpg | {SHARED_A}]", f"[PHOTO: b.jpg | {SHARED_B}]")
    assert MAX_SHARED_OPENINGS == 2
    assert shared_opening_groups(two) == []
    assert len(shared_opening_groups(_four_sharing())) == 1


def test_markers_that_open_differently_form_no_group():
    body = _body(f"[PHOTO: a.jpg | {SHARED_A}]", f"[PHOTO: e.jpg | {OUTSIDE}]")
    assert shared_opening_groups(body) == []


def test_a_body_with_no_markers_has_no_groups():
    assert shared_opening_groups(_body()) == []


# --- the gate: a component is licensed as one ------------------------------

def test_a_finding_moved_onto_another_member_of_the_component_is_allowed():
    """The measured failure. Rewriting one member so it stops sharing can
    leave the other two sharing with each other, which is a finding on markers
    the single marker licence does not name."""
    before = _four_sharing()
    after = before.replace(SHARED_A, A_VARIED)
    refused = blog_repair_damage(
        before, after, program=PROGRAM, venue=VENUE,
        photo_filenames=COMPONENT,
        touched=Touched.marker("a.jpg", component=COMPONENT))
    assert refused == [], (
        f"the gate refused a rewrite inside one component: {refused}")


def test_the_same_rewrite_is_refused_when_only_one_marker_is_licensed():
    """The control (L159). Without it, the test above cannot tell a working
    component licence from a gate that was never going to refuse anything."""
    before = _four_sharing()
    after = before.replace(SHARED_A, A_VARIED)

    refused = blog_repair_damage(
        before, after, program=PROGRAM, venue=VENUE,
        photo_filenames=COMPONENT, touched=Touched.marker("a.jpg"))
    assert refused, (
        "the single marker licence accepted this, so the component licence "
        "above is not what made the difference and proves nothing")


def test_the_component_licence_is_no_wider_than_the_component():
    """A licence covering the whole post would accept damage anywhere, which
    is the safeguard this milestone is built on, not a detail."""
    before = _body(f"[PHOTO: a.jpg | {SHARED_A}]",
                   f"[PHOTO: b.jpg | {SHARED_B}]",
                   f"[PHOTO: c.jpg | {SHARED_C}]",
                   f"[PHOTO: d.jpg | {SHARED_D}]",
                   f"[PHOTO: e.jpg | {OUTSIDE}]")
    # Damage to a marker OUTSIDE the component: its alt text is gutted.
    after = before.replace(OUTSIDE, "A performer")

    refused = blog_repair_damage(
        before, after, program=PROGRAM, venue=VENUE,
        photo_filenames=COMPONENT + ["e.jpg"],
        touched=Touched.marker("a.jpg", component=COMPONENT))
    assert refused, "damage outside the component was licensed by it"


# --- selection: the code becomes reachable at all --------------------------

@pytest.fixture
def photos(tmp_path):
    def _make(*names):
        out = {}
        for i, name in enumerate(names):
            path = tmp_path / name
            Image.new("RGB", (40, 30), (10 + i, 20, 30)).save(path)
            out[name] = str(path)
        return out
    return _make


def test_the_pass_selects_a_marker_whose_only_fault_is_a_shared_opening(photos):
    """Every marker here passes `check_alt_text` clean. If selection reads only
    that function, nothing is selected and the finding stands forever."""
    files = photos(*COMPONENT)
    body = _four_sharing()
    assert any(f.code == "alt_text_repeated_opening" for f in check_blog(body))

    calls = []

    def runner(prompt, *, timeout, image_paths, image_labels, step):
        calls.append(image_labels[0])
        return {"alt": A_VARIED}

    result = repair_alt_text(body, program=PROGRAM, venue=VENUE,
                             photo_paths=files, runner=runner,
                             now=lambda: 0.0, deadline=1_000_000.0,
                             max_rounds=1)
    assert result.selected, "the pass selected nothing on a body that fires"
    assert calls, "the pass made no call, so the code is still unreachable"


def test_a_body_with_nothing_wrong_still_selects_nothing(photos):
    """The control for the test above: selection must not have been widened
    into selecting every marker on every post."""
    files = photos("a.jpg", "e.jpg")
    body = _body(f"[PHOTO: a.jpg | {SHARED_A}]", f"[PHOTO: e.jpg | {OUTSIDE}]")
    assert [f.code for f in check_blog(body, venue=VENUE)] == []

    def runner(prompt, **kwargs):
        raise AssertionError("a clean body reached the model")

    result = repair_alt_text(body, program=PROGRAM, venue=VENUE,
                             photo_paths=files, runner=runner,
                             now=lambda: 0.0, deadline=1_000_000.0,
                             max_rounds=1)
    assert result.selected == []


def test_a_component_licence_does_not_license_changing_those_markers():
    """The two licences answer different questions and must stay apart.

    Listing the whole component as `markers` was the first attempt, and it
    fails in a way that reads as working: every other member's untouched alt
    text is then put through the checks for a REWRITE, so a component holding
    any marker that is short or not yet repaired is refused for damage this
    repair never did. It cost a real test failure to find, and nothing else
    here would catch a return to it.
    """
    before = _four_sharing()
    # b.jpg is gutted. It is inside the component, and it was never rewritten.
    after = before.replace(SHARED_B, "A performer")

    refused = blog_repair_damage(
        before, after, program=PROGRAM, venue=VENUE,
        photo_filenames=COMPONENT,
        touched=Touched.marker("a.jpg", component=COMPONENT))
    assert refused, (
        "the component licence allowed a marker inside it to be CHANGED; "
        "component licenses attribution of a cross-marker finding, never a "
        "rewrite")


def test_an_untouched_short_marker_inside_a_component_is_not_blamed_on_the_repair():
    """The other direction, and the bug this split exists to fix.

    Every other member of a component is usually still awaiting its own repair,
    so it is short, missing the venue, or both. None of that is damage the
    repair being judged has done.
    """
    before = _body(f"[PHOTO: a.jpg | {SHARED_A}]",
                   f"[PHOTO: b.jpg | {SHARED_B}]",
                   f"[PHOTO: c.jpg | {SHARED_C}]",
                   "[PHOTO: f.jpg | A singer]")
    after = before.replace(SHARED_A, A_VARIED)

    refused = blog_repair_damage(
        before, after, program=PROGRAM, venue=VENUE,
        photo_filenames=COMPONENT[:3] + ["f.jpg"],
        touched=Touched.marker("a.jpg",
                               component=["a.jpg", "b.jpg", "c.jpg", "f.jpg"]))
    assert refused == [], (
        f"the repair was blamed for an untouched marker's own faults: {refused}")
