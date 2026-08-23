"""The UI tests quote the alerts the window can actually raise (#877).

`PostRollUITests` compiles `UITests/` only, so it cannot reference
`WindowAlertText` and has to hold the titles as literals. That is a copy of
strings that live in Swift somewhere else, and a copy nothing holds to its
source drifts: a renamed alert leaves a UI test waiting thirty seconds for words
nothing draws, which reads as the harness being unable to see the window, which
is exactly the wrong conclusion to reach again (#860).

Both directions, for the reason the checklist's own guard gives (L96). A RENAMED
title leaves a test that can only fail. A NEW alert leaves a screen the UI tests
never look at, and nothing says so, because they go on passing on the alerts
they already knew about.
"""

from __future__ import annotations

import re

from alert_titles import REPO_ROOT, alert_titles

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
    return {name: title for name, title in found.items()}


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
        f"these alerts have no UI test at all: {missing}. Nothing automated "
        "looks at what they draw, and the checklist step that used to is being "
        "retired as these land"
    )
