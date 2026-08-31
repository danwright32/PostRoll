"""#998: a paragraph rewrite must not be allowed to delete a photo marker.

A `[PHOTO: ...]` marker that sits INSIDE a prose paragraph rather than on its
own line was silently deleted from the post, with nothing reported.

`_prose_indices_with_second_person` and `_prose_indices_without_contractions`
both classify a block as prose when it does not START with `[PHOTO:`. A block
that CONTAINS a marker part way through is therefore prose to them, so
`_fix_second_person` and `_fix_missing_contractions` sent the whole paragraph,
marker and all, to a model to be reworded and spliced the answer back.

The guard that was there is inverted with respect to the failure that matters:

    if "[PHOTO:" not in reworded and len(reworded) < len(original) * 2 + 80:

That refuses a rewrite which PRESERVED the marker, the harmless case, and
accepts one that DROPPED it. A comment beside it asserted that a marker can
never be at a prose index, which is the belief the whole defect rests on.

The photograph is gone from the body, nothing goes red, nothing is printed, and
the only trace is that the post has one fewer picture than it should.

A refusal keyed on the block STARTING with a marker can never fire, because the
index builders have already excluded every such block. The predicate has to be
"contains", which is what `_block_holds_marker` is.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai import generate_blog as gb


MARKER = "[PHOTO: a.jpg | Ryan at the piano, hands on the keys mid phrase.]"

#: An offending paragraph carrying a marker inline. Second person ("You were")
#: and no contraction, so BOTH rewriters pick it up and neither is resting on
#: the other's test (L178).
INLINE = f"You were watching from the back of the room. {MARKER}"

TAIL = "It wasn't a long set.\n\nCome and see the next one."


def _body(first: str) -> str:
    return f"{first}\n\n{TAIL}"


def _refuse(*args, **kwargs):
    raise AssertionError(
        "the rewriter reached the model with a marker in the paragraph, which is "
        "the whole thing this refuses to do")


# -- both rewriters refuse rather than risk the marker ------------------------

#: Each rewriter and the phrase that has to be in its own refusal. Named here
#: so a test asserting "it threw" cannot be satisfied by any throw at all,
#: including one raised by the fixture (L140).
REWRITERS = [("_fix_second_person", "second person"),
             ("_fix_missing_contractions", "contraction")]


@pytest.mark.parametrize("rewriter,pass_name", REWRITERS)
def test_a_paragraph_holding_a_marker_is_refused_before_the_model_sees_it(rewriter, pass_name):
    with patch.object(gb, "run_prompt", side_effect=_refuse), \
         pytest.raises(ValueError) as raised:
        getattr(gb, rewriter)(_body(INLINE))

    message = str(raised.value)
    assert "a.jpg" in message, f"the message does not name the photograph: {message}"
    assert f"the {pass_name} pass" in message, (
        f"the message does not say which pass refused: {message}")
    assert "0" in message, f"the message does not name the paragraph: {message}"


def test_the_two_refusals_do_not_share_one_message():
    # Two causes that produce the same sentence are one outcome in practice, and
    # the sentence then cannot tell whoever reads it which pass to look at (L11).
    messages = []
    for rewriter in ("_fix_second_person", "_fix_missing_contractions"):
        with patch.object(gb, "run_prompt", side_effect=_refuse), \
             pytest.raises(ValueError) as raised:
            getattr(gb, rewriter)(_body(INLINE))
        messages.append(str(raised.value))
    assert messages[0] != messages[1]


def test_a_marker_missing_its_pipe_is_refused_too():
    # Malformed, so `photo_marker_filenames` does not see it. It still names a
    # photograph, and losing it loses the picture just the same, so the
    # predicate is the bare opening rather than the full marker pattern.
    broken = "You were watching from the back of the room. [PHOTO: a.jpg]"
    with patch.object(gb, "run_prompt", side_effect=_refuse), \
         pytest.raises(ValueError):
        gb._fix_second_person(_body(broken))


# -- and still do their job on a paragraph that holds no marker ---------------

def test_a_paragraph_with_no_marker_is_still_reworded():
    # The positive control. Without it every assertion above is satisfied by a
    # pair of rewriters that refuse everything (L159).
    plain = "You were watching from the back of the room."
    fixed = "The room's back row watched it happen."
    with patch.object(gb, "run_prompt", side_effect=lambda *a, **k: fixed):
        out = gb._fix_second_person(_body(plain))
    assert fixed in out
    assert plain not in out


def test_a_marker_on_its_own_line_is_left_where_it_is():
    # The ordinary shape of a blog post: markers on their own lines, prose
    # around them. Nothing here may refuse, and the marker must survive.
    plain = "You were watching from the back of the room."
    fixed = "The room's back row watched it happen."
    body = f"{plain}\n\n{MARKER}\n\n{TAIL}"
    with patch.object(gb, "run_prompt", side_effect=lambda *a, **k: fixed):
        out = gb._fix_second_person(body)
    assert MARKER in out
    assert fixed in out


def test_the_predicate_is_contains_rather_than_starts_with():
    # The measured reason the obvious fix does not work: a block that STARTS
    # with a marker never reaches these rewriters at all, because the index
    # builders excluded it, so a refusal keyed on the start can never fire.
    assert gb._block_holds_marker(INLINE)
    assert gb._block_holds_marker(MARKER)
    assert not gb._block_holds_marker("You were watching from the back.")
