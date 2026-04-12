"""
PostRoll — Caption Generator

Generates a single caption + alt text for one post, in Dan Wright's brand
voice. The same caption is used across Instagram, Facebook, TikTok,
Pinterest, and Bluesky.

Inputs:
- Event metadata (event name, organization, venue, date)
- OCR output dict from ocr_program (uses performers + pieces)
- Photo path (for visual context — what's actually in the frame)
- Day of week (Sun/Mon/Wed) — informs framing for the post type

Output dict:
    {
      "caption": "1-2 sentences",
      "hashtags": ["#dwphotony", ...],
      "alt_text": "15-25 word description"
    }

Usage:
    python -m postroll.ai.generate_captions \\
        --event "Sing Play" \\
        --org "DCINY" \\
        --venue "Carnegie Hall" \\
        --date 2026-04-05 \\
        --photo path/to/photo.jpg \\
        --program path/to/program.json \\
        --day sunday
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from .ai_tells import format_for_prompt as _format_ai_tells
from .ai_tells import get_ai_tells_list
from .claude_client import run_json_prompt, load_brand_voice, ClaudeError
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


PROMPT_TEMPLATE = """\
{brand_voice}
{ai_tells_section}
---

Your task: write ONE social media caption + hashtags + alt text for a
photo from this event. The caption is identical across Instagram,
Facebook, TikTok, Pinterest, and Bluesky.

Event details:
- Event name: {event}
- Organization: {org}
- Venue: {venue}
- Date: {date}
- Day of week posting: {day}
- Shoot type: {shoot_type}  ← CRITICAL: match the caption to what Dan
  actually witnessed. If shoot_type is photo_call, do NOT mention
  applause, audience reactions, or performance moments that require
  an audience. Frame it as a scene being performed for the camera.

Performers (from program OCR):
{performers}

Repertoire (from program OCR):
{pieces}

Photo to caption: {photo_path}

Read the photo so you can refer to what's actually visible in the frame.
The caption should be grounded in this specific image — not generic
"what a great concert" prose.

Return JSON ONLY in this shape (no markdown fences, no commentary):

{{
  "caption": "1-2 sentences in Dan's voice. Concrete observation about the photo, performance, piece, or moment.",
  "hashtags": ["#dwphotony", "#venuetag", "#orgtag", "#performertag", "#additional1", "#additional2"],
  "alt_text": "15-25 word plain description of what's in the frame for screen readers."
}}

Hashtag rules (re-stated for emphasis):
- ALWAYS include #dwphotony.
- Include a venue hashtag derived from "{venue}".
- Include an organization hashtag derived from "{org}".
- Include performer/conductor hashtags if any are listed above.
- Add 2-3 relevant tags (genre, instrument, repertoire, city).
- Total 6-10 hashtags. No padding.

