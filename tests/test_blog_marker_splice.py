"""#1131: a marker the model was told to reproduce is RESTORED, not trusted.

Both the swap path and the revise path hand the model a body full of
`[PHOTO: filename | alt text]` markers and tell it to keep them exactly. Neither
verified it. Until #1141 `markers_preserved_validator` sorted the filenames and
never read the alt text, so a pass that rewrote every description while keeping
every filename was indistinguishable from one that changed nothing. It now
compares the ordered (filename, alt text) pairs; the splice stays because a
validator can only refuse the whole pass, and refusing discards one already
paid for.

The splice makes the instruction unnecessary: whatever the model returns for a
retained marker is discarded and the original is put back verbatim.

The comparison before discarding is the part that is easy to leave out and
matters most. The splice is the correct write AND it destroys the only evidence
that "reproduce these exactly" was ignored: a model that rewrote every retained
marker and one that reproduced them all produce a byte-identical spliced body.
This repo has already shipped that shape once, defensively truncating a list and
hiding the violation on 12 of 21 Thursday reels (#1067). So the drift is counted
and reported; the splice still happens (L340).
"""

from __future__ import annotations

import pytest

from postroll.ai.blog_marker_splice import splice_retained_markers


PROSE = "It's a paragraph about the evening in the room."


def _body(*markers: str) -> str:
    out = [PROSE]
    for marker in markers:
        out.append(marker)
        out.append(PROSE)
    return "\n\n".join(out)


ORIGINAL = _body("[PHOTO: a.jpg | Alt one describing the first photograph]",
                 "[PHOTO: b.jpg | Alt two describing the second photograph]")


def test_a_retained_marker_the_model_rewrote_is_put_back_verbatim():
    produced = _body("[PHOTO: a.jpg | Something the model made up instead]",
                     "[PHOTO: b.jpg | Alt two describing the second photograph]")

    spliced, drift = splice_retained_markers(ORIGINAL, produced, {"a.jpg", "b.jpg"})

    assert spliced == ORIGINAL
    assert drift == 1, "the one rewritten marker was not counted"


def test_a_marker_the_model_reproduced_exactly_counts_no_drift():
    spliced, drift = splice_retained_markers(ORIGINAL, ORIGINAL, {"a.jpg", "b.jpg"})

    assert spliced == ORIGINAL
    assert drift == 0


def test_the_drift_count_is_the_only_evidence_the_instruction_was_ignored():
    """Both inputs produce the SAME spliced body, which is why the count exists.

    Without it, a model that ignored the instruction on every marker and one
    that obeyed it on every marker are indistinguishable afterwards (L340).
    """
    obeyed = ORIGINAL
    ignored = _body("[PHOTO: a.jpg | Made up one]", "[PHOTO: b.jpg | Made up two]")

    a_body, a_drift = splice_retained_markers(ORIGINAL, obeyed, {"a.jpg", "b.jpg"})
    b_body, b_drift = splice_retained_markers(ORIGINAL, ignored, {"a.jpg", "b.jpg"})

    assert a_body == b_body, "the fixture does not demonstrate the problem"
    assert (a_drift, b_drift) == (0, 2)


def test_a_marker_not_being_retained_is_left_as_the_model_wrote_it():
    produced = _body("[PHOTO: c.jpg | A new photograph, newly described]",
                     "[PHOTO: b.jpg | Alt two describing the second photograph]")

    spliced, drift = splice_retained_markers(ORIGINAL, produced, {"b.jpg"})

    assert "[PHOTO: c.jpg | A new photograph, newly described]" in spliced
    assert drift == 0


def test_a_retained_marker_the_model_dropped_is_reported_rather_than_restored():
    """Restoring it would be inventing a position for it.

    Where a dropped marker belongs is a judgement about the flow of the post,
    and putting it back at a guessed position is the shape #998 warns about. The
    caller falls back instead, which is a cost regression and not a silent one.
    """
    produced = _body("[PHOTO: b.jpg | Alt two describing the second photograph]")

    with pytest.raises(ValueError) as caught:
        splice_retained_markers(ORIGINAL, produced, {"a.jpg", "b.jpg"})

    assert "a.jpg" in str(caught.value)


def test_a_near_miss_filename_is_still_the_same_marker():
    """Folded the way markers fold, so a curly quote turning straight is a
    retained marker rather than one dropped and one invented."""
    original = _body('[PHOTO: Cast “Live”.jpg | Alt one describing the picture]')
    produced = _body('[PHOTO: Cast "Live".jpg | Something else entirely here]')

    spliced, drift = splice_retained_markers(original, produced,
                                             {'Cast “Live”.jpg'})

    assert spliced == original
    assert drift == 1


def test_the_splice_is_idempotent():
    """The app can and does re-run a swap."""
    once, _ = splice_retained_markers(ORIGINAL, ORIGINAL, {"a.jpg", "b.jpg"})
    twice, drift = splice_retained_markers(ORIGINAL, once, {"a.jpg", "b.jpg"})

    assert twice == once
    assert drift == 0


def test_prose_the_model_changed_survives_the_splice_unaltered():
    """The splice touches marker lines only. Prose is the gate's business, and
    a splice that also rewrote prose would hide what the gate exists to catch."""
    produced = ORIGINAL.replace(PROSE, "Different prose entirely.", 1)

    spliced, _drift = splice_retained_markers(ORIGINAL, produced,
                                              {"a.jpg", "b.jpg"})

    assert "Different prose entirely." in spliced
