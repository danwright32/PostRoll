"""
PostRoll — OCR Enrichment via Web Research

When OCR output is thin (common for plays, rock shows, improv nights, dance
performances — anything where the program is just a marketing blurb),
automatically enrich the data by searching the web for cast, creative team,
director, playwright, band members, tour info, etc.

The user can optionally pass a `hint` which is either freeform text (e.g.
"The Pushover at Chain Theatre") or a URL (e.g.
https://www.chaintheatre.org/the-pushover). A URL is a STARTING point for
research, not a stopping point — Claude fetches it for initial context,
then keeps searching the web for additional facts.

Enrichment preserves existing OCR data and fills in gaps. It should not
overwrite fields that already have content from the physical program.

Usage:
    python -m postroll.ai.enrich_program \\
        --program output/program.json \\
        --image path/to/program.heic \\
        --hint "https://www.chaintheatre.org/the-pushover" \\
        --output output/program_enriched.json
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from .claude_client import run_json_prompt, ClaudeError
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


# Thresholds for "thin" detection — all must be true for enrichment to trigger
THIN_MAX_PERFORMERS = 1
THIN_MAX_PIECES = 1
THIN_MAX_NOTES_CHARS = 500  # combined organization_notes + program_notes + production_details


def is_thin(ocr_data: dict[str, Any]) -> bool:
    """Heuristic: does this OCR output need web research enrichment?

    Returns True when the program gave us almost nothing to work with —
    empty or near-empty performer list, empty or near-empty pieces list,
    and minimal narrative notes. That's the signature of a play/rock
    show/improv night where the program is just a marketing blurb.
    """
    performers = ocr_data.get("performers") or []
    pieces = ocr_data.get("pieces") or []
    notes = (
        (ocr_data.get("organization_notes") or "")
        + (ocr_data.get("program_notes") or "")
        + (ocr_data.get("production_details") or "")
    )
    return (
        len(performers) <= THIN_MAX_PERFORMERS
        and len(pieces) <= THIN_MAX_PIECES
        and len(notes) < THIN_MAX_NOTES_CHARS
    )


PROMPT_TEMPLATE = """\
You are enriching thin OCR output from a performing arts event program by
researching the web. The program didn't give Dan much — maybe just a
marketing tagline, a short blurb, or a cover image. Your job is to figure
out what the event actually is and fill in the gaps so a blog post and
captions can be written about it.

The event could be any genre of live performance: a play, musical, opera,
classical concert, rock show, dance performance, improv night — anything.
Don't assume classical music.

Current (thin) OCR data:
```json
{ocr_json}
```

Original program images (read them to extract any identifying text —
titles, taglines, venue names, dates, logos, production credits):
{image_list}

{hint_section}

Your process:

1. **Read the program images first.** Extract whatever identifying text
   you can see — title, tagline, venue, dates, production company, QR
   code destinations, logos. This is your strongest signal for what to
   search for.
{hint_process}
3. **Use WebSearch** to find additional context beyond the hint (if given)
   or to identify the event from scratch (if no hint). Search for:
   - The specific event title + venue + year
   - Reviews or previews of the production
   - The production company or organization
   - Cast, creative team, director, playwright, composer, choreographer
   - Run dates, any tour info
   - Anything about the work itself (history, themes, context) that would
     help write a specific blog post
4. **Cross-reference.** If the hint URL is for a different production or
   the same title from a different year, notice that and keep searching
   until you're confident you have the right event.
5. **Merge findings into the OCR schema.** Preserve anything already in
   the OCR data — don't overwrite existing fields that have real content.
   Only fill in gaps.

Return JSON ONLY (no markdown fences, no commentary) matching this schema:

{{
  "performers": [
    {{
      "name": "string",
      "role": "soloist | conductor | ensemble | composer | actor | dancer | band_member | troupe | director | other",
      "voice_or_instrument": "string or null"
    }}
  ],
  "pieces": [
    {{
      "composer": "string — creator of this work (composer/playwright/choreographer/band/etc)",
      "title": "string",
      "movements": ["string", ...],
      "notes": "string or null"
    }}
  ],
  "scenes": [
    {{
      "name": "short label like 'spa scene' or 'Act II finale' or 'second movement'",
      "location": "where this scene takes place if relevant, or null",
      "visual_cues": "what would visually distinguish this scene from others — set design, lighting, costumes, props that someone could recognize from a photo",
      "description": "what happens in this scene, if known, or null"
    }}
  ],
  "organization_notes": "string",
  "program_notes": "string",
  "venue_notes": "string",
  "production_details": "string — director, creative team, run dates, tour info",
  "other": "string",
  "_enrichment": {{
    "researched_event_identity": "short description of what you concluded this event is, e.g. 'The Pushover by Kate Gill at Chain Theatre, Feb-Mar 2026'",
    "sources_used": ["list of URLs or search query results you relied on"],
    "enriched_fields": ["list of field paths that came from web research vs. original OCR, e.g. ['performers', 'production_details', 'program_notes']"],
    "confidence": "high | medium | low",
    "notes_for_human": "anything the photographer should double-check before publishing — conflicts between sources, ambiguity about which production, dates that don't quite match, etc."
  }}
}}

Rules:
- The `_enrichment` block is required on enriched output — it's how the
  GUI knows what came from research vs. the program itself. Flag pass
  will be extra skeptical of enriched fields.
