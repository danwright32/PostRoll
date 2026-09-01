"""#1132: five outcomes, five renderings, no two alike.

Dan's rule 2 says a repair that was TRIED and failed still shows, marked as
tried. It names two states. The budget, the structural gap on the revise path,
and the difference between a refusal and an unreachable model create three more,
and collapsing any of them back into "never attempted" is rule 2 defeated,
because never-attempted renders exactly like today's findings, which is the one
thing rule 2 forbids.

`tried` and `blocked` are two states and not one (L11, L260, L112). Folding a
ClaudeError, a timeout, an unreadable photograph and a genuine gate refusal into
`tried` makes a claim that is false for a network blip: `tried` exists to tell
Dan the app will not get it next time either. The test for whether two states
are one is whether they invite different actions, and these do: one says stop
expecting the app to fix it, the other says try again.

`unavailable` exists because of `revise_blog`. Its manifest carries
`photo_filenames` only, never photo paths, so there is no photograph on that
path and alt text cannot be rewritten there. Rendering those findings as never
attempted would assert something untrue.
"""

from __future__ import annotations

import pytest

from postroll.ai.blog_findings import Finding, RepairState, finding_entry


def test_a_finding_with_no_repair_state_still_says_so_explicitly():
    """An unconditional key, never a conditional one.

    `tests/bridge_payload_keys.py` reads the returned dict LITERAL and refuses a
    computed or conditional key, so a `repair` added only when set would take
    the payload out of the contract's reach entirely.
    """
    entry = finding_entry(Finding("alt_text_length", "m", "d"))

    assert entry["repair"] == "", entry
    assert set(entry) == {"code", "message", "detail", "repair", "target"}


@pytest.mark.parametrize("state", list(RepairState))
def test_every_state_travels_as_its_own_string(state):
    entry = finding_entry(Finding("alt_text_length", "m", "d"), repair=state)

    assert entry["repair"] == state.value
    assert isinstance(entry["repair"], str), "the payload must be plain JSON"


def test_every_state_is_distinct():
    values = [s.value for s in RepairState]
    assert len(set(values)) == len(values), values


def test_exactly_five_states_can_reach_a_payload():
    """REPAIRED is the pass's own outcome and never travels: the finding it
    describes no longer exists, because a repaired alt text stops failing the
    check that selected it. It is in the enum so the pass's partition can be
    asserted TOTAL over everything it selected (L47, L517)."""
    travelling = {s for s in RepairState if s is not RepairState.REPAIRED}
    assert len(travelling) == 5, sorted(s.value for s in travelling)


def test_never_attempted_is_the_empty_string():
    """So every payload written before this shipped decodes to it, and renders
    exactly as it does today."""
    assert RepairState.NEVER.value == ""


@pytest.mark.parametrize(
    "state", [s for s in RepairState if s is not RepairState.NEVER])
def test_every_state_that_happened_says_what_dan_should_do(state):
    """Worded as an action, not as an internal status (L112).

    NEVER is excluded deliberately and not by oversight: it means the pass did
    not touch this finding, so it renders exactly as a finding did before any
    of this existed, and a sentence there would be a claim about work that did
    not happen.
    """
    assert state.wording, f"{state} has no wording, so nothing can render it"
    assert len(state.wording.split()) > 3, state.wording


def test_never_attempted_deliberately_says_nothing():
    assert RepairState.NEVER.wording == "", (
        "never-attempted gained a sentence, which would put a claim about the "
        "repair pass on every finding on every post written before it existed")


def test_blocked_invites_trying_again_and_tried_does_not():
    assert "again" in RepairState.BLOCKED.wording.lower()
    assert "again" not in RepairState.TRIED.wording.lower()


def test_the_caption_paths_inherit_the_field_and_that_is_recorded():
    """A stated consequence, not a discovery (#1132).

    `generate_captions` and `revise_caption` call the same `finding_entry`, so
    caption findings carry `repair=""` at runtime. No contract entry covers
    caption findings, so nothing goes red, and Swift renders them as today. It
    is still a silent widening of a payload shape rule 8 puts out of scope.
    """
    from postroll.ai import generate_captions, revise_caption

    assert generate_captions.finding_entry is finding_entry
    assert revise_caption.finding_entry is finding_entry
    assert finding_entry(Finding("c", "m", "d"))["repair"] == ""
