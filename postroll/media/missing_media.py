"""One named condition for "this file was chosen, and it isn't there".

A chosen input that has gone missing is a fixable problem, and the person who
can fix it is the only one who needs to hear about it. Before this, each surface
handled it its own way: the before/after graphic opened the file unconditionally
and died with a bare FileNotFoundError, while the slider reel checked
``exists()`` and quietly rendered the two-photo version instead, which produces a
plausible-looking file with nothing to notice (#180).

Both now raise the same error naming the slot and the path, so the caller can
record one message per day instead of three behaviours for one input.
"""

from __future__ import annotations

from pathlib import Path


class MissingMediaError(RuntimeError):
    """A media file that was chosen for a render is not on disk."""

    def __init__(self, label: str, path: str):
        self.label = label
        self.path = path
        super().__init__(f"{label} not found: {path}")


def require_present(path, label: str) -> str | None:
    """Return ``path`` as a string when it is usable, else raise.

    An unset path returns None: optional and unset is not missing, there is
    simply nothing referenced. A path that IS set but whose file is absent
    raises `MissingMediaError`, because at that point somebody chose a file and
    the render cannot honour the choice.
    """
    if not path:
        return None
    text = str(path)
    if not Path(text).exists():
        raise MissingMediaError(label, text)
    return text
