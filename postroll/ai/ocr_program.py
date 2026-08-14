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
from ..media.page_regions import image_budget_for, split_page
from .stitch_notes import stitch_notes
from .ocr_batching import (NO_PAGE_NUMBER, batch_images, merge_program_data,
                           merge_rescan)
from .ocr_batching import _dedupe as _dedupe_dicts
from .progress import ProgressWriter

#: Ceiling for one OCR request's images, in base64 bytes. The API refuses a
#: request over 32 MB outright; the headroom covers the prompt and envelope.
#: Splitting pages into bands (#208) doubled how much a program carries, so
#: an eight page program now needs several requests rather than one (#216).
MAX_REQUEST_BYTES = 25_000_000

#: The model every OCR prompt here uses. Named once so the per-image budget
#: the pages are split for cannot drift from the model that reads them: split
#: for one budget and read by a model with another, the bands are either
#: needlessly small or silently reduced again (#208).
OCR_MODEL = "sonnet"


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


def _ordered_unique(unread: list[str], order: list[str]) -> list[str]:
    """The unread pages, once each, in the order the caller listed them.

    A page split into bands can fail three times and is still one page to send
    again, and the app shows this list to Dan: "pages 3, 3 and 3 could not be
    read" is not a sentence anybody should meet. Sorted by the caller's own
    order rather than by when the failures happened, because that is the order
    the pages are on screen in.
    """
    seen = set(unread)
    named = [page for page in order if page in seen]
    # Anything that failed under a name the caller did not pass, which should
    # not happen, is kept rather than dropped: losing a page from this list
    # silently is the failure the list exists to prevent (L11).
    return named + [page for page in unread if page not in set(order)]


def unread_gap(unread: list[str], order: list[str],
               numbers: list[int] | None = None) -> tuple[list[str], list[int]]:
    """The gap as paths AND as positions in the uploaded programme (#558).

    The paths alone cannot survive the programme images being moved or rebased,
    which this repo does do, and a gap keyed on them then names files nothing
    can find: the rescan refuses every page as missing, and the only way back is
    re-uploading the whole programme and paying for it again. The position is
    the part a move cannot break (L15).

    `numbers` runs alongside `order`, one per page, and is what makes a RESCAN
    honest: it is handed a subset, so counting its own images would renumber
    page 7 as page 1 and the merge would strike the wrong page off. Defaults to
    1..N for a run that was given the whole programme.

    Returns two lists of equal length, paired by index, so a reader may take
    entry i of each and know they describe one page.
    """
    if numbers is None:
        numbers = list(range(1, len(order) + 1))
    if len(numbers) != len(order):
        raise ValueError(
            f"one page number per page: {len(numbers)} numbers for "
            f"{len(order)} pages")

    position = {path: number for path, number in zip(order, numbers)}
    paths = _ordered_unique(unread, order)
    return paths, [position.get(path, NO_PAGE_NUMBER) for path in paths]


def _normalize_image_paths(
    image_paths: list[str | Path], tmp_dir: Path
) -> tuple[list[str], dict[str, str]]:
    """Stage all images into one temp dir, splitting oversized pages into bands.

    HEIC files are converted via sips. Other formats are copied as-is.
    Centralizing into one dir means Claude only needs --add-dir for one
    path regardless of where the originals live.

    A page larger than the model's per-image budget is then split into bands,
    because a whole program page capped to that budget puts its small print on
    the boundary of legibility: measured on the real BLUDLINE page, the
    performer "Safa" read as "5afa" 0 times out of 5, and the same band sent as
    its own image read correctly 5 times out of 5 (#200, #207). Each band is
    capped by its own long edge, so it arrives at a third more resolution.

    Splitting here rather than at each call site means every OCR prompt (the
    focused ones, the prose pass and the retry) gets it, instead of whichever
    one somebody remembered.

    Returns the staged paths AND where each one came from. The mapping is not
    positional and cannot be recovered afterwards: one page can become several
    bands, and the staged copies live in a temp directory that is deleted when
    the run ends. Anything the caller has to hand back, a page it could not
    read being the case that matters, has to be named by the path the caller
    passed in (#518, L15).
    """
    budget = image_budget_for(OCR_MODEL)
    resolved: list[str] = []
    origins: dict[str, str] = {}
    for i, p in enumerate(image_paths):
        original = str(p)
        path = Path(p).expanduser().resolve()
        if not path.exists():
            raise FileNotFoundError(f"Program image not found: {path}")

        if path.suffix.lower() in HEIC_SUFFIXES:
            staged = _convert_heic_to_jpeg(path, tmp_dir, prefix=f"{i:03d}_")
        else:
            # Copy with a numeric prefix to avoid name collisions
            staged = tmp_dir / f"{i:03d}_{path.name}"
            shutil.copy2(path, staged)

        try:
            bands = split_page(staged, tmp_dir, budget=budget)
        except Exception as e:  # noqa: BLE001
            # A page we cannot split is still a page we can read, just on the
            # path that misreads small type. Say so rather than failing the
            # whole upload or pretending it was fine.
            print(f"warning: could not split {staged.name} into bands ({e}); "
                  "sending it whole, so small print may be misread",
                  file=sys.stderr, flush=True)
            bands = [Path(staged)]

        for band in bands:
            resolved.append(str(band))
            origins[str(band)] = original
    return resolved, origins


