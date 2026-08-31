"""The posting-layout rules that only read SOURCE TEXT, in Python (#1089).

Five of `PostingLayoutCopyTests`' seven registry entries name a test that reads
nothing but Swift source, at about 29 seconds of rebuilding each. The other two
call `PostingLayoutCopy.thisEvent(...)` and `PostingLayoutSwitch.confirmation(...)`
and stay where they are: making no drawing call is not the same as being
text-only, which is the correction this issue's own measurement needed.

So the class is SPLIT rather than deleted, and what stays is what a text scan
cannot do.

Nothing about the rules changes. Comments are stripped, string literals left in,
which is `swift_without_comments`: a guard that matches raw source can be
satisfied by prose ABOUT the thing, including a comment explaining that the
thing was removed (L103), while a colour or a call written inside a string is
still written at the point of use as far as these rules are concerned.

That is a change from the Swift, which read the raw file. Every place the two
disagree is a comment, and a comment cannot draw a spinner or call a plan, so
this is a tightening: nothing that was caught before can escape now. The
fixtures beside each rule hold both directions, because the tree is clean and
the codebase cannot show the difference (L48, L159).
"""

from __future__ import annotations

from pathlib import Path

from source_text import swift_without_comments

REPO_ROOT = Path(__file__).resolve().parent.parent
VIEWS = REPO_ROOT / "PostRollApp" / "Sources" / "Views"

#: The one control that owns the per-event posting layout picker (#1007).
THE_CONTROL = "PostingLayoutControl.swift"

#: Every screen that SHOWS the layout's effect and must therefore offer the
#: control that changes it.
#:
#: Named rather than derived, deliberately: what belongs here is a judgement
#: about which screens show the effect, which no scan can make. It is three
#: today, and a fourth is a decision somebody has to take.
LAYOUT_SCREENS = (
    "ExportView.swift", "CaptionReviewView.swift", "PhotoAssignmentView.swift",
)

#: The derived sentence, and the hand written ones it replaced.
#:
#: Named rather than described, because this half exists to hold one specific
#: defect closed: the sentence under the picker was a two-way ternary over THREE
#: presets, so selecting Opening printed Classic's words.
DERIVED_SENTENCE = "PostingLayoutCopy.thisEvent("
HAND_WRITTEN_SENTENCES = (
    "Wednesday posts a 10 photo carousel",
    "each post a 4 photo carousel with a collage story",
)

#: The control's own construction, which a comment or an import cannot satisfy
#: (L135, L103), and the inline picker it replaced.
THE_CONTROL_CONSTRUCTION = "PostingLayoutControl("
AN_INLINE_PICKER = 'Picker("Posting layout"'

#: A progress indicator of the control's own. Every screen it sits on already
#: draws the rebuild's progress with elapsed time and an estimate, so a spinner
#: here stacks a second indicator directly above that one, for the same piece of
#: work, carrying less information than the one below it.
A_SPINNER = "ProgressView("

#: Why the control is disabled while a rebuild runs. Without it the control is
#: dead with no reason (L148).
THE_REASON = "cannot change yet"

#: The plan the control has to ask, and the old rule it replaced.
THE_WORK_SPLIT = "PostingLayoutSwitch.work("
THE_PLAN = "PostingLayoutSwitch.plan("
THE_OLD_RULE = "affectedDays"

#: What the control must say and offer when a day was left on the previous
#: layout, and the predicate it must decide staleness by.
#:
#: The third is not decoration: deciding staleness any other way than the
#: predicate the export gate uses lets the two disagree, so the export refuses
#: with a reason the control does not show (L342).
THE_STALE_SENTENCE = "PostingLayoutCopy.stale("
THE_REDRAW_ACTION = "PostingLayoutCopy.redrawAction("
THE_STALE_PREDICATE = "PostingLayoutSwitch.staleDays("

#: Claiming the redraw, and the write it must come before.
THE_CLAIM = "startRedraw("
THE_CLAIM_IS_READ = "guard claimedRedraw"
THE_WRITE = "ev.postingPresetOverride = newValue"


def code(text: str) -> str:
    """`text` with its comments gone, string literals left in."""
    return swift_without_comments(text)


def view(name: str) -> str:
    """One screen's source, decommented.

    Refuses a file that is not there rather than answering with an empty string:
    every rule below asks whether some token is ABSENT, and an empty string
    satisfies all of them at once (L98).
    """
    path = VIEWS / name
    assert path.exists(), (
        f"Sources/Views/{name} is not there, so every rule reading it would be "
        "asking its questions of an empty string"
    )
    return code(path.read_text(encoding="utf-8"))


def claims_before_it_writes(source: str) -> bool | None:
    """Whether the redraw is claimed before the event is changed, or None if
    one of the two is gone.

    Order matters as much as presence: claiming AFTER the write is the same
    defect wearing a guard, because the claim is taken before the event is
    touched precisely so that a refusal costs nothing (L197, L5).
    """
    claim = source.find(THE_CLAIM)
    write = source.find(THE_WRITE)
    if claim < 0 or write < 0:
        return None
    return claim < write
