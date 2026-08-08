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
      "notes": "string or null — prose about THIS piece only (premiere date, dedicatee, programmatic meaning, structure, what the music does). If the program has a separate 'Program Notes' / 'About the Music' section anywhere in the document — even on a later page — find the paragraph(s) about this specific piece and put them here verbatim. Do NOT include the composer's name, life dates, or biography. Leave null only if no piece-specific prose appears anywhere in the program."
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
- **Do not duplicate the composer in `notes`.** Program books often print the
  composer's last name and life dates (e.g. "Shostakovich (1906–1975)") next
  to a piece — that's still composer/biographical info, not piece notes.
  Capture it once in `composer` (full name) and, if the program has a longer
  composer paragraph, put that in `program_notes`. Set `notes` to null when
  no piece-specific prose appears anywhere in the program.
- **Pull piece notes from a separate Program Notes section if one exists.**
  Many programs put a brief title/composer page up front and then a multi-page
  "Program Notes" or "About the Music" section later with paragraphs about
  each piece. Cross-reference: for every entry in `pieces`, scan the entire
  program for a matching paragraph (often headed by the piece title or
  composer name) and copy that prose verbatim into the piece's `notes` field.
  The same prose should also appear in the top-level `program_notes` blob —
  that's expected; piece-level `notes` is the per-piece slice for the
  caption/blog generator.
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


PIECES_PROMPT_TEMPLATE = """\
Read the attached photos of an event program and extract ONLY the list of
pieces / works / songs / numbers performed.

This is a focused fallback call — the main OCR pass returned no pieces, so
we're asking again with a smaller schema. KEEP THE RESPONSE COMPACT — do
NOT include any prose, descriptions, or program notes. Just the structured
fields below. The blog generator gets prose from a separate field.

Image paths:
{image_list}

Return JSON ONLY (no commentary, no markdown fences) as an array of pieces:

[
  {{
    "composer": "string — composer, playwright, choreographer, songwriter, band, or whichever creator label fits this work. For songs, this is the songwriter or band.",
    "title": "string — exact title as printed",
    "movements": ["string", ...]
  }}
]

Rules:
- Read EVERY page. Programs often span multiple pages, with pieces listed on
  one page and program notes on later pages.
- Capture EXACT titles and creator names as printed.
- For concerts that mix classical works and popular songs, capture both —
  songs by Bob Dylan, Billie Eilish, etc. count as pieces with the artist
  or songwriter as `composer`.
- DO NOT include a `notes` or `description` field. Just composer/title/movements.
  Long prose causes truncation and JSON-parse failures.
- Don't invent works. If you can't read clearly, skip that entry.
- Return ONLY the JSON array. No explanation before or after.
"""


PROSE_PROMPT_TEMPLATE = """\
Read the attached photos of an event program and extract the prose/free-text
fields ONLY. This is a focused fallback call because the main extraction
returned empty prose fields.

Image paths:
{image_list}

Return JSON ONLY (no commentary, no markdown fences) as a single object:

{{
  "program_notes": "string — all paragraph-length prose about the works/pieces being performed. Include every per-piece descriptive paragraph in order. Empty string if none.",
  "organization_notes": "string — paragraph(s) about the presenting organization, ensemble, choir, orchestra, theater company, etc. (history, mission, who they are). Empty string if none.",
  "venue_notes": "string — anything printed about the venue. Empty string if nothing printed.",
  "production_details": "string — director, creative team (designers, music director, choreographer), run dates, tour info, production-specific credits. Empty string if nothing printed.",
  "other": "string — any other printed prose that could enrich a blog post. Empty string if nothing useful."
}}

Rules:
- Read EVERY page. Prose is often spread across multiple pages.
- Copy the prose VERBATIM from the program. Don't summarize.
- IMPORTANT: when copying prose that contains quoted phrases, replace any
  internal straight double quotes with single quotes (') so the JSON stays
  valid. The blog generator doesn't care which quote style is used.
- If a field has no content in the program, return an empty string for it.
- Return ONLY the JSON object. No explanation before or after.
"""


