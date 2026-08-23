"""Every alert title the window can put on screen, read from the switch itself.

Two guards need this set and each used to be a chance to spell the parse
differently: `test_hand_check_covers_every_alert.py` asks whether the manual
checklist covers every alert, and `test_ui_tests_quote_the_real_alerts.py` asks
whether the UI test target quotes them correctly. A copy of one derivation is a
copy that drifts, and the failure is the quiet kind: a parse that matches
nothing reports a clean run over an empty set (L98), which is why the reader
below RAISES rather than returning an empty answer.

Read as text rather than compiled, for the reason the rest of this suite gives:
the titles live in Swift and this is Python.
"""

from __future__ import annotations

import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CHECKLIST = REPO_ROOT / "docs" / "HAND-CHECK.md"
WINDOW_MODALS = REPO_ROOT / "PostRollApp" / "Sources" / "Models" / "WindowModals.swift"
LAUNCH_CHECK = REPO_ROOT / "PostRollApp" / "Sources" / "Services" / "LaunchProjectCheck.swift"

# The body of WindowAlertText.title, which is the one switch that decides what
# every alert on the window is called.
TITLE_FUNC = re.compile(r"static func title\(_ alert: WindowAlert\) -> String \{(.*?)\n    \}", re.S)
LITERAL = re.compile(r'return "([^"]+)"')
REFERENCE = re.compile(r"return (\w+)\.title")


def alert_titles() -> set[str]:
    """Every title the window can put on an alert, read from the switch itself.

    Read rather than listed here, so an alert added to the enum raises the bar
    with no edit to this file: a hand written list only ever covers what
    somebody remembered to add, and the entries you remember are the ones
    already safe (L96).
    """
    body_match = TITLE_FUNC.search(WINDOW_MODALS.read_text())
    assert body_match, (
        "WindowAlertText.title could not be found in WindowModals.swift, so "
        "this test is reading nothing at all and would pass on any checklist"
    )
    body = body_match.group(1)

    titles = set(LITERAL.findall(body))
    for referenced in REFERENCE.findall(body):
        # One indirection, the only one the switch uses: the code folder alert
        # takes its title from the launch check that raises it.
        assert referenced == "LaunchProjectCheck", (
            f"{referenced}.title is a title this test does not know how to "
            "resolve, so it would silently check one alert fewer"
        )
        found = re.search(r'static let title = "([^"]+)"', LAUNCH_CHECK.read_text())
        assert found, "LaunchProjectCheck.title is no longer a plain string literal"
        titles.add(found.group(1))

    assert len(titles) >= 3, (
        f"only {len(titles)} alert titles were read out of the switch, and the "
        "window has had three since #846, so the parse is wrong rather than the "
        "app being simpler"
    )
    return titles
