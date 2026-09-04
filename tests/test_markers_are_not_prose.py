"""A `[PHOTO:]` marker is not prose, and the rules that read prose skip it
(#975, #1163).

Two faults with one cause. Code that decides what is prose by looking at a
CONTAINER, the whole body or a whole paragraph, rather than at the SPAN a
marker actually occupies:

* `_fix_wrong_names` substitutes over the WHOLE BODY. Blog filenames are named
  after the show and the venue, so they are full of capitalised word pairs, and
  a performer sharing a surname with one of those words gets the filename
  rewritten. The marker then names a file that does not exist, which is a
  `blog_marker_unknown_photo` plus a `blog_marker_missing_photo`, a photograph
  Dan chose that never appears, and two findings he cannot clear without
  retyping a filename by hand.

* `_prose_paragraphs` drops a block only when the WHOLE block starts with
  `[PHOTO:`, so a marker at the END of a paragraph leaks in and every prose
  rule reads a filename as words Dan wrote. Measured 2026-09-01 over the 21
  stored bodies: 7 markers leaked on one post, which is 8 of the 32
  `invented_number` firings, a quarter of that rule's entire rate, every one a
  false positive on a filename like `-189.jpg`.

The same predicate fails in the other direction too: prose AFTER a marker in
one block is discarded whole, so those words are checked by nothing (L215,
L98). Reachable, and measured as not currently occurring.

L361 names the class: excluding content by testing a property of its whole
container fails in both directions the moment one container mixes the two.

The repo learned this once already. `_fix_second_person` and
`_fix_missing_contractions` were changed under #109 to splice by paragraph
index precisely because "a text search covers the whole body including the
[PHOTO:] markers", and the fix was applied to those two and not to their
sibling.
"""

from __future__ import annotations

import pytest

from postroll.ai.blog_quality import (
    _prose_paragraphs, outside_markers, prose_text_of)
from postroll.ai.generate_blog import _fix_wrong_names

#: A real filename shape: the show, the venue in brackets, the handle, a number.
#: Shows and venues are routinely named after people, which is what makes the
#: collision plausible rather than exotic.
MARKER = "[PHOTO: Cast Party (The Green Room 42) @dwphotony-12.jpg | dancers]"


# ── the name backstop stops at the marker ────────────────────────────────────


def test_a_filename_is_not_rewritten_by_the_name_backstop():
    """#975, reproduced with the real functions.

    `Cast Party` is a capitalised pair inside the FILENAME. With a performer
    called `Ana Party` on the bill, the surname `Party` ties to one first name,
    so the backstop rewrote the filename to `Ana Party (...)` and the marker
    named a file that does not exist.
    """
    body = f"I photographed the show.\n\n{MARKER}\n\nIt ran late."
    program = {"performers": [{"name": "Sam Green"}, {"name": "Ana Party"}]}

    fixed = _fix_wrong_names(body, program)

    assert MARKER in fixed, (
        f"the name backstop rewrote a photo filename, so the marker now names "
        f"a file that does not exist:\n{fixed}")


def test_the_name_backstop_still_corrects_the_prose_around_it():
    """The other half. A backstop that stopped correcting anything would also
    pass the test above (L104, L159)."""
    body = f"I photographed Bob Party at the show.\n\n{MARKER}"
    program = {"performers": [{"name": "Ana Party"}]}

    fixed = _fix_wrong_names(body, program)

    assert "Ana Party at the show" in fixed, (
        f"the backstop no longer corrects a hallucinated first name in prose, "
        f"so it has been disabled rather than confined:\n{fixed}")
    assert MARKER in fixed


def test_a_name_inside_a_marker_s_alt_text_is_left_alone_too():
    """The alt text is part of the marker. Rewriting a name there is the same
    class of damage: the alt text is what a screen reader announces, and it is
    validated against the photograph rather than against the program."""
    marker = "[PHOTO: show.jpg | Bob Party mid turn under a blue wash]"
    program = {"performers": [{"name": "Ana Party"}]}

    assert marker in _fix_wrong_names(marker, program)


# ── the prose rules stop at the marker ───────────────────────────────────────


def test_a_marker_at_the_end_of_a_paragraph_does_not_leak_into_the_prose():
    """#1163. The block does not START with the marker, so the whole thing was
    kept, filename and alt text included."""
    body = f"The room was full.\n{MARKER}"

    prose = " ".join(prose_text_of(body))

    assert "dwphotony" not in prose and ".jpg" not in prose, (
        f"a photo filename reached the prose rules as if it were words Dan "
        f"wrote: {prose!r}")
    assert "The room was full." in prose, "the real prose was dropped with it"


def test_prose_after_a_marker_in_one_block_is_still_read():
    """The other direction of the same predicate, and the one measured as
    reachable but not yet occurring. The block STARTS with the marker, so it
    was discarded entire, taking the prose with it: words checked by nothing,
    and a rule that never sees text cannot report on it (L215, L98)."""
    body = f"{MARKER}\nShe held the last note."

    prose = " ".join(prose_text_of(body))

    assert "She held the last note." in prose, (
        f"prose sharing a block with a marker was dropped, so no rule reads "
        f"it: {prose!r}")


def test_a_block_that_is_only_a_marker_contributes_nothing():
    assert prose_text_of(f"{MARKER}\n\n{MARKER}") == []


# ── the shared primitive both of them use ────────────────────────────────────


def test_outside_markers_leaves_every_marker_byte_for_byte():
    body = f"one\n\n{MARKER}\n\ntwo"

    shouted = outside_markers(body, str.upper)

    assert MARKER in shouted, f"a marker was altered: {shouted!r}"
    assert "ONE" in shouted and "TWO" in shouted, (
        f"the prose was not transformed, so this proves nothing: {shouted!r}")


def test_outside_markers_puts_the_text_back_in_order():
    body = f"a\n\n{MARKER}\n\nb\n\n{MARKER}\n\nc"

    assert outside_markers(body, lambda s: s) == body, (
        "reassembling untouched spans did not reproduce the body, so the "
        "primitive loses or reorders text")


def test_outside_markers_sees_each_prose_span_separately():
    """A substitution must not be able to match ACROSS a marker, which is how a
    whole-body regex reads a filename and the sentence after it as one run."""
    seen: list[str] = []

    outside_markers(f"before {MARKER} after", lambda s: seen.append(s) or s)

    assert all("PHOTO" not in span for span in seen), (
        f"a prose span carried marker text into the substitution: {seen}")
    assert len([s for s in seen if s.strip()]) == 2, (
        f"the prose either side of the marker was not offered separately: "
        f"{seen}")
