"""The posting-layout control, off the app build (#1089, #1007, #1010).

Five registry entries out of `PostingLayoutCopyTests` name a test that reads
nothing but Swift source and paid an app build each to re-prove, about 29
seconds apiece. The class is split rather than deleted: its other two entries
call `PostingLayoutCopy.thisEvent(...)` and `PostingLayoutSwitch.confirmation(...)`
and stay.

Every rule is checked in BOTH directions, which is how they were written and is
the only thing that makes them worth anything: the positive half alone is
satisfied by a call added BESIDE the old behaviour, and the negative half alone
by deleting the feature and showing nothing (L178, L283). `check_guards` caught
exactly that once already, when the first version of the plan guard stayed GREEN
on a control rewired to the old rule.
"""

from __future__ import annotations

import pytest

from swift_layout_control_rules import (
    AN_INLINE_PICKER,
    A_SPINNER,
    DERIVED_SENTENCE,
    HAND_WRITTEN_SENTENCES,
    LAYOUT_SCREENS,
    THE_CLAIM,
    THE_CLAIM_IS_READ,
    THE_CONTROL,
    THE_CONTROL_CONSTRUCTION,
    THE_OLD_RULE,
    THE_REDRAW_ACTION,
    THE_STALE_PREDICATE,
    THE_STALE_SENTENCE,
    THE_PLAN,
    THE_REASON,
    THE_WORK_SPLIT,
    THE_WRITE,
    claims_before_it_writes,
    code,
    view,
)


@pytest.fixture(scope="module")
def control() -> str:
    return view(THE_CONTROL)


# ── the reading: a comment is not the code (L103) ────────────────────────────

def test_a_trailing_comment_is_stripped():
    """A change from the Swift, which read the raw file.

    Every place the two disagree is a comment, and a comment cannot draw a
    spinner or call a plan, so this is a tightening.
    """
    assert A_SPINNER not in code(f"EmptyView() // {A_SPINNER})")


def test_real_code_survives_the_stripping():
    """Without this every rule below is satisfied by a stripper returning
    nothing, which is the same silent pass the comment case is (L98)."""
    assert A_SPINNER in code(f"{A_SPINNER}value: progress)")


def test_a_missing_screen_is_refused_rather_than_read_as_empty():
    """Every rule below asks whether some token is ABSENT, and an empty string
    satisfies all of them at once."""
    with pytest.raises(AssertionError, match="empty string"):
        view("NoSuchScreen.swift")


# ── the derived sentence is what the screens show (#1007) ────────────────────

def test_the_screens_read_the_derived_sentence_and_none_carries_the_old_one(
        control: str):
    """One test, not two, because the two halves are one rule.

    A derived sentence nothing calls leaves the hand written one on screen, so
    every test over the sentence itself would pass while the defect shipped
    unchanged. The positive half alone is satisfied by a call added BESIDE the
    ternary rather than in place of it; the negative half alone by deleting the
    sentence altogether and showing nothing (L178, L283, L46).

    The control owns the sentence since #1007 moved the picker out of
    ExportView, so the positive is asserted against the control. The absence is
    asserted against EVERY screen that shows the layout, because the defect this
    holds closed is a hand written sentence anywhere near the picker, not in one
    file.
    """
    assert DERIVED_SENTENCE in control, (
        "the layout control does not call the derived sentence, so whatever it "
        "draws under the picker is maintained beside the presets"
    )
    for screen in LAYOUT_SCREENS + (THE_CONTROL,):
        source = view(screen)
        for sentence in HAND_WRITTEN_SENTENCES:
            assert sentence not in source, (
                f"{screen} carries a hand written layout sentence: {sentence!r}"
            )


# ── one control, on every screen that shows the layout (#1007) ───────────────

def test_every_screen_that_shows_the_layout_uses_the_one_control():
    """Asserted as a CONSTRUCTION, which a comment or an import cannot satisfy
    (L135, L103), and paired with the absence of the inline picker it replaced
    so a screen cannot end up carrying both.

    One test over every screen rather than one per screen, so the registry entry
    that perturbs CaptionReviewView names a test whose node id does not move
    when a fourth screen is added.
    """
    for screen in LAYOUT_SCREENS:
        source = view(screen)
        assert THE_CONTROL_CONSTRUCTION in source, (
            f"{screen} shows what the posting layout produced and offers no way "
            "to change it"
        )
        assert AN_INLINE_PICKER not in source, (
            f"{screen} builds its own layout picker beside the shared control"
        )


