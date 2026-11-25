"""What a review flag recommends doing about the value it flags (#1653).

A flag used to carry only `suggested_value`, and the app read "differs from the
OCR text" as Claude having proposed something. That left no way to recommend
taking an entry out, which is the whole remedy for a duplicate, so the model
copied the OCR text into the suggestion and the row offered nothing to press.

`recommendation_for` decides it in code, from the two values the app will act
on. What the model says it recommends is only consulted for a removal, which
the values cannot express. Two outcomes are settled by the flag pass
(`flag_issues.py`) around that call, because they need more than the values: a
flag the model withdraws, and a replacement the program's text does not print.
"""

from __future__ import annotations

from typing import Any

REPLACE = "replace"
"""`suggested_value` is a different value to put in the field."""

REMOVE = "remove"
"""The list entry the path lands in should not be in the data at all."""

NONE = "none"
"""Nothing to act on: the suggestion is empty or is the OCR text again."""

UNPRINTED = "unprinted"
"""A different value was suggested, but it uses a word the program's own text
does not contain, so the app shows it without filling it in."""

WITHDRAW = "withdraw"
"""Only ever asked for, never carried: the model found the data right after all.

It writes a flag field by field and cannot take one back, so without this it
finished flags it no longer believed. The flag pass discards them."""


def _settled(value: Any) -> Any:
    """Surrounding space is not a difference; any other JSON type is compared whole."""
    return value.strip() if isinstance(value, str) else value


def _in_a_list(field_path: list[Any]) -> bool:
    """Whether the path lands in a list entry, the only thing that can be removed."""
    return any(isinstance(seg, int) and not isinstance(seg, bool) for seg in field_path)


def recommendation_for(
    field_path: list[Any],
    current_value: Any,
    suggested_value: Any,
    asked: str | None = None,
) -> str:
    """The recommendation a flag carries, given what the model `asked` for."""
    if asked == REMOVE:
        return REMOVE if _in_a_list(field_path) else NONE
    suggested = _settled(suggested_value)
    if suggested in (None, "", [], {}):
        return NONE
    return REPLACE if suggested != _settled(current_value) else NONE
