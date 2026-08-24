"""The UI tests quote the alerts the window can actually raise (#877).

`PostRollUITests` compiles `UITests/` only, so it cannot reference
`WindowAlertText` and has to hold the titles and button labels as literals. That
is a copy of strings that live in Swift somewhere else, and a copy nothing holds
to its source drifts: a renamed alert leaves a UI test waiting for words nothing
draws, which reads as the harness being unable to see the window, which is
exactly the wrong conclusion to reach again (#860).

These are the guards `docs/HAND-CHECK.md` used to carry. The checklist quoted
every alert because nothing automated could see one; now something can, and the
same two questions are asked of the tests instead. Both directions matter and
only one is obvious (L96). A RENAMED title or button leaves a test that can only
fail. A NEW alert leaves a screen nothing looks at, and nothing says so, because
the tests go on passing on the alerts they already knew about.
"""

from __future__ import annotations

import re

from alert_surface import REPO_ROOT, alert_button_labels, alert_titles

UI_TESTS = REPO_ROOT / "PostRollApp" / "UITests" / "LaunchAlertUITests.swift"

# The one enum in that file that spells an alert title.
ENUM = re.compile(r"enum AlertTitle \{(.*?)\n\}", re.S)
DECLARATION = re.compile(r'static let (\w+) = "([^"]+)"')


def quoted_titles() -> dict[str, str]:
    body = ENUM.search(UI_TESTS.read_text())
    assert body, (
        f"there is no AlertTitle enum in {UI_TESTS.name}, so this test reads "
        "nothing and would pass on a file quoting no alerts at all"
    )
    found = dict(DECLARATION.findall(body.group(1)))
    assert found, "the AlertTitle enum declares nothing"
    return found


def test_every_title_the_ui_tests_wait_for_is_one_the_window_can_draw():
    wrong = sorted(set(quoted_titles().values()) - alert_titles())

    assert not wrong, (
        f"the UI tests wait for titles nothing draws: {wrong}. A test waiting "
        "for words that no longer exist times out and reads as the harness "
        "being unable to see the window"
    )


def test_every_alert_the_window_can_draw_is_quoted_by_the_ui_tests():
    missing = sorted(alert_titles() - set(quoted_titles().values()))

    assert not missing, (
        f"these alerts have no UI test at all: {missing}. Nothing looks at what "
        "they draw, and the checklist that used to no longer mentions them"
    )


def test_every_button_the_alerts_can_draw_is_named_by_the_ui_tests():
    """A test that checks only the title passes on a half swapped alert.

    That is the exact failure #855 was opened to find: a title over the previous
    alert's buttons, with each half of the screen reading as correct. It does
    not claim the label is asserted in the RIGHT test, because a whole file
    match is satisfied by any mention anywhere (L135); it claims that a label
    reworded in Swift cannot leave every UI test still passing.
    """
    source = UI_TESTS.read_text()
    missing = sorted(label for label in alert_button_labels() if f'"{label}"' not in source)

    assert not missing, (
        f"the UI tests never name these alert buttons: {missing}. A button "
        "added or reworded there is a change nothing here would notice"
    )
