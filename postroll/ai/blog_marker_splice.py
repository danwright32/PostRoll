"""Put a retained photo marker back exactly as it was (#1131).

Both the swap path and the revise path hand the model a body full of
`[PHOTO: filename | alt text]` markers and instruct it to keep them exactly.
Neither verified it. Until #1141 `markers_preserved_validator` sorted the
filenames and never read the alt text, so a pass that rewrote every description
while keeping every filename was indistinguishable from one that changed
nothing, and `revise_blog`'s first call had no validator at all.

That validator now compares the ordered (filename, alt text) pairs, so the fault
is visible where it was not. The splice stays because seeing it and repairing it
are different things: a validator can only refuse the whole pass, and refusing
throws away a review pass that has already been paid for.

The splice makes the instruction unnecessary rather than better worded: whatever
the model returns for a retained marker is discarded and the original put back
verbatim. It is deterministic, costs nothing, and it is the only thing that
makes "the alt text you did not ask about is unchanged" true.

**The comparison before discarding is the part that matters most.** The splice
is the correct write AND it destroys the only evidence that the instruction was
ignored: a model that rewrote every retained marker and one that reproduced them
all produce a byte-identical spliced body. This repo has already shipped that
exact shape once, truncating a list "defensively" and hiding the violation on 12
of 21 Thursday reels (#1067). So the drift is counted and handed back to the
caller to record. The splice still happens; the point is to know (L340).

A leaf, so the gate and both scripts can take it without dragging anything in.
"""

from __future__ import annotations

import re

from .blog_quality import _PHOTO_MARKER, _fold_filename


def splice_retained_markers(incoming: str, produced: str,
                            retained: set[str]) -> tuple[str, int]:
    """`produced`, with every retained marker restored from `incoming`.

    Returns the spliced body and how many retained markers the model had
    CHANGED, which is the count the journal records.

    Raises `ValueError` naming the marker when a retained one is missing from
    `produced`. It is deliberately not put back at a guessed position: where a
    dropped marker belongs is a judgement about the flow of the post, and
    inserting it somewhere is the shape #998 warns about. The caller falls back
    to the whole rewrite instead, which is a cost regression announced out loud
    rather than a silent correctness one.
    """
    original = {_fold_filename(name): (name, alt)
                for name, alt in _PHOTO_MARKER.findall(incoming)}
    wanted = {_fold_filename(name) for name in retained}

    seen: set[str] = set()
    drift = 0

    def _restore(match: "re.Match[str]") -> str:
        nonlocal drift
        key = _fold_filename(match.group(1).strip())
        if key not in wanted or key not in original:
            return match.group(0)
        seen.add(key)
        name, alt = original[key]
        restored = f"[PHOTO: {name} | {alt}]"
        if match.group(0) != restored:
            drift += 1
        return restored

    spliced = _PHOTO_MARKER.sub(_restore, produced)

    missing = sorted(k for k in wanted if k in original and k not in seen)
    if missing:
        raise ValueError(
            "the model dropped photo markers it was told to reproduce: "
            + ", ".join(original[k][0] for k in missing)
            + ". They cannot be put back without inventing a position for "
              "them, so the caller falls back rather than guessing (#998).")

    return spliced, drift
