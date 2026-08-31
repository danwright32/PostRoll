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
TAGS_DROPPED = "TAGS THAT DID NOT FIT:"

#: How many accounts Instagram will tag on one post (#281).
#:
#: 20, confirmed by Dan on 2026-08-10. Named here with that date rather than
#: typed inline at each use, because Instagram has changed limits of this kind
#: before and a number nobody can find the provenance of gets copied forward
#: long after it stopped being true.
#:
#: Past this the extra handles are simply not tagged when the list is pasted
#: in, and nothing said which ones fell off, so the export read as complete
#: either way.
MAX_TAGS_PER_POST = 20

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


#: The characters an Instagram username is made of.
_HANDLE_CHARACTERS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._")


def is_handle_shaped(raw: str) -> bool:
    """Whether this value could be an Instagram username at all (#899).

    A performer row carried its company's display name in the handle field,
    'DPR Dance', and nothing checked. It reached `tag_handles` as a handle to
    mention, the model wrote `@DPR Dance` into a caption bound for Instagram,
    and `HANDLE_RE` in `caption_credits` then read that as `@dpr`, which was
    never offered and belongs to somebody else. Any `tag_handles` entry
    containing a space produces that pair; it is not probabilistic.

    SHAPE only. Whether a value is a SENTINEL recorded because a lookup found
    nothing ('unknown', 'n/a') is a different question, answered separately, so
    that one word names one unit (L118). 'unknown' is well shaped.

    Mirrors `CaptionBlocks.isHandleShaped` in Swift, and
    `tests/fixtures/handle_shape.json` states the cases once for both, because
    a rule applied on one side of the bridge only is how this happened.
    """
    name = bare_username(raw)
    if not name or name.endswith("."):
        return False
    return all(character in _HANDLE_CHARACTERS for character in name)


#: Values recorded because a lookup found nothing, rather than because somebody
#: has an account by that name. Well shaped, every one of them, which is why
#: shape alone cannot answer the question (#917).
#:
#: The one list in Python, and `tests/test_real_handle.py` holds it to that.
#: Swift keeps its own in `PythonBridge.handleSentinels`, because neither side
#: can read the other's at build time, and `tests/fixtures/real_handle.json`
#: states the list once so the two cannot drift apart by hand (L41, #926).
#:
#: A blacklist admits every placeholder nobody thought to list (L257). It is
#: what ships today on both sides of the bridge, and widening it to a real
#: account check is a separate change; what this must not do is grow a THIRD
#: spelling of the same list.
HANDLE_SENTINELS = frozenset({"unknown", "n/a", "na", "none", "-", "no", "skip"})


def is_real_handle(raw: str) -> bool:
    """Whether this value is an account that can actually be tagged (#917).

    Shaped like a username AND not a sentinel. Both halves are needed and
    neither answers the other: 'DPR Dance' is a real company and no account,
    'unknown' is perfectly well shaped and nobody at all.

    Mirrors `PythonBridge.isRealHandle` in Swift, which `TypedCredit` reads
    through, and the two are held together by `tests/fixtures/real_handle.json`
    (#926). They are the pair that spans the bridge on the deliverable: this is
    what `week_tags` below calls and that is what `CaptionBlocks.weekTags`
    reaches, so between them they decide the TAG LIST Dan pastes into Instagram.

    The one answer in Python, and `tests/test_real_handle.py` holds it to that.
    `generate_captions._is_real_handle` used to sit beside it checking the
    sentinel half only, so 'DPR Dance' passed it while this refused it. Nothing
    had called it since 2026-05-24, when handles were dropped from the
    performers block, so it was dead rather than divergent, and the reason #917
    recorded for leaving it alone (that tightening it would change what reaches
    the model) could not have been true. It is gone.
    """
    return is_handle_shaped(raw) and bare_username(raw).lower() not in HANDLE_SENTINELS


def week_tag_list(days: Iterable[tuple[dict[str, Any] | None,
                                       dict[str, list[str]] | None,
                                       list[Any] | None]]) -> list[str]:
    """Every handle taggable anywhere in the week, deduplicated, in order.

    Each item is (caption, photo_tags, photos). The reel days carry this rather
    than nothing: they are shot at the same event as the rest of the week, so
    anyone taggable on any other day is taggable on the reel, and there is no
    per-photo tag data for a reel day to draw on (#222).
    """
    return week_tags(days)[0]


def week_tags(days: Iterable[tuple[dict[str, Any] | None,
                                   dict[str, list[str]] | None,
                                   list[Any] | None]],
              limit: int = MAX_TAGS_PER_POST) -> tuple[list[str], list[str]]:
    """The handles that fit on a post, and the ones that do not (#281).

    Returns (kept, dropped). Both, because the whole defect was that the
    overflow went nowhere: Instagram silently ignores handles past its limit,
    so a week at a multi-ensemble venue tagged twenty people and lost the rest
    with the export reading as complete either way.

    Handles that appear in a photo's own tags come FIRST, ahead of ones that
    only appear as a day-level tag, so the people actually in the pictures keep
    their slots by construction. Within each group the original traversal order
    holds, so the list is stable rather than dictionary order.

    `tests/fixtures/caption_blocks.json` is the contract this and
    `CaptionBlocks.weekTags` both satisfy.
    """
    seen: set[str] = set()
    in_photos: list[str] = []
    day_level: list[str] = []

    def add(raw: str, into: list[str]) -> None:
        # Only an account reaches the TAG LIST (#917). A name typed in either
        # field is credited by name elsewhere (`CaptionCreditInputs` routes it
        # through `TypedCredit`), so excluding it here loses nothing, while
        # INCLUDING it costs a real person their slot: Instagram tags at most
        # `MAX_TAGS_PER_POST` accounts and the pasted list is silently truncated
        # past that, so a value that is not an account displaces one that is
        # (L117).
        if not is_real_handle(raw):
            return
        name = bare_username(raw)
        if not name:
            return
        # Instagram handles are not case sensitive, so two spellings of one
        # handle are one person and tagging both would tag them twice.
        key = name.lower()
        if key in seen:
            return
        seen.add(key)
        into.append(name)

    # Photos first, so somebody in a picture is never the one cut for somebody
    # who is only on the day. Both passes run over the whole week before
    # anything is trimmed.
    for _caption, photo_tags, photos in days:
        # Photo order, so the list is stable rather than dict order.
        for photo in photos or []:
            for tag in (photo_tags or {}).get(str(photo)) or []:
                add(str(tag), in_photos)
    for caption, _photo_tags, _photos in days:
        for handle in (caption or {}).get("tag_handles") or []:
            add(str(handle), day_level)

    ordered = in_photos + day_level
    return ordered[:limit], ordered[limit:]


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