def _performer_entry(raw: dict[str, Any]) -> dict[str, Any]:
    """One performer, in exactly the fields the app decodes (#274).

    The outer keys of the OCR result were normalised; what was INSIDE a
    performer, a piece or a scene was whatever Claude happened to return, so a
    field renamed one level down went missing exactly the way `other` did for
    years: the outer key still arrives, so nothing looks broken (L27, L46).

    Shaping the entry here makes the boundary a deterministic code check rather
    than a hope about a prompt, and gives the payload contract something real
    to read.
    """
    return {
        "name": _text(raw.get("name")),
        "role": _text(raw.get("role")),
        "voice_or_instrument": _text(raw.get("voice_or_instrument")),
    }


def _piece_entry(raw: dict[str, Any]) -> dict[str, Any]:
    """One piece, in exactly the fields the app decodes (#274)."""
    movements = raw.get("movements")
    return {
        "composer": _text(raw.get("composer")),
        "title": _text(raw.get("title")),
        "movements": [_text(m) for m in movements] if isinstance(movements, list) else [],
        "notes": _text(raw.get("notes")),
    }


def _scene_entry(raw: dict[str, Any]) -> dict[str, Any]:
    """One scene, in exactly the fields the app decodes (#274)."""
    return {
        "name": _text(raw.get("name")),
        "location": _text(raw.get("location")),
        "visual_cues": _text(raw.get("visual_cues")),
        "description": _text(raw.get("description")),
    }


def _text(value: Any) -> str:
    """A field Claude may return as null, a number, or a string.

    Empty string rather than None, because the app decodes these as
    non-optional strings and a null would fall back to the same empty value
    anyway; doing it here means the payload says what it means.
    """
    if value is None:
        return ""
    return value if isinstance(value, str) else str(value)


def _entries(raw: Any, shape) -> list[dict[str, Any]]:
    """Apply `shape` to every dict in `raw`, skipping anything that is not one."""
    if not isinstance(raw, list):
        return []
    return [shape(item) for item in raw if isinstance(item, dict)]


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
    batches = batch_images(resolved_paths, limit_bytes=MAX_REQUEST_BYTES)
    if len(batches) > 1:
        # Merged rather than last-one-wins, or the prose from the first pages
        # disappears behind the prose from the last (#216).
        parts = [_extract_prose_only(batch) for batch in batches]
        merged = merge_program_data(parts)
        return {k: v for k, v in merged.items() if isinstance(v, str)}

    data = run_json_prompt(prompt, timeout=600, image_paths=resolved_paths,
                           step="ocr:prose", model=OCR_MODEL)
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
    # Batched for the same reason the main call is (#216): a large program's
    # recovery call would otherwise send every page at once and be refused,
    # which is the defect that fix closed reappearing on a quieter path.
    batches = batch_images(resolved_paths, limit_bytes=MAX_REQUEST_BYTES)
    if len(batches) > 1:
        out: list[dict[str, Any]] = []
        for batch in batches:
            part = _run_focused_array_prompt(prompt, batch, unwrap_keys)
            out.extend(part)
        return _dedupe_dicts(out)

    data = run_json_prompt(prompt, timeout=600, image_paths=resolved_paths,
                           step="ocr:focused_array", model=OCR_MODEL)
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


#: What a retry adds when a call answered with the wrong shape. One definition,
#: because the per-batch retry and the whole-run retry are the same correction
#: and a second copy is free to weaken on one path only.
_REINFORCED_PREFIX = (
    "CRITICAL: Your response MUST be a single JSON object with the keys "
    "performers, pieces, scenes, organization_notes, program_notes, "
    "venue_notes, production_details, other. DO NOT return a top-level "
    "JSON array \u2014 the array fields must be values inside the object. "
    "Use empty arrays/strings for fields the program doesn't cover.\n\n"
)


