"""
PostRoll — Blog Reviser

Revises an existing blog post draft based on Dan's plain-English feedback.
Only the title and body change; photo markers ([PHOTO: filename.jpg | alt])
must be preserved verbatim.

Input manifest:
{
  "event": "...",
  "org": "...",
  "venue": "...",
  "date": "...",
  "shoot_type": "...",
  "program": { ...OCR dict... },
  "existing": {
    "title": "...",
    "body":  "..."
  },
  "feedback": "tighten the middle, cut the closing CTA",
  "photo_filenames": ["DSC4821.jpg", ...]   // optional; the names the post's
                                            // photos actually carry on disk
}

Output JSON (written to --output file):
{
  "title": "...",
  "body":  "...",
  "photo_count": <preserved from input>
}

Usage:
    python -m postroll.ai.revise_blog \\
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
    BLOG_HUMANIZER_EXTRA_BANS,
    BLOG_VOICE_EXTRA_CHECKS,
    build_review_prompt,
    build_voice_review_prompt,
    is_humanizer_available,
    load_humanizer_rules,
    markers_preserved_validator,
    strip_em_dashes,
)
from .claude_client import run_json_prompt, run_review_pass, load_brand_voice, ClaudeError
from .blog_quality import (check_blog, filenames_used_by, finding_entry,
                           repair_marker_filenames)
from .generate_blog import (
    _fix_missing_contractions,
    _fix_second_person,
    _fix_wrong_names,
    _format_performers,
    _format_pieces,
    BLOG_STRUCTURE,
    BLOG_WRITING_RULES,
)


REVISE_PROMPT = """\
{brand_voice}

---

Dan Wright has reviewed the following blog post draft for {event} and
wants a revision. The brand voice rules above STILL APPLY — preserve the
10-12 short paragraph structure, continuous prose, no headings, no
bullets, honest framing of what Dan actually witnessed.

Existing title:
{title}

Existing body:
{body}

Dan's feedback:
{feedback}

Event context:
- Organization: {org}
- Venue: {venue}{venue_context_line}
- Date: {date}
- Shoot type: {shoot_type}

Performers (from program OCR):
{performers}

Repertoire (from program OCR):
{pieces}

Apply Dan's feedback to revise the title and body. Rules:

1. PRESERVE all [PHOTO: filename.jpg | alt text] markers from the existing
   body EXACTLY — same filenames, same alt text, same positions unless
   Dan's feedback explicitly asks you to move or change one. These are
   the only photos available; you cannot invent new ones.
2. Keep 10-12 short paragraphs separated by blank lines.
3. No headings, no bullets, no section breaks.

{blog_structure}

Prose rules (same as initial generation — all apply):
{blog_writing_rules}
- Inside the JSON "body" string, escape newlines as \\n so the JSON parses cleanly.

Return JSON ONLY (no markdown fences, no commentary) in this shape:

