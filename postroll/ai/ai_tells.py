"""
PostRoll — Humanizer Loader and Review Prompt Builder

Loads the humanizer skill (https://github.com/blader/humanizer) installed
globally at ~/.claude/skills/humanizer/SKILL.md and uses it as the rule
set for the second-pass review-and-revise that runs on every PostRoll
caption and blog. Humanizer is a curated, rewrite-focused version of the
same Wikipedia "Signs of AI writing" patterns we used to fetch directly,
plus voice-calibration and a draft → audit → revise loop.

Earlier versions of this module fetched Wikipedia directly per project
and cached the result. That mechanism is superseded — humanizer is the
single source of truth for AI tells going forward, and PostRoll uses
Dan's `brand-voice.md` as humanizer's voice calibration sample.

Usage:
    from postroll.ai.ai_tells import load_humanizer_rules, build_review_prompt
    rules = load_humanizer_rules()  # reads from default global path
    prompt = build_review_prompt(...)
"""

from __future__ import annotations

from pathlib import Path

from .claude_client import ClaudeError


# Default global install path for the humanizer skill (cloned via
# `git clone https://github.com/blader/humanizer.git ~/.claude/skills/humanizer`).
HUMANIZER_DEFAULT_PATH = Path.home() / ".claude" / "skills" / "humanizer" / "SKILL.md"


def load_humanizer_rules(path: str | Path | None = None) -> str:
    """Read the humanizer SKILL.md from disk and return its content.

    Args:
        path: Optional path to the SKILL.md. Defaults to the global
            install location at ~/.claude/skills/humanizer/SKILL.md.

    Returns:
        The full SKILL.md content as a string.

    Raises:
        FileNotFoundError: If the humanizer skill isn't installed at the
            expected path. Install with:
                git clone https://github.com/blader/humanizer.git \\
                    ~/.claude/skills/humanizer
    """
    p = Path(path).expanduser().resolve() if path else HUMANIZER_DEFAULT_PATH
    if not p.exists():
        raise FileNotFoundError(
            f"Humanizer skill not found at {p}. Install it with:\n"
            f"  git clone https://github.com/blader/humanizer.git "
            f"{HUMANIZER_DEFAULT_PATH.parent}"
        )
    return p.read_text(encoding="utf-8")


def is_humanizer_available(path: str | Path | None = None) -> bool:
    """Check whether the humanizer skill is installed and readable."""
    p = Path(path).expanduser().resolve() if path else HUMANIZER_DEFAULT_PATH
    return p.exists()


def build_review_prompt(
    *,
    draft_json: str,
    humanizer_rules: str,
    brand_voice: str,
    output_shape_description: str,
) -> str:
    """Build a second-pass prompt that reviews a draft and returns a cleaned version.

    The first pass generates a draft. The second pass (this prompt) takes
    the draft, runs it through humanizer's rewrite logic with Dan's brand
    voice as the voice calibration sample, applies fixes, and returns the
    SAME JSON shape with cleaned text in each field.

    Args:
        draft_json: The first-pass output as a JSON string.
        humanizer_rules: The humanizer SKILL.md content.
        brand_voice: The brand voice doc text — used as the voice
            calibration sample so the rewrite matches Dan's voice rather
            than humanizer's default.
        output_shape_description: One-line description of what shape the
            cleaned JSON should keep.
    """
    return f"""\
You are humanizer, a writing editor. You apply the rules in the document
below to remove AI writing tells from a draft, while matching the voice
calibration sample provided.

---

## HUMANIZER RULES (the source of truth for what counts as an AI tell)

{humanizer_rules}

---

## VOICE CALIBRATION SAMPLE (match this voice in your rewrite)

This is Dan Wright Photography's brand voice. When you rewrite the
draft below, do not just remove AI tells — match this voice:

{brand_voice}

---

## THE DRAFT TO REWRITE

```json
{draft_json}
```

## YOUR PROCESS

1. Read the draft carefully.
2. Identify AI tells using the humanizer rules above.
3. Identify brand voice violations using the voice calibration sample.
4. Apply humanizer's "draft → audit → revise" loop:
   a. Mentally produce a first rewrite that fixes the obvious issues.
   b. Ask yourself: "What makes this still obviously AI generated?"
   c. List the remaining tells in your head (do NOT output them).
   d. Revise once more to fix those.
5. Return the final cleaned version in the SAME JSON shape as the
   input ({output_shape_description}).

## CRITICAL OUTPUT RULES

- Return ONLY the cleaned JSON. No commentary, no markdown fences, no
  "here's what I changed", no diff, no draft-vs-final.
- Preserve every key in the input. Don't drop fields.
- For lists like hashtags, keep them unchanged unless one of the
  hashtags itself contains an AI tell.
- For lists of strings (alt_texts, scene_labels), preserve count and
  order — clean each item in place.
- Do NOT return the original draft. Return the revised version.
- If the draft is already clean, return it unchanged.
"""