def _write_partial(output_path: Path, data: dict[str, Any]) -> None:
    """Put what has finished on disk, atomically (#479).

    Called after every batch rather than once at the end. Each batch is a
    600s paid call, and a run can be stopped by something that is not an
    exception at all: the app's watchdog SIGTERMs the subprocess at 1800s, and
    before this every batch already read and already paid for went with it.
    The same shape generate_week uses per day (#206, L5).

    Written to a temp file and moved into place, so a kill mid-write cannot
    leave a truncated file where a good one used to be.
    """
    try:
        output_path.parent.mkdir(parents=True, exist_ok=True)
        tmp = output_path.with_suffix(output_path.suffix + ".partial")
        tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                       encoding="utf-8")
        tmp.replace(output_path)
    except OSError as e:
        # Never fails the run: this exists to protect work, and refusing to
        # continue because the protection could not be written would destroy
        # more than it saves. It says so rather than failing silently.
        print(f"warning: could not save progress after a batch ({e}); a stop "
              "from here loses the batches read so far",
              file=sys.stderr, flush=True)


def _read_one_batch(batch: list[str], *, position: int, total: int) -> dict[str, Any] | None:
    """One batch's structured data, with the retry its single-batch sibling gets.

    A batch answering with the wrong shape used to be recorded as None and
    merged away to nothing: no retry, no salvage, no warning (#479). The
    reinforced prompt and the list salvage already existed for a one-batch
    programme, and a batch is the same failure on a bigger document.

    Returns None when the pages genuinely could not be read, having said which
    ones. None is a gap the merge skips, not an empty result that overwrites.
    """
    where = f"batch {position} of {total} ({', '.join(Path(b).name for b in batch)})"
    image_list = "\n".join(f"- {p}" for p in batch)

    data = run_json_prompt(PROMPT_TEMPLATE.format(image_list=image_list),
                           timeout=600, image_paths=batch,
                           step="ocr:focused", model=OCR_MODEL)
    if isinstance(data, dict):
        return data

    print(f"warning: OCR returned {type(data).__name__} for {where}; "
          "retrying with reinforced prompt", file=sys.stderr, flush=True)
    data = run_json_prompt(
        _REINFORCED_PREFIX + PROMPT_TEMPLATE.format(image_list=image_list),
        timeout=600, image_paths=batch, step="ocr:focused_retry",
        model=OCR_MODEL)
    if isinstance(data, dict):
        return data

    if isinstance(data, list):
        salvaged = _salvage_list_response(data)
        if salvaged:
            print(f"warning: {where} still a list after retry; salvaged as "
                  f"{[k for k, v in salvaged.items() if v]}",
                  file=sys.stderr, flush=True)
            return salvaged

    # The gap, named. Without this the programme quietly comes back read from
    # fewer pages than it has, which is the worst failure this path can produce
    # because nothing on screen distinguishes it from a complete read.
    print(f"warning: could not read {where}; the programme is missing whatever "
          "those pages held, so check the cast list and notes against the "
          "printed programme", file=sys.stderr, flush=True)
    return None


