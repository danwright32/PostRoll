"""What the hand check document itself has to keep true (#866, #877).

It used to hold the alert guards as well, because the checklist quoted every
alert and every alert button: nothing automated could see one, so a document
was the only reviewer they had. Since #877 they are asserted against the
running app, the checklist no longer mentions them, and those two guards moved
to `test_ui_tests_quote_the_real_alerts.py` rather than being deleted. What
they protect is unchanged: an alert nobody looks at can be half swapped and
stay that way (L96).
"""

from __future__ import annotations

import re

from alert_surface import CHECKLIST


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
        1: "One", 2: "Two", 3: "Three", 4: "Four", 5: "Five", 6: "Six",
        7: "Seven", 8: "Eight", 9: "Nine", 10: "Ten", 11: "Eleven", 12: "Twelve",
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
