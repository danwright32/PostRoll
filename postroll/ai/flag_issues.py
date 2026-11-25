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

from .vision_cross_check import (
    VisionTextUnavailable, cross_check_against_vision, words_not_printed,
)
from .claude_client import run_json_prompt, ClaudeError
from .flag_recommendation import (
    NONE, REMOVE, REPLACE, UNPRINTED, WITHDRAW, recommendation_for,
)

#: The fields that are copied off the page, so a suggested value for one can be
#: held to the program's own text. A role or an instrument is the model's
#: description and is printed nowhere in those words.
COPIED_FROM_THE_PAGE = frozenset({"name", "title", "composer"})


def _field(field_path: list[Any]) -> str:
    """The last key of a path, e.g. "composer"."""
    return next((seg for seg in reversed(field_path) if isinstance(seg, str)), "")
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


# The flags the prompt shows the model, one per recommendation. Kept as data so
# a test can put each through `recommendation_for`: an example that broke the
# rule beside it would teach the model the opposite, with more weight than the
# rule itself (#1653).
#
# The key order is the order the model writes in, and it cannot go back. What
# the page shows and why it looks wrong come first, the recommendation after,
# because asked the other way round it recommended removing a performer and
# then explained that both entries were valid.
EXAMPLE_FLAGS: list[dict[str, Any]] = [
    {
        "id": "gonzalez_missing_letter",
        "field_path": ["performers", 12, "name"],
        "current_value": "Maria Gonzlez",
        "program_context": "Page 1 (image 000), cast list, third name in the left column, printed 'Maria Gonzalez'.",
        "concern": "The printed name has an 'a' the OCR dropped.",
        "recommendation": REPLACE,
        "suggested_value": "Maria Gonzalez",
    },
    {
        "id": "riverside_quartet_listed_twice",
        "field_path": ["performers", 31, "name"],
        "current_value": "Riverside Quartet",
        "program_context": "Page 2 (image 001), guest ensembles, printed once under 'With thanks to'.",
        "concern": "Riverside Quartet is already performers[14], and the program prints it once, so this second entry should go.",
        "recommendation": REMOVE,
        "suggested_value": "",
    },
]

_EXAMPLES_JSON = (
    json.dumps(EXAMPLE_FLAGS, indent=2, ensure_ascii=False)
    .replace("{", "{{").replace("}", "}}")
)


_PROMPT_HEAD = """\
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
as an array of flag objects, shaped like these two:

"""

_PROMPT_TAIL = """

Rules:
- field_path is a JSON path as a list of string keys and integer
  indices, e.g. ["pieces", 5, "composer"] or ["performers", 12, "name"]
  or ["other"] or ["organization_notes"].
- id is a short unique slug (lowercase, underscores). It is stable
  within one flag run and need not match future runs.
- current_value is whatever is in the OCR data at that path now.
- Write the fields in the order shown. program_context is a short
  description of where this appeared in the program: which page and
  section, what surrounding text, what the printed characters actually
  look like. It should give Dan enough to find it on the physical page
  without re-reading the whole program. Mention which image and roughly
  where on the page.
- concern is one sentence explaining why this looks wrong.
- recommendation comes after those two, and follows from them. It is
  what Dan should do about it, and he accepts it with one click, so it
  is one of these two:
  - "replace": the field holds text the program does not print there.
    suggested_value is the text the program DOES print, copied
    character for character off the image. It pre-fills the correction
    box and Dan saves it with one click, so it MUST differ from
    current_value and it must be findable on the page.
  - "remove": the entry the path is in (the performer, piece, scene or
    movement) should not be in the data at all, because the program
    does not print it or because it repeats another entry.
    suggested_value is "", and the concern names the entry that stays
    by its index.
- Never copy current_value into suggested_value. That leaves Dan a row
  with nothing to accept. A concern that an entry is a duplicate or was
  invented is a "remove", not a replacement.
- The printed program is the authority, because Dan's captions follow
  it. When the data already says what the page prints, there is nothing
  to flag, however unusual the spelling or the credit looks. Never
  invent a different spelling to have something to suggest, and never
  replace what is printed with a more usual spelling or with a name you
  know from elsewhere (a songwriter, a standard romanization).
- Check each suspicion against the image BEFORE you start writing its
  flag, and leave out anything that turns out to match. If you only
  find that out partway through a flag, set its recommendation to
  "withdraw" and it will be discarded. Never recommend a replacement or
  a removal for data you have just concluded is right.
- If NOTHING is suspicious, return an empty array: []
- Flag at most 10 issues. Prioritize the most likely errors.
- Return ONLY the JSON array. No explanation before or after.
"""

