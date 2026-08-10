"""
PostRoll — OCR Enrichment via Web Research

When OCR output is thin (common for plays, rock shows, improv nights, dance
performances — anything where the program is just a marketing blurb),
automatically enrich the data by searching the web for cast, creative team,
director, playwright, band members, tour info, etc.

The user can optionally pass a `hint` which is either freeform text (e.g.
"The Pushover at Chain Theatre") or a URL (e.g.
https://www.chaintheatre.org/the-pushover). A URL is a STARTING point for
research, not a stopping point — Claude fetches it for initial context,
then keeps searching the web for additional facts.

Enrichment preserves existing OCR data and fills in gaps. It should not
overwrite fields that already have content from the physical program.

Usage:
    python -m postroll.ai.enrich_program \\
        --program output/program.json \\
        --image path/to/program.heic \\
        --hint "https://www.chaintheatre.org/the-pushover" \\
        --output output/program_enriched.json
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from .claude_client import run_json_prompt, ClaudeError
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


# Thresholds for "thin" detection — all must be true for enrichment to trigger
THIN_MAX_PERFORMERS = 1
THIN_MAX_PIECES = 1
THIN_MAX_NOTES_CHARS = 500  # combined organization_notes + program_notes + production_details


def is_thin(ocr_data: dict[str, Any]) -> bool:
    """Heuristic: does this OCR output need web research enrichment?

    Returns True when the program gave us almost nothing to work with —
    empty or near-empty performer list, empty or near-empty pieces list,
    and minimal narrative notes. That's the signature of a play/rock
    show/improv night where the program is just a marketing blurb.
    """
    performers = ocr_data.get("performers") or []
    pieces = ocr_data.get("pieces") or []
    notes = (
        (ocr_data.get("organization_notes") or "")
        + (ocr_data.get("program_notes") or "")
        + (ocr_data.get("production_details") or "")
    )
    return (
        len(performers) <= THIN_MAX_PERFORMERS
        and len(pieces) <= THIN_MAX_PIECES
        and len(notes) < THIN_MAX_NOTES_CHARS
    )


PROMPT_TEMPLATE = """\
You are enriching thin OCR output from a performing arts event program by
researching the web. The program didn't give Dan much — maybe just a
marketing tagline, a short blurb, or a cover image. Your job is to figure
out what the event actually is and fill in the gaps so a blog post and
captions can be written about it.

The event could be any genre of live performance: a play, musical, opera,
classical concert, rock show, dance performance, improv night — anything.
Don't assume classical music.

Current (thin) OCR data:
```json
{ocr_json}
```

Original program images (read them to extract any identifying text —
titles, taglines, venue names, dates, logos, production credits):
{image_list}

{hint_section}

Your process:

1. **Read the program images first.** Extract whatever identifying text
   you can see — title, tagline, venue, dates, production company, QR
   code destinations, logos. This is your strongest signal for what to
   search for.
{hint_process}
3. **Use WebSearch** to find additional context beyond the hint (if given)
   or to identify the event from scratch (if no hint). Search for:
   - The specific event title + venue + year
   - Reviews or previews of the production
   - The production company or organization
   - Cast, creative team, director, playwright, composer, choreographer
   - Run dates, any tour info
   - Anything about the work itself (history, themes, context) that would
     help write a specific blog post
4. **Cross-reference.** If the hint URL is for a different production or
   the same title from a different year, notice that and keep searching
   until you're confident you have the right event.
5. **Merge findings into the OCR schema.** Preserve anything already in
   the OCR data — don't overwrite existing fields that have real content.
   Only fill in gaps.

Return JSON ONLY (no markdown fences, no commentary) matching this schema:

