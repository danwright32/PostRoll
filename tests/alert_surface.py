"""Every alert the window can draw, read out of the Swift that draws it.

Two guards need this and each would otherwise spell the parse differently: one
asks whether the UI tests quote every alert, the other whether they assert every
button. A copy of one derivation is a copy that drifts, and the failure is the
quiet kind, since a parse that matches nothing reports a clean run over an empty
set (L98). Both readers below RAISE rather than returning an empty answer.

This used to serve `docs/HAND-CHECK.md`, which quoted the alerts because nothing
automated could see them. Since #877 they are asserted by
`PostRollApp/UITests/LaunchAlertUITests.swift` and the checklist no longer
mentions them, so the same readers now hold the UI tests instead. What is being
protected did not change: an alert nobody looks at is one that can be
half swapped and stay that way (#855, L96).

Read as text rather than compiled, because the alerts live in Swift and this is
Python.
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


def alert_button_labels() -> set[str]:
    """Every button label the window's one alert modifier can draw.

    Read out of the modifier rather than listed here, for the same reason the
    titles are: a button added to an alert is a thing the checklist has to look
    at, and a hand written list would not know about it.
    """
    # Comments stripped first. The window explains, in a comment above the
    # modifier, why `.alert(_:isPresented:)` alone is not enough, so a search of
    # the raw file finds two alerts and concludes the parse is broken.
    source = (REPO_ROOT / "PostRollApp" / "Sources" / "Views" / "MainWindowView.swift").read_text()
    window = "\n".join(line for line in source.splitlines()
                       if not line.lstrip().startswith("//"))
    block = window.split(".alert(")
    assert len(block) == 2, (
        f"MainWindowView presents {len(block) - 1} alerts. One is the whole "
        "point of #846, and zero means this test is reading nothing at all"
    )
    # Only as far as the message builder, which is where the alert's own
    # buttons end. Reading to the end of the file swept up `New Event` from the
    # window behind it, and a guard that demands somebody quote a button no
    # alert has is a guard nobody can satisfy honestly.
    assert "} message: {" in block[1], (
        "the alert modifier no longer hands off to a message builder, so there "
        "is no end to read to and this would take every button on the window"
    )
    body = block[1].split("} message: {")[0]

    labels = set(re.findall(r'Button\("([^"]+)"', body))
    # The restore button takes its label from a named constant, because the same
    # words appear on the store recovery surfaces too.
    if "StoreRestoreText.restoreLabel" in body:
        text = (REPO_ROOT / "PostRollApp" / "Sources" / "Services" / "StoreRestoreText.swift").read_text()
        found = re.search(r'static let restoreLabel = "([^"]+)"', text)
        assert found, "StoreRestoreText.restoreLabel is no longer a plain string literal"
        labels.add(found.group(1))

    assert len(labels) >= 4, (
        f"only {len(labels)} button labels were read out of the alert modifier, "
        "and the three alerts have carried more than that since #846, so the "
        "parse is wrong rather than the app being simpler"
    )
    return labels
