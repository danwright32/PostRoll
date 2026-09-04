"""#1162: the app and the terminal make the SAME claim about a repair.

The repair journal now has two readers in two languages: `read_repair_log.py`
for a terminal, and `RepairJournal` for the blog panel. Two readers of one file
is a drift hazard, and a shared NAME is read as evidence of shared BEHAVIOUR
without anybody comparing them (L263).

Only one string actually has to agree, and it is the one where disagreement
would be a false statement rather than a cosmetic difference. `after` is null
when the app tried a rewrite and its own damage gate refused the result. Shown
as an empty value that reads as the alt text having been BLANKED, which is the
opposite of what happened, so both readers say it was left unchanged and say it
in the same words.
"""

from __future__ import annotations

import re
from pathlib import Path
from source_text import without_prose

REPO_ROOT = Path(__file__).resolve().parent.parent
SWIFT = REPO_ROOT / "PostRollApp" / "Sources" / "Services" / "RepairJournal.swift"
PYTHON_READER = REPO_ROOT / "tools" / "read_repair_log.py"


def _swift_refused_wording() -> str:
    # Comments blanked (#1074). String literals are kept: what this reads
    # IS a literal, and blanking those would make it unsatisfiable (L104).
    source = without_prose(SWIFT)
    match = re.search(r'static let refusedWording = "([^"]+)"', source)
    assert match, (
        "RepairJournal no longer declares refusedWording where this reads it, "
        "so the two readers' agreement is no longer checked by anything")
    return match.group(1)


def _python_refused_wording() -> str:
    source = PYTHON_READER.read_text(encoding="utf-8")
    match = re.search(r'after_refused = "([^"]+)"', source)
    assert match, (
        "read_repair_log.py no longer declares after_refused where this reads "
        "it")
    return match.group(1)


def test_both_readers_describe_a_refused_rewrite_identically():
    assert _swift_refused_wording() == _python_refused_wording(), (
        "the panel and the terminal report a refused rewrite differently, so "
        "the same record reads as two different outcomes depending on where "
        "Dan looks at it")


def test_the_wording_says_the_text_was_kept():
    """Not merely that the two agree. Two readers agreeing on a sentence that
    reads as "the alt text is now empty" would pass the test above while both
    being wrong (L178)."""
    wording = _swift_refused_wording()

    assert "unchanged" in wording.lower(), (
        f"the refused wording does not say the original text was kept: "
        f"{wording!r}. An empty-looking value here claims the app blanked the "
        f"alt text, which is the opposite of what a refusal does.")


def test_the_panel_selects_on_the_event_id_and_has_no_fallback():
    """The keying fix is the reason the panel can be per-post at all. A
    fallback to the name or the venue reintroduces exactly the guess it
    replaced, and would do so silently (L214)."""
    # Comments blanked (#1074). String literals are kept: what this reads
    # IS a literal, and blanking those would make it unsatisfiable (L104).
    source = without_prose(SWIFT)

    assert 'record["event_id"]' in source, (
        "the panel's reader no longer selects on the event id")
    for guess in ('record["event"]', 'record["venue"]'):
        assert guess not in source, (
            f"the panel's reader reads {guess}, which is the venue-shaped "
            f"guess the event id replaced: two posts at the same venue would "
            f"be shown as one")
