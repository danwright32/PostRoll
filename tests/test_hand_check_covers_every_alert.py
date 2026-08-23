"""Every alert the window can show is in the hand check (#866).

The checklist quotes each alert by its title and its buttons, because "check the
alert looks right" is not a step anybody can be wrong about. That makes it a
document holding copies of strings that live in Swift, and a document quoting
code it is not held to is worse than no document: it sends whoever is running
the check looking for words that no longer exist, and a step that cannot be
completed is usually recorded as a step that passed.

Both directions matter and only one of them is obvious. A RENAMED title leaves a
checklist step nobody can carry out. A NEW alert leaves a screen the routine
never looks at, and nothing anywhere would say so, because the checklist goes on
passing on the alerts it already knew about (L96).

What this deliberately does NOT check is the sentence beside each title. The
message bodies name paths and are composed at runtime, so quoting them exactly
would break on every legitimate rewording; the checklist describes them instead
(L210).
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


def test_every_alert_title_appears_in_the_checklist():
    checklist = CHECKLIST.read_text()
    missing = sorted(t for t in alert_titles() if t not in checklist)

    assert not missing, (
        "the hand check does not cover these alerts, so nothing looks at what "
        f"they draw and nothing ever will: {missing}"
    )


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
    body = block[1]

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


def test_every_alert_button_is_named_in_the_checklist():
    """A step that checks only the title passes on a half swapped alert, which
    is the exact failure #855 was opened to find, so the buttons are quoted too.

    This catches the direction that actually goes wrong: a label reworded in
    Swift while the checklist goes on asking for the old words, which leaves a
    step nobody can carry out and which is usually recorded as a step that
    passed. It does not claim the label is quoted in the RIGHT step; a whole
    file match is satisfied by any mention anywhere (L135), and holding a prose
    sentence to a position in the document would break on every rewrite of it.
    """
    checklist = CHECKLIST.read_text()
    missing = sorted(label for label in alert_button_labels() if label not in checklist)

    assert not missing, (
        "the checklist never names these alert buttons, so whoever runs it "
        f"cannot tell a correctly drawn alert from a half swapped one: {missing}"
    )


def test_the_checklist_counts_its_own_steps_correctly():
    """The opening line says how many questions there are, and it is a number
    kept by hand beside a list that grows (L41).

    It had already drifted once, in the README, which said six while there were
    eight. The README no longer claims a count at all; this one is worth keeping
    because it is the first sentence somebody reads before deciding whether to
    start, but only if something holds it to the steps below it.
    """
    text = CHECKLIST.read_text()

    steps = re.findall(r"^## (\d+)\. ", text, re.M)
    assert steps, "no numbered steps were found at all, so this test reads nothing"
    assert [int(number) for number in steps] == list(range(1, len(steps) + 1)), (
        f"the steps are numbered {steps}, which is not 1 upwards, so a count of "
        "them is not what the opening line is claiming"
    )

    spelled = {
        4: "Four", 5: "Five", 6: "Six", 7: "Seven", 8: "Eight",
        9: "Nine", 10: "Ten", 11: "Eleven", 12: "Twelve",
    }
    expected = spelled.get(len(steps))
    assert expected, (
        f"{len(steps)} steps, and this test has no word for that number. Add it "
        "rather than deleting the check"
    )
    first_line = text.splitlines()[2]
    assert first_line.startswith(f"{expected} questions"), (
        f"the checklist opens with {first_line!r} and holds {len(steps)} steps"
    )