{{
  "performers": [
    {{
      "name": "string",
      "role": "soloist | conductor | ensemble | composer | actor | dancer | band_member | troupe | director | other",
      "voice_or_instrument": "string or null"
    }}
  ],
  "pieces": [
    {{
      "composer": "string — creator of this work (composer/playwright/choreographer/band/etc)",
      "title": "string",
      "movements": ["string", ...],
      "notes": "string or null"
    }}
  ],
  "scenes": [
    {{
      "name": "short label like 'spa scene' or 'Act II finale' or 'second movement'",
      "location": "where this scene takes place if relevant, or null",
      "visual_cues": "concrete visible things a photographer would see: specific props, costume colors/styles, set pieces, number of people, lighting state. NOT mood or atmosphere — actual objects. Example: 'two actors at small table, one in red dress' or 'full chorus in black, conductor at podium'",
      "description": "what happens in this scene, if known, or null"
    }}
  ],
  "organization_notes": "string",
  "program_notes": "string",
  "venue_notes": "string",
  "production_details": "string — director, creative team, run dates, tour info",
  "other": "string",
  "_enrichment": {{
    "researched_event_identity": "short description of what you concluded this event is, e.g. 'The Pushover by Kate Gill at Chain Theatre, Feb-Mar 2026'",
    "sources_used": ["list of URLs or search query results you relied on"],
    "enriched_fields": ["list of field paths that came from web research vs. original OCR, e.g. ['performers', 'production_details', 'program_notes']"],
    "confidence": "high | medium | low",
    "notes_for_human": "anything the photographer should double-check before publishing — conflicts between sources, ambiguity about which production, dates that don't quite match, etc."
  }}
}}

Rules:
- The `_enrichment` block is required on enriched output — it's how the
  GUI knows what came from research vs. the program itself. Flag pass
  will be extra skeptical of enriched fields.
- For `scenes`, look for any mention of distinct settings, locations,
  scenes, sets, acts, or sections in the synopsis/reviews/web research.
  Populate one entry per distinct scene with the most concrete visual_cues
  you can find — specific props, costume details, set pieces, staging,
  not mood or atmosphere. The caption generator matches photos by looking
  for literal visible objects, so "red dress, small table, two actors" is
  far more useful than "intimate restaurant atmosphere".
- Don't fabricate. If you can't find solid information about something,
  leave the field empty rather than guessing. Note the gap in
  `notes_for_human`.
- Don't pull in facts about a different production just because the title
  matches. Pay attention to venue, year, and creative team to disambiguate.
- Return ONLY the JSON object. No explanation before or after.
"""


HINT_SECTION_WITH = """\
Hint from the photographer (use this as a starting point but DON'T stop
here — always search for more context beyond the hint):
{hint}
"""

HINT_SECTION_WITHOUT = """\
No hint was provided. Identify the event from the program images alone.
"""


def _hint_looks_like_url(hint: str) -> bool:
    return hint.strip().lower().startswith(("http://", "https://"))


def _build_hint_sections(hint: str | None) -> tuple[str, str]:
    """Return (hint_section, hint_process_step_2) tuple for the prompt."""
    if not hint:
        return HINT_SECTION_WITHOUT, ""
    section = HINT_SECTION_WITH.format(hint=hint)
    if _hint_looks_like_url(hint):
        process = (
            "2. **Fetch the hint URL first.** The photographer gave you a URL: "
            f"{hint.strip()}\n"
            "   Use WebFetch to pull it in for initial context. This is the\n"
            "   starting point, NOT the final answer — still do step 3.\n"
        )
    else:
        process = (
            "2. **Use the text hint as a search seed.** The photographer said: "
            f"{hint.strip()!r}\n"
            "   Search for this in combination with venue and dates to narrow down.\n"
        )
    return section, process


def enrich_program(
    ocr_data: dict[str, Any],
    image_paths: list[str | Path],
    hint: str | None = None,
) -> dict[str, Any]:
    """Enrich thin OCR output by researching the web.

    Args:
        ocr_data: Current (thin) OCR output from ocr_program.
        image_paths: Original program images.
        hint: Optional URL or freeform text. URLs are starting points,
              not stopping points — Claude still searches beyond them.

    Returns:
        Enriched dict with the same schema as OCR output, plus an
        `_enrichment` metadata block noting which fields came from
        research.
    """
    if not image_paths:
        raise ValueError("At least one image path is required")

    hint_section, hint_process = _build_hint_sections(hint)

    with tempfile.TemporaryDirectory(prefix="postroll-enrich-") as tmp:
        tmp_path = Path(tmp)
        staged: list[str] = []
        for i, p in enumerate(image_paths):
            src = Path(p).expanduser().resolve()
            if not src.exists():
                raise FileNotFoundError(f"Program image not found: {src}")
            if src.suffix.lower() in HEIC_SUFFIXES:
                dest = _convert_heic_to_jpeg(src, tmp_path, prefix=f"{i:03d}_")
            else:
                dest = tmp_path / f"{i:03d}_{src.name}"
                shutil.copy2(src, dest)
            staged.append(str(dest))

        image_list = "\n".join(f"- {p}" for p in staged)

        prompt = PROMPT_TEMPLATE.format(
            ocr_json=json.dumps(ocr_data, indent=2, ensure_ascii=False),
            image_list=image_list,
            hint_section=hint_section,
            hint_process=hint_process,
        )

        data = run_json_prompt(
            prompt,
            timeout=900,  # web research can take a while
            allowed_dirs=[tmp_path],
            allowed_tools=["Read", "WebSearch", "WebFetch"],
            step="enrich",
        )

    if not isinstance(data, dict):
        raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

    # Merge enriched fields over the OCR data. The prompt tells Claude to
    # preserve existing content, but that guarantee must live in code: the
    # full schema response routinely contains empty lists and strings, and
    # an empty enrichment value must never erase real OCR content.
    def merge(key: str, default: Any) -> Any:
        enriched = data.get(key)
        existing = ocr_data.get(key, default)
        if enriched is None:
            return existing
        if not enriched and existing:
            return existing
        return enriched

    result = {
        "performers": merge("performers", []),
        "pieces": merge("pieces", []),
        "scenes": merge("scenes", []),
        "organization_notes": merge("organization_notes", ""),
        "program_notes": merge("program_notes", ""),
        "venue_notes": merge("venue_notes", ""),
        "production_details": merge("production_details", ""),
        "other": merge("other", ""),
        "_enrichment": data.get("_enrichment", {}),
    }
    return result


FETCH_PERFORMERS_PROMPT = """\
Fetch the event page at this URL and extract the performing artists:

