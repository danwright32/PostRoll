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

import re
from pathlib import Path



# --- Deterministic backstops -------------------------------------------------
# Hard checkable constraints are enforced here in code, not only by LLM self
# scan: a review pass that reintroduces an em dash or drops a [PHOTO:] marker
# would otherwise ship silently.

_DASH_RANGE_RE = re.compile(r"(?<=\d)\s*[—–]\s*(?=\d)")
_DASH_RE = re.compile(r"\s*[—–]\s*")


def strip_em_dashes(text: str) -> str:
    """Deterministically remove em and en dashes from output text: digit
    ranges ("7–9pm") become a hyphen, everything else becomes a comma join."""
    if not text or ("—" not in text and "–" not in text):
        return text
    text = _DASH_RANGE_RE.sub("-", text)
    return _DASH_RE.sub(", ", text)


_PHOTO_MARKER_RE = re.compile(r"\[PHOTO:\s*([^|\]]+?)\s*\|")


def photo_marker_filenames(body: str) -> list[str]:
    """Sorted [PHOTO: filename | alt] marker filenames in a blog body."""
    return sorted(m.group(1).strip() for m in _PHOTO_MARKER_RE.finditer(body or ""))


def markers_preserved_validator(prior: dict, revised: dict) -> str | None:
    """run_review_pass validator: a review pass must not add, drop, or rename
    [PHOTO:] markers. Returns a problem description, or None when intact."""
    expected = photo_marker_filenames(prior.get("body", ""))
    got = photo_marker_filenames(revised.get("body", ""))
    if expected != got:
        return f"changed [PHOTO:] markers ({expected} -> {got})"
    return None


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


# Blog-only hard ban injected into the humanizer (Pass 3) prompt via
# build_review_prompt(extra_hard_bans=...). Captions have no practical-value
# beat or CTA, so only the blog generators pass this. The Pass 1/2 rules
# already forbid narrating the business case; this restates it as a Pass 3
# hard ban because the humanizer kept letting it through in the CTA.
BLOG_CTA_HARD_BAN = """\
7. **HARD BAN (CTA): the practical value beat must NOT explain to the
   reader why the photos matter.** Do not write sentences like "these
   photos show kids who..." or "this kind of documentation holds up in
   grant applications because...". Trust the audience: a presenter
   reading this already knows why documentation matters. State what the
   photos contain (briefly), then move to the CTA. If a sentence in the
   CTA or the preceding paragraph could be prefaced with "in case you
   didn't know," cut it."""


# Blog-only Pass 3 hard ban. Complements BLOG_CTA_HARD_BAN: the humanizer kept
# reintroducing business-case narration (where the files get used) even with
# that ban present, so this restates the use-case angle explicitly.
BLOG_BUSINESS_CASE_HARD_BAN = """\
8. **HARD BAN: do not add sentences explaining what the photos will be
   used for.** "These photos end up in grant applications" is the
   pattern. The practical value beat establishes why documentation
   matters by describing what's in the frames, not by telling the
   reader where the files will be sent. If a sentence in the practical
   value paragraph could appear in a sales deck, cut it."""


# Blog-only voice check injected into the voice review (Pass 2) prompt via
# build_voice_review_prompt(extra_checks=...). The brand voice requires
# contractions throughout, but the blog draft kept coming back formal, so
# this restates it as an explicit per-paragraph hard ban for blog posts.
BLOG_VOICE_CONTRACTION_CHECK = """\
6. **HARD BAN: contractions in every paragraph.** Every paragraph must
   contain at least one contraction. No exceptions. A paragraph with
   zero contractions reads clinical and formal. That's a voice failure.
   If a paragraph has no contraction, rewrite it before returning.
   BLOCKING GATE: before returning, go through the draft paragraph by
   paragraph and, for each one, find the contraction it contains. If any
   paragraph has none, rewrite it before returning. A draft returned
   with any paragraph still missing a contraction has not finished this
   pass. Do this paragraph-by-paragraph check as an INTERNAL scratchpad
   only: do NOT print the list or any commentary, the returned output
   must be only the post, valid JSON."""


# Blog-only literal second-person scan. Pass 1 (BLOG_WRITING_RULES) already
# runs this, but generic "you" kept surviving into the final draft, so the
# voice (Pass 2) and humanizer (Pass 3) passes re-run the same token scan.
BLOG_SECOND_PERSON_SCAN = """\
HARD BAN (second person): scan the text for every instance of the word
"you" or "your." Each one is a violation UNLESS it appears in the CTA
("if you're planning…") or inside a direct quote. There are no other
valid uses. Rewrite every other instance in Dan's first person before
returning. Do this scan internally; the output stays valid JSON with no
added commentary."""


# Bundles of blog-only additions passed to the shared review prompts. Add
# future blog-specific rules to the bundle so call sites never change.
BLOG_VOICE_EXTRA_CHECKS = BLOG_VOICE_CONTRACTION_CHECK + "\n\n" + BLOG_SECOND_PERSON_SCAN
BLOG_HUMANIZER_EXTRA_BANS = (
    BLOG_CTA_HARD_BAN + "\n\n" + BLOG_BUSINESS_CASE_HARD_BAN
    + "\n\n" + BLOG_SECOND_PERSON_SCAN
)


def build_review_prompt(
    *,
    draft_json: str,
    humanizer_rules: str,
    brand_voice: str,
    output_shape_description: str,
    extra_hard_bans: str = "",
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
        extra_hard_bans: Optional extra numbered hard-ban text injected
            after the built-in bans. Blog callers pass BLOG_CTA_HARD_BAN;
            captions leave it empty.
    """
    extra_block = (
        "\n" + extra_hard_bans.strip() + "\n"
        if extra_hard_bans and extra_hard_bans.strip()
        else ""
    )
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
{extra_block}
Before you return anything, scan your output for each of the hard bans
above and verify zero violations. If you catch one, fix it before
returning.

## YOUR PROCESS

1. Read the draft carefully.
2. Scan for the hard bans above. Flag every violation.
3. Identify additional AI tells using the humanizer rules above.
4. Identify brand voice violations using the voice calibration sample.
5. Apply humanizer's "draft → audit → revise" loop:
   a. Mentally produce a first rewrite that fixes the obvious issues.
   b. Ask yourself: "What makes this still obviously AI generated?"
   c. List the remaining tells in your head (do NOT output them).
   d. Revise once more to fix those.
6. **Final hard-ban scan.** Re-read your rewrite and check every
   hard ban above one more time. No em dashes. No parallel-three credits.
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
    extra_checks: str = "",
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
        extra_checks: Optional extra numbered checklist text injected
            after the built-in voice checks. Blog callers pass
            BLOG_VOICE_CONTRACTION_CHECK; captions leave it empty.
    """
    checks_block = (
        "\n" + extra_checks.strip() + "\n"
        if extra_checks and extra_checks.strip()
        else ""
    )
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
{checks_block}
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