PROMPT_TEMPLATE = _PROMPT_HEAD + _EXAMPLES_JSON + _PROMPT_TAIL


def vision_flags_or_reason(
    ocr_data: dict[str, Any],
    vision_text: str | None,
) -> tuple[list[dict[str, Any]], str | None]:
    """Cross-check spelling against the Vision text, or say why it could not.

    Returns the flags plus, when the check stood down, the reason in words.

    The reason is returned rather than raised so it can be reported WITHOUT
    taking the rest of the review with it. A program that is a one-page flyer
    has a real text layer holding a handful of words: too thin to be a spelling
    authority, but no reason at all to abandon the ordinary review, which does
    not depend on it. Standing down and cancelling everything else is not
    failing loudly, it is failing wide.
    """
    if vision_text is None:
        return [], None
    try:
        return cross_check_against_vision(ocr_data, vision_text), None
    except VisionTextUnavailable as e:
        return [], str(e)


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

    vision_flags, vision_stood_down = vision_flags_or_reason(ocr_data, vision_text)
    if vision_stood_down:
        # Reported, not swallowed. It stands down alone: the model review below
        # has nothing to do with spelling, and taking it down too would leave
        # Dan with no flags at all on a program that is merely sparse.
        print(f"warning: the spelling cross-check did not run: {vision_stood_down}",
              file=sys.stderr, flush=True)

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
    # The program's text judges a suggestion only where it judged the names:
    # given, and not stood down as too thin to be an authority.
    text_is_authority = vision_text is not None and not vision_stood_down

    flags: list[dict[str, Any]] = list(vision_flags)
    withdrawn: list[str] = []
    unprinted: list[str] = []
    for i, raw in enumerate(data):
        if not isinstance(raw, dict):
            continue
        flag_id = raw.get("id") or f"flag_{i}"
        if raw.get("recommendation") == WITHDRAW:
            # The model's own verdict that the data is right. Showing Dan a
            # row whose note ends "no error, withdrawing" is the defect. Its
            # note is kept, because nothing else records why it was dropped.
            withdrawn.append(f"{flag_id}: {raw.get('concern', '')}")
            continue
        field_path = raw.get("field_path") or []
        current = raw.get("current_value", "")
        suggested = raw.get("suggested_value", "")
        # Decided here from the values, not taken from the model: the prompt's
        # rule that every flag proposes something was being broken on five
        # flags in eight with nothing to show it (#1653).
        recommendation = recommendation_for(
            field_path, current, suggested, asked=raw.get("recommendation"))
        if (recommendation == REPLACE and text_is_authority
                and _field(field_path) in COPIED_FROM_THE_PAGE
                and isinstance(suggested, str)):
            missing = words_not_printed(
                suggested, current if isinstance(current, str) else "", vision_text)
            if missing:
                # Still shown, with the suggestion, but not filled into the box
                # where one click would save it (Dan, 2026-11-25, #1653).
                recommendation = UNPRINTED
                unprinted.append(f"{flag_id} ({', '.join(missing)})")
        flags.append(
            {
                "id": flag_id,
                "field_path": field_path,
                "current_value": current,
                "suggested_value": suggested,
                "recommendation": recommendation,
                "concern": raw.get("concern", ""),
                "program_context": raw.get("program_context", ""),
            }
        )

    # Only the model's flags: a spelling flag with nothing close to suggest is
    # an honest answer, while a model flag with nothing is a broken instruction.
    from_model = flags[len(vision_flags):]
    if withdrawn:
        # Said, so a pass that withdraws everything is not read as a clean one.
        print(f"note: the model withdrew {len(withdrawn)} of "
              f"{len(from_model) + len(withdrawn)} review flags after checking the "
              f"image, and they were discarded:\n  " + "\n  ".join(withdrawn),
              file=sys.stderr, flush=True)
    if unprinted:
        print(f"warning: {len(unprinted)} of {len(from_model)} review flags suggest "
              f"words the program does not print, so they are shown without being "
              f"filled in: {', '.join(unprinted)}",
              file=sys.stderr, flush=True)
    empty = [f["id"] for f in from_model if f["recommendation"] == NONE]
    if empty:
        print(f"warning: {len(empty)} of {len(from_model)} review flags recommend "
              f"nothing, so their rows offer no fix to accept: {', '.join(empty)}",
              file=sys.stderr, flush=True)
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
    except (ClaudeError, FileNotFoundError, ValueError) as e:
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