{url}

Use WebFetch to load the page. Then return a JSON array of performers.

**What to include:**
- Named conductors (e.g. "Jennaya Robison, Conductor")
- Participating ensembles / choirs / orchestras by their official group name
- Named featured soloists
- Composers or arrangers if listed as participants

**What NOT to include:**
- Individual singers listed within a choir roster
- Individual orchestral musicians listed in a section roster
- Staff, admin, or non-performing credits (directors, designers, etc.)
- Sponsors, donors, board members

The goal is a CURATED list of the top-level performers — the names that
would appear in a photo caption or blog credit line. For a large choral
concert, that's the conductors + the choir/orchestra names, not every member.

Return JSON ONLY (no markdown fences) as an array:

[
  {{
    "name": "string — exact name as printed on the page",
    "role": "soloist | conductor | ensemble | composer | other",
    "voice_or_instrument": "string or null"
  }}
]

Rules:
- NEVER invent names. Only include names you can see on the fetched page.
- For ensembles, use the full official group name as `name`.
- If the page doesn't have a cast/artist list, return an empty array [].
- Return ONLY the JSON array. No explanation.
"""



# ── shaping what Claude returns (#273) ────────────────────────────────────────
#
# These three payloads used to be handed to the app exactly as Claude produced
# them, so their field names lived only in the prompt text above. The app reads
# by key and its decoders tolerate anything missing, so a renamed field would
# have arrived as a silent blank on the one path whose whole job is filling in
# facts about real people. A rule that lives only in a prompt is a hope (L27),
# and this is the deterministic check at the boundary.
#
# Each also gives the key contract something to read, which is why the shapes
# are dict literals rather than a passthrough.

def _clean(value: object) -> str | None:
    """A trimmed string, or None when there is nothing there.

    None rather than "" so the app can tell "no account exists" from "we never
    looked", which are different answers to Dan.
    """
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    return trimmed or None


def _normalise_performers(data: list) -> list[dict]:
    """The performer list the app decodes, with every key present.

    A different shape from a handle suggestion, which is a separate lookup: this
    is who was on stage, that is where to find them online.

    An entry with no name is dropped: it cannot be credited, matched to a photo
    or tagged, so it is not a performer, and keeping it puts a blank row in
    front of Dan.
    """
    out = []
    for raw in data:
        if not isinstance(raw, dict):
            continue
        name = _clean(raw.get("name"))
        if not name:
            continue
        out.append({
            "name":                name,
            # "other" rather than a guess: the role drives how someone is
            # credited, and inventing "soloist" for an unstated role would put
            # a claim in a caption that nothing supports.
            "role":                _clean(raw.get("role")) or "other",
            "voice_or_instrument": _clean(raw.get("voice_or_instrument")),
        })
    return out


def _normalise_handle_suggestions(data: list) -> list[dict]:
    """Suggested social handles, keyed by the name they were searched for.

    The name is what the suggestion is applied back against, so an entry
    without one has nothing to attach to.
    """
    out = []
    for raw in data:
        if not isinstance(raw, dict):
            continue
        name = _clean(raw.get("name"))
        if not name:
            continue
        out.append({
            "name":        name,
            "handle":      _clean(raw.get("handle")),
            "profile_url": _clean(raw.get("profile_url")),
            # Low, not high: an unstated confidence is not a confident answer,
            # and defaulting the other way presents a guess as verified.
            "confidence":  _clean(raw.get("confidence")) or "low",
            "note":        _clean(raw.get("note")),
        })
    return out


def _normalise_piece_notes(data: list) -> list[dict]:
    """Programme notes per work, with every key present.

    A piece whose lookup found nothing is KEPT, with `notes` None: that records
    that the lookup happened, which is what stops it being paid for again.
    """
    out = []
    for raw in data:
        if not isinstance(raw, dict):
            continue
        title = _clean(raw.get("title"))
        if not title:
            continue
        out.append({
            "title":    title,
            "composer": _clean(raw.get("composer")) or "",
            "notes":    _clean(raw.get("notes")),
        })
    return out


def fetch_performers_from_url(url: str) -> list[dict]:
    """Fetch an event page and extract the curated performer list.

    Returns conductors + named groups/ensembles + soloists.
    Does NOT include individual choir/orchestra members.

    Raises ClaudeError if the fetch or extraction fails.
    """
    prompt = FETCH_PERFORMERS_PROMPT.format(url=url)
    data = run_json_prompt(
        prompt,
        timeout=120,
        allowed_tools=["WebFetch"],
        step="enrich:performers",
    )
    if not isinstance(data, list):
        raise ClaudeError(f"Expected JSON array, got {type(data).__name__}")
    return _normalise_performers(data)


SUGGEST_HANDLES_PROMPT = """\
Search the web for the official Instagram accounts of the following
performing artists / ensembles / organizations. The context is a live
performance event — these are musicians, conductors, theater companies,
choirs, orchestras, etc.