def extract_program(image_paths: list[str | Path], *,
                    output_path: Path | None = None,
                    progress_path: str | Path | None = None,
                    page_numbers: list[int] | None = None) -> dict[str, Any]:
    """Run OCR on one or more program images and return structured data.

    Accepts JPEG, PNG, and HEIC paths. HEIC files are auto-converted to
    JPEG via macOS `sips` (HEIC support requires macOS). All images are
    staged into a single temp directory which is granted to Claude via
    --add-dir.

    `page_numbers` says where each passed image sits in the whole uploaded
    programme, one per image, and is what the recorded gap is keyed to (#558).
    A RESCAN is handed a subset, so without it page 7 would be numbered 1 and a
    later merge would strike the wrong page off. Defaults to 1..N, which is
    right for a run given the whole programme.

    `progress_path` is where this run reports what it is doing (#467). The
    screen watching it used to assert "still working" from a wall clock that
    ticks whether or not this process is alive, so a hung read looked exactly
    like a slow one until the 30 minute watchdog fired. A step file is the
    run's own report, and its timestamp is what tells the two apart.
    """
    if not image_paths:
        raise ValueError("At least one image path is required")

    say = ProgressWriter(progress_path)

    with tempfile.TemporaryDirectory(prefix="postroll-ocr-") as tmp:
        tmp_path = Path(tmp)
        say.step("Preparing the program pages")
        resolved, origins = _normalize_image_paths(image_paths, tmp_path)

        # Several requests when the program is too big for one. Merged rather
        # than last-one-wins, or the notes from the first pages would silently
        # disappear behind the notes from the last (#216).
        batches = batch_images(resolved, limit_bytes=MAX_REQUEST_BYTES)
        if len(batches) > 1:
            print(f"[ocr] program too large for one request; sending "
                  f"{len(resolved)} image(s) in {len(batches)} batches",
                  file=sys.stderr, flush=True)

        per_batch: list[dict[str, Any] | None] = []
        failures: list[str] = []
        # Which pages nobody managed to read, carried in the RESULT rather than
        # only printed (#518). It lived in a log line, so closing the gap meant
        # re-running the whole scan and paying again for every page that had
        # already been read. An empty list is a real answer: it says this run
        # read everything, which a reader has to be able to tell from a result
        # too old to say either way (L11).
        unread_pages: list[str] = []
        if len(batches) == 1:
            # One batch has nothing to protect and nothing to merge: it either
            # finishes or the run produced nothing at all, so it keeps the
            # existing whole-run retry and salvage below, which needs the raw
            # non-dict response, and pays no extra write.
            image_list = "\n".join(f"- {p}" for p in batches[0])
            say.step("Reading the program", index=1, total=1)
            data = run_json_prompt(PROMPT_TEMPLATE.format(image_list=image_list),
                                   timeout=600, image_paths=batches[0],
                                   step="ocr:focused", model=OCR_MODEL)
        else:
            for position, batch in enumerate(batches, start=1):
                # Each batch is its own failure boundary (L73). Independent
                # pages sharing one try block would make every page's fate
                # depend on every other page's worst case, and the ones lost
                # are unrelated to the one that broke.
                say.step("Reading the program", index=position, total=len(batches))
                try:
                    read = _read_one_batch(batch, position=position,
                                           total=len(batches))
                    per_batch.append(read)
                    if read is None:
                        # Retried, salvaged, and still unreadable. The pages are
                        # as unread as the ones that raised.
                        unread_pages.extend(origins.get(b, b) for b in batch)
                except ClaudeError as e:
                    failures.append(f"batch {position}: {e}")
                    print(f"warning: {e} (batch {position} of {len(batches)}; "
                          "the remaining pages are still being read)",
                          file=sys.stderr, flush=True)
                    per_batch.append(None)
                    unread_pages.extend(origins.get(b, b) for b in batch)

                # On disk before the next 600s call starts, so a stop from
                # here keeps what has already been paid for (#479, #206).
                if output_path is not None:
                    so_far = merge_program_data(per_batch)
                    if isinstance(so_far, dict):
                        # The same list the finished result will carry, through
                        # the same helper: two spellings of one answer is how
                        # the crash-recovered copy and the finished one end up
                        # disagreeing about which pages to re-send (L16).
                        gap_paths, gap_numbers = unread_gap(
                            unread_pages, [str(page) for page in image_paths],
                            page_numbers)
                        so_far = {**so_far, "unread_pages": gap_paths,
                                  "unread_page_numbers": gap_numbers}
                    _write_partial(output_path, so_far)

            if not any(isinstance(r, dict) for r in per_batch):
                raise ClaudeError(
                    "Every OCR batch failed, so nothing was read from the "
                    "programme at all. "
                    + ("; ".join(failures) if failures else
                       "None of the batches returned usable data.")
                )

            data = merge_program_data(per_batch)
            # A split means no single call saw the work listing and the notes
            # section together, so the cross-page instruction in the prompt
            # could not be followed. One text-only pass puts them back (#219).
            if isinstance(data, dict):
                data = stitch_notes(data, batch_count=len(batches))

        image_list = "\n".join(f"- {p}" for p in resolved)
        base_prompt = PROMPT_TEMPLATE.format(image_list=image_list)

        # Retry once if Claude returned a top-level array (or other non-dict).
        # Some programs — especially notes/lyrics-only PDFs with no cast list —
        # push Claude into returning just a single array (usually pieces).
        if not isinstance(data, dict):
            print(
                f"warning: OCR returned {type(data).__name__}, retrying with reinforced prompt",
                file=sys.stderr,
            )
            retry_prompt = _REINFORCED_PREFIX + base_prompt
            data = run_json_prompt(retry_prompt, timeout=600, image_paths=resolved, step="ocr:focused_retry",
                               model=OCR_MODEL)

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
            say.step("Looking again for the works")
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
            say.step("Looking again for the performers")
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

    # The run is over, so the last step stops reading as in flight.
    say.finish()

    gap_paths, gap_numbers = unread_gap(
        unread_pages, [str(p) for p in image_paths], page_numbers)

    # Fill in any missing keys with empty defaults so downstream code is safe
    return {
        # The nested entries are shaped explicitly, not passed through: a field
        # renamed inside a performer, piece or scene is otherwise invisible,
        # because the outer key still arrives (#274).
        "performers": _entries(data.get("performers"), _performer_entry),
        "pieces": _entries(data.get("pieces"), _piece_entry),
        "scenes": _entries(data.get("scenes"), _scene_entry),
        "organization_notes": data.get("organization_notes", ""),
        "program_notes": data.get("program_notes", ""),
        "venue_notes": data.get("venue_notes", ""),
        "production_details": data.get("production_details", ""),
        "other": data.get("other", ""),
        # Always present, empty when the run read everything (#518). One entry
        # per page the caller passed, in the caller's order: several bands of
        # one page failing is one page to re-send, not three.
        "unread_pages": gap_paths,
        # The same gap, keyed to where each page sits in the uploaded programme,
        # which is the part a move or a rebase cannot break (#558). Paired with
        # the list above by index.
        "unread_page_numbers": gap_numbers,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Extract structured data from program photos")
    parser.add_argument(
        "--image",
        action="append",
        required=True,
        help="Path to a program photo (repeat for multi-page programs)",
    )
    parser.add_argument(
        "--page-number",
        action="append",
        type=int,
        dest="page_number",
        help="Where the matching --image sits in the whole uploaded programme, "
             "1-based, repeated once per --image (#558). This is what the "
             "recorded gap is keyed to, so a rescan of pages 3 and 7 must say "
             "so rather than letting them be counted as 1 and 2. Omit it and "
             "the images are numbered in the order they were given.",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Where to write the JSON output (defaults to stdout)",
    )
    parser.add_argument(
        "--progress",
        type=Path,
        help="Where to record what this run is doing, for the app to read (#467)",
    )
    parser.add_argument(
        "--merge-into",
        type=Path,
        help="A stored OCR result to fold this run into, for rescanning only "
             "the pages an earlier run could not read (#518). Without it, the "
             "run replaces whatever the caller had.",
    )
    args = parser.parse_args(argv)

    # Refused rather than padded or truncated, and BEFORE the paid call. A
    # numbering that does not line up with the images cannot be repaired by
    # guessing: it would silently record one page's gap against another page's
    # position, and every rescan after that strikes off the wrong page.
    if args.page_number is not None and len(args.page_number) != len(args.image):
        print(f"error: one page number per page: {len(args.page_number)} "
              f"--page-number values for {len(args.image)} --image values",
              file=sys.stderr)
        return 1

    # Read BEFORE the paid call, so an unreadable stored result costs nothing
    # and fails before the money is spent rather than after it.
    previous = None
    if args.merge_into is not None:
        try:
            previous = json.loads(args.merge_into.read_text(encoding="utf-8"))
        except (OSError, ValueError) as e:
            # Unreadable is not empty. Merging into {} would write a result
            # built from nothing back over a programme that was read and paid
            # for (L105).
            print(f"error: --merge-into {args.merge_into} could not be read, so "
                  f"there is nothing to merge into and the stored result must be "
                  f"left alone: {e}", file=sys.stderr)
            return 1
        if not isinstance(previous, dict):
            print(f"error: --merge-into {args.merge_into} does not hold an OCR "
                  f"result", file=sys.stderr)
            return 1

    try:
        # The output path goes IN, not just out (#479). Each batch of a large
        # programme is a 600s paid call, and passing the destination is what
        # lets a run stopped partway leave the batches it already read where
        # the app can find them, instead of paying for them all again.
        data = extract_program(args.image, output_path=args.output,
                               progress_path=args.progress,
                               page_numbers=args.page_number)
    except (ClaudeError, FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if previous is not None:
        # One merge rule, the same one that combines batches within a run, so
        # there is no second implementation to drift from it (#518).
        try:
            data = merge_rescan(previous, data,
                                rescanned_pages=[str(p) for p in args.image],
                                rescanned_page_numbers=args.page_number)
        except ValueError as e:
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
