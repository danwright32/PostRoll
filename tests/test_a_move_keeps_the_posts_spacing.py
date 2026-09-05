"""Moving a marker does not reformat the rest of the post (#1170).

`repair_marker_placement` split the body on blank lines, moved the marker it
had to move, and rejoined with a single blank line. When it moves NOTHING it
returns the body untouched, deliberately, so a post it has no reason to rewrite
keeps its exact bytes. When it does move something, every block separator in
the post was normalised.

Invisible on the 21 stored bodies, which all use single blank lines because
that is what the generator emits. A post written or edited with different
spacing came back silently reformatted, and nothing reported it: the repair's
own report names only the markers it moved (L340, the repair destroys the
evidence that it touched anything else).

## What a separator belongs to

The GAP, not the block. Blocks are reordered by a move and the separators stay
where they are, so the post keeps its own rhythm and the content moves through
it. That is the only reading that survives a reorder without inventing a
separator for a block that has changed neighbours.
"""

from __future__ import annotations

from postroll.ai.blog_quality import (
    MAX_PROSE_BEFORE_FIRST_PHOTO, repair_marker_placement)

A = "[PHOTO: a.jpg | first]"
B = "[PHOTO: b.jpg | second]"


def prose(n: int) -> list[str]:
    return [f"Paragraph {i}." for i in range(1, n + 1)]


def test_a_body_that_moves_nothing_is_returned_byte_for_byte():
    """The existing guarantee, pinned here because the change below is about
    the other branch and must not weaken this one."""
    body = "One.\n\n\n\nTwo.\n\n" + A

    assert repair_marker_placement(body).body == body


def test_an_unusual_separator_survives_a_move():
    """The fault. A stacked pair forces a move, and every OTHER gap in the post
    must come back as it was."""
    # Two markers with no prose between them is `stacked_photos`, so the second
    # moves after the next prose block.
    body = f"One.\n\n\n\n{A}\n\n{B}\n\nTwo.\n\n\n\nThree."

    repaired = repair_marker_placement(body)

    assert repaired.moved, "this body was meant to force a move"
    assert "One.\n\n\n\n" in repaired.body, (
        f"the four newline gap after the first paragraph was normalised to "
        f"one blank line:\n{repaired.body!r}")
    assert "\n\n\n\nThree." in repaired.body, (
        f"the gap before the last paragraph was normalised:\n{repaired.body!r}")


def test_the_move_still_happens():
    """The control. A repair that stopped moving anything would keep every
    separator perfectly (L104, L159)."""
    body = f"One.\n\n{A}\n\n{B}\n\nTwo."

    repaired = repair_marker_placement(body)

    assert [name for name, _rule in repaired.moved] == ["b.jpg"], repaired.moved
    assert repaired.body.index(A) < repaired.body.index("Two.") < repaired.body.index(B), (
        f"the stacked marker was not moved after the next prose block:\n"
        f"{repaired.body!r}")


def test_a_late_first_photo_move_keeps_the_spacing_too():
    """The other rule that moves a marker, so the fix covers both rather than
    the one the test happened to drive (L247)."""
    blocks = prose(MAX_PROSE_BEFORE_FIRST_PHOTO + 1)
    body = "\n\n\n\n".join(blocks) + f"\n\n\n\n{A}"

    repaired = repair_marker_placement(body)

    assert repaired.moved, "this body was meant to force a late_first_photo move"
    assert "\n\n\n\n" in repaired.body, (
        f"every four newline gap was normalised by the move:\n{repaired.body!r}")
    assert repaired.body.count("\n\n\n\n") == body.count("\n\n\n\n"), (
        f"the number of wide gaps changed, so separators were not preserved "
        f"positionally:\n{repaired.body!r}")


def test_the_ordinary_single_blank_line_post_is_unchanged_by_the_fix():
    """What the 21 stored bodies look like. The fix must not alter the case it
    was already right about."""
    body = f"One.\n\n{A}\n\n{B}\n\nTwo."

    repaired = repair_marker_placement(body)

    assert "\n\n\n" not in repaired.body, (
        f"a wider gap appeared in a post that had none:\n{repaired.body!r}")
    assert repaired.body == f"One.\n\n{A}\n\nTwo.\n\n{B}", repaired.body