{{
  "title": "<revised title>",
  "body":  "<revised markdown body with [PHOTO: ...] markers preserved>"
}}
"""


def revise_blog(
    *,
    event: str,
    org: str,
    venue: str,
    date: str,
    shoot_type: str = "performance",
    program: dict[str, Any],
    existing: dict[str, Any],
    feedback: str,
    venue_context: str = "",
    photo_filenames: list[str] | None = None,
    humanizer_path: str | Path | None = None,
    skip_humanizer: bool = False,
    skip_voice_pass: bool = False,
) -> dict[str, Any]:
    """Revise an existing blog post based on plain-English feedback.

    Photo markers in the body are preserved; only the prose is revised.
    Pipeline mirrors generate_blog: draft → voice pass → humanizer pass.

    `photo_filenames` are the names the post's photos carry on disk. With them
    the filename rules run, which is what makes a marker the revision renamed
    visible at all; without them those two rules stay off, exactly as
    `check_blog` documents, so an event whose photo paths are gone does not
    have every marker reported as unknown (#962).
    """
    brand_voice_text = load_brand_voice()

    title = existing.get("title", "")
    body  = existing.get("body", "")
    photo_count = int(existing.get("photo_count", 0) or 0)

    venue_context_line = (
        f" — performed in {venue_context.strip()}"
        if venue_context and venue_context.strip() else ""
    )

    prompt = REVISE_PROMPT.format(
        brand_voice=brand_voice_text,
        blog_structure=BLOG_STRUCTURE,
        blog_writing_rules=BLOG_WRITING_RULES,
        event=event,
        org=org,
        venue=venue,
        venue_context_line=venue_context_line,
        date=date,
        shoot_type=shoot_type,
        title=title,
        body=body,
        feedback=feedback,
        performers=_format_performers(program.get("performers", [])),
        pieces=_format_pieces(program.get("pieces", [])),
    )

    data = run_json_prompt(prompt, timeout=600, step="revise_blog")
    if not isinstance(data, dict):
        raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

    blog_shape = (
        "{title: string, body: string with [PHOTO: filename.jpg | alt text]"
        " markers preserved exactly as-is}"
    )

    if not skip_voice_pass:
        voice_prompt = build_voice_review_prompt(
            draft_json=json.dumps(data, ensure_ascii=False, indent=2),
            brand_voice=brand_voice_text,
            output_shape_description=blog_shape,
            extra_checks=BLOG_VOICE_EXTRA_CHECKS,
        )
        data = run_review_pass(
            voice_prompt, data, label="voice", timeout=600,
            runner=run_json_prompt, validate=markers_preserved_validator,
        )

    if not skip_humanizer and is_humanizer_available(humanizer_path):
        humanizer_rules = load_humanizer_rules(humanizer_path)
        review_prompt = build_review_prompt(
            draft_json=json.dumps(data, ensure_ascii=False, indent=2),
            humanizer_rules=humanizer_rules,
            brand_voice=brand_voice_text,
            output_shape_description=blog_shape,
            extra_hard_bans=BLOG_HUMANIZER_EXTRA_BANS,
        )
        data = run_review_pass(
            review_prompt, data, label="humanizer", timeout=600,
            runner=run_json_prompt, validate=markers_preserved_validator,
        )

    final_body = strip_em_dashes(data.get("body", body).strip())
    final_body = _fix_wrong_names(final_body, program)
    final_body = _fix_second_person(final_body)
    final_body = _fix_missing_contractions(final_body)
    # A revision is a live path back into the blog, and "add more detail" is
    # exactly the request most likely to reintroduce an invented number or a
    # performance review, so it runs the same deterministic checks the first
    # pass does (#201).
    # The list carries the photos AVAILABLE to this event, not the photos in
    # this post: generation subsamples to seven when more are assigned, and
    # Dan's DiGangi event holds twelve. Checked against all twelve, the five
    # nobody chose are reported as never placed on every single revision, which
    # is the check crying wolf (L36). The post's own set is stated by the body
    # being revised, which this pass is under orders to preserve verbatim.
    in_the_post = filenames_used_by(body, photo_filenames)
    if photo_filenames and not in_the_post:
        # Deliberate, and said out loud rather than fallen through to: no
        # marker in the existing body names any photo on this event, so which
        # photos the post holds is genuinely unknown. That is a different
        # situation from having been sent no list at all (L214), and the answer
        # is the same only because reporting every marker as unknown would be
        # worse than reporting none.
        print(f"[revise_blog] no marker in the existing body names any of the "
              f"{len(photo_filenames)} photos on this event, so the filename "
              f"rules are skipped rather than reporting every marker unknown",
              flush=True, file=sys.stderr)

    # A near-miss filename is repaired rather than reported (#962).
    final_body, repairs = repair_marker_filenames(final_body, in_the_post)
    for was, now in repairs:
        print(f"[revise_blog] REPAIRED marker filename: {was!r} -> {now!r}",
              flush=True, file=sys.stderr)
    findings = check_blog(final_body, program=program, venue=venue,
                          photo_filenames=in_the_post or None)
    for f in findings:
        print(f"[revise_blog] CHECK {f.code}: {f.message} ({f.detail})",
              flush=True, file=sys.stderr)

    return {
        "title":       data.get("title", title).strip(),
        "body":        final_body,
        "photo_count": photo_count,
        "findings": [finding_entry(f) for f in findings],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Revise a PostRoll blog draft based on feedback")
    parser.add_argument("--manifest", required=True, help="Path to revision manifest JSON")
    parser.add_argument("--output",   required=True, help="Path to write revised output JSON")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"Manifest not found: {manifest_path}", file=sys.stderr)
        return 1

    m = json.loads(manifest_path.read_text(encoding="utf-8"))
    result = revise_blog(
        event=m["event"],
        org=m["org"],
        venue=m["venue"],
        venue_context=m.get("venue_context", "") or "",
        date=m["date"],
        shoot_type=m.get("shoot_type", "performance"),
        program=m["program"],
        existing=m["existing"],
        feedback=m["feedback"],
        # Optional: an app build that predates #962 sends no such key, and a
        # revision must not fail on one. Absent means the filename rules stay
        # off, which is what shipped before.
        photo_filenames=m.get("photo_filenames"),
    )
    Path(args.output).write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"Revised blog written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
