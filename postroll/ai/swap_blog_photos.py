"""
PostRoll — Blog Photo Marker Swapper

Replaces [PHOTO: filename | alt text] markers in an existing blog body with
new markers for a different set of photos. Every word of prose is preserved
exactly. Only the marker lines change.

Input manifest:
{
  "body": "<current blog body with [PHOTO: ...] markers>",
  "photo_paths": ["/path/to/p1.jpg", ...]
}

Output JSON:
{
  "body": "<updated body with new markers>",
  "photo_count": <N>
}
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path

from .ai_tells import strip_em_dashes
from .claude_client import run_json_prompt, ClaudeError
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


PROMPT = """\
An existing blog post body is shown below. It contains [PHOTO: filename | alt text]
markers embedded among the paragraphs. The photos are being replaced with a new set.

YOUR ONLY JOB: replace the [PHOTO: ...] marker lines with new ones for the new photos.

Rules:
- Do NOT change any prose. Not one word, comma, or paragraph break.
- Look at each new photo. Write an alt text for each (15–35 words: who, what, where,
  lighting, gestures — useful for a reader who cannot see the image).
- Use this exact format, on its own line between paragraphs:
    [PHOTO: filename.jpg | alt text description]
  where "filename.jpg" is the base filename only, no directory path.
- If the new photo count matches the old marker count: replace each marker 1-for-1
  in the same positions.
- If the counts differ: redistribute the markers at paragraph breaks, spread evenly
  through the post — not clustered at start or end.

New photos ({photo_count} total):
{photo_list}

Current body (preserve ALL prose verbatim — only the [PHOTO: ...] lines change):
{body}

Return JSON ONLY (no markdown fences, no commentary):
{{
  "body": "<updated body, newlines escaped as \\n>",
  "photo_count": {photo_count}
}}
"""


def swap_blog_photos(*, body: str, photo_paths: list[str | Path]) -> dict:
    """Replace [PHOTO: ...] markers in body with markers for new photos.

    All prose is preserved verbatim. Only the marker lines change.
    """
    if not photo_paths:
        raise ValueError("No photo paths provided")
    if not body.strip():
        raise ValueError("No blog body provided")

    with tempfile.TemporaryDirectory(prefix="postroll-blog-swap-") as tmp:
        tmp_path = Path(tmp)
        resolved: list[str] = []
        for i, p in enumerate(photo_paths):
            path = Path(p).expanduser().resolve()
            if not path.exists():
                raise FileNotFoundError(f"Photo not found: {path}")
            if path.suffix.lower() in HEIC_SUFFIXES:
                staged = _convert_heic_to_jpeg(path, tmp_path, prefix=f"{i:03d}_")
            else:
                staged = tmp_path / f"{i:03d}_{path.name}"
                shutil.copy2(path, staged)
            resolved.append(str(staged))

        # Show clean filenames (without the 000_ staging prefix) in the
        # prompt so markers use the original name. The same clean names go
        # in as image_labels so each attached image is preceded by a
        # `Photo N: filename.jpg` block, anchoring the file to image
        # correspondence instead of leaving Claude to correlate by order.
        photo_filenames = [
            Path(p).name.split('_', 1)[1] if '_' in Path(p).name else Path(p).name
            for p in resolved
        ]
        photo_list = "\n".join(f"- {n}" for n in photo_filenames)

        prompt = PROMPT.format(
            photo_count=len(resolved),
            photo_list=photo_list,
            body=body,
        )

        data = run_json_prompt(
            prompt,
            timeout=300,
            image_paths=resolved,
            image_labels=photo_filenames,
            step="swap_blog_photos",
        )
        if not isinstance(data, dict):
            raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

    # Same deterministic dash strip its two sibling paths apply on the way out
    # (generate_blog.py, revise_blog.py). Without it a post whose photos were
    # swapped could ship an em dash into published copy (#203).
    return {
        "body":        strip_em_dashes(data.get("body", body).strip()),
        "photo_count": len(photo_paths),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Replace blog photo markers")
    parser.add_argument("--manifest", required=True, help="JSON manifest with body + photo_paths")
    parser.add_argument("--output",   required=True, help="Where to write result JSON")
    args = parser.parse_args()

    m = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    try:
        result = swap_blog_photos(
            body=m["body"],
            photo_paths=m["photo_paths"],
        )
    except (ClaudeError, FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    Path(args.output).write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
