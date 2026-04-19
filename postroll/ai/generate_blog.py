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
    build_voice_review_prompt,
    is_humanizer_available,
    load_humanizer_rules,
)
from .claude_client import run_json_prompt, load_brand_voice, ClaudeError
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


# Shared prose rules — imported by revise_blog.py so both prompts stay in sync.
# Update here; revise_blog picks up the change automatically.
BLOG_WRITING_RULES = """\
- NO banned hype words (stunning, magical, breathtaking, unforgettable, etc.).
- NO AI tells (in a world where, it's not just X it's Y, rule-of-three tics).
- NO false intimacy about what performers were feeling.
- Open with a specific observation, NOT "Last Saturday I had the pleasure of...".
- Close with one short, useful sentence. No hard sell. The CTA must use specific
  language grounded in this post — not vague gestures like "this kind of attention"
  or "this kind of work." Name the actual thing: "photography that's watching the
  stage, not waiting for a pose" is better than "photography that pays this kind
  of attention to what happens on stage."
  The CTA cannot arrive as a non-sequitur from the last paragraph about the
  performance. Before the ask, there must be a short transitional beat that places
  Dan in the room — a quiet, factual sentence about what he was doing there while
  all of this was happening. Something like: "I was at the back of the hall for
  most of the night, working quietly while all of that happened." That bridge is
  not optional. The closing moves: [last observation about the performance] →
  [one sentence placing Dan in the room] → [CTA].
- FACTUAL ACCURACY — CRITICAL: Only attribute conducting, soloist roles,
  speaking roles, or any specific performance duties to a named individual
  if the program text EXPLICITLY states it. Do NOT infer from a person's
  title, billing order, or presence on stage that they took a particular
  role in the performance. If the program lists "Jennifer Lucy Cook —
  composer/arranger" and her pieces appear on the program, that does NOT
  mean she conducted them. When attribution is uncertain, describe what is
  visible in the photos instead of asserting a role.
- NOT a program breakdown. Do NOT move piece by piece through the repertoire
  as if reviewing a setlist. The program notes and repertoire are context, not
  an outline. Pick the two or three moments that actually say something and
  build the post around those. A piece that isn't worth a specific observation
  doesn't need a paragraph.
- NO gestural phrases: "that kind of X," "this kind of Y," "that sort of thing."
  Name what the X actually is. If you wrote "that kind of history reads as ease,"
  say what the history IS and why it produces ease.
- NO soft-landing abstractions as substitutes for specific observations: "room to
  open up," "landed differently," "carried the room." If you need to explain what
  you mean in the next sentence, fold the explanation forward into this sentence
  and cut the abstraction.
- NO inanimate objects performing human actions: "The hall took it," "the room
  held," "the stage gave." Rewrite with a human subject or cut the sentence.\
"""


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
- Venue: {venue}{venue_context_line}
- Date: {date}
- Shoot type: {shoot_type}  ← CRITICAL: the prose MUST match what Dan
  actually witnessed.
{event_url_line} See the "Honor what Dan actually witnessed"
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
marker in the body where each photo belongs:
{photo_list}

Photo placement rules:
- Place each photo in the prose at a moment where it makes sense — a
  reference to a specific piece, performer, or moment that the photo
  shows.
- Use this EXACT format on its own line between paragraphs:
    [PHOTO: filename.jpg | alt text description of what is in the photo]
  Where "filename.jpg" is the base filename only (no directory path),
  and the alt text is a specific, useful description for a reader who
  cannot see the image (15-35 words: who, what, where, lighting,
  gestures). Example:
    [PHOTO: 003_DSC4821.jpg | Conductor leading a full chorus from the
    podium at Carnegie Hall, arms raised mid-phrase, blue stage light
    behind the choir risers]
- Use ALL {photo_count} photos. Spread them through the post — not
  clustered at the start or end.

Return JSON ONLY (no markdown fences around the outer object, no
commentary) in this shape:

{{
  "title": "Blog post title — short, specific, no clickbait, no colon-subtitle pattern",
  "body": "Markdown body. 10-12 short paragraphs separated by blank lines. [PHOTO: filename.jpg | alt text] markers placed inline on their own lines. Closes with one quiet, useful CTA.",
  "photo_count": {photo_count}
}}

Reminders:
{blog_writing_rules}
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
    event_url: str = "",
    venue_context: str = "",
    humanizer_path: str | Path | None = None,
    skip_humanizer: bool = False,
    skip_voice_pass: bool = False,
) -> dict[str, Any]:
    """Generate a blog post draft for one event.

    Accepts JPEG, PNG, and HEIC photos. HEIC is converted via sips.

    shoot_type controls how the prose frames what Dan witnessed. Common
    values: "performance", "rehearsal_and_performance", "photo_call",
    "rehearsal", "dress_rehearsal". Any other string is passed through
    verbatim to the prompt for unusual cases.

    Pipeline: draft → voice pass → humanizer pass (3 passes total,
    matching the caption pipeline). The humanizer is always the final
    pass so nothing downstream can re-introduce AI tells.
    skip_humanizer / skip_voice_pass exist for tests only.
    """
    # Auto-select up to 7 photos when more are provided (blog photos are now
    # auto-derived from all Sunday/Monday/Wednesday assignments).
    if len(photo_paths) > 7:
        step = len(photo_paths) / 7
        photo_paths = [photo_paths[round(i * step)] for i in range(7)]

    if len(photo_paths) < 1:
        raise ValueError("No blog photos provided")

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

        # Show clean filenames (without the 000_ staging prefix) in the
        # prompt so [PHOTO:] markers use the original name.
        photo_list = "\n".join(
            f"- {Path(p).name.split('_', 1)[1] if '_' in Path(p).name else Path(p).name}"
            for p in resolved
        )

        brand_voice_text = load_brand_voice()

        event_url_line = (
            f"- Event page URL (additional context): {event_url}"
            if event_url else ""
        )
        # Specific room inside the venue (e.g. Weill Recital Hall inside Carnegie
        # Hall) — used only for prose context. Graphics still show top-level venue.
        venue_context_line = (
            f" — performed in {venue_context.strip()}"
            if venue_context and venue_context.strip() else ""
        )

        # === Pass 1: generate the draft ===
        prompt = PROMPT_TEMPLATE.format(
            brand_voice=brand_voice_text,
            blog_writing_rules=BLOG_WRITING_RULES,
            event=event,
            org=org,
            venue=venue,
            venue_context_line=venue_context_line,
            date=date,
            shoot_type=shoot_type,
            event_url_line=event_url_line,
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
            image_paths=resolved,
        )

        if not isinstance(data, dict):
            raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

        blog_shape = (
            "{title: string, body: string with [PHOTO: filename.jpg | alt text]"
            " markers preserved exactly as-is, photo_count: integer}"
        )

        # === Pass 2: voice review (does this actually sound like Dan?) ===
        if not skip_voice_pass:
            voice_prompt = build_voice_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                brand_voice=brand_voice_text,
                output_shape_description=blog_shape,
            )
            data = run_json_prompt(voice_prompt, timeout=600)
            if not isinstance(data, dict):
                raise ClaudeError(
                    f"Voice pass returned {type(data).__name__}, expected JSON object"
                )

        # === Pass 3: humanizer — always last, non-negotiable ===
        # Runs after the voice pass so it catches any AI tells the voice pass
        # introduced. skip_humanizer exists for tests only.
        if not skip_humanizer and is_humanizer_available(humanizer_path):
            humanizer_rules = load_humanizer_rules(humanizer_path)
            review_prompt = build_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                humanizer_rules=humanizer_rules,
                brand_voice=brand_voice_text,
                output_shape_description=blog_shape,
            )
            data = run_json_prompt(review_prompt, timeout=600)
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
