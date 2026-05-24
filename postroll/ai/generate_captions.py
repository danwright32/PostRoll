"""
PostRoll — Caption Generator

Generates one caption + per-photo alt text for a post, in Dan Wright's
brand voice. The same caption is used across Instagram, Facebook,
TikTok, Pinterest, and Bluesky.

Supports both single-photo posts (Sun/Mon feed) and multi-photo posts
(Wed carousel, Tue/Thu reels with multiple source frames). For
multi-photo posts the caption stays general and doesn't reference any
single frame.

Inputs:
- Event metadata (event name, organization, venue, date, shoot_type)
- OCR / enrichment dict (performers, pieces, scenes, etc.)
- One or more photo paths
- Day of week (informs framing)
- Optional list of @ handles to tag in this post
- Optional ai_tells_cache for the second-pass review

Output dict:
    {
      "caption": "the caption text including any @-mentions",
      "hashtags": ["#dwphotony", ...],
      "alt_texts": ["alt for photo 1", "alt for photo 2", ...],
      "scene_labels": ["scene for photo 1", ...],
    }

Usage:
    python -m postroll.ai.generate_captions \\
        --event "Vocal Colors" \\
        --org "DCINY" \\
        --venue "David Geffen Hall" \\
        --date 2026-04-04 \\
        --photo path/to/photo1.jpg --photo path/to/photo2.jpg \\
        --program path/to/program.json \\
        --day sunday \\
        --tag @dciny --tag @lincolncenter
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from .ai_tells import (
    HUMANIZER_DEFAULT_PATH,
    build_diversity_review_prompt,
    build_review_prompt,
    build_voice_review_prompt,
    is_humanizer_available,
    load_humanizer_rules,
)
from .claude_client import run_json_prompt, load_brand_voice, ClaudeError
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


PROMPT_TEMPLATE = """\
{brand_voice}

---

Your task: write ONE social media caption + per-photo alt text for a
post containing {photo_count} photo(s). The same caption is used
across Instagram, Facebook, TikTok, Pinterest, and Bluesky.

If there are multiple photos (a carousel, or a reel built from many
source frames), the caption stays GENERAL — it doesn't reference any
individual frame. The alt text is per-photo, but the caption is one
shared post-level caption.

Event details:
- Event name: {event}
- Organization: {org}
- Venue: {venue}{venue_context_line}
- Date: {date}
- Day of week posting: {day}
- Shoot type: {shoot_type}
{event_url_line}  ← CRITICAL: match the caption to what Dan
  actually witnessed. If shoot_type is photo_call, do NOT mention
  applause, audience reactions, or performance moments that require
  an audience. For photo_call, rehearsal, and dress_rehearsal, the
  Repertoire below is the PLANNED program, not a transcript. Do NOT
  describe how a piece sounded unless a photo clearly anchors it.

Post type: {post_type}
{post_type_framing}

Performers (from program OCR / enrichment):
{performers}

Repertoire / works (from program OCR / enrichment):
{pieces}

Scenes / sections in this production (from program OCR / enrichment):
{scenes}

Required @-mentions for this post (must appear in the caption text
somewhere — body or trailing credit line). Each becomes a #-tag too:
{tag_handles}

