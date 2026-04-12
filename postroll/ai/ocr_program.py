"""
PostRoll — Program OCR

Extracts structured data from photos of an event program. Uses Claude
Code's vision (via the `claude` CLI) so messy real-world program layouts
work without per-program tuning.

The output is a single dict shaped for both the caption generator
(needs performers + basic event info) and the blog generator (needs
program notes, organization context, repertoire details, etc.).

Accepts JPEG, PNG, and HEIC. HEIC files are auto-converted to JPEG
via macOS `sips` before being passed to Claude vision (this is the
common case since iPhone photos default to HEIC).

Usage:
    python -m postroll.ai.ocr_program \\
        --image path/to/program_p1.jpg \\
        --image path/to/program_p2.jpg \\
        --output output/program.json
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

from .claude_client import run_json_prompt, ClaudeError


HEIC_SUFFIXES = {".heic", ".heif"}


# === Output schema ===
#
# {
#   "performers": [
#       {"name": "...", "role": "soloist|conductor|ensemble|composer", "voice_or_instrument": "..."}
#   ],
#   "pieces": [
#       {"composer": "...", "title": "...", "movements": [...], "notes": "..."}
#   ],
#   "organization_notes": "free text about the org — history, mission, who they are",
#   "program_notes": "free text — composer notes, piece descriptions, historical context",
#   "venue_notes": "free text about the venue, if printed",
#   "other": "anything else printed in the program that could be useful"
# }


PROMPT_TEMPLATE = """\
You are extracting structured data from photos of a classical music event
program. The program is for a concert that Dan Wright photographed and will
write about in a blog post.

Read the image(s) at the following path(s) and return JSON with the schema
below. Read EVERY image carefully — programs often span multiple pages.

Image paths:
{image_list}

Return JSON ONLY (no commentary, no markdown fences) matching this schema:

{{
  "performers": [
    {{
      "name": "string",
      "role": "soloist | conductor | ensemble | composer | other",
      "voice_or_instrument": "string or null (e.g. soprano, violin, etc.)"
    }}
  ],
  "pieces": [
    {{
      "composer": "string",
      "title": "string",
      "movements": ["string", ...],
      "notes": "string or null — anything printed about this specific piece"
    }}
  ],
  "organization_notes": "string — everything printed about the presenting organization (history, mission, who they are). Empty string if nothing printed.",
  "program_notes": "string — composer biographies, piece descriptions, historical context, any prose printed in the program about the music itself. Empty string if nothing printed.",
  "venue_notes": "string — anything printed about the venue. Empty string if nothing printed.",
  "other": "string — any other printed content that could enrich a blog post (sponsor notes, dedications, audience instructions, etc.). Empty string if nothing useful."
}}

Rules:
- Capture EXACT names as printed (don't normalize spelling).
- For program_notes and organization_notes, preserve the substance — long
  paragraphs are fine. Don't summarize aggressively.
- If a piece has multiple movements listed, capture all of them.
- If you can't read part of the program clearly, do your best and skip
  what's truly illegible.
- Return ONLY the JSON object. No explanation before or after.
"""


def _convert_heic_to_jpeg(src: Path, dest_dir: Path) -> Path:
    """Convert a HEIC file to JPEG using macOS `sips`. Returns the new path.

    Raises ClaudeError if `sips` is not available (non-Mac systems).
    """
    if shutil.which("sips") is None:
        raise ClaudeError(
            f"Cannot read HEIC file {src.name}: macOS `sips` not found. "
            "HEIC conversion is only supported on macOS."
        )

    dest = dest_dir / (src.stem + ".jpg")
    result = subprocess.run(
        ["sips", "-s", "format", "jpeg", str(src), "--out", str(dest)],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0 or not dest.exists():
        raise ClaudeError(
            f"sips failed to convert {src.name}: {result.stderr.strip()}"
        )
    return dest


def _normalize_image_paths(
    image_paths: list[str | Path], tmp_dir: Path
) -> list[str]:
    """Stage all images into one temp dir as JPEGs.

    HEIC files are converted via sips. Other formats are copied as-is.
    Centralizing into one dir means Claude only needs --add-dir for one
    path regardless of where the originals live.
    """
    resolved: list[str] = []
    for i, p in enumerate(image_paths):
        path = Path(p).expanduser().resolve()
        if not path.exists():
            raise FileNotFoundError(f"Program image not found: {path}")

        if path.suffix.lower() in HEIC_SUFFIXES:
            staged = _convert_heic_to_jpeg(path, tmp_dir)
        else:
            # Copy with a numeric prefix to avoid name collisions
            staged = tmp_dir / f"{i:03d}_{path.name}"
            shutil.copy2(path, staged)

        resolved.append(str(staged))
    return resolved


def extract_program(image_paths: list[str | Path]) -> dict[str, Any]:
    """Run OCR on one or more program images and return structured data.

    Accepts JPEG, PNG, and HEIC paths. HEIC files are auto-converted to
    JPEG via macOS `sips` (HEIC support requires macOS). All images are
    staged into a single temp directory which is granted to Claude via
    --add-dir.
    """
    if not image_paths:
        raise ValueError("At least one image path is required")

    with tempfile.TemporaryDirectory(prefix="postroll-ocr-") as tmp:
        tmp_path = Path(tmp)
        resolved = _normalize_image_paths(image_paths, tmp_path)

        image_list = "\n".join(f"- {p}" for p in resolved)
        prompt = PROMPT_TEMPLATE.format(image_list=image_list)

        data = run_json_prompt(
            prompt,
            timeout=600,
            allowed_dirs=[tmp_path],
            allowed_tools=["Read"],
        )

    if not isinstance(data, dict):
        raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

    # Fill in any missing keys with empty defaults so downstream code is safe
    return {
        "performers": data.get("performers", []),
        "pieces": data.get("pieces", []),
        "organization_notes": data.get("organization_notes", ""),
        "program_notes": data.get("program_notes", ""),
        "venue_notes": data.get("venue_notes", ""),
        "other": data.get("other", ""),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract structured data from program photos")
    parser.add_argument(
        "--image",
        action="append",
        required=True,
        help="Path to a program photo (repeat for multi-page programs)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Where to write the JSON output (defaults to stdout)",
    )
    args = parser.parse_args()

    try:
        data = extract_program(args.image)
    except (ClaudeError, FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    text = json.dumps(data, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n", encoding="utf-8")
        print(f"wrote {args.output}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
