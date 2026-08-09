"""Re-attach program notes to the works they describe after a split (#219).

`PROMPT_TEMPLATE` tells the model to find a piece-specific paragraph in a
separate Program Notes section, "even on a later page", and attach it to the
matching work. Batching a large program into several requests (#216) means the
model can no longer see the work listing and the notes section in the same
call, so on programs big enough to split, those notes go unmatched.

A quality regression rather than a failure, introduced as a side effect of
fixing the request size limit, and only on programs of roughly eight pages or
more.

The repair is one text-only pass over the merged result. No images, so it
cannot approach the size limit that forced the split in the first place, and it
costs almost nothing.
"""

from __future__ import annotations

import sys
from typing import Any, Callable

PROMPT = """\
Below is a list of works from a concert or theatre program, and the program
notes text printed elsewhere in the same program.

Some paragraphs in the notes describe a specific work. Match each such
paragraph to the work it is about.

RULES
- Only match a paragraph that is clearly about that specific work. If a
  paragraph is about the composer's life, the ensemble, the venue, or the
  evening in general, leave it out.
- Do not invent, summarise or rewrite. Copy the paragraph text as printed.
- A work with no matching paragraph is simply absent from your answer.
- Match on the work, not on word overlap. A paragraph naming a different piece
  by the same composer belongs to that other piece, or to neither.

WORKS
{works}

PROGRAM NOTES
{notes}

Return JSON ONLY, an object keyed by the exact work title as given above:
{{"<work title>": "<the paragraph about it, verbatim>"}}
Return {{}} if nothing matches.
"""


def needs_stitch(data: dict[str, Any], *, batch_count: int) -> bool:
    """Whether the repair pass is worth a call.

    Only after an actual split, only when there are works without notes, and
    only when there is notes prose that might describe them. Any other case
    would be paying for a call that cannot change anything.
    """
    if batch_count < 2:
        return False
    pieces = data.get("pieces")
    if not isinstance(pieces, list) or not pieces:
        return False
    if not any(isinstance(p, dict) and not (p.get("notes") or "").strip()
               for p in pieces):
        return False
    notes = data.get("program_notes")
    return isinstance(notes, str) and bool(notes.strip())


def stitch_notes(data: dict[str, Any], *, batch_count: int,
                 runner: Callable[..., Any] | None = None) -> dict[str, Any]:
    """Attach each notes paragraph to the work it describes.

    Returns the data unchanged on any failure. This runs after a program has
    already been read successfully, so a repair that goes wrong must not cost
    the read: a work with unmatched notes is a lesser problem than no program.
    """
    if not needs_stitch(data, batch_count=batch_count):
        return data

    if runner is None:
        from .claude_client import run_json_prompt as runner  # type: ignore

    pieces = data["pieces"]
    titles = [str(p.get("title", "")).strip() for p in pieces
              if isinstance(p, dict) and str(p.get("title", "")).strip()]
    if not titles:
        return data

    prompt = PROMPT.format(
        works="\n".join(f"- {t}" for t in titles),
        notes=data["program_notes"],
    )
    try:
        matched = runner(prompt, timeout=300, step="ocr:stitch_notes")
    except Exception as e:  # noqa: BLE001 - the program is already read
        print(f"warning: could not match program notes to works: {e}",
              file=sys.stderr, flush=True)
        return data
    if not isinstance(matched, dict):
        print(f"warning: notes matching returned {type(matched).__name__}, "
              "leaving works as they are", file=sys.stderr, flush=True)
        return data

    by_title = {t.strip().lower(): t for t in matched if isinstance(t, str)}
    out = dict(data)
    updated = []
    filled = 0
    for piece in pieces:
        if not isinstance(piece, dict):
            updated.append(piece)
            continue
        title = str(piece.get("title", "")).strip().lower()
        existing = (piece.get("notes") or "").strip()
        # Never overwrite a note the page-level read already found: that one
        # saw the work and its paragraph together, which is better evidence.
        if existing or title not in by_title:
            updated.append(piece)
            continue
        note = matched[by_title[title]]
        if not isinstance(note, str) or not note.strip():
            updated.append(piece)
            continue
        piece = dict(piece)
        piece["notes"] = note.strip()
        filled += 1
        updated.append(piece)

    if filled:
        print(f"[ocr] matched program notes to {filled} work(s) after the split",
              file=sys.stderr, flush=True)
    out["pieces"] = updated
    return out