Event context (use this to disambiguate common names):
- Organization: {org}
- Venue: {venue}
- Event: {event}

Performers to look up:
{performer_list}

For EACH performer, use WebSearch with MULTIPLE search strategies until
you find a result or exhaust all options:

1. **Site-restricted search first**: "<name> site:instagram.com"
   This surfaces Instagram profiles directly and is the most reliable.
2. **General search**: "<name> instagram"
3. **Keyword variations for ensembles/orgs**: try abbreviations, initials,
   or key words. E.g. for "Eastern Sierra Community Chorus" also try
   "eastern sierra chorus site:instagram.com" or "ESCC instagram".
4. **Parent organization search** (for school/church/community groups):
   if the ensemble is part of a larger org (e.g. "Singing Sergeants of
   Wilson Memorial High School"), also search for the school/church/org
   instagram — the ensemble often posts from the parent account, not its
   own. Try "<school name> instagram" or "<school name> choir instagram".
5. **Verify the profile**: When you find a candidate handle, use WebFetch
   on "https://www.instagram.com/<handle>/" to confirm the profile exists
   and matches the performer. Check that the bio or page title relates to
   performing arts / the organization in question.

Do NOT stop after the first search if it returns no results — try at
least 3-4 different query variations before giving up.

Return JSON ONLY (no markdown fences) as an array with one entry per
performer, in the SAME ORDER as the input list:

[
  {{
    "name": "exact name from the input list",
    "handle": "@theirhandle or null if not found",
    "profile_url": "https://www.instagram.com/theirhandle/ or null",
    "confidence": "high | medium | low",
    "note": "short reason for confidence level, e.g. 'verified account' or 'common name, multiple matches'"
  }}
]

Rules:
- Only suggest handles you actually found via search. NEVER guess or fabricate.
- "high" confidence: the account name/bio clearly matches the performer
  and the content is consistent (photos of performances, music, etc.).
  Also "high" if you successfully fetched the Instagram profile page and
  confirmed the bio matches.
- "medium": likely match but can't be 100% certain (e.g. no verification,
  bio is vague but name matches).
