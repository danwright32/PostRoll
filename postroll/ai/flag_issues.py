"""
PostRoll — OCR Issue Flagger

Second-pass review of OCR output. Looks for likely misreads, implausible
values, and ambiguous entries so the GUI can surface them for human
review before captions/blogs run.

Each flag has a stable id (so the GUI can key on it across re-renders),
a JSON path into the OCR data (as a list of keys/indices), the current
value, a short concern, and a description of where in the program it
came from so Dan has enough context to decide.

Usage:
    python -m postroll.ai.flag_issues \\
        --program output/program.json \\
        --image path/to/program_p1.heic \\
        --image path/to/program_p2.heic \\
        --output output/flags.json
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from .vision_cross_check import VisionTextUnavailable, cross_check_against_vision
from .claude_client import run_json_prompt, ClaudeError
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


PROMPT_TEMPLATE = """\
You are reviewing structured data extracted by OCR from photos of a
classical music event program. Your job is to identify ONLY items that
look suspicious — likely misreads, implausible values, ambiguous
entries, or things a human should double-check before this data gets
used in published captions and a blog post.

DO NOT flag things that just happen to be unusual but are plausible.
Student-composed pieces, long composer names, rare repertoire, and
unusual instrument assignments are all fine. Focus on things that
smell like extraction errors.

Good reasons to flag:
- A composer name that doesn't look like any composer (e.g. looks like
  a piece title or a partial phrase)
- A "special guest" or similar one-word entry that could be a misread
  of something longer
- Performer names with obvious OCR garbles (missing letters, weird
  punctuation)
- Pieces with composer/title swapped
- Entries where the OCR clearly hallucinated content not in the image
- Missing critical content: a piece with no title, a performer with no
  name, a clearly-listed work that's absent from the pieces array

