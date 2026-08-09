"""#226: the invented-number check must stop firing on finished posts.

Measured against the two correction fixtures committed in #204, `invented_number`
fires twice on posts Dan considered finished, and both are false positives. An
alert that cries wolf gets ignored, so the whole check was on its way to being
worthless.

The two causes are different and are fixed separately:

1. A numeral that is part of a TITLE or section label ("Matchbook Spark Vol. 2",
   "Book 2 of Homer's Odyssey"). It is a name, not a measurement, so there is
   nothing for it to be wrong about.

2. A count DERIVABLE from the names written beside it. The bludline post says
   "Eight people at mic stands" in a paragraph that names exactly eight people.
   Note this is not the cast size: that programme has ten performers. Deriving
   it from the cast list would have been wrong here and would have accepted the
   number for a reason that is not true, so the rule counts the names actually
   in the paragraph.

What must NOT change is the check's ability to catch a number the generator
made up, which is the reason it exists.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.ai.blog_quality import check_blog


FIXTURES = Path(__file__).parent / "fixtures" / "blog_corrections"


def _codes(findings):
    return [f.code for f in findings]


def _fixture(name):
    return json.loads((FIXTURES / name).read_text())


# ── the measured false positives ──────────────────────────────────────────────

@pytest.mark.parametrize("name", ["one_man_odyssey.json", "bludline.json"])
def test_no_invented_number_on_a_post_dan_considered_finished(name):
    d = _fixture(name)

    findings = check_blog(d["corrected"], program=d["program"], venue=d["venue"])

    assert "invented_number" not in _codes(findings), (
        "fired on: " + "; ".join(f.detail for f in findings
                                 if f.code == "invented_number"))


# ── cause 1: a number inside a title is a name, not a count ───────────────────

@pytest.mark.parametrize("phrase", [
    "The show was part of Matchbook Spark Vol. 2, presented downtown.",
    "He performs Book 2 of Homer's Odyssey in Ancient Greek.",
    "They opened with Symphony No. 4 before the interval.",
    "The quartet played Op. 59 from memory.",
    "Act 3 ran without an interval.",
    "Volume 2 collects the earlier sessions.",
])
def test_a_numeral_used_as_a_title_label_is_not_a_count(phrase):
    findings = check_blog(phrase, program={}, venue="")

    assert "invented_number" not in _codes(findings), f"flagged: {phrase}"


# ── cause 2: a count the paragraph itself supports ────────────────────────────

def test_a_count_matching_the_names_beside_it_is_derivable():
    program = {"performers": [{"name": n} for n in
                              ["Ana Silva", "Ben Cole", "Cara Diaz", "Dev Rao"]]}
    body = ("Ana Silva and Ben Cole play against Cara Diaz and Dev Rao. "
            "Four people on stage means the frames fill up fast.")

    findings = check_blog(body, program=program, venue="")

    assert "invented_number" not in _codes(findings)


def test_a_count_that_does_not_match_the_names_still_fires():
    # The point of the rule. A number nobody can source is exactly what the
    # generator invents, and it must not be waved through just because some
    # names happen to be nearby.
    program = {"performers": [{"name": n} for n in
                              ["Ana Silva", "Ben Cole", "Cara Diaz", "Dev Rao"]]}
    body = ("Ana Silva and Ben Cole play against Cara Diaz and Dev Rao. "
            "Nine people on stage means the frames fill up fast.")

    findings = check_blog(body, program=program, venue="")

    assert "invented_number" in _codes(findings)


def test_the_cast_size_alone_does_not_bless_a_number():
    # bludline's cast is ten while the sentence says eight, so accepting a
    # number for matching the cast size would have accepted it for a reason
    # that is not true, and would accept a genuinely wrong count elsewhere.
    program = {"performers": [{"name": f"Person {i}"} for i in range(10)]}
    body = "Ten people were somewhere in the building that night."

    findings = check_blog(body, program=program, venue="")

    assert "invented_number" in _codes(findings), (
        "no names in this paragraph, so nothing supports the count")


# ── the check still does its job ──────────────────────────────────────────────

def test_a_plainly_invented_number_is_still_caught():
    body = "The audience of 400 stayed to the end and the run lasted 90 minutes."

    codes = _codes(check_blog(body, program={}, venue=""))

    assert codes.count("invented_number") == 2


def test_a_number_present_in_the_program_data_is_still_accepted():
    program = {"pieces": [{"title": "Sonata for 2 Pianos", "composer": "Mozart"}]}
    body = "They closed with the Sonata for 2 Pianos."

    assert "invented_number" not in _codes(check_blog(body, program=program, venue=""))


def test_the_draft_versions_still_fire_so_the_check_has_not_been_gutted():
    # Both drafts are pinned in expectations.json as having to fire this check.
    # A fix that made it stop firing on the drafts too would have removed the
    # detector rather than corrected it.
    fired = []
    for name in ("one_man_odyssey.json", "bludline.json"):
        d = _fixture(name)
        fired.append("invented_number" in
                     _codes(check_blog(d["draft"], program=d["program"], venue=d["venue"])))

    assert any(fired), "at least one draft must still trip the check"
