"""Posting presets: how the week's photos are shaped per day.

A preset decides, for each posting day, whether it is a ``single`` post (one
feed photo + a story image) or a ``collage_carousel`` post (a multi-photo
carousel feed plus a collage that doubles as the story), and how many photos it
uses.

Two presets ship today:

* ``balanced`` (the default) — Sunday, Monday, and Wednesday each carry a
  4 photo carousel plus a 4 photo collage story.
* ``classic`` — the original layout: Sunday and Monday are single feed photos,
  Wednesday is a 10 photo carousel + collage.

Tuesday, Thursday, and Friday are not governed by the preset; their format is
fixed (speed-edit reel, scroll reel, before/after) regardless of preset.

This module is the single source of truth so the asset generator, the caption
pipeline, and both export paths can never drift.
"""

from __future__ import annotations

# Post formats a day can take.
SINGLE = "single"                      # one feed photo + story.png
COLLAGE_CAROUSEL = "collage_carousel"  # carousel feed + collage.png (story)

DEFAULT_PRESET = "balanced"

# preset -> day -> (format, photo_count)
# Only the preset-governed days appear here; other days fall through to None.
_PRESETS: dict[str, dict[str, tuple[str, int]]] = {
    "balanced": {
        "sunday":    (COLLAGE_CAROUSEL, 4),
        "monday":    (COLLAGE_CAROUSEL, 4),
        "wednesday": (COLLAGE_CAROUSEL, 4),
    },
    "classic": {
        "sunday":    (SINGLE, 1),
        "monday":    (SINGLE, 1),
        "wednesday": (COLLAGE_CAROUSEL, 10),
    },
}


def _normalize(preset: str | None) -> str:
    return preset if preset in _PRESETS else DEFAULT_PRESET


def day_format(preset: str | None, day: str) -> tuple[str, int] | None:
    """Return ``(format, photo_count)`` for a preset-governed day, else None.

    ``None`` means the day's format is not controlled by the preset (Tuesday,
    Thursday, Friday) and the caller should use that day's fixed handling.
    """
    return _PRESETS[_normalize(preset)].get(day)


def collage_count(preset: str | None, day: str) -> int | None:
    """Photo count for a ``collage_carousel`` day, else None."""
    fmt = day_format(preset, day)
    if fmt and fmt[0] == COLLAGE_CAROUSEL:
        return fmt[1]
    return None


def is_collage_carousel(preset: str | None, day: str) -> bool:
    fmt = day_format(preset, day)
    return bool(fmt and fmt[0] == COLLAGE_CAROUSEL)
