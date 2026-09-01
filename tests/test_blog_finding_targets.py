"""#1129: a finding's target survives the rewrite that changes the finding.

`Finding` is three strings and `detail` embeds the offending text
(`alt_text_length` gives `f"{name}: {words} words. {alt[:90]}"`), so a finding's
identity moves the moment the text it is about is rewritten. The damage gate
compares the findings before a repair against the findings after it, and a
round cap counts attempts per target. Both need a key that does NOT move when
the alt text does.

`detail` cannot be parsed back into one: `alt[:90]` truncates, and
`stacked_photos` gives `f"{earlier[:48]} then {later[:48]}"` with no block index
at all. So the target is recorded where the finding is built, and `check_blog`
delegates to the targeted form and drops them, which leaves the frozen
`Finding`, `finding_entry`, the bridge contract, Swift and every test file
importing `check_blog` untouched.
"""

from __future__ import annotations

from postroll.ai.blog_quality import check_blog, check_blog_targeted


PROSE = "It's a paragraph about the evening in the room."
PROGRAM = {"performers": [{"name": "Kate DiGangi"}], "pieces": []}
VENUE = "The Green Room 42"


def _body(*blocks: str) -> str:
    return "\n\n".join(blocks)


def test_the_targeted_form_and_check_blog_report_the_same_findings_in_the_same_order():
    """The refactor is invisible to every existing caller, order included."""
    body = _body(PROSE, "[PHOTO: a.jpg | Short alt]", PROSE,
                 "[PHOTO: b.jpg | Another short one]", PROSE)
    plain = check_blog(body, program=PROGRAM, venue=VENUE, photo_filenames=["a.jpg"])
    targeted = check_blog_targeted(body, program=PROGRAM, venue=VENUE,
                                   photo_filenames=["a.jpg"])

    assert [f for f, _ in targeted] == plain


def test_a_marker_finding_is_keyed_on_the_folded_filename():
    body = _body(PROSE, "[PHOTO: a.jpg | Short alt]", PROSE)
    targeted = check_blog_targeted(body, program=PROGRAM, venue=VENUE)

    for finding, target in targeted:
        if finding.code.startswith("alt_text_"):
            assert target.kind == "marker"
            assert target.key == "a.jpg"


def test_the_target_survives_a_rewrite_that_changes_the_finding():
    """The test that proves a round cap can increment at all.

    A cap keyed on finding identity restarts at zero on every rewrite and never
    increments, so it would read as a cap while capping nothing (L344).
    """
    def one(alt: str):
        found = check_blog_targeted(_body(PROSE, f"[PHOTO: a.jpg | {alt}]", PROSE),
                                    program=PROGRAM, venue=VENUE)
        return next((f, t) for f, t in found if f.code == "alt_text_length")

    before_f, before_t = one("Short alt")
    after_f, after_t = one("A different but still far too short alt")

    assert before_f != after_f, "the finding did not move, so this proves nothing"
    assert before_t == after_t, (
        "the target moved with the text, so a round counter keyed on it would "
        "restart at zero on every attempt and never reach its cap")


def test_a_marker_target_folds_punctuation_the_way_the_repairer_does():
    # A curly-quoted filename and its straight-quoted near miss are one
    # photograph, so they must be one target, or a repair attempt on the near
    # miss is counted against a target nothing else ever names.
    curly = check_blog_targeted(_body(PROSE, '[PHOTO: Cast “Live”.jpg | Short]', PROSE),
                                program=PROGRAM, venue=VENUE)
    straight = check_blog_targeted(_body(PROSE, '[PHOTO: Cast "Live".jpg | Short]', PROSE),
                                   program=PROGRAM, venue=VENUE)

    assert {t.key for _, t in curly} == {t.key for _, t in straight}


def test_a_prose_finding_is_keyed_on_its_paragraph_position():
    body = _body(PROSE, "[PHOTO: a.jpg | " + " ".join(["word"] * 18) + "]",
                 "There were 47 people there.")
    targeted = check_blog_targeted(body, program=PROGRAM, venue=VENUE)

    numbers = [t for f, t in targeted if f.code == "invented_number"]
    assert numbers, "the fixture did not produce the finding this test is about"
    assert numbers[0].kind == "prose"
    # Indexed into the PROSE-only list, so inserting or removing a marker does
    # not renumber the paragraphs a repair was licensed to touch.
    assert numbers[0].index == 1


def test_every_finding_carries_a_target():
    """No default branch: a code with no target is a code nothing can cap."""
    body = _body("A paragraph with no contraction and 47 people in it.",
                 "[PHOTO: a.jpg | Short]", "[PHOTO: b.jpg | Also short]",
                 "The female performers in the cast and the others.")
    targeted = check_blog_targeted(body, program=PROGRAM, venue=VENUE,
                                   photo_filenames=["a.jpg", "c.jpg"])

    assert targeted, "the fixture produced no findings at all"
    for finding, target in targeted:
        assert target is not None, finding
        assert target.kind in {"marker", "prose", "body"}, (finding, target)