- For `scenes`, look for any mention of distinct settings, locations,
  scenes, sets, acts, or sections in the synopsis/reviews/web research.
  Populate one entry per distinct scene with the strongest visual_cues
  you can find. The caption generator uses this list to label which
  scene each photo shows. Even partial info (just a name + a one-line
  visual cue) is better than an empty list.
- Don't fabricate. If you can't find solid information about something,
  leave the field empty rather than guessing. Note the gap in
  `notes_for_human`.
- Don't pull in facts about a different production just because the title
  matches. Pay attention to venue, year, and creative team to disambiguate.
- Return ONLY the JSON object. No explanation before or after.
"""


HINT_SECTION_WITH = """\
Hint from the photographer (use this as a starting point but DON'T stop
here — always search for more context beyond the hint):
{hint}
"""

HINT_SECTION_WITHOUT = """\
No hint was provided. Identify the event from the program images alone.
"""


def _hint_looks_like_url(hint: str) -> bool:
    return hint.strip().lower().startswith(("http://", "https://"))


def _build_hint_sections(hint: str | None) -> tuple[str, str]:
    """Return (hint_section, hint_process_step_2) tuple for the prompt."""
    if not hint:
        return HINT_SECTION_WITHOUT, ""
    section = HINT_SECTION_WITH.format(hint=hint)
    if _hint_looks_like_url(hint):
        process = (
            "2. **Fetch the hint URL first.** The photographer gave you a URL: "
            f"{hint.strip()}\n"
            "   Use WebFetch to pull it in for initial context. This is the\n"
            "   starting point, NOT the final answer — still do step 3.\n"
        )
    else:
        process = (
            "2. **Use the text hint as a search seed.** The photographer said: "
            f"{hint.strip()!r}\n"
            "   Search for this in combination with venue and dates to narrow down.\n"
        )
    return section, process


def enrich_program(
    ocr_data: dict[str, Any],
    image_paths: list[str | Path],
    hint: str | None = None,
) -> dict[str, Any]:
    """Enrich thin OCR output by researching the web.

    Args:
        ocr_data: Current (thin) OCR output from ocr_program.
        image_paths: Original program images.
        hint: Optional URL or freeform text. URLs are starting points,
              not stopping points — Claude still searches beyond them.

    Returns:
        Enriched dict with the same schema as OCR output, plus an
        `_enrichment` metadata block noting which fields came from
        research.
    """
    if not image_paths:
        raise ValueError("At least one image path is required")

    hint_section, hint_process = _build_hint_sections(hint)

    with tempfile.TemporaryDirectory(prefix="postroll-enrich-") as tmp:
        tmp_path = Path(tmp)
        staged: list[str] = []
        for i, p in enumerate(image_paths):
            src = Path(p).expanduser().resolve()
            if not src.exists():
                raise FileNotFoundError(f"Program image not found: {src}")
            if src.suffix.lower() in HEIC_SUFFIXES:
                dest = _convert_heic_to_jpeg(src, tmp_path)
            else:
                dest = tmp_path / f"{i:03d}_{src.name}"
                shutil.copy2(src, dest)
            staged.append(str(dest))

        image_list = "\n".join(f"- {p}" for p in staged)

        prompt = PROMPT_TEMPLATE.format(
            ocr_json=json.dumps(ocr_data, indent=2, ensure_ascii=False),
            image_list=image_list,
            hint_section=hint_section,
            hint_process=hint_process,
        )

        data = run_json_prompt(
            prompt,
            timeout=900,  # web research can take a while
            allowed_dirs=[tmp_path],
            allowed_tools=["Read", "WebSearch", "WebFetch"],
        )

    if not isinstance(data, dict):
        raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

    # Fill any missing keys with empty defaults so downstream code is safe
    result = {
        "performers": data.get("performers", ocr_data.get("performers", [])),
        "pieces": data.get("pieces", ocr_data.get("pieces", [])),
        "scenes": data.get("scenes", ocr_data.get("scenes", [])),
        "organization_notes": data.get(
            "organization_notes", ocr_data.get("organization_notes", "")
        ),
        "program_notes": data.get(
            "program_notes", ocr_data.get("program_notes", "")
        ),
        "venue_notes": data.get("venue_notes", ocr_data.get("venue_notes", "")),
        "production_details": data.get(
            "production_details", ocr_data.get("production_details", "")
        ),
        "other": data.get("other", ocr_data.get("other", "")),
        "_enrichment": data.get("_enrichment", {}),
    }
    return result


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Enrich thin OCR output via web research"
    )
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
        help="Path to a program photo (repeat for multi-page)",
    )
    parser.add_argument(
        "--hint",
        help="Optional URL or text hint about the event (e.g. 'https://chaintheatre.org/the-pushover' or 'The Pushover at Chain Theatre')",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Run enrichment even if the OCR data doesn't look thin",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Where to write enriched JSON (defaults to stdout)",
    )
    args = parser.parse_args()

    ocr_data = json.loads(args.program.read_text(encoding="utf-8"))

    if not args.force and not is_thin(ocr_data):
        print(
            "OCR data is not thin — enrichment skipped. Use --force to override.",
            file=sys.stderr,
        )
        return 0

    try:
        enriched = enrich_program(ocr_data, args.image, hint=args.hint)
    except (ClaudeError, FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    text = json.dumps(enriched, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n", encoding="utf-8")
        confidence = enriched.get("_enrichment", {}).get("confidence", "?")
        identity = enriched.get("_enrichment", {}).get("researched_event_identity", "?")
        print(f"wrote {args.output}")
        print(f"  event: {identity}")
        print(f"  confidence: {confidence}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
