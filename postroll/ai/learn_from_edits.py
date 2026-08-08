"""
PostRoll — Learn from Caption Edits

Analyzes the delta between generated captions and Dan's approved versions
to surface new brand voice patterns not yet captured in brand-voice.md.
If no meaningful new pattern is found, returns {"suggestion": null}.

Input manifest (written by the Swift app):
{
  "brand_voice": "...full brand voice doc...",
  "edits": [
    {
      "day": "sunday",
      "original_caption": "...",
      "approved_caption": "..."
    },
    ...
  ]
}

Output JSON (written to --output):
{"suggestion": "...one concise brand voice rule..."}
or
{"suggestion": null}

Usage:
    python -m postroll.ai.learn_from_edits \\
        --manifest /tmp/edits.json \\
        --output   /tmp/suggestion.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .claude_client import run_json_prompt, load_brand_voice, ClaudeError


LEARN_PROMPT = """\
You are a writing coach analyzing the gap between AI-generated captions and
the version a specific photographer (Dan Wright) actually approved.

Your job is NOT to rewrite anything. Your job is to look at Dan's edits and
extract ONE useful brand voice rule that isn't already in his brand voice doc.

---

## DAN'S CURRENT BRAND VOICE DOC

{brand_voice}

---

## CAPTION PAIRS (original AI draft → what Dan actually approved)

{edit_pairs}

---

## YOUR TASK

1. Look at what Dan changed in each pair. What pattern do you see?
2. Check the brand voice doc above. Is this pattern ALREADY captured there?
   - If yes: return {{"suggestion": null}}. Don't repeat what's already documented.
3. If you find something NEW that Dan consistently prefers but isn't in the doc:
   - Write ONE concise rule in Dan's voice (first person: "I prefer...", "avoid...",
     "don't...") that captures this preference.
   - Keep it specific and actionable. Bad: "Be more natural." Good: "Don't open
     with a name — put the person's role or the moment first."
   - If the edit is too minor or idiosyncratic to be a general rule, return null.

Return ONLY JSON (no markdown fences, no commentary):
{{"suggestion": "...one rule..." | null}}

If nothing new: {{"suggestion": null}}
"""


def _format_edit_pairs(edits: list[dict]) -> str:
    lines = []
    for i, edit in enumerate(edits, 1):
        day = edit.get("day", f"day {i}")
        original = edit.get("original_caption", "").strip()
        approved = edit.get("approved_caption", "").strip()
        if not original or not approved or original == approved:
            continue
        lines.append(f"### {day.title()} (pair {i})")
        lines.append(f"**AI generated:**\n{original}")
        lines.append(f"**Dan approved:**\n{approved}")
        lines.append("")
    return "\n".join(lines).strip()


def learn_from_edits(
    *,
    brand_voice: str,
    edits: list[dict],
) -> dict:
    """Analyze edit pairs and return a brand voice suggestion or null.

    Args:
        brand_voice: Current brand voice doc text.
        edits: List of {day, original_caption, approved_caption} dicts.

    Returns:
        {"suggestion": "...rule..."} or {"suggestion": None}
    """
    # Filter to pairs that actually differ
    meaningful = [
        e for e in edits
        if e.get("original_caption", "").strip() != e.get("approved_caption", "").strip()
        and e.get("original_caption", "").strip()
        and e.get("approved_caption", "").strip()
    ]
    if not meaningful:
        return {"suggestion": None}

    edit_pairs_text = _format_edit_pairs(meaningful)
    if not edit_pairs_text:
        return {"suggestion": None}

    prompt = LEARN_PROMPT.format(
        brand_voice=brand_voice,
        edit_pairs=edit_pairs_text,
    )

    data = run_json_prompt(prompt, timeout=120, step="learn_from_edits")
    if not isinstance(data, dict):
        return {"suggestion": None}

    raw = data.get("suggestion")
    if not raw or not isinstance(raw, str) or not raw.strip():
        return {"suggestion": None}

    return {"suggestion": raw.strip()}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Learn brand voice rules from caption edits")
    parser.add_argument("--manifest", required=True, help="Path to edits manifest JSON")
    parser.add_argument("--output",   required=True, help="Path to write suggestion JSON")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"Manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(1)

    m = json.loads(manifest_path.read_text(encoding="utf-8"))
    brand_voice_text = m.get("brand_voice") or load_brand_voice()
    edits_list = m.get("edits", [])

    try:
        result = learn_from_edits(brand_voice=brand_voice_text, edits=edits_list)
    except ClaudeError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)

    Path(args.output).write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
