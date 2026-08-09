"""Shared rules for the day blocks in CAPTIONS.txt (#221, #222, #223).

CAPTIONS.txt is the deliverable: it is what gets pasted into Instagram. A
wrongly formatted or entirely missing section produces a file that reads as
complete, so it ships and is only caught if Dan happens to notice something
absent. That is how #221 and #222 were both found.

Mirrors `PostRollApp/Sources/Services/CaptionBlocks.swift`. The two are kept in
parity by hand, so `tests/fixtures/caption_blocks.json` states the cases once
and both sides assert against it (#104, #186).
"""

from __future__ import annotations

from typing import Any, Iterable

#: Section headers, exactly as they appear in the file.
ALT_TEXT = "ALT TEXT:"
PHOTO_TAGS = "PHOTO TAGS:"
TAG_LIST = "TAG LIST:"

#: The days that carry a reel and therefore the whole week's tag list.
REEL_DAYS = ("tuesday", "thursday")


def bare_username(raw: str) -> str:
    """Strip an @ prefix (and a pasted profile URL) down to the username.

    Instagram's "Tag people" field takes a bare username, not an @ mention
    (#221).
    """
    name = (raw or "").strip()
    marker = "instagram.com/"
    if marker in name:
        name = name.split(marker, 1)[1]
    name = name.strip("/")
    while name.startswith("@"):
        name = name[1:]
    return name.strip()


def week_tag_list(days: Iterable[tuple[dict[str, Any] | None,
                                       dict[str, list[str]] | None,
                                       list[Any] | None]]) -> list[str]:
    """Every handle taggable anywhere in the week, deduplicated, in order.

    Each item is (caption, photo_tags, photos). The reel days carry this rather
    than nothing: they are shot at the same event as the rest of the week, so
    anyone taggable on any other day is taggable on the reel, and there is no
    per-photo tag data for a reel day to draw on (#222).
    """
    seen: set[str] = set()
    out: list[str] = []

    def add(raw: str) -> None:
        name = bare_username(raw)
        if not name:
            return
        # Instagram handles are not case sensitive, so two spellings of one
        # handle are one person and tagging both would tag them twice.
        key = name.lower()
        if key in seen:
            return
        seen.add(key)
        out.append(name)

    for caption, photo_tags, photos in days:
        for handle in (caption or {}).get("tag_handles") or []:
            add(str(handle))
        # Photo order, so the list is stable rather than dict order.
        for photo in photos or []:
            for tag in (photo_tags or {}).get(str(photo)) or []:
                add(str(tag))
    return out


def expected_blocks(*, day: str, is_collage_carousel: bool, has_alt_text: bool,
                    has_photo_tags: bool, has_week_tags: bool) -> set[str]:
    """Which sections this day's block must contain (#223).

    Declared here rather than inferred from whichever builder ran: a check
    derived from the code it checks can only prove that code is self
    consistent.
    """
    blocks = {"caption"}
    if has_alt_text:
        blocks.add(ALT_TEXT)
    if is_collage_carousel:
        if has_photo_tags:
            blocks.add(PHOTO_TAGS)
    elif day.lower() in REEL_DAYS and has_week_tags:
        blocks.add(TAG_LIST)
    return blocks


def missing_blocks(text: str, expected: set[str]) -> list[str]:
    """Which expected sections are absent from a day's block.

    Returns the shortfall rather than a bool, because "the export is wrong" is
    not an actionable message.
    """
    missing: list[str] = []
    for block in ("caption", ALT_TEXT, PHOTO_TAGS, TAG_LIST):
        if block not in expected:
            continue
        if block == "caption":
            body = text
            for header in (ALT_TEXT, PHOTO_TAGS, TAG_LIST):
                marker = "\n\n" + header
                if marker in body:
                    body = body.split(marker, 1)[0]
            # Everything after the "=== DAY ===" heading line.
            after_heading = body.split("\n", 1)[1] if "\n" in body else ""
            if not after_heading.strip():
                missing.append(block)
        elif block not in text:
            missing.append(block)
    return missing