# ── the control draws no progress indicator of its own (#1007) ───────────────

def test_the_control_draws_no_progress_indicator_of_its_own(control: str):
    """Two indistinguishable indicators for one job is the display #135 exists
    to prevent, and the screen's own line carries elapsed time and an estimate
    this one does not.

    Checked in both directions: no spinner, AND the reason still shown, so the
    fix cannot be satisfied by deleting the busy state altogether and leaving a
    dead control with nothing saying why (L178, L148).
    """
    assert A_SPINNER not in control, (
        "the layout control draws its own spinner above the screen's own "
        "progress line, which already carries elapsed time and an estimate this "
        "one does not"
    )
    assert THE_REASON in control, (
        "the control is disabled while a rebuild runs and has to say why, or it "
        "is a dead control with no reason"
    )


# ── the control asks the plan what to rebuild (#1010) ────────────────────────

def test_the_control_asks_the_plan_what_to_rebuild(control: str):
    """A plan nothing calls changes nothing.

    The pure tests over `plan` and `work` pass whether or not the control uses
    them, so they would have gone on passing while the switch kept rebuilding
    every day. `check_guards` caught exactly that: the first version of this
    guard stayed GREEN on a control rewired to the old behaviour.
    """
    assert THE_WORK_SPLIT in control, (
        "the control does not split the switch into paid and free work, so "
        "whatever it rebuilds is decided somewhere else"
    )
    assert THE_PLAN in control, (
        "the control does not ask which days actually change"
    )
    assert THE_OLD_RULE not in control, (
        "the control still reaches for the old rule, which names every governed "
        "day with photos whether or not the switch moves it"
    )


# ── a refused redraw claim stops the switch (#1010) ──────────────────────────

def test_the_order_reader_sees_a_claim_taken_after_the_write():
    """The defect, in a fixture, because the tree is clean and cannot show it."""
    assert claims_before_it_writes(f"{THE_WRITE}\n{THE_CLAIM}id)") is False


def test_the_order_reader_sees_a_claim_taken_before_the_write():
    assert claims_before_it_writes(f"{THE_CLAIM}id)\n{THE_WRITE}") is True


def test_the_order_reader_says_so_when_one_half_is_gone():
    """None rather than False, because "the control no longer claims" and "it
    claims too late" are different failures and only one of them is about
    order (L11)."""
    assert claims_before_it_writes(THE_WRITE) is None
    assert claims_before_it_writes(f"{THE_CLAIM}id)") is None


def test_a_refused_redraw_claim_stops_the_switch(control: str):
    """The claim is taken before the event is touched precisely so a refusal
    costs nothing. Reading the answer and carrying on regardless leaves the
    layout changed with no run to redraw it, which is worse than refusing the
    switch outright (L197, L5)."""
    assert THE_CLAIM_IS_READ in control, (
        "the control reads whether the redraw was claimed and does not act on "
        "the answer, so a busy day still gets its layout changed"
    )
    order = claims_before_it_writes(control)
    assert order is not None, (
        "the control no longer claims the redraw or no longer writes the "
        "override, so nothing here checked the order"
    )
    assert order, (
        "the redraw is claimed AFTER the event is changed, so a refusal leaves "
        "the layout switched with nothing rebuilding it"
    )


# ── the control shows the stale days and offers the redraw (#1010) ───────────

def test_the_control_shows_the_stale_days_and_offers_the_redraw(control: str):
    """The control has to actually offer it, not merely be able to phrase it.

    Checked in all three directions, like the rebuild scan above: the sentence
    alone is satisfied by a reason rendered with no way to act on it, and both
    of those are satisfied by a control deciding staleness its own way, which
    lets it disagree with the export gate that refuses (L178, L342).

    No registry entry names this one, and it moved with its neighbours because
    it reads the same file the same way: leaving it behind would have kept the
    whole Swift class, and its helper, alive to re-prove nothing.
    """
    assert THE_STALE_SENTENCE in control, (
        "the control never says a day was left on the previous layout, so the "
        "export refuses with the reason on another screen"
    )
    assert THE_REDRAW_ACTION in control, (
        "the reason is stated with no way to act on it, and picking the layout "
        "already selected fires nothing"
    )
    assert THE_STALE_PREDICATE in control, (
        "the control decides staleness some other way than the predicate the "
        "export gate uses, so the two can disagree"
    )