- "low": possible match but ambiguous (common name, multiple candidates).
- If you can't find an Instagram account at all, set handle and
  profile_url to null with confidence "low" and note "not found".
- For ensembles/organizations, look for their official org account.
- Return ONLY the JSON array. No explanation.
"""


def suggest_handles(
    performers: list[dict[str, Any]],
    org: str = "",
    venue: str = "",
    event: str = "",
) -> list[dict[str, Any]]:
    """Search the web for Instagram handles for a list of performers.

    Returns a list of suggestions with handle, profile_url, confidence, and note.
    """
    names = [p.get("name", "?") for p in performers if p.get("name")]
    if not names:
        return []

    performer_list = "\n".join(f"- {n}" for n in names)
    prompt = SUGGEST_HANDLES_PROMPT.format(
        org=org or "(not specified)",
        venue=venue or "(not specified)",
        event=event or "(not specified)",
        performer_list=performer_list,
    )
    data = run_json_prompt(
        prompt,
        timeout=600,
        allowed_tools=["WebSearch", "WebFetch"],
        step="enrich:piece_notes",
    )
    # Claude sometimes wraps the array in an object — unwrap it
    if isinstance(data, dict):
        # Try common wrapper keys
        for key in ("suggestions", "performers", "results", "data"):
            if key in data and isinstance(data[key], list):
                data = data[key]
                break
        else:
            # If there's exactly one key whose value is a list, use it
            lists = [v for v in data.values() if isinstance(v, list)]
            if len(lists) == 1:
                data = lists[0]
            elif "name" in data:
                # Single suggestion returned as a bare dict — wrap it
                data = [data]
    if not isinstance(data, list):
        keys = list(data.keys()) if isinstance(data, dict) else []
        raise ClaudeError(
            f"Expected JSON array, got {type(data).__name__} with keys {keys}"
        )
    return _normalise_handle_suggestions(data)


FETCH_PIECE_NOTES_PROMPT = """\
Find brief, factual program notes for each of these works. The user is a
photographer writing captions and a blog post about a live performance — they
need 1-2 sentences (3-4 max if absolutely necessary) per piece that capture
something interesting and concrete: when it was written, what it's about,
why it's notable, or a specific musical/dramatic feature. NOT composer
biography (we already have that elsewhere).

