"""Keeps ordinary performer names out of the hashtag list (#199).

Decided 2026-06-16, written into brand-voice.md, and it kept happening anyway:
a tag like `#janesmith` for a local cast member is noise rather than reach, and
those people belong in the caption body (as an @mention when they have a
handle, otherwise by plain name).

The prompt has been corrected, but a rule that lives only in a prompt is a
hope. This is the deterministic half: whatever the model returns is filtered
against the program data the caller already holds, the same shape as the
`_strip_second_person` backstop next door.

The gate covers PEOPLE. Composers, playwrights, arrangers and band names keep
their tags, because repertoire search behaves differently from people search.
It keys off ROLE rather than name, because one human can hold both kinds of
credit: the bassoonist whose `#bradballiett` tag shipped is also an arranger,
and matching on the name alone would let the arranger credit un-gate the
performer.
"""

from __future__ import annotations

import re
from typing import Any, Iterable

#: Roles whose names must not become hashtags unless the person is famous.
GATED_ROLES = frozenset({
    "soloist", "conductor", "ensemble", "actor", "dancer", "band_member",
    "troupe", "accompanist", "choreographer", "cast", "director",
    "singer", "musician", "performer", "instrumentalist", "vocalist",
})

#: Roles that are a credit on the WORK rather than a person on the stage.
#: These keep their hashtags: they are how repertoire is found.
REPERTOIRE_ROLES = frozenset({
    "composer", "playwright", "arranger", "lyricist", "librettist",
    "band", "orchestrator", "author",
})


def _key(text: str) -> str:
    """Comparison form: letters and digits only, lowercased.

    So "Mary-Jane O'Connor", "@maryjaneoconnor" and "#MaryJaneOConnor" all
    collapse to the same thing.
    """
    return re.sub(r"[^a-z0-9]", "", str(text).lower())


def gated_names(
    *,
    program: dict[str, Any] | None = None,
    name_mentions: Iterable[str] | None = None,
    photo_tags: dict[str, list[str]] | None = None,
    tag_handles: Iterable[str] | None = None,
    famous: Iterable[str] | None = None,
) -> set[str]:
    """Every person whose name must not appear as a hashtag.

    Drawn from four places the caller already has: the program's performers
    (by role), the plain-name credits, the per-photo people tags, and any
    person handle passed for mentioning. `famous` removes people the model
    judged genuinely famous, whose tags do aid discovery.

    Handles in `tag_handles` are only gated when they belong to someone who is
    ALSO a gated person in the program or the photo tags: an organization or
    venue handle still becomes a hashtag, which is the whole point of it.
    """
    gated: set[str] = set()

    performers = (program or {}).get("performers") or []
    for person in performers:
        if not isinstance(person, dict):
            continue
        role = str(person.get("role", "")).strip().lower()
        name = str(person.get("name", "")).strip()
        if not name or role not in GATED_ROLES:
            continue
        gated.add(name)
        handle = str(person.get("handle", "")).strip().lstrip("@")
        if handle:
            gated.add(handle)

    for name in name_mentions or []:
        text = str(name).strip()
        if text:
            gated.add(text.lstrip("@"))

    for people in (photo_tags or {}).values():
        for entry in people or []:
            text = str(entry).strip()
            if text:
                gated.add(text.lstrip("@"))

    # A handle only gets gated through the people above. Left alone here, so a
    # venue or organization handle keeps its hashtag.
    _ = tag_handles

    if famous:
        famous_keys = {_key(f) for f in famous}
        gated = {n for n in gated if _key(n) not in famous_keys}

    return {n for n in gated if _key(n)}


def strip_performer_hashtags(
    hashtags: Iterable[str],
    *,
    program: dict[str, Any] | None = None,
    name_mentions: Iterable[str] | None = None,
    photo_tags: dict[str, list[str]] | None = None,
    tag_handles: Iterable[str] | None = None,
    famous: Iterable[str] | None = None,
) -> list[str]:
    """Drop any hashtag that is an ordinary person's name. Order is kept."""
    blocked = {_key(n) for n in gated_names(
        program=program, name_mentions=name_mentions, photo_tags=photo_tags,
        tag_handles=tag_handles, famous=famous)}
    if not blocked:
        return list(hashtags)
    return [tag for tag in hashtags if _key(tag) not in blocked]
