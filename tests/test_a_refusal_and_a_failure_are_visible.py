"""A refusal that is computed reaches the screen, and a failed run says so (#1089).

Two rules that read nothing but Swift source and were paying an app build each
time they were re-proved: `VisibleRefusalGuardTests` (#402) and one sweep out of
`WorkWithNoWindowTests` (#863, #872). Five registry entries at about 29 seconds
apiece, answered here in well under a second.

The strongest check on the first is not here and never was:
`BannerLegibilityTests` renders both refusals and measures ink on the page,
which is the only way to know they are LEGIBLE rather than merely present. What
these add is the two things a render cannot see, that the producers are still
wired up and that the tooltip-only shape has not come back.

Each matcher is asked directly what it can see, in both directions, before the
sweep that uses it: the tree is clean, so a matcher that catches one spelling
and a matcher that catches three give the same silent pass over the real files
(L1, L48, L159).
"""

from __future__ import annotations

import pytest

from swift_visible_failure_rules import (
    A_REAL_FAILURE_SWEEP,
    ANNOUNCEMENT_WINDOW,
    FAILURE_SPELLINGS,
    REFUSAL_NOTE,
    REFUSAL_PRODUCERS,
    SOURCES,
    THE_ANNOUNCEMENT,
    code,
    code_in,
    missing_producers,
    silent_failure_paths,
)


@pytest.fixture(scope="module")
def services() -> str:
    return code_in("Services")


@pytest.fixture(scope="module")
def views() -> str:
    return code_in("Views")


def view_source(name: str) -> str:
    return code((SOURCES / "Views" / name).read_text(encoding="utf-8"))


# ── the reading: a comment is not the code (#416, L103) ──────────────────────

def test_a_trailing_comment_is_stripped():
    """The exact break the mutation registry recorded.

    `EmptyView() // RefusalNote(...)` satisfied every check below until this
    was cut at the first slashes rather than only at the start of a line.
    """
    assert REFUSAL_NOTE not in code(f"EmptyView() // {REFUSAL_NOTE}note)")


def test_a_whole_comment_line_is_stripped():
    assert REFUSAL_NOTE not in code(f"// {REFUSAL_NOTE}note)\nEmptyView()")


def test_a_block_comment_is_stripped():
    """The Swift version dropped lines beginning with `*`, which is the middle
    of a block comment and not its first or last line."""
    assert REFUSAL_NOTE not in code(f"/*\n * {REFUSAL_NOTE}note)\n */\nEmptyView()")


def test_real_code_survives_the_stripping():
    """Without this the checks below are all satisfied by a stripper that
    returns nothing, which is the same silent pass the comment case is (L98)."""
    assert REFUSAL_NOTE in code(f"{REFUSAL_NOTE}NewEventValidation.refusal(x))")


def test_a_slash_inside_a_string_is_not_a_comment():
    """Where this reading differs from the Swift one it replaces.

    The Swift stripper cut at the first `//` on the line, inside string literals
    included, and said so in as many words. Everywhere the two disagree is a
    place it discarded real code, so this is a tightening: nothing that was
    caught before can escape now.
    """
    assert REFUSAL_NOTE in code(f'Text("https://example.com") ; {REFUSAL_NOTE}n)')


# ── every listed producer is declared and used, both directions (L96) ────────

def test_the_producer_check_sees_one_that_is_no_longer_declared():
    problems = missing_producers(services="", views="\n".join(REFUSAL_PRODUCERS))
    assert len(problems) == len(REFUSAL_PRODUCERS)
    assert all("not declared" in problem for problem in problems)


def test_the_producer_check_sees_one_no_screen_calls():
    """A producer nothing calls is a refusal nobody can be shown, which looks
    exactly like one that works (L46)."""
    declared = "\n".join(f"func {p.rsplit('.', 1)[-1]}()" for p in REFUSAL_PRODUCERS)
    problems = missing_producers(services=declared, views="")
    assert len(problems) == len(REFUSAL_PRODUCERS)
    assert all("can never be seen" in problem for problem in problems)


def test_the_producer_check_leaves_a_wired_up_producer_alone():
    declared = "\n".join(f"func {p.rsplit('.', 1)[-1]}()" for p in REFUSAL_PRODUCERS)
    assert missing_producers(services=declared,
                             views="\n".join(REFUSAL_PRODUCERS)) == []


def test_every_listed_producer_is_declared_and_used(services: str, views: str):
    problems = missing_producers(services, views)
    assert not problems, "\n".join(problems)


# ── the shape that shipped ───────────────────────────────────────────────────

