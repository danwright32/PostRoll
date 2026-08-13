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
    strip_em_dashes,
)
from .blog_quality import finding_entry
from .caption_credits import credit_findings
from .claude_client import run_json_prompt, run_review_pass, load_brand_voice, ClaudeError
from .performer_hashtags import strip_performer_hashtags
from .generate_captions import (
    _enforce_caption_bans,
    _format_performers,
    dedupe_credit_stack,
)


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
- Venue: {venue}{venue_context_line}
- Shoot type: {shoot_type}
- Performers: {performers}

Apply Dan's feedback to revise the caption and hashtags. The brand voice
rules above STILL APPLY to the revision — preserve the structural,
honest tone while making the requested changes.

The alt texts and scene labels are LOCKED — do NOT modify them.

Return JSON in this exact shape (no markdown fences, no commentary):
{{
  "caption": "<revised caption>",
  "hashtags": ["#dwphotony", ...],
  "famous_people": ["<any performer above you judge genuinely famous>", ...]
}}

`famous_people` is how a genuinely famous performer keeps their hashtag: list
only people who are household names or major figures in their field, and leave
it empty otherwise. It is not shown to anyone; it is read by the check that
removes ordinary performers' name tags. Leaving it out of your answer strips
those tags, so answer it on every revision even when nothing about the
hashtags changed.
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
    venue_context: str = "",
    tag_handles: list[str] | None = None,
    name_mentions: list[str] | None = None,
    photo_tags: dict[str, list[str]] | None = None,
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

    venue_context_line = (
        f" — performed in {venue_context.strip()}"
        if venue_context and venue_context.strip() else ""
    )

    prompt = REVISE_PROMPT.format(
        brand_voice=brand_voice_text,
        event=event,
        day=day,
        org=org,
        venue=venue,
        venue_context_line=venue_context_line,
        shoot_type=shoot_type,
        caption=caption_text,
        hashtags=hashtags_text,
        feedback=feedback,
        performers=_format_performers(program.get("performers", [])),
    )

    data = run_json_prompt(prompt, timeout=300, step="revise_caption")

    if not isinstance(data, dict):
        raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

    output_shape = ("{caption: string, hashtags: list of strings, "
                    "famous_people: list of strings}")

    # Humanizer pass — same rules as generation
    if not skip_humanizer and is_humanizer_available(humanizer_path):
        humanizer_rules = load_humanizer_rules(humanizer_path)
        review_prompt = build_review_prompt(
            draft_json=json.dumps(data, ensure_ascii=False, indent=2),
            humanizer_rules=humanizer_rules,
            brand_voice=brand_voice_text,
            output_shape_description=output_shape,
        )
        data = run_review_pass(review_prompt, data, label="humanizer", timeout=180, runner=run_json_prompt)

    # Every deterministic pass generation applies, in the same order (#476).
    # A revision is a live route back into the caption, and "add a call to
    # action" or "add more tags" is exactly the request that reintroduces what
    # these gates exist to remove. Running one of the three here meant the
    # other two only ever held on a caption Dan never asked to change.
    revised_caption = dedupe_credit_stack(_enforce_caption_bans(
        strip_em_dashes(data.get("caption", caption_text).strip()),
        tag_handles=tag_handles, name_mentions=name_mentions))

    # Merge revised text with locked photo-derived fields
    return {
        "caption":      revised_caption,
        # The same gate the first pass runs (#199), with the same inputs. It
        # judged against the program alone while the manifest withheld the
        # other three, so a person credited by plain name or tagged on a photo
        # could keep a hashtag the generation path would have removed.
        "hashtags":     strip_performer_hashtags(
            data.get("hashtags", hashtags),
            program=program,
            name_mentions=name_mentions,
            photo_tags=photo_tags,
            tag_handles=tag_handles,
            famous=data.get("famous_people") or [],
        ),
        "alt_texts":    existing.get("alt_texts", []),
        "scene_labels": existing.get("scene_labels", []),
        # The handle and name rules, checked here too (#475). A revision is
        # where a handle is most likely to be invented, because "add @someone"
        # is a thing Dan types.
        "findings": [
            finding_entry(f) for f in credit_findings(
                revised_caption, tag_handles=tag_handles,
                name_mentions=name_mentions)
        ],
        "findings_caption": revised_caption,
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
        venue_context=m.get("venue_context", "") or "",
        date=m["date"],
        day=m["day"],
        shoot_type=m.get("shoot_type", "performance"),
        program=m["program"],
        existing=m["existing"],
        feedback=m["feedback"],
        tag_handles=m.get("tag_handles") or None,
        name_mentions=m.get("name_mentions") or None,
        photo_tags=m.get("photo_tags") or None,
    )
    Path(args.output).write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"Revised caption written to {args.output}")
