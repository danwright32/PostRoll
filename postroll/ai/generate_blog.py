"""
PostRoll — Blog Post Generator

Generates a Squarespace-ready blog draft for one event in Dan Wright's
brand voice. 10-12 short paragraphs, continuous prose, no headings, with
photo placement markers the GUI can match against actual photos later.

Inputs:
- Event metadata (event name, organization, venue, date)
- Full OCR output dict from ocr_program (uses everything)
- List of selected photo paths (4-7 photos)

Output:
    {
      "title": "Blog post title",
      "body": "Markdown body with [PHOTO: ...] markers inline",
      "photo_count": 5
    }

Usage:
    python -m postroll.ai.generate_blog \\
        --event "Sing Play" \\
        --org "DCINY" \\
        --venue "Carnegie Hall" \\
        --date 2026-04-05 \\
        --program path/to/program.json \\
        --photo path/to/p1.jpg --photo path/to/p2.jpg --photo path/to/p3.jpg \\
        --photo path/to/p4.jpg --photo path/to/p5.jpg \\
        --output output/blog.md
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from .ai_tells import (
    build_review_prompt,
    is_humanizer_available,
    load_humanizer_rules,
)
from .claude_client import run_json_prompt, load_brand_voice, ClaudeError
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


PROMPT_TEMPLATE = """\
{brand_voice}

---

Your task: write a blog post draft for Dan Wright's website about an
event he photographed. Follow the blog post rules in the brand voice
above EXACTLY — 10-12 short paragraphs, continuous prose, no headings,
no bullets, no section breaks.

Event details:
- Event name: {event}
- Organization: {org}
- Venue: {venue}
- Date: {date}
- Shoot type: {shoot_type}  ← CRITICAL: the prose MUST match what Dan
  actually witnessed. See the "Honor what Dan actually witnessed"
  section in the brand voice above. If shoot_type is photo_call or
  rehearsal, do NOT describe an audience, applause, a curtain call, or
  the arc of a performance. Frame it honestly as the access Dan had.

Performers (from program OCR):
{performers}

Repertoire (from program OCR):
{pieces}

Organization notes (from program OCR — use this to add depth, ONCE,
naturally, not as a press release paragraph):
{organization_notes}

Program notes (from program OCR — composer/piece context to weave into
the discussion of each piece):
{program_notes}

Venue notes (from program OCR):
{venue_notes}

Production details (director, creative team, run dates, tour info):
{production_details}

Other printed content (from program OCR):
{other}

Photos selected for this post ({photo_count} total). READ EACH ONE so
the prose can refer to what's actually visible in them, then place a
[PHOTO: short description] marker in the body where each photo belongs:
{photo_list}

Photo placement rules:
- Place each photo in the prose at a moment where it makes sense — a
  reference to a specific piece, performer, or moment that the photo
  shows.
- Use the format [PHOTO: brief description] on its own line between
  paragraphs. The description should match what's actually in that
  specific image so a human (or the GUI) can pair them up later.
- Use ALL {photo_count} photos. Spread them through the post — not
  clustered at the start or end.

Return JSON ONLY (no markdown fences around the outer object, no
commentary) in this shape:

{{
  "title": "Blog post title — short, specific, no clickbait, no colon-subtitle pattern",
  "body": "Markdown body. 10-12 short paragraphs separated by blank lines. [PHOTO: ...] markers placed inline on their own lines. Closes with one quiet, useful CTA.",
  "photo_count": {photo_count}
}}

Reminders:
- NO banned hype words (stunning, magical, breathtaking, unforgettable, etc.).
- NO AI tells (in a world where, it's not just X it's Y, rule-of-three tics).
- NO false intimacy about what performers were feeling.
- Open with a specific observation, NOT "Last Saturday I had the pleasure of...".
- Close with one short, useful sentence. No hard sell.
- Inside the JSON "body" string, escape newlines as \\n so the JSON parses cleanly.
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
        notes = p.get("notes")
        line = f"- {composer} — {title}"
        if notes:
            line += f"\n    notes: {notes}"
        lines.append(line)
    return "\n".join(lines)