Bad reasons to flag (do NOT flag these):
- Long organization notes (they're supposed to be long)
- Unusual but real composer names
- Duplicates that are actually different performers/pieces
- Empty `production_details`, `venue_notes`, `organization_notes`, or
  `other` just because the program prints the event header (event name,
  date, time, venue, presenter / org). Dan enters those four header
  fields when he creates the event in the app, so a program that ONLY
  contains the basic header at the top is not missing anything. Only
  flag these prose fields when the program clearly contains substantive
  printed content of that type — e.g. a director/creative-team list
  (production_details), a paragraph about the venue (venue_notes), a
  paragraph about the org's mission/history (organization_notes) — that
  was NOT extracted.
- Empty fields in general. The OCR schema is permissive; only flag a
  missing field when there's identifiable printed content in the image
  that should have populated it.

Current OCR data:
```json
{ocr_json}
```

Original program images (read them to compare against the OCR data):
{image_list}

Read the images so you can check what the OCR extracted against what's
actually printed. Return JSON ONLY (no markdown fences, no commentary)
as an array of flag objects:

[
  {{
    "id": "short_stable_slug_like_this",
    "field_path": ["pieces", 5, "composer"],
    "current_value": "whatever is currently in the OCR data at that path",
    "suggested_value": "your best guess at what this field should actually be, based on the printed image",
    "concern": "One sentence explaining why this looks wrong.",
    "program_context": "Short description of where this appeared in the program — which page/section, what surrounding text, what the printed characters actually look like."
  }},
  ...
]

Rules:
- field_path is a JSON path as a list of string keys and integer
  indices, e.g. ["pieces", 5, "composer"] or ["performers", 12, "name"]
  or ["other"] or ["organization_notes"].
- id is a short unique slug (lowercase, underscores). Stable within one
  flag run — doesn't need to match future runs.
- suggested_value MUST be your best guess at the correct value, read
  directly off the printed program image. This pre-fills the
  correction box for Dan, so it should be the value he'd most likely
  accept. If the field should be empty (e.g. a hallucinated entry that
  isn't in the program), use an empty string. Do not echo
  current_value back as the suggestion — that defeats the purpose.
- program_context should give Dan enough to find it on the physical
  page without re-reading the whole program. Mention which image and
  roughly where on the page.
- If NOTHING is suspicious, return an empty array: []
- Flag at most 10 issues. Prioritize the most likely errors.
- Return ONLY the JSON array. No explanation before or after.
"""


def flag_issues(
    ocr_data: dict[str, Any],
    image_paths: list[str | Path],
    vision_text: str | None = None,
) -> list[dict[str, Any]]:
    """Review OCR data + original images and return a list of flags.

    When `vision_text` is supplied it is the text layer Apple Vision baked into
    the program PDF at upload time, and every performer name and handle is
    cross-checked against it first (#209). Those flags are produced in code
    rather than asked of the model, because "does this string appear in that
    text" is exactly checkable and a rule that lives only in a prompt is a hope.
    They come first in the list: a misspelling Vision can disprove outright is
    more certain than anything the review pass infers from the pixels.
    """
    if not image_paths:
        raise ValueError("At least one image path is required")

    # Deliberately NOT wrapped in a try/except. A missing or half-baked text
    # layer raises, because a cross-check that silently produced nothing would
    # be indistinguishable from a program with nothing wrong in it.
    vision_flags = (
        cross_check_against_vision(ocr_data, vision_text) if vision_text is not None else []
    )

    with tempfile.TemporaryDirectory(prefix="postroll-flags-") as tmp:
        tmp_path = Path(tmp)
        staged: list[str] = []
        for i, p in enumerate(image_paths):
            src = Path(p).expanduser().resolve()
            if not src.exists():
                raise FileNotFoundError(f"Program image not found: {src}")
            if src.suffix.lower() in HEIC_SUFFIXES:
                dest = _convert_heic_to_jpeg(src, tmp_path, prefix=f"{i:03d}_")
            else:
                dest = tmp_path / f"{i:03d}_{src.name}"
                shutil.copy2(src, dest)
            staged.append(str(dest))

        image_list = "\n".join(f"- {p}" for p in staged)
        prompt = PROMPT_TEMPLATE.format(
            ocr_json=json.dumps(ocr_data, indent=2, ensure_ascii=False),
            image_list=image_list,
        )

        data = run_json_prompt(
            prompt,
            timeout=600,
            image_paths=staged,
            step="flag_issues",
        )

    if not isinstance(data, list):
        raise ClaudeError(f"Expected JSON array of flags, got {type(data).__name__}")

    # Normalize — fill defaults if model omitted any field
    flags: list[dict[str, Any]] = list(vision_flags)
    for i, raw in enumerate(data):
        if not isinstance(raw, dict):
            continue
        flags.append(
            {
                "id": raw.get("id") or f"flag_{i}",
                "field_path": raw.get("field_path") or [],
                "current_value": raw.get("current_value", ""),
                "suggested_value": raw.get("suggested_value", ""),
                "concern": raw.get("concern", ""),
                "program_context": raw.get("program_context", ""),
            }
        )
    return flags


def main() -> int:
    parser = argparse.ArgumentParser(description="Flag suspicious items in OCR output")
    parser.add_argument(
        "--program",
        type=Path,
        required=True,
        help="Path to OCR program JSON from ocr_program",
    )
    parser.add_argument(
        "--image",
        action="append",
        required=True,
        help="Path to a program photo (repeat for multi-page programs)",
    )
    parser.add_argument(
        "--vision-text",
        type=Path,
        help="Path to the Vision text layer extracted from the program PDF. "
             "When given, every performer name and handle is cross-checked "
             "against it for spelling before the model review runs (#209).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Where to write the flags JSON (defaults to stdout)",
    )
    args = parser.parse_args()

    ocr_data = json.loads(args.program.read_text(encoding="utf-8"))
    vision_text = (
        args.vision_text.read_text(encoding="utf-8") if args.vision_text else None
    )

    try:
        flags = flag_issues(ocr_data, args.image, vision_text=vision_text)
    except (ClaudeError, FileNotFoundError, ValueError, VisionTextUnavailable) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    text = json.dumps(flags, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n", encoding="utf-8")
        print(f"wrote {args.output} ({len(flags)} flags)")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