Caption rules (re-stated):
- 1-2 sentences. One is often enough.
- Specific observation > generic praise.
- NO banned hype words (stunning, breathtaking, magical, etc.).
- NO false intimacy ("you could feel...", "the audience knew...").
- NO emoji.
- Lowercase or sentence case is fine — match Dan's natural register.
"""


def _format_performers(performers: list[dict[str, Any]]) -> str:
    if not performers:
        return "(none listed)"
    lines = []
    for p in performers:
        name = p.get("name", "?")
        role = p.get("role", "")
        instr = p.get("voice_or_instrument") or ""
        bits = [name]
        if role:
            bits.append(f"({role}{', ' + instr if instr else ''})")
        elif instr:
            bits.append(f"({instr})")
        lines.append("- " + " ".join(bits))
    return "\n".join(lines)


def _format_pieces(pieces: list[dict[str, Any]]) -> str:
    if not pieces:
        return "(none listed)"
    lines = []
    for p in pieces:
        composer = p.get("composer", "?")
        title = p.get("title", "?")
        lines.append(f"- {composer} — {title}")
    return "\n".join(lines)


def generate_caption(
    *,
    event: str,
    org: str,
    venue: str,
    date: str,
    day: str,
    photo_path: str | Path,
    program: dict[str, Any],
    shoot_type: str = "performance",
    ai_tells_cache: str | Path | None = None,
) -> dict[str, Any]:
    """Generate caption + hashtags + alt text for a single post.

    Accepts JPEG, PNG, and HEIC photos. HEIC is converted via sips.

    shoot_type controls how the prose frames what Dan witnessed. Common
    values: "performance", "rehearsal_and_performance", "photo_call",
    "rehearsal", "dress_rehearsal". Any other string is passed through
    verbatim to the prompt for unusual cases.

    ai_tells_cache, if provided, is a path to a per-project cache file
    holding the latest AI writing signals from Wikipedia. The list is
    injected into the prompt and Claude self-reviews against it before
    returning.
    """
    photo = Path(photo_path).expanduser().resolve()
    if not photo.exists():
        raise FileNotFoundError(f"Photo not found: {photo}")

    with tempfile.TemporaryDirectory(prefix="postroll-caption-") as tmp:
        tmp_path = Path(tmp)
        # Stage the photo into the temp dir (convert HEIC, copy others)
        if photo.suffix.lower() in HEIC_SUFFIXES:
            staged = _convert_heic_to_jpeg(photo, tmp_path)
        else:
            staged = tmp_path / photo.name
            shutil.copy2(photo, staged)

        ai_tells_section = ""
        if ai_tells_cache:
            ai_tells_text = get_ai_tells_list(ai_tells_cache)
            ai_tells_section = "\n" + _format_ai_tells(ai_tells_text)

        prompt = PROMPT_TEMPLATE.format(
            brand_voice=load_brand_voice(),
            ai_tells_section=ai_tells_section,
            event=event,
            org=org,
            venue=venue,
            date=date,
            day=day,
            shoot_type=shoot_type,
            performers=_format_performers(program.get("performers", [])),
            pieces=_format_pieces(program.get("pieces", [])),
            photo_path=str(staged),
        )

        data = run_json_prompt(
            prompt,
            timeout=300,
            allowed_dirs=[tmp_path],
            allowed_tools=["Read"],
        )

    if not isinstance(data, dict):
        raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

    return {
        "caption": data.get("caption", "").strip(),
        "hashtags": data.get("hashtags", []),
        "alt_text": data.get("alt_text", "").strip(),
    }


def format_for_post(result: dict[str, Any]) -> str:
    """Render the caption + hashtags as it would actually be posted."""
    caption = result["caption"]
    tags = " ".join(result.get("hashtags", []))
    return f"{caption}\n\n{tags}".rstrip()


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a caption for one post")
    parser.add_argument("--event", required=True, help="Event name")
    parser.add_argument("--org", required=True, help="Organization")
    parser.add_argument("--venue", required=True, help="Venue")
    parser.add_argument("--date", required=True, help="Event date (YYYY-MM-DD)")
    parser.add_argument(
        "--day",
        required=True,
        choices=["sunday", "monday", "wednesday"],
        help="Day of week the post will be published",
    )
    parser.add_argument(
        "--shoot-type",
        default="performance",
        help="What Dan actually witnessed: performance, rehearsal_and_performance, photo_call, rehearsal, dress_rehearsal, or free text",
    )
    parser.add_argument(
        "--ai-tells-cache",
        type=Path,
        help="Path to per-project AI tells cache. Fetched from Wikipedia if missing/stale.",
    )
    parser.add_argument("--photo", required=True, type=Path, help="Photo to caption")
    parser.add_argument(
        "--program",
        type=Path,
        help="Path to program JSON from ocr_program (optional but recommended)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Where to write the JSON result (defaults to stdout)",
    )
    args = parser.parse_args()

    program: dict[str, Any] = {}
    if args.program:
        program = json.loads(args.program.read_text(encoding="utf-8"))

    try:
        result = generate_caption(
            event=args.event,
            org=args.org,
            venue=args.venue,
            date=args.date,
            day=args.day,
            photo_path=args.photo,
            program=program,
            shoot_type=args.shoot_type,
            ai_tells_cache=args.ai_tells_cache,
        )
    except (ClaudeError, FileNotFoundError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    text = json.dumps(result, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n", encoding="utf-8")
        print(f"wrote {args.output}")
    else:
        print(text)
        print()
        print("--- as it would post ---")
        print(format_for_post(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