PERFORMERS_PROMPT_TEMPLATE = """\
Read the attached photos of an event program and extract ONLY the people and
ensembles performing — including those mentioned in prose paragraphs, not
just those listed in a formal cast list.

This is a focused fallback call — the main OCR pass returned no performers,
so we're asking again with a smaller schema. Many programs (especially
program-notes booklets) name performers inside prose like "directed by Jane
Smith and accompanied by John Doe" or "vocal soloists Alice Lee and Bob Park
and violinist Mac Teng". Pull those out.

Image paths:
{image_list}

Return JSON ONLY (no commentary, no markdown fences) as an array:

[
  {{
    "name": "string — the person's name or the ensemble's name, exactly as printed",
    "role": "soloist | conductor | ensemble | composer | actor | dancer | band_member | troupe | director | accompanist | other",
    "voice_or_instrument": "string or null — soprano, violin, piano, lead guitar, principal dancer, etc."
  }}
]

Rules:
- Look at EVERY page. Performers may be named on a cast page, in the
  introductory paragraph, or buried in piece-specific notes.
- Capture EXACT names as printed (don't normalize spelling).
- Each ensemble (choir, orchestra, band, troupe) is its own entry with
  role="ensemble" and the full group name as `name`.
- A piano accompanist gets role="accompanist" and voice_or_instrument="piano".
- Solo performers named in piece notes (e.g. "violinist Mac Teng",
  "flute obbligato by Adrienne Reina-Sinchak") count — extract them with
  role="soloist" and the instrument/voice in voice_or_instrument.
- NEVER invent names. If unsure, skip rather than guess.
- Return ONLY the JSON array. No explanation before or after.
"""


def _convert_heic_to_jpeg(src: Path, dest_dir: Path, prefix: str = "") -> Path:
    """Convert a HEIC file to JPEG using macOS `sips`. Returns the new path.

    Callers must pass the same staging prefix they use for plain copies
    (e.g. "000_"): prefix stripping downstream assumes every staged name
    carries one, and an unprefixed name both mangles the recovered original
    filename (IMG_1234 becomes 1234) and lets same-stem files from
    different folders silently overwrite each other.

    Raises ClaudeError if `sips` is not available (non-Mac systems).
    """
    if shutil.which("sips") is None:
        raise ClaudeError(
            f"Cannot read HEIC file {src.name}: macOS `sips` not found. "
            "HEIC conversion is only supported on macOS."
        )

    dest = dest_dir / f"{prefix}{src.stem}.jpg"
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
            staged = _convert_heic_to_jpeg(path, tmp_dir, prefix=f"{i:03d}_")
        else:
            # Copy with a numeric prefix to avoid name collisions
            staged = tmp_dir / f"{i:03d}_{path.name}"
            shutil.copy2(path, staged)

        resolved.append(str(staged))
    return resolved


def _extract_pieces_only(resolved_paths: list[str]) -> list[dict[str, Any]]:
    """Run a focused Claude call that asks ONLY for the pieces array.

    Used as a fallback when the main multi-field extraction returns an empty
    pieces list. A smaller, single-purpose schema is significantly more
    reliable than the full eight-key schema for complex multi-page programs.
    """
    image_list = "\n".join(f"- {p}" for p in resolved_paths)
    prompt = PIECES_PROMPT_TEMPLATE.format(image_list=image_list)
    return _run_focused_array_prompt(
        prompt, resolved_paths, ("pieces", "works", "songs", "items")
    )


def _extract_prose_only(resolved_paths: list[str]) -> dict[str, str]:
    """Run a focused Claude call that asks ONLY for the prose fields.

    Used when the main extraction returned a non-dict (so prose fields were
    lost in salvage) or when prose fields came back empty despite obvious
    program-notes content in the images.
    """
    image_list = "\n".join(f"- {p}" for p in resolved_paths)
    prompt = PROSE_PROMPT_TEMPLATE.format(image_list=image_list)
    data = run_json_prompt(prompt, timeout=600, image_paths=resolved_paths, step="ocr:prose")
    if not isinstance(data, dict):
        return {}
    out: dict[str, str] = {}
    for key in ("program_notes", "organization_notes", "venue_notes",
                "production_details", "other"):
        value = data.get(key)
        if isinstance(value, str):
            out[key] = value
    return out


def _extract_performers_only(resolved_paths: list[str]) -> list[dict[str, Any]]:
    """Run a focused Claude call that asks ONLY for the performers array.

    Mirrors _extract_pieces_only — used when the main extraction returns no
    performers. Especially useful for program-notes booklets where performers
    are named in prose (intro paragraph, piece notes) rather than a cast list.
    """
    image_list = "\n".join(f"- {p}" for p in resolved_paths)
    prompt = PERFORMERS_PROMPT_TEMPLATE.format(image_list=image_list)
    return _run_focused_array_prompt(
        prompt, resolved_paths, ("performers", "people", "cast", "items")
    )


def _run_focused_array_prompt(
    prompt: str,
    resolved_paths: list[str],
    unwrap_keys: tuple[str, ...],
) -> list[dict[str, Any]]:
    """Shared helper for fallback calls that should return a JSON array of dicts.

    Claude usually returns the array directly; if it wraps the array in a
    single-key object, unwrap it under any of the expected key names.
    """
    data = run_json_prompt(prompt, timeout=600, image_paths=resolved_paths,
                           step="ocr:focused_array")
    if isinstance(data, list):
        return [item for item in data if isinstance(item, dict)]
    if isinstance(data, dict):
        for key in unwrap_keys:
            value = data.get(key)
            if isinstance(value, list):
                return [item for item in value if isinstance(item, dict)]
    return []


