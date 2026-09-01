"""#1128 (Phase 0e): what the marker drift tool counts, and what it cannot.

The plan wanted a revision drift rate. There is no revision history anywhere in
`events.json`, so the only pair available is `generated_body` against `body`,
which mixes a revision with Dan's own hand edits. The tool measures that pair
and says so; these tests hold it to counting what it claims.

Written as a tool rather than a number in a comment because the reading moves
every time Dan finishes a post, and a dated number reads as more trustworthy
the older it gets (L316, L244).
"""

from __future__ import annotations

from tools.measure_blog_marker_drift import measure


def _event(generated: str | None, final: str | None) -> dict:
    return {"weekResult": {"blog": {"generated_body": generated, "body": final}}}


PROSE = "A paragraph about the evening."


def _body(*markers: str) -> str:
    return "\n\n".join([PROSE, *markers])


def test_an_unchanged_marker_is_shared_and_does_not_differ():
    counts = measure([_event(_body("[PHOTO: a.jpg | Alt one]"),
                             _body("[PHOTO: a.jpg | Alt one]"))])

    assert counts["with_both_bodies"] == 1
    assert counts["shared_markers"] == 1
    assert counts["alt_text_differs"] == 0
    assert counts["order_changed"] == 0


def test_a_rewritten_alt_text_counts_as_differing():
    counts = measure([_event(_body("[PHOTO: a.jpg | Alt one]"),
                             _body("[PHOTO: a.jpg | Something else entirely]"))])

    assert counts["alt_text_differs"] == 1


def test_a_marker_named_with_different_punctuation_is_the_same_marker():
    # Folded the way the checker folds, so a curly quote turning straight is a
    # retained marker rather than one dropped and one added, which would report
    # drift that never happened.
    counts = measure([_event(_body('[PHOTO: Cast “Live”.jpg | Alt one]'),
                             _body('[PHOTO: Cast "Live".jpg | Alt one]'))])

    assert counts["shared_markers"] == 1
    assert counts["alt_text_differs"] == 0


def test_a_reorder_is_counted_and_a_swapped_photo_is_not():
    reordered = measure([_event(_body("[PHOTO: a.jpg | A]", "[PHOTO: b.jpg | B]"),
                                _body("[PHOTO: b.jpg | B]", "[PHOTO: a.jpg | A]"))])
    assert reordered["order_changed"] == 1

    # One photo replaced by another is not a reorder of the markers they share.
    swapped = measure([_event(_body("[PHOTO: a.jpg | A]", "[PHOTO: b.jpg | B]"),
                              _body("[PHOTO: a.jpg | A]", "[PHOTO: c.jpg | C]"))])
    assert swapped["order_changed"] == 0
    assert swapped["shared_markers"] == 1


def test_an_event_missing_either_body_is_not_counted_as_measured():
    # Absent is not "measured and found identical" (L98).
    counts = measure([_event(_body("[PHOTO: a.jpg | A]"), None),
                      _event(None, _body("[PHOTO: a.jpg | A]")),
                      {"weekResult": {}}])

    assert counts["events"] == 3
    assert counts["with_both_bodies"] == 0
    assert counts["shared_markers"] == 0