Required plain-name credits for this post (people without Instagram
handles — appear as plain text in the caption, NOT as #-tags):
{name_mentions}

{shooter_notes_section}**SCOPE RULE — read this before writing anything.**
{scope_rule}

{existing_captions_section}Photos in this post ({photo_count}):
{photo_list}

You will work in four explicit ordered stages. Do them IN ORDER.

**Stage 1 — alt text.** {alt_text_instruction}

**Stage 2 — scene match.** For EACH entry you just wrote in
`alt_texts` (so one total for most post types, one per photo only for
carousels), use the structured scenes list above to decide which
scene/section it shows. Match by comparing the alt text against each
scene's `visual_cues`. Be DECISIVE — if the visual evidence points
clearly to one scene, pick it.

Write a short phrase like "[Scene name]" or null if no scene from the
list matches. Put the labels into `scene_labels` IN THE SAME ORDER
and at the SAME LENGTH as `alt_texts`.

**Stage 3 — unified caption.** Now write ONE caption for the whole
post. You are NOT allowed to look back at the photos for this stage —
work from the alt texts, the scene labels, and the event metadata.

How to write it depends on `scene_labels`:

- If `scene_labels` has ONE entry (single-subject posts, scroll reels,
  or a carousel where every photo matched the same scene): use that
  label as the differentiating context when it is non-null, or fall
  back to a generic event-level frame when it is null.
- If `scene_labels` has MULTIPLE entries that span different scenes
  (carousels with mixed scenes), DO NOT pick one — write a more
  general caption about the event/show as a whole. Don't try to
  mention every scene; pick a unifying frame ("highlights from",
  "selected moments from", "scenes from", etc.) and stay general.
- If there are NO scene labels (scenes list was empty or no matches),
  fall back to a generic event-level caption.

Now incorporate the required @-mentions from the tag_handles list AND
the required plain-name credits from the name_mentions list. EVERY
handle and EVERY name MUST appear somewhere in the final caption text.

**VARY the credit shape across captions.** Don't default to the same
"body sentence + 'with @x @y' trailing line" pattern for every post.
Rotate through these shapes based on what reads most naturally:

1. **Inline-woven credits** — work 2-3 handles/names directly into a
   body sentence. Example: "@dciny's Vocal Colors at @lincolncenter,
   Sorenson Requiem conducted by @stephenmartintenor."
2. **Body + trailing stack, no "with" prefix** — body sentence, then
   a bare line with all remaining handles/names. Example:
   "[body]\n\n@dciny @lincolncenter @kylepedersonmusic"
3. **Body + "with" line** (the previous default) — use sparingly, not
   every time. Example: "[body]\n\nwith @dciny @lincolncenter"
4. **Body + "conducted by / featuring / with" phrase** — a semantic
   prefix that matches what the handle-people actually do. Example:
   "[body]\n\nConducted by @jennayarobison. With @dciny @lincolncenter
   @kylepedersonmusic."
5. **Split credit by role** — short stanza for conductors, another
   for composer, another for org/venue. Example:
   "[body]\n\nConducted by @stephenmartintenor and Jordan Langworthy.\n
   Featuring @kylepedersonmusic.\n@dciny at @lincolncenter."

Pick a different shape than what the last caption used if you can.
When name_mentions (plain-text names like "Jordan Langworthy") appear
in the credits, they fit naturally alongside @ handles — do NOT add an
"@" to them, do NOT put them in the hashtag list.

The caption must follow the brand voice rules: short, structural, no
description of the photo, no fabrication, no AI tells.

**Do NOT default to "From the [scene]." as the opener.** Vary the
position and shape of any scene reference. See the "Acceptable shapes"
list in the brand voice doc above.

**Body length targets:**
- Single-photo feed posts: 80–180 characters for the body
- Carousels and scroll reels (multi-photo general captions): 120–280
  characters — use the extra room to be specific about the scope
  (multiple scenes, three conductors by name, run times, etc.)
- Before/after reels: 80–180 characters — keep it about the edit
  reveal

These are targets for the BODY only, excluding the credit stanza.

**Stage 4 — hashtags.** 6–12 hashtags. Required: #dwphotony, venue,
org/show, composer/playwright/band, performers visible, genre. Plus
one #-tag per @ handle in tag_handles (so they're searchable too).

Return JSON ONLY in this exact shape (no markdown fences, no
commentary). `alt_texts` and `scene_labels` are arrays but their
length follows Stage 1: one entry for most post types, one entry
per photo only for carousels.

{{
  "alt_texts": ["<stage 1 output>", ...],
  "scene_labels": ["<stage 2 output>", ...],
  "caption": "<stage 3 output, including @ mentions>",
  "hashtags": ["#dwphotony", ...]
}}

Hashtag rules (re-stated for emphasis):
- ALWAYS include #dwphotony.
- Include a venue hashtag derived from "{venue}".
- Include an organization hashtag derived from "{org}".
- Include performer/conductor hashtags if any are listed above.
- Add 2-3 relevant tags (genre, instrument, repertoire, city).
- Total 6-10 hashtags. No padding.

Caption rules (re-stated, with hard defaults):

DEFAULT FORMAT — short and structural. The system does NOT have a
`dan_notes` field with Dan's actual observations from the shoot, so you
must NOT write a "voice-y" caption with a behind-the-camera hook.
Write a short caption that:

1. **REQUIRED: differentiate this photo from other photos in the same
   event by LABELING which scene/section/moment of the production it
   shows.** This is mandatory whenever the program/enrichment data
   above lists distinct scenes/sections AND the photo visibly shows
   one of them. Do NOT skip the label and write a generic "photo call"
   caption when a scene label is available — that produces identical
   captions for every post in the event, which is a failure mode.

   How to find the label:
   a. Scan the program/enrichment data above for any list of scenes,
      sets, movements, acts, pieces, or sections.
   b. Read the photo and identify which one of those it shows. Use
      visible cues — set design (kitchen vs spa, podium vs stage,
      indoor vs outdoor), costumes, props, location.
   c. Write the label as a short phrase: "From the [scene name]" or
      "[Scene name]." Use only labels that exist in the data — do not
      invent scene names.
   d. Put ONLY the label in the caption. The visible cues you used to
      pick it stay in alt text.

   Example logic: if the program says the play has two scenes — a
   spa and a restaurant — and you see a kitchen table with bowls in
   the photo, the label is "From the restaurant scene." If you see a
   massage table or screens in a wellness room, the label is "From
   the spa scene." Pick decisively based on visible evidence; don't
   hedge.

   If no scene labels exist in the program data, fall back to "Photo
   call at [venue]" or similar generic context. Better generic-but-
   honest than fabricated specificity. But default to LABELING when
   the data supports it.

2. Names cast/work/venue in a single woven sentence, NOT a stacked
   billing block. If multiple performers are visible, prefer naming
   the ones in THIS frame over listing the whole cast.

3. Stops.

Target length: 80–180 characters for the caption itself. Shorter is
fine. Longer needs to earn it with real material — and you don't have
real material here.

ABSOLUTELY NEVER:
- Describe the photo's literal contents — costumes, props, gestures,
  facial expressions, lighting, framing — as the caption body. That's
  alt text's job. Use those cues to IDENTIFY which scene/section the
  photo shows, then write the LABEL, not the description.
- Open with a comma-separated list of objects ("A table, two bowls,
  one Heineken...") — that's the AI list cadence and it's banned.
- Use rule-of-three patterns ("X, Y, and Z").
- Fabricate observations, durations, counts, activities, audience
  reactions, what the cast was doing before/after the photo, what
  characters were thinking, or anything not in the inputs.
- Fabricate or guess @ handles. ONLY use handles from the tag_handles
  list above. If tag_handles is "(none)", do NOT invent any @ mentions.
  A wrong handle tags the wrong account — this is a hard rule.
- Pull handles from anywhere except `tag_handles`. The shared
  Performers block lists names + roles only and contains NO handles by
  design. If a performer's handle is not in tag_handles, that performer
  must NOT be tagged in this post (not in the body, not in a trailing
  stack, nowhere). Mention them by plain name only if they appear in
  `name_mentions` — otherwise omit them entirely.
- Copy any specific phrase, person, venue, or detail from the
  example captions in the brand voice doc. Those are STRUCTURAL
  patterns from other events.
- Stack credits like a press release.
- Use hype words (stunning, breathtaking, magical, etc.).
- Use emoji.
- Use "link in bio," "DM me," "swipe to see more," or any
  scroll-pattern engagement bait.
- End with a generic "what do you think?" question.

Lowercase or sentence case is fine — match Dan's natural register.
"""


_HANDLE_SENTINELS = {"unknown", "n/a", "na", "none", "-", "no", "skip"}


def _is_real_handle(handle: str) -> bool:
    return bool(handle) and handle.strip().lower() not in _HANDLE_SENTINELS


def _format_performers(performers: list[dict[str, Any]]) -> str:
    """Format the shared performers context block for the caption prompt.

    Intentionally omits @handles. Each post's `tag_handles` list (passed
    separately, per post) is the authoritative source for which handles to
    tag in that post's caption. Showing handles in this shared block leaks
    them across posts — Claude sees all 13 handles and dumps them into a
    single-subject post's trailing stack instead of obeying tag_handles.
    """
    if not performers:
        return "(none listed)"
    lines = []
    for p in performers:
        name = p.get("name", "?")
        role = p.get("role", "")
        instr = p.get("voice_or_instrument") or ""
        bits = [name]
        if role:
            bits.append(f"({role}{', ' + instr if instr else ''})")
        elif instr:
            bits.append(f"({instr})")
        lines.append("- " + " ".join(bits))
    return "\n".join(lines)


def _format_pieces(pieces: list[dict[str, Any]]) -> str:
    if not pieces:
        return "(none listed)"
    lines = []
    for p in pieces:
        composer = p.get("composer", "?")
        title = p.get("title", "?")
        lines.append(f"- {composer} — {title}")
    return "\n".join(lines)


def _format_scenes(scenes: list[dict[str, Any]]) -> str:
    """Format the structured scenes list for the prompt."""
    if not scenes:
        return "(none listed in program data — fall back to generic event-level context)"
    lines = []
    for i, s in enumerate(scenes):
        name = s.get("name", "?")
        location = s.get("location") or ""
        cues = s.get("visual_cues") or ""
        desc = s.get("description") or ""
        line = f"- [{i}] {name}"
        if location:
            line += f" (location: {location})"
        if cues:
            line += f"\n      visual cues: {cues}"
        if desc:
            line += f"\n      description: {desc}"
        lines.append(line)
    return "\n".join(lines)


def _format_tag_handles(tag_handles: list[str] | None) -> str:
    """Format the list of @ handles for the prompt."""
    if not tag_handles:
        return "(none — generate the caption without forced @ mentions)"
    return "\n".join(f"- {h}" for h in tag_handles)


def _format_name_mentions(name_mentions: list[str] | None) -> str:
    """Format the list of plain-text names for the prompt."""
    if not name_mentions:
        return "(none — no forced plain-name credits)"
    return "\n".join(f"- {n}" for n in name_mentions)


def _format_existing_captions(existing: list[str] | None) -> str:
    """Format the list of other captions from the same event for the prompt."""
    if not existing:
        return ""
    lines = ["Other captions already generated for this event:"]
    for i, c in enumerate(existing, 1):
        lines.append(f"  [{i}] {c}")
    lines.append(
        "\nThis new caption must NOT share an opener, credit shape, "
        "or sentence structure with any of the above. Pick a different "
        "shape entirely."
    )
    return "\n".join(lines) + "\n\n"


# Post types where the subject is ONE moment / one frame / one scene.
# For these, the caption body must stay focused on what's visible in
# THIS photo, not recap the whole event. Other required @handles and
# name credits go on a minimal trailing credit stack.
SINGLE_SUBJECT_POST_TYPES = {
    "feed_photo",
    "slider_reel",
    "morph_reel",
    "screen_reel",
    "before_after_story",
    "performance",
}

# Post types where the subject IS the whole event — a carousel of
# different scenes, or a scroll reel covering many photos. For these,
# the body can legitimately weave all credits in and cover the full
# scope of the show.
EVENT_LEVEL_POST_TYPES = {
    "carousel",
    "scroll_reel",
}


SCOPE_RULE_SINGLE_SUBJECT = """\
This is a SINGLE-SUBJECT post — one photo, or one edit of one photo.
The BODY of the caption must stay locked to what is actually in this
frame: the one scene / set / conductor / cast grouping visible. Do NOT
recap the whole event. Do NOT list every conductor, every set, every
piece on the program. A reader who sees only this post should learn
about THIS moment, not the three-hour arc of the night.

Handle the required @ mentions and name credits like this:

1. Body (1–2 short sentences): name ONLY the people, pieces, and
   context relevant to THIS frame. If only one conductor is visibly
   leading in the photo, only that conductor belongs in the body. The
   piece being performed, the section being staged, the actor in the
   shot — those go in the body. Everyone else does NOT.

2. Trailing credit stack (separated by ONE blank line): on a new line
   after the body, put the @ handles and name_mentions that did NOT
   make it into the body, as a bare stack with no "with" prefix and no
   narrative connector. Org and venue handles almost always land here.
   Example shape:

       [body sentence about the one scene/set in the frame]

       @org @venue @conductor_not_in_frame Name Without Handle

   Every handle and every name_mention must appear SOMEWHERE — body OR
   trailing stack. But credits for people not in the frame belong in
   the stack, not woven into prose about moments they weren't part of.

3. If the body already mentions a handle naturally, don't repeat it in
   the trailing stack. The stack is for what's left over.

Violations to avoid:
- "Opened with [A], [B] had the middle set, [C] closed on [D]" — that
  is a concert recap, not a caption about this photo. Banned.
- "Earlier in the night [other conductor] did [other thing]" — banned.
  You are not the program notes.
- Naming a performer who is not visibly in this frame in the body.
- **Backhanded compliments / faint praise.** Phrasings like "held his
  own", "kept up", "more than capable", "did her best", "managed",
  "tried hard", "respectable showing", or any descriptive stand-in for
  a performer's name (e.g. "a pianist who…", "the accompanist who…")
  are BANNED. They sound condescending. If a performer is in the frame
  with a tag handle or name_mention, name them by that handle / name —
  never by a generic role noun followed by faint praise.
- **Reducing a tagged performer to a description.** If `@filam_pianist`
  is in the required tag_handles list and they are visibly in this
  frame, the caption must use `@filam_pianist` (in body or stack) — not
  "a pianist". The same rule applies to name_mentions: use the actual
  name, not "a pianist named such-and-such" or any role-noun substitute.
"""

SCOPE_RULE_EVENT_LEVEL = """\
This is an EVENT-LEVEL post — a carousel or scroll reel that really
does cover the whole event. The body legitimately spans everything.
Credits can weave through the body naturally, or land in a trailing
stack — pick whichever shape reads best and varies from the other
captions in the week.

Every required handle and every name_mention must appear somewhere in
the caption. Because this post covers the whole event, it's fine to
name multiple conductors / sets / pieces in the body — that matches
what the post actually shows.
"""


def _scope_rule_for(post_type: str) -> str:
    """Return the scope rule block for a given post type."""
    if post_type in EVENT_LEVEL_POST_TYPES:
        return SCOPE_RULE_EVENT_LEVEL
    return SCOPE_RULE_SINGLE_SUBJECT


# Post-type-specific framing guidance injected into the prompt
POST_TYPE_FRAMING = {
    "feed_photo": (
        "A single-photo feed post. The caption frames ONE moment from the show. "
        "Short and structural with a woven credit."
    ),
    "carousel": (
        "A multi-photo carousel feed post. The caption covers the whole event or a "
        "broad arc, NOT any single photo. If photos span multiple scenes, stay general — "
        "don't try to label a single scene. If photos are all from one scene, label it."
    ),
    "slider_reel": (
        "A before/after slider reel — a short video that wipes between the RAW image "
        "and the edited image of the SAME photo. The caption should honestly reference "
        "the edit reveal (RAW → final, editing process, the invisible work behind a "
        "single frame) as the reason this post exists. Do NOT describe it as just "
        "another photo from the show — that misses the point of the post."
    ),
    "morph_reel": (
        "A before/after split-compare reel — a short video showing the RAW and edited "
        "versions side by side or morphing between them. Same framing as slider_reel: "
        "the post is about the edit, not just the moment."
    ),
    "screen_reel": (
        "A sped-up Lightroom screen recording reel — a short video of Dan editing a "
        "single photo, compressed into ~15-20 seconds. The caption should reference "
        "the editing process itself. Do NOT pretend the post shows the performance — "
        "it shows Dan working."
    ),
    "scroll_reel": (
        "A photo scroll reel — a short video built from many photos of the event "
        "scrolling or transitioning past. The caption should be general-event-level, "
        "not photo-specific. Reference the scope (a night, a week, a whole show) "
        "rather than any individual frame."
    ),
    "before_after_story": (
        "A static before/after story image (not a reel). A single 1080x1920 image "
        "showing the RAW and edited photos stacked. No caption needed for Instagram "
        "stories — but if one is generated, frame it as the edit reveal."
    ),
    "performance": (
        "Generic single-photo feed post framing. Use this as a default."
    ),
}


# Per-post-type Stage 1 (alt text) instructions. Wed carousels get one
# alt per photo; everything else gets ONE alt text in the list.
# Instagram only attaches one alt text to a single feed post, story,
# or reel — per-photo alt texts on scroll reels never get used.
ALT_TEXT_INSTRUCTION = {
    "carousel": (
        "Write ONE alt text per photo in the `alt_texts` list — 15-35 "
        "words each — IN THE SAME ORDER as the photos listed above. "
        "Describe what is actually visible in each frame: who, what, "
        "where, lighting, gestures, set design, props."
    ),
    "scroll_reel": (
        "Write ONE alt text for the reel AS A WHOLE. Put it as a SINGLE "
        "entry in the `alt_texts` list — the list must have exactly 1 entry. "
        "Write a UNIFIED NARRATIVE summary: what is this reel about, who "
        "appears, what is the setting. Do NOT list what individual photos "
        "show. Do NOT use semicolons or 'and' to chain descriptions of "
        "separate frames — that is just per-frame alt text in disguise. "
        "Think of it as one sentence describing the reel the way a human "
        "would describe a video: 'A photo scroll through [event] at [venue], "
        "covering [subject].' 25-50 words."
    ),
    "slider_reel": (
        "These photos are the before (RAW) and after (edited) versions "
        "of the SAME single moment. Write ONE alt text describing that "
        "one moment and put it as a SINGLE entry in `alt_texts`. 15-35 "
        "words. Do not write one per file."
    ),
}
ALT_TEXT_INSTRUCTION["morph_reel"]  = ALT_TEXT_INSTRUCTION["slider_reel"]
ALT_TEXT_INSTRUCTION["screen_reel"] = ALT_TEXT_INSTRUCTION["slider_reel"]

DEFAULT_ALT_TEXT_INSTRUCTION = (
    "Write ONE alt text for the photo and put it as a SINGLE entry in "
    "the `alt_texts` list. 15-35 words. Describe what is actually "
    "visible: who, what, where, lighting, gestures, set design, props."
)

# Post types where alt_texts should collapse to one entry.
SINGLE_ALT_POST_TYPES = {
    "feed_photo",
    "slider_reel",
    "morph_reel",
    "screen_reel",
    "before_after_story",
    "performance",
    "scroll_reel",
}


def _alt_text_instruction_for(post_type: str) -> str:
    return ALT_TEXT_INSTRUCTION.get(post_type, DEFAULT_ALT_TEXT_INSTRUCTION)


def generate_caption(
    *,
    event: str,
    org: str,
    venue: str,
    date: str,
    day: str,
    photo_paths: list[str | Path],
    program: dict[str, Any],
    shoot_type: str = "performance",
    post_type: str = "feed_photo",
    tag_handles: list[str] | None = None,
    name_mentions: list[str] | None = None,
    notes: str = "",
    existing_captions: list[str] | None = None,
    event_url: str = "",
    venue_context: str = "",
    humanizer_path: str | Path | None = None,
    skip_humanizer: bool = False,
    skip_voice_pass: bool = False,
) -> dict[str, Any]:
    """Generate caption + hashtags + per-photo alt text for one post.

    Accepts one or more photos. JPEG, PNG, and HEIC are all fine; HEIC is
    converted to JPEG via sips.

    shoot_type controls how the prose frames what Dan witnessed. Common
    values: "performance", "rehearsal_and_performance", "photo_call",
    "rehearsal", "dress_rehearsal".

    post_type controls how the caption frames the post. Common values:
    "feed_photo", "carousel", "slider_reel", "morph_reel", "screen_reel",
    "scroll_reel", "before_after_story". Default is "feed_photo" which
    is a safe single-photo framing. Reels and multi-photo posts need
    specific framing so the caption reflects what kind of post it is
    (e.g. a slider reel's caption should reference the edit reveal).

    tag_handles is an optional list of @ handles to mention in the caption
    (e.g. ["@dciny", "@lincolncenter"]). Each MUST start with "@". Each
    also becomes a #-tag in the hashtag list.

    name_mentions is an optional list of plain-text names to credit in
    the caption (e.g. ["Jordan Langworthy"]). These are for people who
    don't have an Instagram handle to tag. They appear in the caption
    body or credit line by name, and they do NOT become hashtags.

    existing_captions is an optional list of other captions from the
    same event (e.g. the other 4 captions in a week) that the new one
    should NOT share shapes or openers with. Pass this when regenerating
    a single caption from a week so the new one stays varied against
    the rest. Pass None for standalone captions outside a week context.

    The second-pass review-and-revise (humanizer) runs by default if the
    humanizer skill is installed at ~/.claude/skills/humanizer/SKILL.md.
    Pass `skip_humanizer=True` to skip the review pass (mostly used in
    tests). Pass `humanizer_path` to override the default install path.
    """
    if not photo_paths:
        raise ValueError("At least one photo path is required")

    with tempfile.TemporaryDirectory(prefix="postroll-caption-") as tmp:
        tmp_path = Path(tmp)
        staged_paths: list[str] = []
        for i, p in enumerate(photo_paths):
            photo = Path(p).expanduser().resolve()
            if not photo.exists():
                raise FileNotFoundError(f"Photo not found: {photo}")
            if photo.suffix.lower() in HEIC_SUFFIXES:
                staged = _convert_heic_to_jpeg(photo, tmp_path)
            else:
                staged = tmp_path / f"{i:03d}_{photo.name}"
                shutil.copy2(photo, staged)
            staged_paths.append(str(staged))

        brand_voice_text = load_brand_voice()
        photo_count = len(staged_paths)
        # Each filename is also passed as image_labels so the model gets a
        # `Photo N: filename.jpg` block right before each attached image.
        # That eliminates the "alt text describes the wrong photo" failure
        # mode where the model guessed at file ↔ image correspondence.
        photo_filenames = [Path(p).name for p in staged_paths]
        photo_list = "\n".join(f"- {n}" for n in photo_filenames)
        post_type_framing = POST_TYPE_FRAMING.get(
            post_type, POST_TYPE_FRAMING["feed_photo"]
        )
        existing_section = _format_existing_captions(existing_captions)
        scope_rule = _scope_rule_for(post_type)
        shooter_notes_section = (
            f"Shooter's observations for this post (first-hand detail from Dan"
            f" — use these to write a more specific, voice-y caption):\n{notes.strip()}\n\n"
        ) if notes.strip() else ""

        event_url_line = (
            f"- Event page URL (additional context): {event_url}"
            if event_url else ""
        )
        # Specific room inside the venue (e.g. Weill Recital Hall inside Carnegie Hall)
        # — used only for prose context. Graphics still show the top-level venue.
        venue_context_line = (
            f" — performed in {venue_context.strip()}"
            if venue_context and venue_context.strip() else ""
        )

        # === Pass 1: generate the draft ===
        prompt = PROMPT_TEMPLATE.format(
            brand_voice=brand_voice_text,
            event=event,
            org=org,
            venue=venue,
            venue_context_line=venue_context_line,
            date=date,
            day=day,
            shoot_type=shoot_type,
            event_url_line=event_url_line,
            post_type=post_type,
            post_type_framing=post_type_framing,
            scope_rule=scope_rule,
            alt_text_instruction=_alt_text_instruction_for(post_type),
            performers=_format_performers(program.get("performers", [])),
            pieces=_format_pieces(program.get("pieces", [])),
            scenes=_format_scenes(program.get("scenes", [])),
            tag_handles=_format_tag_handles(tag_handles),
            name_mentions=_format_name_mentions(name_mentions),
            shooter_notes_section=shooter_notes_section,
            existing_captions_section=existing_section,
            photo_count=photo_count,
            photo_list=photo_list,
        )

        data = run_json_prompt(
            prompt,
            timeout=600,
            image_paths=staged_paths,
            image_labels=photo_filenames,
        )

        if not isinstance(data, dict):
            raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

        single_shape = (
            "{alt_texts: list of strings, scene_labels: list of strings or "
            "nulls, caption: string, hashtags: list of strings}"
        )

        # === Pass 2: brand-voice review (does this actually sound like Dan?) ===
        # Narrower than humanizer — asks only "voice match?"
        if not skip_voice_pass:
            voice_prompt = build_voice_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                brand_voice=brand_voice_text,
                output_shape_description=single_shape,
            )
            data = run_json_prompt(
                voice_prompt,
                timeout=300,
            )
            if not isinstance(data, dict):
                raise ClaudeError(
                    f"Voice pass returned {type(data).__name__}, expected JSON object"
                )

        # === Pass 3 (FINAL): humanizer — always runs last, non-negotiable ===
        # Humanizer is the final word on AI tells. It MUST be the last pass
        # so nothing downstream can re-introduce tells. skip_humanizer exists
        # only for tests — production runs should never skip this.
        if not skip_humanizer and is_humanizer_available(humanizer_path):
            humanizer_rules = load_humanizer_rules(humanizer_path)
            review_prompt = build_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                humanizer_rules=humanizer_rules,
                brand_voice=brand_voice_text,
                output_shape_description=single_shape,
            )
            data = run_json_prompt(
                review_prompt,
                timeout=300,
            )
            if not isinstance(data, dict):
                raise ClaudeError(
                    f"Humanizer pass returned {type(data).__name__}, expected JSON object"
                )

    # Normalize alt_texts and scene_labels. For single-alt post types,
    # collapse to the first entry defensively in case Claude wrote one
    # per photo anyway.
    alt_texts = data.get("alt_texts") or []
    scene_labels = data.get("scene_labels") or []
    if not isinstance(alt_texts, list):
        alt_texts = [str(alt_texts)]
    if not isinstance(scene_labels, list):
        scene_labels = [scene_labels]

    if post_type in SINGLE_ALT_POST_TYPES:
        alt_texts = alt_texts[:1]
        scene_labels = scene_labels[:1]

    return {
        "caption": data.get("caption", "").strip(),
        "hashtags": data.get("hashtags", []),
        "alt_texts": [str(a).strip() for a in alt_texts],
        "scene_labels": scene_labels,
    }


def format_for_post(result: dict[str, Any]) -> str:
    """Render the caption + hashtags as it would actually be posted."""
    caption = result["caption"]
    tags = " ".join(result.get("hashtags", []))
    return f"{caption}\n\n{tags}".rstrip()


# ===================================================================
# Batch generation — one Claude call for a whole week
# ===================================================================


WEEK_PROMPT_TEMPLATE = """\
{brand_voice}

---

Your task: write captions + per-photo alt text for a WHOLE WEEK of
posts from the same event. The same brand voice, program data, and
event context apply to every post. You will generate ALL captions in
ONE response as an array.

Event details (shared across all posts):
- Event name: {event}
- Organization: {org}
- Venue: {venue}{venue_context_line}
- Date: {date}
- Shoot type: {shoot_type}  ← CRITICAL: match every caption to what
  Dan actually witnessed. If shoot_type is photo_call, do NOT mention
  applause, audience reactions, or performance moments that require
  an audience. For photo_call, rehearsal, and dress_rehearsal, the
  Repertoire below is the PLANNED program, not a transcript. Do NOT
  describe how a piece sounded unless a photo clearly anchors it.

Performers (from program OCR / enrichment):
{performers}

Repertoire / works (from program OCR / enrichment):
{pieces}

Scenes / sections in this production (from program OCR / enrichment):
{scenes}

---

Posts in this week ({post_count} total):

{posts_section}

---

You will work in FOUR explicit ordered stages for EACH post, then
return all results as one JSON array. Do them IN ORDER per post.

**Stage 1 — alt text.** For each post, follow the "Alt text
instruction" listed for THAT post in the block above. Most post
types take ONE alt text total (the whole reel or the whole feed
photo); carousels take ONE alt text per photo. Put the result(s)
into that post's `alt_texts` list.

**Stage 2 — scene match.** For EACH entry in each post's `alt_texts`
(so one total for most post types, one per photo only for carousels),
use the structured scenes list above to decide which scene it shows.
Be decisive — if the visual evidence points clearly, pick it. Put
the labels into `scene_labels` at the SAME LENGTH and ORDER as
`alt_texts`.

**Stage 3 — unified caption per post.** For each post, write ONE
caption following the brand voice rules, the post-type-specific
framing, AND the SCOPE RULE listed with each post.

The scope rule is the most important structural input. Read it
carefully per post before writing. Summary:

- SINGLE-SUBJECT posts (feed_photo, slider_reel, morph_reel,
  screen_reel, before_after_story): body stays locked to what is
  visibly in THIS frame. Do NOT recap the whole concert. Do NOT name
  every conductor / set / piece. Required @handles and name_mentions
  that are NOT in this frame go on a trailing credit stack separated
  by one blank line — bare, no "with" prefix, no narrative connector.
  Org and venue handles almost always land in that trailing stack.

- EVENT-LEVEL posts (carousel, scroll_reel): body legitimately spans
  the whole event. Credits can weave through or land in a stack.

Incorporate the required @-mentions and plain-name credits from each
post's tag_handles and name_mentions lists. EVERY handle and EVERY
name MUST appear somewhere in the final caption — but for
single-subject posts, "somewhere" often means the trailing stack, not
the body. Do not force in-frame naming of people who aren't in the
frame.

**NEVER fabricate or guess @ handles.** ONLY use handles from each
post's tag_handles list. If tag_handles is "(none)", do NOT invent any
@ mentions. A wrong handle tags the wrong account — this is a hard rule.

**The shared `Performers` block above contains NO handles by design.**
It exists only so you know each performer's role / voice / instrument
for context. To tag any performer in a caption, that performer's
handle must appear in THAT post's `tag_handles` list. Do NOT pull
handles from anywhere else, including: prior posts in this week, the
event-wide org/venue handles you already have, or your training data.
For single-subject posts: if a performer is NOT in this post's
tag_handles, they are NOT tagged in this post — period. Don't sneak
them into a trailing stack "for context."

**NEVER reduce a tagged performer to a faint-praise role noun.** If a
performer is in the required tag_handles or name_mentions list, you
must credit them by their @handle or actual name — never as "a pianist
who held his own", "an accompanist who kept up", "a soloist who tried
their best", or any descriptive substitute. Phrasings like "held his
own", "kept up", "more than capable", "managed", "respectable showing"
read as backhanded compliments and are banned across ALL post types
(both single-subject and event-level). Treat every tagged performer
with the same warmth — Dan won't post a caption that demeans a client.

**Stage 4 — VARY across the whole week.** This is the key advantage
of generating all 5 at once: the captions must NOT share openers,
credit shapes, or sentence structures across the week. Use a
different shape for EACH caption. The "Acceptable shapes" list in the
brand voice doc above gives you options — spread them across the
week. If caption 1 uses "body + woven credits", caption 2 should use
"body + trailing stack with no 'with' prefix", caption 3 should use
"Conducted by / featuring" phrase, and so on. No Mad Libs pattern.

**Stage 5 — hashtags per post.** 6–12 hashtags including #dwphotony,
venue, org/show, composer/playwright/band, performers, genre. Plus
one #-tag per @ handle in that post's tag_handles.

Return JSON ONLY in this exact shape (no markdown fences, no
commentary). `alt_texts` and `scene_labels` per post follow Stage 1:
one entry for most post types, one entry per photo only for carousels.

{{
  "posts": [
    {{
      "day": "<the day key from the input, e.g. 'sunday'>",
      "post_type": "<the post_type from the input>",
      "alt_texts": ["<stage 1 output>", ...],
      "scene_labels": ["<stage 2 output>", ...],
      "caption": "<stage 3 output, including @ mentions and plain names>",
      "hashtags": ["#dwphotony", ...]
    }},
    ...
  ]
}}

Return ONE object with a `posts` array containing {post_count} entries
in the SAME ORDER as the posts listed above. Do NOT omit any post.
Each post's entry should be self-contained with all four required
fields.
"""


def _format_week_posts(posts: list[dict[str, Any]]) -> str:
    """Format the week's posts section for the batch prompt."""
    lines = []
    for i, post in enumerate(posts, 1):
        day = post["day"]
        post_type = post["post_type"]
        photo_paths = post["photo_paths"]
        tag_handles = post.get("tag_handles") or []
        name_mentions = post.get("name_mentions") or []

        framing = POST_TYPE_FRAMING.get(post_type, POST_TYPE_FRAMING["feed_photo"])
        scope_kind = (
            "EVENT-LEVEL"
            if post_type in EVENT_LEVEL_POST_TYPES
            else "SINGLE-SUBJECT"
        )

        lines.append(f"### Post {i}: {day.upper()} ({post_type})")
        lines.append(f"Scope: {scope_kind}")
        lines.append(f"Framing: {framing}")
        lines.append(f"Alt text instruction: {_alt_text_instruction_for(post_type)}")
        lines.append(f"Required @ handles: {', '.join(tag_handles) if tag_handles else '(none)'}")
        lines.append(
            f"Required plain-name credits: {', '.join(name_mentions) if name_mentions else '(none)'}"
        )
        lines.append(f"Photos ({len(photo_paths)}):")
        for p in photo_paths:
            lines.append(f"  - {p}")
        lines.append("")
    return "\n".join(lines)


def generate_week_captions(
    *,
    event: str,
    org: str,
    venue: str,
    date: str,
    program: dict[str, Any],
    posts: list[dict[str, Any]],
    shoot_type: str = "performance",
    venue_context: str = "",
    humanizer_path: str | Path | None = None,
    skip_humanizer: bool = False,
    skip_voice_pass: bool = False,
    skip_diversity_pass: bool = False,
) -> list[dict[str, Any]]:
    """Generate captions for a whole week in ONE Claude call.

    This is the batch entry point. Use it when you want captions for
    every post in an event at once — it's dramatically cheaper than
    calling generate_caption() 5 times (shared brand voice / program
    data / humanizer review) and it naturally produces cross-caption
    variation because the model sees all 5 at once.

    Args:
        event, org, venue, date: Shared event metadata.
        program: The OCR / enrichment dict (scenes, performers, etc.).
        posts: A list of per-day post specs. Each must have:
            - day: str ("sunday", "monday", etc.)
            - post_type: str ("feed_photo", "carousel", "slider_reel",
              "scroll_reel", etc.)
            - photo_paths: list[str | Path] — photos for this post
            - tag_handles: list[str] | None — @ handles for this post
            - name_mentions: list[str] | None — plain names for this post
        shoot_type: What Dan witnessed (usually "performance").
        humanizer_path, skip_humanizer: Same as generate_caption.

    Returns:
        A list of result dicts, one per post, in the same order as
        the input posts. Each has {day, post_type, caption, hashtags,
        alt_texts, scene_labels}.
    """
    if not posts:
        raise ValueError("At least one post is required")

    with tempfile.TemporaryDirectory(prefix="postroll-week-") as tmp:
        tmp_path = Path(tmp)

        # Stage all photos across all posts into one temp dir
        staged_posts: list[dict[str, Any]] = []
        for i, post in enumerate(posts):
            staged_paths: list[str] = []
            for j, p in enumerate(post["photo_paths"]):
                photo = Path(p).expanduser().resolve()
                if not photo.exists():
                    raise FileNotFoundError(f"Photo not found for post {i} ({post.get('day')}): {photo}")
                if photo.suffix.lower() in HEIC_SUFFIXES:
                    staged = _convert_heic_to_jpeg(photo, tmp_path)
                else:
                    staged = tmp_path / f"post{i:02d}_photo{j:03d}_{photo.name}"
                    shutil.copy2(photo, staged)
                staged_paths.append(str(staged))
            staged_posts.append({**post, "photo_paths": staged_paths})

        brand_voice_text = load_brand_voice()

        venue_context_line = (
            f" — performed in {venue_context.strip()}"
            if venue_context and venue_context.strip() else ""
        )

        # === Pass 1: generate all captions in one call ===
        prompt = WEEK_PROMPT_TEMPLATE.format(
            brand_voice=brand_voice_text,
            event=event,
            org=org,
            venue=venue,
            venue_context_line=venue_context_line,
            date=date,
            shoot_type=shoot_type,
            performers=_format_performers(program.get("performers", [])),
            pieces=_format_pieces(program.get("pieces", [])),
            scenes=_format_scenes(program.get("scenes", [])),
            post_count=len(staged_posts),
            posts_section=_format_week_posts(staged_posts),
        )

        all_staged = [p for post in staged_posts for p in post["photo_paths"]]
        all_labels = [Path(p).name for p in all_staged]
        data = run_json_prompt(
            prompt,
            timeout=900,
            image_paths=all_staged,
            image_labels=all_labels,
        )

        if not isinstance(data, dict) or "posts" not in data:
            raise ClaudeError(
                f"Expected JSON with 'posts' array, got {type(data).__name__}"
            )

        week_shape = (
            '{posts: list of {day, post_type, alt_texts, scene_labels, '
            "caption, hashtags}}"
        )

        # === Pass 2: brand-voice review (sounds like Dan?) ===
        if not skip_voice_pass:
            voice_prompt = build_voice_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                brand_voice=brand_voice_text,
                output_shape_description=week_shape,
            )
            data = run_json_prompt(voice_prompt, timeout=900)
            if not isinstance(data, dict) or "posts" not in data:
                raise ClaudeError(
                    f"Voice pass returned {type(data).__name__}, expected object with 'posts'"
                )

        # === Pass 3: cross-caption diversity check across the whole week ===
        if not skip_diversity_pass:
            diversity_prompt = build_diversity_review_prompt(
                week_json=json.dumps(data, ensure_ascii=False, indent=2),
                brand_voice=brand_voice_text,
            )
            data = run_json_prompt(diversity_prompt, timeout=900)
            if not isinstance(data, dict) or "posts" not in data:
                raise ClaudeError(
                    f"Diversity pass returned {type(data).__name__}, expected object with 'posts'"
                )

        # === Pass 4 (FINAL): humanizer — always runs last, non-negotiable ===
        # Humanizer is the final word on AI tells. It MUST be the last pass
        # so nothing downstream (voice, diversity) can re-introduce tells.
        # skip_humanizer exists only for tests — production runs never skip.
        if not skip_humanizer and is_humanizer_available(humanizer_path):
            humanizer_rules = load_humanizer_rules(humanizer_path)
            review_prompt = build_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                humanizer_rules=humanizer_rules,
                brand_voice=brand_voice_text,
                output_shape_description=week_shape,
            )
            data = run_json_prompt(review_prompt, timeout=900)
            if not isinstance(data, dict) or "posts" not in data:
                raise ClaudeError(
                    f"Humanizer pass returned {type(data).__name__}, expected object with 'posts'"
                )

    # Normalize each result. For single-alt post types, collapse
    # alt_texts/scene_labels to the first entry defensively in case
    # Claude ignored the Stage 1 instruction.
    results: list[dict[str, Any]] = []
    for post_data in data.get("posts", []):
        if not isinstance(post_data, dict):
            continue
        alt_texts = post_data.get("alt_texts") or []
        scene_labels = post_data.get("scene_labels") or []
        if not isinstance(alt_texts, list):
            alt_texts = [str(alt_texts)]
        if not isinstance(scene_labels, list):
            scene_labels = [scene_labels]
        post_type_out = post_data.get("post_type", "")
        if post_type_out in SINGLE_ALT_POST_TYPES:
            alt_texts = alt_texts[:1]
            scene_labels = scene_labels[:1]
        results.append(
            {
                "day": post_data.get("day", ""),
                "post_type": post_type_out,
                "caption": post_data.get("caption", "").strip(),
                "hashtags": post_data.get("hashtags", []),
                "alt_texts": [str(a).strip() for a in alt_texts],
                "scene_labels": scene_labels,
            }
        )
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a caption for one post")
    parser.add_argument("--event", required=True, help="Event name")
    parser.add_argument("--org", required=True, help="Organization")
    parser.add_argument("--venue", required=True, help="Venue")
    parser.add_argument("--date", required=True, help="Event date (YYYY-MM-DD)")
    parser.add_argument(
        "--day",
        required=True,
        choices=["sunday", "monday", "tuesday", "wednesday", "thursday", "friday"],
        help="Day of week the post will be published",
    )
    parser.add_argument(
        "--shoot-type",
        default="performance",
        help="What Dan actually witnessed: performance, rehearsal_and_performance, photo_call, rehearsal, dress_rehearsal, or free text",
    )
    parser.add_argument(
        "--post-type",
        default="feed_photo",
        help="Kind of post: feed_photo, carousel, slider_reel, morph_reel, screen_reel, scroll_reel, before_after_story",
    )
    parser.add_argument(
        "--name",
        action="append",
        default=[],
        help="Plain-text name to credit in the caption (for people without Instagram). Repeat for multiple.",
    )
    parser.add_argument(
        "--humanizer-path",
        type=Path,
        help="Path to humanizer SKILL.md (defaults to ~/.claude/skills/humanizer/SKILL.md)",
    )
    parser.add_argument(
        "--skip-humanizer",
        action="store_true",
        help="Skip the humanizer review pass (faster but lower quality)",
    )
    parser.add_argument(
        "--photo",
        action="append",
        required=True,
        type=Path,
        help="Photo to caption (repeat for multi-photo posts)",
    )
    parser.add_argument(
        "--tag",
        action="append",
        default=[],
        help="@ handle to mention in this post (repeat for multiple)",
    )
    parser.add_argument(
        "--program",
        type=Path,
        help="Path to program JSON from ocr_program (optional but recommended)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Where to write the JSON result (defaults to stdout)",
    )
    args = parser.parse_args()

    program: dict[str, Any] = {}
    if args.program:
        program = json.loads(args.program.read_text(encoding="utf-8"))

    try:
        result = generate_caption(
            event=args.event,
            org=args.org,
            venue=args.venue,
            date=args.date,
            day=args.day,
            photo_paths=args.photo,
            program=program,
            shoot_type=args.shoot_type,
            post_type=args.post_type,
            tag_handles=args.tag or None,
            name_mentions=args.name or None,
            humanizer_path=args.humanizer_path,
            skip_humanizer=args.skip_humanizer,
        )
    except (ClaudeError, FileNotFoundError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    text = json.dumps(result, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n", encoding="utf-8")
        print(f"wrote {args.output}")
    else:
        print(text)
        print()
        print("--- as it would post ---")
        print(format_for_post(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
