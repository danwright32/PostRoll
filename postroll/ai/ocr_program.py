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
import urllib.request
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

from .claude_client import run_json_prompt, ClaudeError


HEIC_SUFFIXES = {".heic", ".heif"}


# === Output schema ===
#
# Genre-agnostic — works for classical, plays, musicals, opera, rock, dance,
# improv. The `composer` field is used loosely: composer (classical),
# playwright (plays), book-writer or composer (musicals), choreographer
# (dance), artist or band (rock shows), company (improv).
#
# {
#   "performers": [
#       {"name": "...", "role": "soloist|conductor|ensemble|composer|actor|dancer|band|other", "voice_or_instrument": "..."}
#   ],
#   "pieces": [
#       {"composer": "creator/playwright/choreographer/band", "title": "...", "movements": ["acts/scenes if applicable"], "notes": "..."}
#   ],
#   "scenes": [
#       {"name": "spa scene", "location": "New Mexico", "visual_cues": "wellness setting, soft lighting, possibly Asian-inspired decor", "description": "what happens here, if known"}
#   ],
#   "organization_notes": "theater co / orchestra / band / label — mission, history, who they are",
#   "program_notes": "free text — composer/playwright/director notes, scene descriptions, historical context",
#   "venue_notes": "free text about the venue, if printed",
#   "production_details": "director, creative team, run dates, tour info, anything production-specific",
#   "other": "anything else printed in the program that could be useful"
# }
#
# `scenes` is the differentiating-context field for captions. The caption
# generator uses it to label which scene/section/movement a photo belongs
# to, so different photos in the same event get different captions.
# Populate it whenever the program lists distinct scenes, sets, locations,
# movements, acts, or sections.


PROMPT_TEMPLATE = """\
You are extracting structured data from photos of a performing arts event
program. Dan Wright photographed this event and will write about it. The
event might be a classical concert, a play, a musical, an opera, a rock
show, a dance performance, or an improv night — any genre of live
performance.

Read the image(s) at the following path(s) and return JSON with the schema
below. Read EVERY image carefully — programs often span multiple pages.

Image paths:
{image_list}

Return JSON ONLY (no commentary, no markdown fences) matching this schema:

{{
  "performers": [
    {{
      "name": "string",
      "role": "soloist | conductor | ensemble | composer | actor | dancer | band_member | troupe | director | other",
      "voice_or_instrument": "string or null (soprano, violin, lead guitar, principal dancer, etc.)"
    }}
  ],
  "pieces": [
    {{
      "composer": "string — the creator of this work. Composer for music, playwright for plays, book writer or composer for musicals, choreographer for dance, artist or band for rock, troupe for improv. Use whichever fits.",
      "title": "string",
      "movements": ["string", ...],
      "notes": "string or null — anything printed about this specific piece/scene/song"
    }}
  ],
  "scenes": [
    {{
      "name": "string — short label for the scene, set, section, or movement. Examples: 'spa scene', 'restaurant scene', 'Act II finale', 'second movement', 'opening number'",
      "location": "string or null — where the scene takes place if relevant (e.g. 'New Mexico', 'Queens')",
      "visual_cues": "string — concrete visible things a photographer would see in a photo from this scene: specific props, costume colors or styles, set pieces, number of people, lighting state. NOT mood or vibe — actual objects. Examples: 'two actors at small table, one in red dress, one in suit jacket' or 'bare stage, single spotlight, actor alone at microphone' or 'full chorus in black, conductor at podium, piano stage right'",
      "description": "string or null — what happens in this scene, if known"
    }}
  ],
  "organization_notes": "string — presenting organization, theater company, orchestra, band, label, or production company (history, mission, who they are). Empty string if nothing printed.",
  "program_notes": "string — composer/playwright/director notes, piece/scene descriptions, historical context, any prose printed about the work itself. Empty string if nothing printed.",
  "venue_notes": "string — anything printed about the venue. Empty string if nothing printed.",
  "production_details": "string — director, creative team (designers, music director, choreographer), run dates, tour info, production-specific credits that don't fit in performers or pieces. Empty string if nothing printed.",
  "other": "string — any other printed content that could enrich a blog post (sponsor notes, dedications, audience instructions, etc.). Empty string if nothing useful."
}}

Rules:
- **NEVER invent or guess names.** Only include names you can read clearly
  in the program image. Hallucinating a name (e.g. a plausible-sounding
  conductor or soloist that isn't printed) is far worse than leaving the
  field empty. If you are uncertain, omit the entry entirely.
- Capture EXACT names as printed (don't normalize spelling).
- For text fields, preserve the substance — long paragraphs are fine.
  Don't summarize aggressively.
- `composer` is used loosely for the work's originator across all genres.
  Don't leave it blank just because the event isn't classical.
- If a piece has multiple movements/acts/scenes listed, capture all of them.
- For `scenes`, populate one entry per distinct scene/section/set/
  movement/act mentioned in the program. The caption generator uses
  this to differentiate photos from different parts of the same show.
  Each scene should have a short distinguishing `name` and `visual_cues`
  that name specific visible objects (props, costumes, set pieces,
  staging) — not mood or atmosphere. A photo-matching system needs to
  know what to literally look for, not how the scene feels.
- If the program doesn't list scenes/sections explicitly, leave
  `scenes` as an empty array — don't invent.
- **Choral and festival programs:** Many programs — especially large choral
  concerts and festivals — list numerous participating ensembles (choirs,
  school groups, orchestras). Capture EACH ensemble as a separate performer
  entry with role="ensemble" and the full group name as `name`. These often
  appear as a bulleted or columned list of school or choir names. Do not
  collapse them into one entry — list every group individually.
- **Conductors vs. ensembles:** Conductors are typically named individuals
  (e.g. "Jennaya Robison, Conductor"). Each conducting ensemble may have
  its own conductor. List conductors by their personal name. List choirs and
  orchestras by their group name with role="ensemble".
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
        "scenes": data.get("scenes", []),
        "organization_notes": data.get("organization_notes", ""),
        "program_notes": data.get("program_notes", ""),
        "venue_notes": data.get("venue_notes", ""),
        "production_details": data.get("production_details", ""),
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
