"""
PostRoll — Caption Reviser

Revises an existing caption based on Dan's plain-English feedback.
Only caption text and hashtags change; alt texts and scene labels
(photo-derived) are locked and returned unchanged.

Input manifest:
{
  "event": "...",
  "org": "...",
  "venue": "...",
  "date": "...",
  "shoot_type": "...",
  "day": "sunday",
  "program": { ...OCR dict... },
  "existing": {
    "caption": "...",
    "hashtags": [...],
    "alt_texts": [...],
    "scene_labels": [...]
  },
  "feedback": "make it shorter and add @dciny"
}

Output JSON (written to --output file):
{
  "caption": "...",
  "hashtags": [...],
  "alt_texts": [...],    ← unchanged from input
  "scene_labels": [...]  ← unchanged from input
}

Usage:
    python -m postroll.ai.revise_caption \\
        --manifest /path/to/revision.json \\
        --output   /path/to/result.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from .ai_tells import (
    build_review_prompt,
    is_humanizer_available,
    load_humanizer_rules,
)
from .claude_client import run_json_prompt, load_brand_voice, ClaudeError
from .generate_captions import _format_performers


REVISE_PROMPT = """\
{brand_voice}

---

Dan Wright has reviewed the following social media caption for {event}
(posting day: {day}) and wants a revision.

Existing caption:
{caption}

Hashtags:
{hashtags}

Dan's feedback:
{feedback}

Event context:
- Organization: {org}
- Venue: {venue}
- Shoot type: {shoot_type}
- Performers: {performers}

Apply Dan's feedback to revise the caption and hashtags. The brand voice
rules above STILL APPLY to the revision — preserve the structural,
honest tone while making the requested changes.

The alt texts and scene labels are LOCKED — do NOT modify them.

Return JSON in this exact shape (no markdown fences, no commentary):
{{
  "caption": "<revised caption>",
  "hashtags": ["#dwphotony", ...]
}}
"""


def revise_caption(
    *,
    event: str,
    org: str,
    venue: str,
    date: str,
    day: str,
    shoot_type: str = "performance",
    program: dict[str, Any],
    existing: dict[str, Any],
    feedback: str,
    humanizer_path: str | Path | None = None,
    skip_humanizer: bool = False,
) -> dict[str, Any]:
    """Revise an existing caption based on plain-English feedback.

    Alt texts and scene labels from `existing` are preserved unchanged;
    only the caption text and hashtags are revised.
    """
    brand_voice_text = load_brand_voice()

    caption_text  = existing.get("caption", "")
    hashtags      = existing.get("hashtags", [])
    hashtags_text = " ".join(hashtags) if hashtags else "(none)"

    prompt = REVISE_PROMPT.format(
        brand_voice=brand_voice_text,
        event=event,
        day=day,
        org=org,
        venue=venue,
        shoot_type=shoot_type,
        caption=caption_text,
        hashtags=hashtags_text,
        feedback=feedback,
        performers=_format_performers(program.get("performers", [])),
    )

    data = run_json_prompt(prompt, timeout=300)

    if not isinstance(data, dict):
        raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

    output_shape = "{caption: string, hashtags: list of strings}"

    # Humanizer pass — same rules as generation
    if not skip_humanizer and is_humanizer_available(humanizer_path):
        humanizer_rules = load_humanizer_rules(humanizer_path)
        review_prompt = build_review_prompt(
            draft_json=json.dumps(data, ensure_ascii=False, indent=2),
            humanizer_rules=humanizer_rules,
            brand_voice=brand_voice_text,
            output_shape_description=output_shape,
        )
        data = run_json_prompt(review_prompt, timeout=180)
        if not isinstance(data, dict):
            raise ClaudeError(
                f"Humanizer pass returned {type(data).__name__}, expected JSON object"
            )

    # Merge revised text with locked photo-derived fields
    return {
        "caption":      data.get("caption", caption_text).strip(),
        "hashtags":     data.get("hashtags", hashtags),
        "alt_texts":    existing.get("alt_texts", []),
        "scene_labels": existing.get("scene_labels", []),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Revise a PostRoll caption based on feedback")
    parser.add_argument("--manifest", required=True, help="Path to revision manifest JSON")
    parser.add_argument("--output",   required=True, help="Path to write revised output JSON")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"Manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    m = json.loads(manifest_path.read_text(encoding="utf-8"))
    result = revise_caption(
        event=m["event"],
        org=m["org"],
        venue=m["venue"],
        date=m["date"],
        day=m["day"],
        shoot_type=m.get("shoot_type", "performance"),
        program=m["program"],
        existing=m["existing"],
        feedback=m["feedback"],
    )
    Path(args.output).write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"Revised caption written to {args.output}")