Event context (for disambiguation only — don't infer arrangements or versions
that aren't stated):
- Organization: {org}
- Event: {event}

Pieces to research (preserving the order — return notes in the same order):
{piece_list}

For each piece, use WebSearch to find what's commonly written about it in
program notes / liner notes / scholarly summaries. Then distill into 1-2
sentences. Hard cap: 4 sentences.

Style:
- Concrete facts, not adjectives. "Premiered in 1934 in Leningrad and dedicated
  to cellist Viktor Kubatsky" beats "a beloved staple of the cello repertoire".
- Specific over general. "Four movements, with a haunting Largo at the heart"
  beats "a deeply emotional work".
- No composer biography. We already have the composer field.
- No filler ("This piece is a wonderful example of…").
- If you genuinely can't find anything specific, return null for that entry —
  do NOT pad with generic prose.

Return JSON ONLY (no markdown fences, no commentary) as an array with one
entry per piece, in the SAME ORDER as the input list:

[
  {{
    "title": "exact title from the input",
    "composer": "exact composer from the input",
    "notes": "1-2 sentence note, or null if nothing solid was found"
  }}
]

Return ONLY the JSON array. No explanation.
"""


def fetch_piece_notes(
    pieces: list[dict[str, Any]],
    org: str = "",
    event: str = "",
) -> list[dict[str, Any]]:
    """Search the web for short program notes for a list of pieces.

    Returns a list aligned to the input order, each with `title`, `composer`,
    and `notes` (string or None). Pieces are not filtered here — the caller
    decides which ones to send.
    """
    if not pieces:
        return []

    lines = []
    for i, p in enumerate(pieces, start=1):
        composer = (p.get("composer") or "").strip() or "(unknown)"
        title    = (p.get("title")    or "").strip() or "(untitled)"
        lines.append(f"{i}. \"{title}\" — {composer}")
    piece_list = "\n".join(lines)

    prompt = FETCH_PIECE_NOTES_PROMPT.format(
        org=org or "(not specified)",
        event=event or "(not specified)",
        piece_list=piece_list,
    )
    data = run_json_prompt(
        prompt,
        timeout=600,
        allowed_tools=["WebSearch", "WebFetch"],
        step="enrich:handles",
    )
    # Unwrap if Claude wrapped the array in an object
    if isinstance(data, dict):
        for key in ("notes", "pieces", "results", "data"):
            if key in data and isinstance(data[key], list):
                data = data[key]
                break
        else:
            lists = [v for v in data.values() if isinstance(v, list)]
            if len(lists) == 1:
                data = lists[0]
    if not isinstance(data, list):
        raise ClaudeError(f"Expected JSON array, got {type(data).__name__}")
    return _normalise_piece_notes(data)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Enrich thin OCR output via web research"
    )
    parser.add_argument(
        "--fetch-performers",
        metavar="URL",
        help="Fetch performers from an event page URL and write a JSON array to --output",
    )
    parser.add_argument(
        "--program",
        type=Path,
        help="Path to OCR program JSON from ocr_program",
    )
    parser.add_argument(
        "--image",
        action="append",
        help="Path to a program photo (repeat for multi-page)",
    )
    parser.add_argument(
        "--hint",
        help="Optional URL or text hint about the event (e.g. 'https://chaintheatre.org/the-pushover' or 'The Pushover at Chain Theatre')",
    )
    parser.add_argument(
        "--suggest-handles",
        type=Path,
        metavar="JSON",
        help="Path to a JSON file with {performers, org, venue, event}. Searches the web for Instagram handles.",
    )
    parser.add_argument(
        "--fetch-piece-notes",
        type=Path,
        metavar="JSON",
        help="Path to a JSON file with {pieces, org, event}. Searches the web for short program notes per piece.",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="Run enrichment even if the OCR data doesn't look thin",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Where to write enriched JSON (defaults to stdout)",
    )
    args = parser.parse_args()

    # --fetch-piece-notes mode: short program notes per piece via web search
    if args.fetch_piece_notes:
        try:
            input_data = json.loads(args.fetch_piece_notes.read_text(encoding="utf-8"))
            results = fetch_piece_notes(
                pieces=input_data.get("pieces", []),
                org=input_data.get("org", ""),
                event=input_data.get("event", ""),
            )
        except (ClaudeError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        text = json.dumps(results, indent=2, ensure_ascii=False)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(text + "\n", encoding="utf-8")
            print(f"wrote {args.output} ({len(results)} piece notes)")
        else:
            print(text)
        return 0

    # --suggest-handles mode: search for Instagram handles for performers
    if args.suggest_handles:
        try:
            input_data = json.loads(args.suggest_handles.read_text(encoding="utf-8"))
            suggestions = suggest_handles(
                performers=input_data.get("performers", []),
                org=input_data.get("org", ""),
                venue=input_data.get("venue", ""),
                event=input_data.get("event", ""),
            )
        except (ClaudeError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        text = json.dumps(suggestions, indent=2, ensure_ascii=False)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(text + "\n", encoding="utf-8")
            print(f"wrote {args.output} ({len(suggestions)} suggestions)")
        else:
            print(text)
        return 0

    # --fetch-performers mode: fetch a URL and return just the performers array
    if args.fetch_performers:
        try:
            performers = fetch_performers_from_url(args.fetch_performers)
        except (ClaudeError, ValueError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 1
        text = json.dumps(performers, indent=2, ensure_ascii=False)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(text + "\n", encoding="utf-8")
            print(f"wrote {args.output} ({len(performers)} performers)")
        else:
            print(text)
        return 0

    if not args.program:
        print("error: --program is required unless --fetch-performers is used", file=sys.stderr)
        return 1

    ocr_data = json.loads(args.program.read_text(encoding="utf-8"))

    if not args.force and not is_thin(ocr_data):
        print(
            "OCR data is not thin — enrichment skipped. Use --force to override.",
            file=sys.stderr,
        )
        return 0

    try:
        enriched = enrich_program(ocr_data, args.image, hint=args.hint)
    except (ClaudeError, FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    text = json.dumps(enriched, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n", encoding="utf-8")
        confidence = enriched.get("_enrichment", {}).get("confidence", "?")
        identity = enriched.get("_enrichment", {}).get("researched_event_identity", "?")
        print(f"wrote {args.output}")
        print(f"  event: {identity}")
        print(f"  confidence: {confidence}")
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
