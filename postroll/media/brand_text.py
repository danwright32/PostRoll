"""Brand text rules the media templates share.

Companion to `design_tokens.py`, which holds the colours and type the templates
agree on. This holds the wording rules: the small decisions about what text
appears under a title that every template is supposed to make the same way.

Deliberately NOT here: how a template lays that text out. Whether the lines are
centred, letter-spaced, joined with a separator or stacked is per-template
design and stays in the generator that owns it. What belongs here is WHICH
lines there are.
"""

from __future__ import annotations


def detail_lines(event_name: str, org: str, venue: str) -> list[str]:
    """The organisation and venue lines that sit under an event's title.

    When the organisation is the same name as the event, it is already the big
    script title above, so repeating it underneath is noise and it is dropped.
    Comparison ignores case and surrounding whitespace, because the org arrives
    from a different field than the event name and rarely matches byte for byte.

    Returns the lines in order, already stripped, with empty ones removed. A
    template that wants them on one line joins them with its own separator
    (`generate_collage` uses a middle dot); one that stacks them iterates.
    """
    event_name = (event_name or "").strip()
    org = (org or "").strip()
    venue = (venue or "").strip()

    lines = []
    if org and org.casefold() != event_name.casefold():
        lines.append(org)
    if venue:
        lines.append(venue)
    return lines