def generate_blog(
    *,
    event: str,
    org: str,
    venue: str,
    date: str,
    program: dict[str, Any],
    photo_paths: list[str | Path],
    shoot_type: str = "performance",
    humanizer_path: str | Path | None = None,
    skip_humanizer: bool = False,
) -> dict[str, Any]:
    """Generate a blog post draft for one event.

    Accepts JPEG, PNG, and HEIC photos. HEIC is converted via sips.

    shoot_type controls how the prose frames what Dan witnessed. Common
    values: "performance", "rehearsal_and_performance", "photo_call",
    "rehearsal", "dress_rehearsal". Any other string is passed through
    verbatim to the prompt for unusual cases.

    The second-pass humanizer review runs by default if the humanizer
    skill is installed at ~/.claude/skills/humanizer/SKILL.md. Pass
    `skip_humanizer=True` to skip (mostly used in tests).
    """
    if not (4 <= len(photo_paths) <= 7):
        raise ValueError(
            f"Blog posts use 4-7 photos per the brand voice; got {len(photo_paths)}"
        )

    with tempfile.TemporaryDirectory(prefix="postroll-blog-") as tmp:
        tmp_path = Path(tmp)
        resolved: list[str] = []
        for i, p in enumerate(photo_paths):
            path = Path(p).expanduser().resolve()
            if not path.exists():
                raise FileNotFoundError(f"Photo not found: {path}")
            if path.suffix.lower() in HEIC_SUFFIXES:
                staged = _convert_heic_to_jpeg(path, tmp_path)
            else:
                staged = tmp_path / f"{i:03d}_{path.name}"
                shutil.copy2(path, staged)
            resolved.append(str(staged))

        photo_list = "\n".join(f"- {p}" for p in resolved)

        brand_voice_text = load_brand_voice()

        # === Pass 1: generate the draft ===
        prompt = PROMPT_TEMPLATE.format(
            brand_voice=brand_voice_text,
            event=event,
            org=org,
            venue=venue,
            date=date,
            shoot_type=shoot_type,
            performers=_format_performers(program.get("performers", [])),
            pieces=_format_pieces(program.get("pieces", [])),
            organization_notes=program.get("organization_notes") or "(none)",
            program_notes=program.get("program_notes") or "(none)",
            venue_notes=program.get("venue_notes") or "(none)",
            production_details=program.get("production_details") or "(none)",
            other=program.get("other") or "(none)",
            photo_count=len(resolved),
            photo_list=photo_list,
        )

        data = run_json_prompt(
            prompt,
            timeout=600,
            allowed_dirs=[tmp_path],
            allowed_tools=["Read"],
        )

        if not isinstance(data, dict):
            raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

        # === Pass 2: humanizer review-and-revise against brand voice + AI tells ===
        if not skip_humanizer and is_humanizer_available(humanizer_path):
            humanizer_rules = load_humanizer_rules(humanizer_path)
            review_prompt = build_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                humanizer_rules=humanizer_rules,
                brand_voice=brand_voice_text,
                output_shape_description="{title: string, body: string with [PHOTO: ...] markers preserved, photo_count: integer}",
            )
            data = run_json_prompt(
                review_prompt,
                timeout=600,
            )
            if not isinstance(data, dict):
                raise ClaudeError(
                    f"Humanizer pass returned {type(data).__name__}, expected JSON object"
                )

    return {
        "title": data.get("title", "").strip(),
        "body": data.get("body", "").strip(),
        "photo_count": len(resolved),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a blog post draft")
    parser.add_argument("--event", required=True, help="Event name")
    parser.add_argument("--org", required=True, help="Organization")
    parser.add_argument("--venue", required=True, help="Venue")
    parser.add_argument("--date", required=True, help="Event date (YYYY-MM-DD)")
    parser.add_argument(
        "--program",
        type=Path,
        required=True,
        help="Path to program JSON from ocr_program",
    )
    parser.add_argument(
        "--shoot-type",
        default="performance",
        help="What Dan actually witnessed: performance, rehearsal_and_performance, photo_call, rehearsal, dress_rehearsal, or free text",
    )
    parser.add_argument(
        "--humanizer-path",
        type=Path,
        help="Path to humanizer SKILL.md (defaults to ~/.claude/skills/humanizer/SKILL.md)",
    )
    parser.add_argument(
        "--skip-humanizer",
        action="store_true",
        help="Skip the humanizer review pass (faster but lower quality)",
    )
    parser.add_argument(
        "--photo",
        action="append",
        required=True,
        type=Path,
        help="Photo to embed (repeat 4-7 times)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Where to write the blog draft (defaults to stdout)",
    )
    args = parser.parse_args()

    program = json.loads(args.program.read_text(encoding="utf-8"))

    try:
        result = generate_blog(
            event=args.event,
            org=args.org,
            venue=args.venue,
            date=args.date,
            program=program,
            photo_paths=args.photo,
            shoot_type=args.shoot_type,
            humanizer_path=args.humanizer_path,
            skip_humanizer=args.skip_humanizer,
        )
    except (ClaudeError, FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        # Write the markdown body to .md and the metadata alongside
        args.output.write_text(
            f"# {result['title']}\n\n{result['body']}\n", encoding="utf-8"
        )
        meta_path = args.output.with_suffix(".json")
        meta_path.write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"wrote {args.output}")
        print(f"wrote {meta_path}")
    else:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
