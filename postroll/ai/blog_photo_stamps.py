"""What decides that a photograph is the SAME photograph (#1130).

Retaining an alt text is deciding to SKIP work, and the comparison behind that
decision has to change whenever the content changes (L40). This app's own
`ThumbnailStore` already states the rule in its own words: photos here are
EDITED IN PLACE, a crop or a re-export rewrites the file and leaves the path
alone, and both the modification date and the size move when the bytes move, so
both belong in the key.

Nothing stored could answer that question before this. `BlogOutput` carried
title, body, photo_count, generated_body, findings and findings_body: no photo
paths, no stat, no per-marker anchor. So a post now records a stamp per placed
photograph, and that record does two jobs at once. It is the retention key, and
it is the durable evidence of WHICH seven of twelve photographs the post was
written around, which is what `blog_marker_missing_photo` was providing
incidentally and would stop providing once the repair pass acts on it (L277).

Every post written before this ships carries no stamps, so its first swap
retains nothing and costs exactly what it costs today. That backlog is named
here rather than assumed away (L223).

It reads the filesystem and the blog checker's filename fold, and nothing that
can reach a model runner, so the gate and the repair loop can both take it.
"""

from __future__ import annotations

import enum
import os
from urllib.parse import unquote, urlparse

# The checker's own fold, not a copy of it (L263). `blog_quality` reaches
# `ai_tells` and `blog_findings` and nothing else, so taking it costs nothing
# and cannot pull a model runner in behind it, which
# tests/test_blog_photo_stamps.py asserts rather than leaves to be remembered.
from .blog_quality import _fold_filename as fold_filename

class Retention(enum.Enum):
    """Why a photograph's alt text is or is not being kept.

    Four answers, not a boolean, and never three (L11, L289). "Nothing was
    recorded" is a first run; "the file could not be read" is a broken path or a
    moved photograph; "the bytes moved" is a re-export. They call for different
    things and they must not share a name, because if they do, the day the path
    decoder breaks looks exactly like the day this feature shipped and the
    saving stops with nothing reporting it.
    """
    RETAINED = "retained"
    NEW_NO_STAMP = "new (no recorded stamp)"
    NEW_UNREADABLE = "new (could not read the file)"
    NEW_EDITED = "new (the photograph changed since the post was written)"

    @property
    def reason(self) -> str:
        return self.value


def decode_photo_path(path: str) -> str:
    """A stored photo path as something the filesystem will accept.

    `Event.blogPhotoPaths` are percent-encoded `file://` URL strings. Measured
    on the stored events: all 12 paths on the DiGangi event return False from
    `os.path.exists` on the raw string and True after decoding. A stat against
    the raw string fails silently on every one of them, answers every photograph
    as new, and the entire saving stops happening while every test stays green
    (L289).

    A plain path is returned unchanged, so a caller does not have to know which
    kind it is holding.
    """
    text = str(path or "")
    if not text.startswith("file://"):
        return text
    return unquote(urlparse(text).path)


def photo_stamps(filenames: list[str], paths: list[str]) -> dict[str, list[int]]:
    """The stamp for each photograph a post places, keyed by folded filename.

    A file that cannot be stat'ed is LEFT OUT rather than recorded as zeros: a
    stamp nobody could verify would answer every later comparison as retained,
    which is the failure this exists to prevent (L215).
    """
    stamps: dict[str, list[int]] = {}
    for name, path in zip(filenames, paths):
        try:
            info = os.stat(decode_photo_path(path))
        except OSError:
            continue
        stamps[fold_filename(name)] = [info.st_mtime_ns, info.st_size]
    return stamps


def retention_for(filename: str, path: str,
                  stamps: dict[str, list[int]] | None) -> Retention:
    """Whether this photograph's alt text may be kept, and why not when it may not."""
    recorded = (stamps or {}).get(fold_filename(filename))
    if recorded is None:
        return Retention.NEW_NO_STAMP
    try:
        info = os.stat(decode_photo_path(path))
    except OSError:
        return Retention.NEW_UNREADABLE
    # Compared as a list of ints so a stamp that has been through JSON and one
    # freshly taken are the same value.
    if [int(v) for v in recorded] == [info.st_mtime_ns, info.st_size]:
        return Retention.RETAINED
    return Retention.NEW_EDITED