def test_the_stage_strip_draws_its_refusal_rather_than_hiding_it_on_hover():
    """The stage strip, because that is where it shipped and it is on every screen.

    A hover tooltip does not count as saying it: `.help()` is invisible until the
    mouse rests on the control, and nobody rests a mouse on something that looks
    dead (L49, L109).
    """
    source = view_source("ProgramUploadView.swift")
    assert REFUSAL_NOTE in source, (
        "the stage strip has to draw its refusal, not only offer it on hover"
    )
    assert ".disabled(blocked != nil" not in source, (
        "a blocked step stays pressable so it can explain itself; only "
        '"you are here" is inert'
    )


def test_the_new_event_sheet_draws_what_is_missing():
    """The sheet that had no refusal at all: two required fields, a button at
    40% opacity, and no way to learn which field was empty."""
    source = view_source("NewEventSheet.swift")
    assert REFUSAL_NOTE in source, (
        "a greyed Create Event button has to say which field is empty"
    )
    assert "NewEventValidation.refusal" in source, (
        "and the disabled state and the sentence have to come from one predicate"
    )


def test_the_refusal_line_has_one_implementation(views: str):
    """`RefusalNote` exists once and is shared, rather than each screen growing
    its own quiet explanatory line that drifts from the others (L41)."""
    declarations = views.count("struct RefusalNote")
    assert declarations == 1, (
        f"RefusalNote is declared {declarations} times; it is meant to be shared"
    )


# ── no manager gets to fail quietly (#872) ───────────────────────────────────

def test_the_failure_sweep_sees_every_spelling_of_becoming_failed(tmp_path):
    """The defect this matcher exists for.

    The first version looked for `markFailed`, which is how five of the managers
    record a failure. `ExportManager` is not one of them: it sets a failed phase
    and deactivates instead, so the longest running work in the app was the one
    kind that still failed in silence while the sweep reported all clear over
    five real sites (L247).
    """
    for index, spelling in enumerate(FAILURE_SPELLINGS):
        (tmp_path / f"Manager{index}.swift").write_text(
            f"func die() {{\n    self{spelling}reason)\n}}\n")

    silent, checked = silent_failure_paths(tmp_path)
    assert checked == len(FAILURE_SPELLINGS), (
        f"the sweep found {checked} of {len(FAILURE_SPELLINGS)} spellings, so a "
        "manager failing the way it missed would be exempt from the rule"
    )
    assert len(silent) == len(FAILURE_SPELLINGS)


def test_the_failure_sweep_accepts_an_announcement_within_the_window(tmp_path):
    (tmp_path / "Manager.swift").write_text(
        "func die() {\n"
        "    self.markFailed(reason)\n"
        + "    // padding\n" * (ANNOUNCEMENT_WINDOW - 3)
        + f"    {THE_ANNOUNCEMENT}name)\n"
        "}\n")
    silent, checked = silent_failure_paths(tmp_path)
    assert checked == 1
    assert silent == []


def test_the_failure_sweep_refuses_an_announcement_past_the_window(tmp_path):
    """The boundary from the other side, so the window's SIZE is a real edge
    rather than a number nothing tests (L172)."""
    (tmp_path / "Manager.swift").write_text(
        "func die() {\n"
        "    self.markFailed(reason)\n"
        + "    // padding\n" * (ANNOUNCEMENT_WINDOW + 2)
        + f"    {THE_ANNOUNCEMENT}name)\n"
        "}\n")
    silent, _ = silent_failure_paths(tmp_path)
    assert silent == ["Manager.swift:2"]


def test_the_failure_sweep_skips_the_file_that_only_defines_the_call(tmp_path):
    """JobTracker DEFINES markFailed. It does not call it about any particular
    piece of work and has no event name to announce."""
    (tmp_path / "JobTracker.swift").write_text(
        "func markFailed(_ r: String) {\n    self.markFailed(r)\n}\n")
    silent, checked = silent_failure_paths(tmp_path)
    assert (silent, checked) == ([], 0)


def test_a_commented_out_failure_path_is_not_a_failure_path(tmp_path):
    """The reading is the code, not prose about it (L103).

    The Swift sweep read raw text and would have counted this. On the tree as it
    stands the two readings agree exactly, eight sites either way, which is
    precisely why the difference needs a fixture rather than the codebase.
    """
    (tmp_path / "Manager.swift").write_text(
        "func fine() {\n    // self.markFailed(reason)\n}\n")
    silent, checked = silent_failure_paths(tmp_path)
    assert (silent, checked) == ([], 0)


def test_every_failure_path_announces_itself():
    silent, checked = silent_failure_paths()
    # No offenders is what a sweep that read nothing also reports (L98).
    assert checked >= A_REAL_FAILURE_SWEEP, (
        f"the sweep found {checked} failure paths and there have been "
        f"{A_REAL_FAILURE_SWEEP} since #718, so it is reading the wrong thing "
        "rather than the app having fewer"
    )
    assert not silent, (
        "these runs are marked failed and say nothing, so with the window closed "
        f"a dead run is indistinguishable from one still going: {silent}"
    )
