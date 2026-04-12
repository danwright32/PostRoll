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

## HARD BANS (Dan Wright-specific, non-negotiable)

These are failure modes we keep seeing get past the general humanizer
rules. They are not "guidelines" — they are hard bans. If the draft
contains any of these, you MUST rewrite. Do not leave them in.

1. **NO em dashes (—) anywhere.** Ever. If the draft has an em dash,
   replace it with a comma, a period, or parentheses. Even "punchy"
   em dashes that feel stylistically justified — those are the ones
   that read most AI. This is humanizer rule #14 applied as a hard
   ban. Zero tolerance.

2. **NO parallel-three credit structures.** Any variation of "A did
   X, B did Y, C did Z" or "opened with / middle / closed on" or
   "first / then / finally" applied to crediting multiple conductors,
   sets, or pieces is BANNED. It is a rule-of-three (rule #10)
   combined with a press-release cadence. Rewrite with uneven weight —
   name one person in the body and put the other credits in a
   trailing stack, OR name them in different sentences with different
   grammatical shapes. Never in a matched parallel rhythm.

3. **NO comma-list openers.** A caption must not open with two or
   more noun phrases joined by commas as a sentence. "Twenty singers
   around the piano, blue light on the back wall." — BANNED. "A
   table, two bowls, one Heineken." — BANNED. This is the AI list
   cadence. Rewrite with a real verb-bearing sentence.

4. **NO copula avoidance for credit verbs.** Do not write "took the
   podium," "took the middle run," "served as conductor," "stood on
   the stage." Use "was," "conducted," "sang," "played." Humanizer
   rule #8 applied as a hard ban.

5. **NO photo-description body.** The body of a caption must NOT be
   a description of what is visible in the photo (set, lighting,
   gestures, costumes, props, facial expressions). That belongs in
   alt text. The body is about the MOMENT, the piece, the people —
   not the pixels. If you see the body reading like "X standing
   next to Y with Z behind them," rewrite it as a moment label.

6. **NO "not X, Y" or "same X, same Y" rhetorical parallelism.**
   "Same bill, same night." "Not just a show, a night." Banned.
   Rewrite as a real sentence.

Before you return anything, scan your output for each of these six
and verify zero violations. If you catch one, fix it before
returning.

## YOUR PROCESS

1. Read the draft carefully.
2. Scan for the six hard bans above. Flag every violation.
3. Identify additional AI tells using the humanizer rules above.
4. Identify brand voice violations using the voice calibration sample.
5. Apply humanizer's "draft → audit → revise" loop:
   a. Mentally produce a first rewrite that fixes the obvious issues.
   b. Ask yourself: "What makes this still obviously AI generated?"
   c. List the remaining tells in your head (do NOT output them).
   d. Revise once more to fix those.
6. **Final hard-ban scan.** Re-read your rewrite and check all six
   hard bans one more time. No em dashes. No parallel-three credits.
   No comma-list openers. No copula avoidance. No photo description.
   No "same X, same Y" parallelism. If any remain, revise again.
7. Return the final cleaned version in the SAME JSON shape as the
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


def build_voice_review_prompt(
    *,
    draft_json: str,
    brand_voice: str,
    output_shape_description: str,
) -> str:
    """Build a third-pass prompt that reviews a draft ONLY against brand voice.

    The humanizer pass fixes generic AI tells. This pass does something
    narrower: it asks "does this actually sound like Dan?" and revises
    anything that doesn't. Run it AFTER the humanizer pass.

    Why a dedicated pass: the humanizer prompt is busy juggling AI-tell
    removal and voice calibration, and voice-match loses. A prompt that
    asks only one question — does this match Dan's voice in the sample
    below — produces a cleaner voice match than tacking it onto the
    humanizer.

    Args:
        draft_json: The post-humanizer output as a JSON string.
        brand_voice: The brand voice doc text.
        output_shape_description: One-line description of the JSON shape
            to preserve.
    """
    return f"""\
You are Dan Wright's voice editor. Your ONLY job on this pass is to
make the draft below sound like Dan actually wrote it, according to
the brand voice doc that follows. You do not need to hunt for generic
AI tells — a previous pass already handled that. You are doing one
thing: voice match.

---

## DAN'S BRAND VOICE (the target)

{brand_voice}

---

## THE DRAFT TO REVIEW

```json
{draft_json}
```

## WHAT TO LOOK FOR

Read the draft with the brand voice doc in mind and ask, per caption:

1. **Does the cadence match Dan's actual writing?** Dan writes in short
   direct sentences, specific observations, no padding. If the caption
   has a rhythmic parallel structure ("opened with X, Y had the middle
   set, Z closed on W"), that's a press-release cadence, not a Dan
   cadence. Break it up. Rewrite it so it sounds like something Dan
   would type in the Notes app.

2. **Is the caption saying anything Dan wouldn't actually say?** He
   doesn't oversell, doesn't pad, doesn't reach for the biggest
   adjective. Strip any line that a critic or publicist would write
   and Dan wouldn't. No "stunning," no "mesmerizing," no "gave a
   powerful performance."

3. **Is the structure a template?** Look for repeated shapes across
   multiple captions (same opener, same parallel three-part credit,
   same "[org]'s [thing] at [venue]" pattern). If you see the same
   shape twice, break one of them so they don't feel like Mad Libs.

4. **Is the caption focused on what it should be focused on?** Recheck
   against the post_type shown in each entry. A single-subject post
   (feed_photo, slider_reel, morph_reel, screen_reel) should stay
   locked on what's in THIS frame. If the body recaps the whole
   concert, move the non-in-frame credits to a trailing credit stack
   separated by one blank line.

5. **Does any caption use specific phrases, names, venues, or details
   copied from the brand voice example captions?** Those are
   STRUCTURAL samples, not content to reuse. Rewrite with the same
   shape but event-specific content.

## WHAT NOT TO CHANGE

- Factual content from the program/enrichment data.
- The hashtags list (unless a hashtag itself is awkward).
- The alt_texts unless they violate the voice.
- The list of @ handles and plain names — everyone who was named
  before must still be named. You can MOVE them (body → trailing
  stack) but not drop them.

## OUTPUT RULES

- Return ONLY the cleaned JSON. No commentary, no markdown fences, no
  diff, no explanation of changes.
- Preserve every key in the input. Don't drop fields.
- For lists (alt_texts, scene_labels, hashtags), preserve count and
  order. Clean in place.
- If the draft already sounds like Dan, return it unchanged.
- Expected output shape: {output_shape_description}
"""


def build_diversity_review_prompt(
    *,
    week_json: str,
    brand_voice: str,
) -> str:
    """Build a pass that checks a whole week's captions for structural diversity.

    Used only by generate_week_captions. Given the full week's batch of
    captions after the humanizer and voice passes, this prompt looks at
    them ALL together and rewrites any that share structural shapes.

    Args:
        week_json: The week's captions batch as a JSON string
            (the {{"posts": [...]}} shape).
        brand_voice: The brand voice doc (used as voice reference when
            rewriting).
    """
    return f"""\
You are Dan Wright's caption batch editor. You have just been handed
a WEEK of captions that were generated for the same event. Your job
is a cross-caption diversity check: you look at them ALL TOGETHER and
rewrite any captions that share structural shapes with each other.

A viewer scrolling Dan's feed sees these posts across five days. If
they all open the same way, or all use the same three-part credit, or
all phrase the venue the same way, the feed reads like a template.
Your job is to prevent that.

---

## DAN'S BRAND VOICE (for voice match during any rewrites)

{brand_voice}

---

## THE FULL WEEK OF CAPTIONS

```json
{week_json}
```

## WHAT TO CHECK, ACROSS THE WHOLE WEEK

Compare the captions to each other — NOT to some ideal — and flag any
of these cross-caption repetitions:

1. **Shared opener shape.** If two or more captions start with the
   same grammatical shape ("@org's X at @venue." / "[Thing] at
   @venue." / "From the [scene]." / "Ten frames from..."), rewrite all
   but one to use a different opener.

2. **Shared credit layout.** If two or more captions use the same
   credit structure (e.g. "body sentence + trailing 'with @x @y @z'"
   or "three-conductor recap in sequence"), break the pattern in all
   but one.

3. **Shared parallel rhythm.** "A opened with X, B had the middle, C
   closed on Y" is a rhythm. If it appears in more than one caption,
   rewrite to break the symmetry.

4. **Shared connector phrases.** Words like "earlier," "the night,"
   "all-[composer] closer," "middle hour" — if they appear in
   multiple captions, vary them.

5. **Same [org]'s + [thing] + at @venue template.** Common default.
   Break it.

## WHAT NOT TO CHANGE

- Factual content.
- Hashtags (unless a hashtag is itself problematic).
- Alt texts.
- The list of people named in each caption — everyone who was named
  must still be named. You can move them between body and trailing
  stack but can't drop them.
- The post_type scope rules: single-subject posts (feed_photo,
  slider_reel, morph_reel, screen_reel) still keep the body focused on
  the in-frame moment, and non-in-frame credits go to a trailing
  stack. Event-level posts (carousel, scroll_reel) can span the event.

## OUTPUT RULES

- Return ONLY the cleaned JSON with the same {{"posts": [...]}} shape.
  No commentary, no markdown fences, no explanation.
- Preserve the order and count of the posts array.
- Preserve every key in every post entry.
- If the batch already has good structural diversity, return it
  unchanged.
"""