def _salvage_list_response(items: list[Any]) -> dict[str, Any]:
    """Wrap a top-level JSON array under the schema key its items resemble.

    Claude occasionally returns a bare array when given a PDF that doesn't
    cover the full schema (e.g. program notes without a cast list). Inspect
    item shape and slot the array under pieces / performers / scenes so the
    user gets a usable starting point in OCR review.
    """
    sample = next((x for x in items if isinstance(x, dict)), None)
    if sample is None:
        return {}
    keys = set(sample.keys())
    if {"title", "composer"} <= keys or "movements" in keys:
        return {"pieces": items}
    if {"name", "role"} <= keys or "voice_or_instrument" in keys:
        return {"performers": items}
    if "visual_cues" in keys or {"name", "location"} <= keys:
        return {"scenes": items}
    return {}


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
        base_prompt = PROMPT_TEMPLATE.format(image_list=image_list)

        # First attempt
        data = run_json_prompt(base_prompt, timeout=600, image_paths=resolved, step="ocr:focused")

        # Retry once if Claude returned a top-level array (or other non-dict).
        # Some programs — especially notes/lyrics-only PDFs with no cast list —
        # push Claude into returning just a single array (usually pieces).
        if not isinstance(data, dict):
            print(
                f"warning: OCR returned {type(data).__name__}, retrying with reinforced prompt",
                file=sys.stderr,
            )
            retry_prompt = (
                "CRITICAL: Your response MUST be a single JSON object with the keys "
                "performers, pieces, scenes, organization_notes, program_notes, "
                "venue_notes, production_details, other. DO NOT return a top-level "
                "JSON array — the array fields must be values inside the object. "
                "Use empty arrays/strings for fields the program doesn't cover.\n\n"
                + base_prompt
            )
            data = run_json_prompt(retry_prompt, timeout=600, image_paths=resolved, step="ocr:focused_retry")

        # Last-resort salvage: if it's still a list, wrap it under whichever schema
        # key the items resemble. Better to give the user partial OCR they can edit
        # than to fail outright — performers can also come from the event URL.
        if isinstance(data, list):
            salvaged = _salvage_list_response(data)
            print(
                f"warning: OCR still a list after retry; salvaged as "
                f"{[k for k, v in salvaged.items() if v]}",
                file=sys.stderr,
            )
            data = salvaged

        if not isinstance(data, dict):
            raise ClaudeError(
                f"OCR returned unexpected JSON ({type(data).__name__}). "
                "Try uploading a different program PDF, or click 'No program' to skip OCR."
            )

        # Pieces fallback: complex multi-field schemas sometimes leave the
        # pieces array empty even when the program clearly lists works. A
        # focused single-purpose call recovers them. Done inside the temp-dir
        # block so the resolved (possibly HEIC-converted) paths are still valid.
        if not data.get("pieces"):
            try:
                recovered = _extract_pieces_only(resolved)
                if recovered:
                    data["pieces"] = recovered
                    print(
                        f"info: pieces fallback recovered {len(recovered)} works",
                        file=sys.stderr,
                    )
            except ClaudeError as e:
                print(f"warning: pieces fallback failed: {e}", file=sys.stderr)

        # Performers fallback: same idea — performer names often hide in prose
        # ("directed by …", "violinist …") that the main multi-field call
        # misses. A focused performers-only prompt picks them up. If the
        # program truly has no performers (rare), the fallback returns [] and
        # nothing changes.
        if not data.get("performers"):
            try:
                recovered = _extract_performers_only(resolved)
                if recovered:
                    data["performers"] = recovered
                    print(
                        f"info: performers fallback recovered {len(recovered)} entries",
                        file=sys.stderr,
                    )
            except ClaudeError as e:
                print(f"warning: performers fallback failed: {e}", file=sys.stderr)

        # Prose fallback: program_notes drives the blog generator. When the
        # main call returned a list and was salvaged, all prose fields are
        # gone — recover them with a focused prose-only call. Trigger
        # whenever program_notes is missing AND there's at least one piece
        # to write about (avoids burning a call on truly empty programs).
        if not data.get("program_notes") and data.get("pieces"):
            try:
                prose = _extract_prose_only(resolved)
                # Don't overwrite anything that survived; only fill gaps.
                filled = []
                for key, value in prose.items():
                    if value and not data.get(key):
                        data[key] = value
                        filled.append(key)
                if filled:
                    print(
                        f"info: prose fallback recovered {filled}",
                        file=sys.stderr,
                    )
            except ClaudeError as e:
                print(f"warning: prose fallback failed: {e}", file=sys.stderr)

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
