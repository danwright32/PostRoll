"""
PostRoll: Caption Generator

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
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from .ai_tells import (
    build_review_prompt,
    build_voice_review_prompt,
    is_humanizer_available,
    load_humanizer_rules,
    strip_em_dashes,
)
from .claude_client import (run_json_prompt, run_prompt, run_review_pass,
                            load_brand_voice, ClaudeError, partition_uploadable)
from .blog_findings import Finding, finding_entry
from .caption_credits import (
    HANDLE_RE,
    credit_findings,
    norm_handle,
    rewrite_lost_a_credit,
)
from .caption_quality import check_caption_alt_texts, problems_in, REWRITE_PROMPT
from . import org_prompt
from .performer_hashtags import ensure_brand_hashtag, strip_performer_hashtags
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


PROMPT_TEMPLATE = """\
{brand_voice}

---

Your task: write ONE social media caption + alt text for a
post containing {post_size_line}. The same caption is used
across Instagram, Facebook, TikTok, Pinterest, and Bluesky.

If there are multiple photos (a carousel, or a reel built from many
source frames), the caption stays GENERAL: it doesn't reference any
individual frame. {alt_shape_line}

Event details:
- Event name: {event}{org_line}
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
somewhere, body or trailing credit line). Each becomes a #-tag too:
{tag_handles}

Required plain-name credits for this post (people without Instagram
handles, appear as plain text in the caption, NOT as #-tags):
{name_mentions}

{shooter_notes_section}**SCOPE RULE. Read this before writing anything.**
{scope_rule}

{existing_captions_section}{photo_list_heading}
{photo_list}

You will work in four explicit ordered stages. Do them IN ORDER.

**Stage 1, alt text.** {alt_text_instruction}

**Stage 2, scene match.** For EACH entry you just wrote in
`alt_texts` (so one total for most post types, one per photo only for
carousels), use the structured scenes list above to decide which
scene/section it shows. Match by comparing the alt text against each
scene's `visual_cues`. Be DECISIVE: if the visual evidence points
clearly to one scene, pick it.

Write a short phrase like "[Scene name]" or null if no scene from the
list matches. Put the labels into `scene_labels` IN THE SAME ORDER
and at the SAME LENGTH as `alt_texts`.

**Stage 3, unified caption.** Now write ONE caption for the whole
post. You are NOT allowed to look back at the photos for this stage.
work from the alt texts, the scene labels, and the event metadata.

How to write it depends on `scene_labels`:

- If `scene_labels` has ONE entry (single-subject posts, scroll reels,
  or a carousel where every photo matched the same scene): use that
  label as the differentiating context when it is non-null, or fall
  back to a generic event-level frame when it is null.
- If `scene_labels` has MULTIPLE entries that span different scenes
  (carousels with mixed scenes), DO NOT pick one. Write a more
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

1. **Inline-woven credits.** Work 2-3 handles/names directly into a
   body sentence. Example: "@dciny's Vocal Colors at @lincolncenter,
   Sorenson Requiem conducted by @stephenmartintenor."
2. **Body + trailing stack, no "with" prefix.** Body sentence, then
   a bare line with all remaining handles/names. Example:
   "[body]\n\n@dciny @lincolncenter @kylepedersonmusic"
3. **Body + "with" line** (the previous default). Use sparingly, not
   every time. Example: "[body]\n\nwith @dciny @lincolncenter"
4. **Body + "conducted by / featuring / with" phrase.** A semantic
   prefix that matches what the handle-people actually do. Example:
   "[body]\n\nConducted by @jennayarobison. With @dciny @lincolncenter
   @kylepedersonmusic."
5. **Split credit by role.** Short stanza for conductors, another
   for composer, another for org/venue. Example:
   "[body]\n\nConducted by @stephenmartintenor and Jordan Langworthy.\n
   Featuring @kylepedersonmusic.\n@dciny at @lincolncenter."

Pick a different shape than what the last caption used if you can.
When name_mentions (plain-text names like "Jordan Langworthy") appear
in the credits, they fit naturally alongside @ handles. Do NOT add an
"@" to them, do NOT put them in the hashtag list.

The caption must follow the brand voice rules: short, structural, no
description of the photo, no fabrication, no AI tells.

**Do NOT default to "From the [scene]." as the opener.** Vary the
position and shape of any scene reference. See the "Acceptable shapes"
list in the brand voice doc above.

**Body length targets:**
- Single-photo feed posts: 80-180 characters for the body
- Carousels and scroll reels (multi-photo general captions): 120-280
  characters. Use the extra room to be specific about the scope
  (multiple scenes, three conductors by name, run times, etc.)
- Before/after reels: 80-180 characters. Keep it about the edit
  reveal

These are targets for the BODY only, excluding the credit stanza.

**Stage 4, hashtags.** 6-12 hashtags. Required: #dwphotony, venue,
show, composer/playwright/band, genre. Do NOT add a hashtag for a
performer, cast member, conductor or choreographer unless that person
is genuinely famous (a household name or a major figure in their
field); credit everyone else inline in the caption body instead. Plus
one #-tag per @ handle in tag_handles that belongs to an ORGANIZATION
or VENUE (so they're searchable too). A person's handle stays an
@mention in the body and never becomes a hashtag.

Return JSON ONLY in this exact shape (no markdown fences, no
commentary). `alt_texts` and `scene_labels` are arrays but their
length follows Stage 1: one entry for most post types, one entry
per photo only for carousels.

{{
  "alt_texts": ["<stage 1 output>", ...],
  "scene_labels": ["<stage 2 output>", ...],
  "caption": "<stage 3 output, including @ mentions>",
  "hashtags": ["#dwphotony", ...],
  "famous_people": ["<any person above you judged genuinely famous>", ...]
}}

`famous_people` is how a genuinely famous performer keeps their hashtag:
list only people who are household names or major figures in their
field, and leave it empty otherwise. It is not shown to anyone; it is
read by the check that removes ordinary performers' name tags.

Hashtag rules (re-stated for emphasis):
- ALWAYS include #dwphotony.
- Include a venue hashtag derived from "{venue}".
{org_hashtag_rule}
- Performer, cast, conductor and choreographer hashtags ONLY when the
  person is genuinely famous (a household name or a major figure in
  their field), so the tag actually aids discovery. Do not turn
  ordinary performer names into hashtags: a tag like #janesmith for a
  local cast member is noise, not reach. Credit those people inline in
  the caption body instead (as an @mention if they have a handle,
  otherwise by plain name). Composer, playwright and band tags are NOT
  subject to this: repertoire search works differently, so keep them.
- Add 2-3 relevant tags (genre, instrument, repertoire, city).
- Total 6-10 hashtags. No padding.

Caption rules (re-stated, with hard defaults):

DEFAULT FORMAT, short and structural. The system does NOT have a
`dan_notes` field with Dan's actual observations from the shoot, so you
must NOT write a "voice-y" caption with a behind-the-camera hook.
Write a short caption that:

1. **REQUIRED: differentiate this photo from other photos in the same
   event by LABELING which scene/section/moment of the production it
   shows.** This is mandatory whenever the program/enrichment data
   above lists distinct scenes/sections AND the photo visibly shows
   one of them. Do NOT skip the label and write a generic "photo call"
   caption when a scene label is available. That produces identical
   captions for every post in the event, which is a failure mode.

   How to find the label:
   a. Scan the program/enrichment data above for any list of scenes,
      sets, movements, acts, pieces, or sections.
   b. Read the photo and identify which one of those it shows. Use
      visible cues: set design (kitchen vs spa, podium vs stage,
      indoor vs outdoor), costumes, props, location.
   c. Write the label as a short phrase: "From the [scene name]" or
      "[Scene name]." Use only labels that exist in the data. Do not
      invent scene names.
   d. Put ONLY the label in the caption. The visible cues you used to
      pick it stay in alt text.

   Example logic: if the program says the play has two scenes, a
   spa and a restaurant, and you see a kitchen table with bowls in
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

Target length: 80-180 characters for the caption itself. Shorter is
fine. Longer needs to earn it with real material, and you don't have
real material here.

ABSOLUTELY NEVER:
- Describe the photo's literal contents (costumes, props, gestures,
  facial expressions, lighting, framing) as the caption body. That's
  alt text's job. Use those cues to IDENTIFY which scene/section the
  photo shows, then write the LABEL, not the description.
- Open with a comma-separated list of objects ("A table, two bowls,
  one Heineken..."). That is the AI list cadence and it is banned.
- Use rule-of-three patterns ("X, Y, and Z").
- Fabricate observations, durations, counts, activities, audience
  reactions, what the cast was doing before/after the photo, what
  characters were thinking, or anything not in the inputs.
- Fabricate or guess @ handles. ONLY use handles from the tag_handles
  list above. If tag_handles is "(none)", do NOT invent any @ mentions.
  A wrong handle tags the wrong account. This is a hard rule.
- Pull handles from anywhere except `tag_handles`. The shared
  Performers block lists names + roles only and contains NO handles by
  design. If a performer's handle is not in tag_handles, that performer
  must NOT be tagged in this post (not in the body, not in a trailing
  stack, nowhere). Mention them by plain name only if they appear in
  `name_mentions`, otherwise omit them entirely.
- Copy any specific phrase, person, venue, or detail from the
  example captions in the brand voice doc. Those are STRUCTURAL
  patterns from other events.
- Stack credits like a press release.
- Use hype words (stunning, breathtaking, magical, etc.).
- Use emoji.
- Use "link in bio," "DM me," "swipe to see more," or any
  scroll-pattern engagement bait.
- End with a generic "what do you think?" question.

Lowercase or sentence case is fine. Match Dan's natural register.
"""


def _format_performers(performers: list[dict[str, Any]]) -> str:
    """Format the shared performers context block for the caption prompt.

    Intentionally omits @handles. Each post's `tag_handles` list (passed
    separately, per post) is the authoritative source for which handles to
    tag in that post's caption. Showing handles in this shared block leaks
    them across posts: Claude sees all 13 handles and dumps them into a
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
        lines.append(f"- {composer}: {title}")
    return "\n".join(lines)


def _format_scenes(scenes: list[dict[str, Any]]) -> str:
    """Format the structured scenes list for the prompt."""
    if not scenes:
        return "(none listed in program data, fall back to generic event-level context)"
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
        return "(none: generate the caption without forced @ mentions)"
    return "\n".join(f"- {h}" for h in tag_handles)


def _format_name_mentions(name_mentions: list[str] | None) -> str:
    """Format the list of plain-text names for the prompt."""
    if not name_mentions:
        return "(none: no forced plain-name credits)"
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

# Post types where the subject IS the whole event, a carousel of
# different scenes, or a scroll reel covering many photos. For these,
# the body can legitimately weave all credits in and cover the full
# scope of the show.
EVENT_LEVEL_POST_TYPES = {
    "carousel",
    "scroll_reel",
    "clip_reel",
}


SCOPE_RULE_SINGLE_SUBJECT = """\
This is a SINGLE-SUBJECT post: one photo, or one edit of one photo.
The BODY of the caption must stay locked to what is actually in this
frame: the one scene / set / conductor / cast grouping visible. Do NOT
recap the whole event. Do NOT list every conductor, every set, every
piece on the program. A reader who sees only this post should learn
about THIS moment, not the three-hour arc of the night.

Handle the required @ mentions and name credits like this:

1. Body (1-2 short sentences): name ONLY the people, pieces, and
   context relevant to THIS frame. If only one conductor is visibly
   leading in the photo, only that conductor belongs in the body. The
   piece being performed, the section being staged, the actor in the
   shot. Those go in the body. Everyone else does NOT.

2. Trailing credit stack (separated by ONE blank line): on a new line
   after the body, put the @ handles and name_mentions that did NOT
   make it into the body, as a bare stack with no "with" prefix and no
   narrative connector. Org and venue handles almost always land here.
   Example shape:

       [body sentence about the one scene/set in the frame]

       @org @venue @conductor_not_in_frame Name Without Handle

   Every handle and every name_mention must appear SOMEWHERE, body OR
   trailing stack. But credits for people not in the frame belong in
   the stack, not woven into prose about moments they weren't part of.

   EXACTLY ONCE. Body OR stack, never both. If you name @greenwich_house
   in the body, it does NOT go in the stack as well. This is enforced in
   code after you answer, so a repeat is deleted rather than shipped.

   WHEN THE LIST IS LONG (five or more credits, which a carousel with a
   different person tagged per photo will produce), do NOT try to name
   them all in the body. Weave in the two or three the photos are
   actually about, and let the trailing stack carry the rest. A body
   that lists ten people is a credit dump, not a caption.

3. If the body already mentions a handle naturally, don't repeat it in
   the trailing stack. The stack is for what's left over.

Violations to avoid:
- "Opened with [A], [B] had the middle set, [C] closed on [D]"
  is a concert recap, not a caption about this photo. Banned.
- "Earlier in the night [other conductor] did [other thing]" is banned.
  You are not the program notes.
- Naming a performer who is not visibly in this frame in the body.
- **Backhanded compliments / faint praise.** Phrasings like "held his
  own", "kept up", "more than capable", "did her best", "managed",
  "tried hard", "respectable showing", or any descriptive stand-in for
  a performer's name (e.g. "a pianist who…", "the accompanist who…")
  are BANNED. They sound condescending. If a performer is in the frame
  with a tag handle or name_mention, name them by that handle or name,
  never by a generic role noun followed by faint praise.
- **Reducing a tagged performer to a description.** If `@filam_pianist`
  is in the required tag_handles list and they are visibly in this
  frame, the caption must use `@filam_pianist` (in body or stack), not
  "a pianist". The same rule applies to name_mentions: use the actual
  name, not "a pianist named such-and-such" or any role-noun substitute.
"""

SCOPE_RULE_EVENT_LEVEL = """\
This is an EVENT-LEVEL post: a carousel or scroll reel that really
does cover the whole event. The body legitimately spans everything.
Credits can weave through the body naturally, or land in a trailing
stack. Pick whichever shape reads best and varies from the other
captions in the week.

Every required handle and every name_mention must appear somewhere in
the caption. Because this post covers the whole event, it's fine to
name multiple conductors / sets / pieces in the body, which matches
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
        "broad arc, NOT any single photo. If photos span multiple scenes, stay general. "
        "don't try to label a single scene. If photos are all from one scene, label it."
    ),
    "slider_reel": (
        "A before/after slider reel, a short video that wipes between the RAW image "
        "and the edited image of the SAME photo. The caption should honestly reference "
        "the edit reveal (RAW → final, editing process, the invisible work behind a "
        "single frame) as the reason this post exists. Do NOT describe it as just "
        "another photo from the show, which misses the point of the post."
    ),
    "morph_reel": (
        "A before/after split-compare reel, a short video showing the RAW and edited "
        "versions side by side or morphing between them. Same framing as slider_reel: "
        "the post is about the edit, not just the moment."
    ),
    "screen_reel": (
        "A sped-up Lightroom screen recording reel, a short video of Dan editing a "
        "single photo, compressed into ~15-20 seconds. The caption should reference "
        "the editing process itself. Do NOT pretend the post shows the performance. "
        "it shows Dan working."
    ),
    "scroll_reel": (
        "A photo scroll reel, a short video built from many photos of the event "
        "scrolling or transitioning past. The caption should be general-event-level, "
        "not photo-specific. Reference the scope (a night, a week, a whole show) "
        "rather than any individual frame."
    ),
    "clip_reel": (
        "An auto-cut highlight reel: a short video built from several video clips "
        "shot live at the event, edited together with cuts and transitions to a music "
        "bed. The caption should be general-event-level like a scroll reel, not tied "
        "to any single clip's moment. Reference the overall energy or arc of the "
        "performance rather than describing individual cuts."
    ),
    "before_after_story": (
        "A static before/after story image (not a reel). A single 1080x1920 image "
        "showing the RAW and edited photos stacked. No caption needed for Instagram "
        "stories, but if one is generated, frame it as the edit reveal."
    ),
    "performance": (
        "Generic single-photo feed post framing. Use this as a default."
    ),
}


# Per-post-type Stage 1 (alt text) instructions. Wed carousels get one
# alt per photo; everything else gets ONE alt text in the list.
# Instagram only attaches one alt text to a single feed post, story,
# or reel: per-photo alt texts on scroll reels never get used.
ALT_TEXT_INSTRUCTION = {
    "carousel": (
        "Write ONE alt text per photo in the `alt_texts` list, 15-35 "
        "words each, IN THE SAME ORDER as the photos listed above. "
        "Describe what is actually visible in each frame: who, what, "
        "where, lighting, gestures, set design, props."
    ),
    "scroll_reel": (
        "Write ONE alt text for the reel AS A WHOLE. Put it as a SINGLE "
        "entry in the `alt_texts` list. The list must have exactly 1 entry. "
        "Write a UNIFIED NARRATIVE summary: what is this reel about, who "
        "appears, what is the setting. Do NOT list what individual photos "
        "show. Do NOT use semicolons or 'and' to chain descriptions of "
        "separate frames, which is just per-frame alt text in disguise. "
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
ALT_TEXT_INSTRUCTION["clip_reel"]   = ALT_TEXT_INSTRUCTION["scroll_reel"]

def _post_size_line(post_type: str, attached: int, post_photo_count: int | None) -> str:
    """What the post actually holds, said in the prompt's opening sentence.

    Thursday's scroll reel is 50 to 200 photographs and the prompt is handed
    four of them, because sending the reel's whole photo set would blow past
    the request size for no benefit. The header then said "a post containing 4
    photo(s)", and the photo list named four files, so the model was being
    asked to summarise a reel it had been told was four pictures (#1067).

    Half the Thursday alt texts in the live store describe a single moment as a
    result, which reads as correct: it is a well written true sentence about one
    photograph, and a screen reader user is told a 234 photo reel is a picture
    of four dancers.
    """
    if post_photo_count and post_photo_count > attached:
        return (f"{post_photo_count} photo(s), of which {attached} "
                f"representative one(s) are attached below")
    return f"{attached} photo(s)"


def _photo_list_heading(attached: int, post_photo_count: int | None) -> str:
    if post_photo_count and post_photo_count > attached:
        return (f"A representative sample of the post's {post_photo_count} photos "
                f"({attached} attached, NOT the whole post):")
    return f"Photos in this post ({attached}):"


def _alt_shape_line(post_type: str) -> str:
    """Whether alt text is per photo, said per POST TYPE.

    This sentence used to read "The alt text is per-photo" for every post type,
    including the ones whose own instruction says the opposite three paragraphs
    later. A rule stated once is outweighed by surrounding prose that breaks it,
    and here the contradicting prose was in the same prompt (L270, #1067).
    """
    if post_type in SINGLE_ALT_POST_TYPES:
        return ("This post takes ONE alt text describing the post as a whole, "
                "and one shared post-level caption.")
    return "The alt text is per-photo, but the caption is one shared post-level caption."


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
    "clip_reel",
}


def _alt_text_instruction_for(post_type: str) -> str:
    return ALT_TEXT_INSTRUCTION.get(post_type, DEFAULT_ALT_TEXT_INSTRUCTION)


_WORD_RANGE_RE = re.compile(r"(\d+)\s*[-\u2013\u2014]\s*(\d+)\s*words", re.I)


def _word_floor_in(instruction: str) -> int | None:
    """The smaller half of the "25-50 words" range an alt instruction states."""
    band = _word_band_in(instruction)
    return band[0] if band else None


def _word_band_in(instruction: str) -> tuple[int, int] | None:
    """Both ends of the "25-50 words" range an alt instruction states."""
    match = _WORD_RANGE_RE.search(instruction or "")
    return (int(match.group(1)), int(match.group(2))) if match else None


def _alt_word_band(post_type: str) -> tuple[int, int] | None:
    """The word range this post type's OWN alt instruction asks for (#1068).

    Read out of the instruction rather than written down beside it, so the
    check and the rule it enforces cannot drift into two numbers (L41). A
    scroll reel asks for 25 to 50 and a carousel photo for 15 to 35, so there
    is no single band to write down even if that were wanted.
    """
    return _word_band_in(_alt_text_instruction_for(post_type))


def _alt_word_floor(post_type: str) -> int | None:
    """The minimum word count this post type's OWN alt instruction asks for.

    Read out of the instruction rather than written down beside it, so the
    check and the thing it checks cannot drift into two numbers (L41).

    None means the instruction states no range, which switches the floor check
    off for that post type. `test_every_post_type_alt_instruction_states_a_word_floor`
    is what keeps that unreachable: an instruction reworded without its numbers
    fails the suite rather than silently disabling the check (L113, L100).
    """
    return _word_floor_in(_alt_text_instruction_for(post_type))


def _word_overlap(left: str, right: str) -> float:
    """How much two alt texts share, 0 to 1, as a fraction of all their words.

    Deliberately crude. It only has to separate "this is the same description
    with a few words changed" from "this is somebody else's description", and
    those sit at opposite ends of the range.
    """
    a = {w for w in str(left).lower().split() if w}
    b = {w for w in str(right).lower().split() if w}
    if not a or not b:
        return 1.0 if a == b else 0.0
    return len(a & b) / len(a | b)


#: How much a returned alt text must resemble one of the draft's OTHER entries
#: before that counts as a swap rather than as noise. A real swap lands near 1,
#: because a clean in place changes a few words; unrelated descriptions of the
#: same event share only the small words and sit far below this.
_SWAP_RESEMBLANCE = 0.5


def _alt_shape_fault(post_type: str, draft: object, produced: object) -> str | None:
    """A fault in the SHAPE of the returned alt texts, or None.

    These are whole list faults: what is wrong is the alignment between the
    list and the photographs, so there is no good entry to keep and the draft's
    list stands entire.
    """
    if not isinstance(produced, list) or not isinstance(draft, list):
        return (f"returned {type(produced).__name__} where the draft had "
                f"{type(draft).__name__}")

    if len(produced) != len(draft):
        return (f"returned {len(produced)} alt texts where the draft had "
                f"{len(draft)}, which moves every entry after the change onto "
                f"a different photograph")

    # A reorder, whether or not the entries were also reworded.
    #
    # This first shipped as a multiset comparison, which only saw a swap when
    # the entries came back byte identical. A pass that reordered AND cleaned
    # defeated it: the count was unchanged and every entry cleared its word
    # floor, so every other rule passed and the post shipped with each
    # description beside the wrong photograph. Found by running the check
    # rather than by reading it, the day after it shipped.
    #
    # The multiset comparison is GONE rather than kept alongside this, because
    # this catches everything it caught: two byte identical entries swapped
    # resemble each other's slots perfectly, and swapping two entries that are
    # identical to each other is not a change at all (L29).
    #
    # A clean in place changes a few words, so a returned entry still resembles
    # its OWN draft far more than a neighbour's. A swap is the opposite, and the
    # two cases are nowhere near each other.
    #
    # Zipped rather than indexed, so this cannot raise when the lists are
    # different lengths. The count rule above returns first in the shipped code,
    # but a guard that only holds while the rule ABOVE it is intact is a guard
    # whose mutation crashes instead of failing (L140).
    for index, (now, _mine_draft) in enumerate(zip(produced, draft)):
        mine = _word_overlap(now, draft[index])
        for other, was in enumerate(draft):
            if other == index:
                continue
            theirs = _word_overlap(now, was)
            if theirs > mine and theirs >= _SWAP_RESEMBLANCE:
                return (f"moved alt text {other + 1} into slot {index + 1} while "
                        f"rewording it, so each description now sits beside a "
                        f"different photograph")
    return None


def _alt_entries_below_floor(post_type: str, draft: list,
                             produced: list) -> list[int]:
    """Which returned entries were cut under their own instruction's word floor.

    Per entry, not the whole list, because this fault is confined to the entry
    that has it: on a twenty photo carousel one description cut too short is no
    reason to throw away the cleaning on the other nineteen. The shape faults
    above are the opposite, and are handled as a whole.

    An entry must be BOTH under the floor and shorter than the draft's, so a
    clean that leaves an already short alt alone, or lengthens it towards the
    floor, is not refused for a fault it did not commit.
    """
    floor = _alt_word_floor(post_type)
    if floor is None:
        return []
    return [index for index, (was, now) in enumerate(zip(draft, produced))
            if len(str(now).split()) < floor
            and len(str(now).split()) < len(str(was).split())]


def _rewritten_alt_detail(draft: object, produced: object) -> str:
    """What a review pass did to the alt texts, said in the unit that matters.

    A post with one alt text has one sentence worth quoting. A per photo post
    has a list whose POSITION is its meaning, and there the useful facts are how
    many entries moved and where the first one is: one rewritten entry and all
    of them rewritten want different responses, and quoting entry 0 alone cannot
    tell those apart (L11, #1214).
    """
    was = draft if isinstance(draft, list) else []
    now = produced if isinstance(produced, list) else []

    def quote(items: list, index: int) -> str:
        return str(items[index])[:90] if index < len(items) else "(none)"

    if len(was) <= 1 and len(now) <= 1:
        return f"Shipped: {quote(was, 0)} | The pass wanted: {quote(now, 0)}"

    moved = [i for i in range(max(len(was), len(now)))
             if quote(was, i) != quote(now, i)]
    parts = [f"{len(moved)} of {len(was)} alt texts differ"]
    if len(was) != len(now):
        # A length change is the shape that shifts every later entry onto a
        # different photograph, so it is named rather than folded into the count.
        parts.append(f"the pass returned {len(now)}")
    if moved:
        parts.append(f"first at photo {moved[0] + 1}. Shipped: "
                     f"{quote(was, moved[0])} | The pass wanted: "
                     f"{quote(now, moved[0])}")
    return ". ".join(parts)


def org_prompt_lines(org: str) -> tuple[str, str]:
    """What this prompt says about the organisation: the detail line, and the
    hashtag rule (#689).

    Both come from `org_prompt`, which the blog prompt uses too: the same two
    branches written in two files would drift, and the one that drifts is the
    one nobody is looking at.

    Returned as a pair rather than formatted in place so both cases can be read
    and asserted without running a caption (L151).
    """
    return (org_prompt.detail_line(org), org_prompt.hashtag_rule(org))


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
    photo_tags: dict[str, list[str]] | None = None,
    existing_captions: list[str] | None = None,
    event_url: str = "",
    venue_context: str = "",
    #: How many photographs the POST holds, when that is more than the number
    #: attached. Thursday's scroll reel is 50 to 200 photos and is handed four
    #: of them; without this the prompt said "a post containing 4 photo(s)" and
    #: the model summarised a reel it had been told was four pictures (#1067).
    post_photo_count: int | None = None,
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

    photo_tags is an optional mapping of photo path -> list of people in
    that specific photo (e.g. {"/photos/show-277.jpg": ["Mike Bono"]}).
    Used for multi-photo carousels (Wednesday) so each per-photo alt text
    knows who is actually in that frame. Keys must match the entries in
    photo_paths.

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
                staged = _convert_heic_to_jpeg(photo, tmp_path, prefix=f"{i:03d}_")
            else:
                staged = tmp_path / f"{i:03d}_{photo.name}"
                shutil.copy2(photo, staged)
            staged_paths.append(str(staged))

        # A photo that cannot be opened is dropped rather than failing the
        # whole day (#228). Done HERE, before the prompt below is formatted:
        # the prompt states the photo count and lists the filenames, so a photo
        # dropped after that point would leave the model reading about a
        # photograph it never received. Refuses outright when nothing survives.
        kept_indices, skipped_photos = partition_uploadable(staged_paths, model="sonnet")
        if skipped_photos:
            for s in skipped_photos:
                print(f"[generate_captions] skipping unreadable photo "
                      f"{Path(photo_paths[s.index]).name}: {s.reason}",
                      flush=True, file=sys.stderr)
            # Everything the prompt and the request are built from now describes
            # only the photos that survived, so all three agree.
            original_paths = list(photo_paths)
            photo_paths = [photo_paths[i] for i in kept_indices]
            staged_paths = [staged_paths[i] for i in kept_indices]
        else:
            original_paths = list(photo_paths)

        brand_voice_text = load_brand_voice()
        photo_count = len(staged_paths)
        # Each filename is also passed as image_labels so the model gets a
        # `Photo N: filename.jpg` block right before each attached image.
        # That eliminates the "alt text describes the wrong photo" failure
        # mode where the model guessed at file ↔ image correspondence.
        photo_filenames = [Path(p).name for p in staged_paths]
        # Annotate each photo with the people tagged in it (if any), aligned by
        # index to the original photo_paths. Lets per-photo alt text reference
        # who is actually in each carousel frame.
        if photo_tags:
            photo_lines = []
            for i, name in enumerate(photo_filenames):
                key = str(photo_paths[i]) if i < len(photo_paths) else None
                tags = photo_tags.get(key) if key else None
                if tags:
                    photo_lines.append(f"- {name} (people in this photo: {', '.join(tags)})")
                else:
                    photo_lines.append(f"- {name}")
            photo_list = "\n".join(photo_lines)
        else:
            photo_list = "\n".join(f"- {n}" for n in photo_filenames)
        post_type_framing = POST_TYPE_FRAMING.get(
            post_type, POST_TYPE_FRAMING["feed_photo"]
        )
        existing_section = _format_existing_captions(existing_captions)
        scope_rule = _scope_rule_for(post_type)
        shooter_notes_section = (
            f"Shooter's observations for this post (first-hand detail from Dan"
            f", use these to write a more specific, voice-y caption):\n{notes.strip()}\n\n"
        ) if notes.strip() else ""

        event_url_line = (
            f"- Event page URL (additional context): {event_url}"
            if event_url else ""
        )
        # Specific room inside the venue (e.g. Weill Recital Hall inside Carnegie Hall)
        # Used only for prose context. Graphics still show the top-level venue.
        venue_context_line = (
            f", performed in {venue_context.strip()}"
            if venue_context and venue_context.strip() else ""
        )

        # === Pass 1: generate the draft ===
        org_line, org_hashtag_rule = org_prompt_lines(org)
        prompt = PROMPT_TEMPLATE.format(
            brand_voice=brand_voice_text,
            event=event,
            org_line=org_line,
            org_hashtag_rule=org_hashtag_rule,
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
            post_size_line=_post_size_line(post_type, photo_count, post_photo_count),
            photo_list_heading=_photo_list_heading(photo_count, post_photo_count),
            alt_shape_line=_alt_shape_line(post_type),
            photo_list=photo_list,
        )

        data = run_json_prompt(
            prompt,
            timeout=600,
            image_paths=staged_paths,
            image_labels=photo_filenames,
            step="caption",
        )

        if not isinstance(data, dict):
            raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

        # What the DRAFT pass wrote, kept before either review pass can touch
        # it (#1067, the fourth cause).
        #
        # Passes 2 and 3 hand the whole draft JSON back to the model to
        # rewrite, carrying the humanizer rules, the brand voice and a one line
        # output shape. Neither carries the post type, so neither has any idea
        # that a reel takes one alt text describing the whole reel. A compliant
        # reel level alt could be condensed back into a single frame
        # description by a later stage, and the stage that enforced the rule
        # had already run (L280).
        #
        # Carrying the rule into both prompts was the other option and it is
        # weaker: it is still a rule living in a prompt, on the two passes that
        # are not asked to touch alt text at all (L27). Putting the draft's alt
        # text back is structural, costs nothing, and cannot be talked out of.
        draft_alt_texts = data.get("alt_texts")

        single_shape = (
            "{alt_texts: list of strings, scene_labels: list of strings or "
            "nulls, caption: string, hashtags: list of strings}"
        )

        # === Pass 2: brand-voice review (does this actually sound like Dan?) ===
        # Narrower than humanizer: asks only "voice match?"
        if not skip_voice_pass:
            voice_prompt = build_voice_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                brand_voice=brand_voice_text,
                output_shape_description=single_shape,
            )
            data = run_review_pass(voice_prompt, data, label="voice", timeout=300, runner=run_json_prompt)

        # === Pass 3 (FINAL): humanizer, always runs last, non-negotiable ===
        # Humanizer is the final word on AI tells. It MUST be the last pass
        # so nothing downstream can re-introduce tells. skip_humanizer exists
        # only for tests. Production runs should never skip this.
        if not skip_humanizer and is_humanizer_available(humanizer_path):
            humanizer_rules = load_humanizer_rules(humanizer_path)
            review_prompt = build_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                humanizer_rules=humanizer_rules,
                brand_voice=brand_voice_text,
                output_shape_description=single_shape,
            )
            data = run_review_pass(review_prompt, data, label="humanizer", timeout=300, runner=run_json_prompt)

    # Normalize alt_texts and scene_labels. For single-alt post types,
    # collapse to the first entry defensively in case Claude wrote one
    # per photo anyway, and say so rather than swallowing it (#1067).
    per_frame_findings: list[Finding] = []

    # The review passes may clean the alt text; what they may not do is change
    # its shape (#1067, #1214, and Dan's call on 2026-09-02).
    #
    # Both review prompts already ask for exactly this: "for lists of strings
    # (alt_texts, scene_labels), preserve count and order, clean each item in
    # place" (`ai_tells.py`). Nothing enforced either half, so a pass could
    # condense a reel level description into one frame's, and on a per photo
    # post could reorder or drop entries and shift every later alt text onto a
    # different photograph. That second one is #1008's failure by another
    # route, and invisible for the same reason: each sentence is true of SOME
    # photograph in the post, so a sighted read does not catch it.
    #
    # #1067 and #1214 first held alt text out of the rewrite entirely, which
    # stopped the damage and also stopped the cleaning the humanizer is there
    # to do. So the action is allowed and the RESULT is judged instead.
    #
    # Two kinds of fault, handled differently because they are different sizes.
    # A SHAPE fault (a changed count, a reorder, a reorder hiding inside a
    # reword) is wrong about the whole list's alignment to the photographs, so
    # the draft's list stands entire. An entry CUT under its own word floor is
    # wrong about one entry, so only that one falls back and the cleaning on
    # every other photograph survives.
    #
    # Refusing rather than repairing: the pass's answer for the offending field
    # is discarded, so a refusal costs the cleaning and never the correctness.
    # A rule that lives only in a prompt is a hope (L27); this is the same rule
    # with something reading the answer.
    #
    # Reported, because a refusal is evidence a pass ignored an instruction and
    # putting the draft back destroys it (L340). Not reported when the pass is
    # accepted: this fires on real weeks, and a finding on every tidied post is
    # a panel that gets skimmed (L36).
    produced = data.get("alt_texts")
    shape_fault = _alt_shape_fault(post_type, draft_alt_texts, produced)
    if shape_fault is not None:
        per_frame_findings.append(Finding(
            code="alt_text_rewritten_by_review",
            message=("A review pass changed this post's alt text in a way it "
                     "was not asked to. The draft's own alt text is what "
                     "shipped."),
            detail=(f"The pass {shape_fault}. "
                    + _rewritten_alt_detail(draft_alt_texts, produced)),
        ))
        data = dict(data, alt_texts=draft_alt_texts)
    else:
        cut = _alt_entries_below_floor(post_type, draft_alt_texts, produced)
        if cut:
            floor = _alt_word_floor(post_type)
            kept = [draft_alt_texts[i] if i in set(cut) else produced[i]
                    for i in range(len(produced))]
            where = ", ".join(str(i + 1) for i in cut)
            per_frame_findings.append(Finding(
                code="alt_text_rewritten_by_review",
                message=("A review pass cut this post's alt text shorter than "
                         "it should be. The draft's own alt text is what "
                         "shipped for the ones it cut."),
                detail=(f"The pass cut alt text {where} under the {floor} word "
                        f"floor a {post_type} asks for, which is what "
                        f"condensing a post into one frame's description looks "
                        f"like. "
                        + _rewritten_alt_detail(draft_alt_texts, produced)),
            ))
            data = dict(data, alt_texts=kept)

    alt_texts = data.get("alt_texts") or []
    scene_labels = data.get("scene_labels") or []
    if not isinstance(alt_texts, list):
        alt_texts = [str(alt_texts)]
    if not isinstance(scene_labels, list):
        scene_labels = [scene_labels]

    if post_type in SINGLE_ALT_POST_TYPES:
        # The trim stays, because everything downstream takes entry 0 and a
        # list of per-frame alts would ship whichever one happened to be first.
        # What is new is that it is REPORTED (#1067, L340).
        #
        # This post type asks for one alt text describing the whole post. A
        # model that wrote one per photograph has ignored that, and the entry
        # that survives is a single frame's description: correctly formed, true
        # of one picture, and indistinguishable from a compliant post level alt.
        # Coercing it silently destroyed the only evidence the instruction was
        # ignored, at the moment it was made, and it fails a bit over half the
        # time on Thursday reels in the live store.
        if len(alt_texts) > 1:
            per_frame_findings.append(Finding(
                code="alt_text_per_frame",
                message=("This post takes one alt text for the whole post, and "
                         "one per photo came back. The first is what shipped."),
                detail=(f"{len(alt_texts)} alt texts for a {post_type}. "
                        f"Kept: {alt_texts[0][:90]}"),
            ))
        alt_texts = alt_texts[:1]
        scene_labels = scene_labels[:1]
    elif skipped_photos:
        # Per-photo output came back one entry per photo that was SENT, while
        # everything downstream (CAPTIONS.txt, the review screen) indexes into
        # the day's full photo list. Left as-is, every photo after the skipped
        # one would carry its neighbour's alt text, which is the invented-alt-
        # text failure this feature exists to avoid. Put the holes back.
        alt_texts = _reinsert_skipped(alt_texts, kept_indices, len(original_paths))
        scene_labels = _reinsert_skipped(scene_labels, kept_indices, len(original_paths))

    # A credit appears exactly once (#188, #191). The prompt asks for a few
    # woven into the body and the rest left for the trailing stack; this
    # removes from that stack anything the body already credits, because
    # whether a handle appears twice is checkable and a rule that lives only
    # in a prompt is a hope.
    # What actually ships, computed once and both returned and checked (#1068).
    #
    # `strip_em_dashes` splits a dash joined token into two, so a word count
    # taken before it and one taken after it are different numbers. The blog
    # side learned this the hard way: its repairer and its checker measured the
    # same body differently and the round cap became a silent give up. So the
    # checks read the text that reaches Instagram, not the text before the last
    # thing that rewrites it.
    shipped_alt_texts = [strip_em_dashes(str(a).strip()) for a in alt_texts]

    final_caption = dedupe_credit_stack(_enforce_caption_bans(
        strip_em_dashes(data.get("caption", "").strip()),
        tag_handles=tag_handles, name_mentions=name_mentions))

    return {
        "caption": final_caption,
        # Deterministic backstop, not a second ask of the model: the prompt
        # above states the fame gate, and this enforces it against the program
        # data. A rule that lives only in a prompt is a hope (#199).
        # Two deterministic backstops, both because a rule that lives only in
        # the prompt is a hope (#199, #478). One removes what must not be
        # there; the other puts back the one tag that must (the prompt says
        # ALWAYS include #dwphotony, twice, and nothing checked).
        "hashtags": ensure_brand_hashtag(strip_performer_hashtags(
            data.get("hashtags", []),
            program=program,
            name_mentions=name_mentions,
            photo_tags=photo_tags,
            tag_handles=tag_handles,
            famous=data.get("famous_people") or [],
        )),
        "alt_texts": shipped_alt_texts,
        "scene_labels": scene_labels,
        # Named so the review screen can say which file was left out. Always
        # present, so a consumer reading it cannot mistake "no key" for "no
        # skips" (#228).
        "skipped_photos": [
            {"file": Path(original_paths[s.index]).name, "reason": s.reason}
            for s in skipped_photos
        ],
        # The handle and name rules, checked rather than asked for (#475).
        # Reported, not repaired: an invented handle cannot be replaced with
        # the right one by anything here, and Dan reads the caption before it
        # is posted.
        "findings": [
            finding_entry(f) for f in (
                credit_findings(final_caption, tag_handles=tag_handles,
                                name_mentions=name_mentions)
                + per_frame_findings
                # The alt text rules (#1068). Three of the blog's six, chosen by
                # measuring all six against the live store rather than by
                # reading them; `caption_quality` records the rates and why the
                # other three are out.
                + check_caption_alt_texts(
                    shipped_alt_texts,
                    band=_alt_word_band(post_type),
                    photo_names=[Path(p).name for p in original_paths]))
        ],
        # The exact text those findings were measured against, so an edited
        # caption stops showing findings about the text before the edit. Same
        # reason the blog paths emit findings_body (#201, #974).
        "findings_caption": final_caption,
        # Which photo each alt text describes (#1008).
        #
        # `alt_texts` is positional against this list, and everything that edits
        # a day afterwards moves the photos without it. `removingPhotos` re-keys
        # the crops, the tags and the collage cells and cannot reach the alt
        # texts, which live on a different object, and a drag to reorder moves
        # nothing but the photos. So position measures whatever later occupies
        # it (L237), and the export labels an alt text with a filename that is
        # not its subject.
        #
        # `original_paths` rather than `photo_paths`, which is the SURVIVING
        # subset when a photo could not be read: the alt texts have already had
        # their holes put back against the full list just above, so anchoring to
        # the subset would reintroduce the off-by-one that `_reinsert_skipped`
        # exists to prevent, at the one moment it is hardest to notice.
        #
        # Truncated to the alt texts that survived normalization, so the two
        # lists are the same length in every branch. A single alt post keeps one
        # alt text, and an anchor list still naming every photo would claim all
        # of them for it (L16).
        "alt_text_photo_paths": [str(p) for p in original_paths][:len(alt_texts)],
    }


# #188 / #191: a credit appears exactly ONCE in a caption.
#
# The organisation and venue handles go on every caption automatically and are
# also offered as per-photo tags, so an event account could be credited twice by
# two routes. On a 10-photo carousel with a different person tagged per photo,
# ten credits arrive at once and the same doubling multiplies.
#
# Dan's rule: if it is already mentioned in the caption, it does not need to be
# mentioned again in the trailing credit stack.
#
# Which credits read naturally in the body is a judgement, so the prompt asks
# for that. Whether a handle appears twice is exactly checkable, so it is
# settled here rather than by asking the model whether it obeyed.
# One definition of what an @ handle looks like and of how two spellings of
# one are compared, shared with the credit checks in caption_credits (#475).
# Two copies would drift, and they drift in the direction that matters: the
# dedupe keeping a credit the enforcement thinks is missing, or the other way
# round.
_STACK_HANDLE = HANDLE_RE


def _norm_handle(token: str) -> str:
    """A handle in comparison form, with the leading @ kept.

    `norm_handle` drops the @ so a bare handle-book entry and a written one
    compare equal. The stack dedupe compares tokens that always carry it, and
    keeping it here means an @-less word in a credit stack can never collide
    with a handle.
    """
    return "@" + norm_handle(token)


def _stack_looks_like_credits(block: str) -> bool:
    """A trailing credit stack is handles and bare names, not prose.

    Getting this wrong in the permissive direction is the dangerous one: a
    closing sentence mistaken for the credit list has a name deleted out of the
    middle of it, and the caption ships starting mid-phrase. Counting words was
    too permissive exactly that way, because the brand voice favours short
    sentences.

    A block with an @ handle in it is a stack. Without one, only a bare list of
    names counts, and prose gives itself away with sentence punctuation or a
    lowercase word.
    """
    stripped = block.strip()
    if not stripped or stripped.startswith("#"):
        return False
    if _STACK_HANDLE.search(stripped):
        # A handle can still sit inside a sentence, and a sentence is prose.
        return not stripped.endswith((".", "!", "?"))
    if stripped.endswith((".", "!", "?")):
        return False
    tokens = stripped.split()
    return bool(tokens) and all(token[:1].isupper() for token in tokens)


def dedupe_credit_stack(caption: str) -> str:
    """Drop from the trailing credit stack anything the body already credits."""
    blocks = caption.split("\n\n")
    if len(blocks) < 2:
        return caption

    # The stack is the last block that is not the hashtag block, which has its
    # own rules and is not a credit list.
    index = len(blocks) - 1
    if blocks[index].strip().startswith("#") and len(blocks) >= 3:
        index -= 1
    if index == 0 or not _stack_looks_like_credits(blocks[index]):
        return caption

    body = "\n\n".join(blocks[:index])
    body_handles = {_norm_handle(h) for h in _STACK_HANDLE.findall(body)}
    body_low = body.casefold()

    kept: list[str] = []
    for token in blocks[index].split():
        if token.startswith("@"):
            # Exact handle match only. @safa is a different account from
            # @safa.wav, and dropping one for the other removes a real credit.
            if _norm_handle(token) in body_handles:
                continue
            kept.append(token)
        else:
            kept.append(token)

    # Plain-name credits are whole names, so they are removed by name rather
    # than word by word, which would leave a dangling surname behind. A stack of
    # several handle-less names reads as ONE long run of capitals, so each run
    # is searched for the longest sub-run the body already credits instead of
    # being matched whole, or a stack of two names would never match either.
    stack = " ".join(kept)
    for run in _plain_name_runs(stack):
        tokens = run.split()
        start = 0
        while start < len(tokens):
            for size in range(len(tokens) - start, 1, -1):
                candidate = " ".join(tokens[start:start + size])
                if candidate.casefold() in body_low:
                    stack = stack.replace(candidate, "", 1)
                    start += size
                    break
            else:
                start += 1
    stack = " ".join(stack.split())

    remaining = blocks[:index] + ([stack] if stack else []) + blocks[index + 1:]
    return "\n\n".join(b for b in remaining if b.strip())


def _plain_name_runs(stack: str) -> list[str]:
    """Runs of capitalised words in a credit stack: the names without handles."""
    return re.findall(r"\b(?:[A-Z][\w'\-.]*)(?:\s+[A-Z][\w'\-.]*)+", stack)


def _enforce_caption_bans(caption: str, *, tag_handles=None,
                          name_mentions=None) -> str:
    """Remove engagement bait and the generic second person, in code (#110).

    The prompt already bans both, and the blog already enforces its equivalent
    after the model has answered. These are hard checkable strings, so whether
    they are present is settled by a regex rather than by asking the model
    whether it obeyed.

    One focused rewrite, and only when something was actually found, so an
    ordinary caption costs no extra call. A rewrite that still carries the
    problem is refused and the original kept: the backstop must never make a
    caption worse, nor claim a fix it did not make.
    """
    problems = problems_in(caption)
    if not problems:
        return caption

    try:
        raw = run_prompt(
            REWRITE_PROMPT.format(problems=" and ".join(problems), caption=caption),
            timeout=120,
            step="caption:bans",
        )
    except ClaudeError as e:
        print(f"warning: caption ban rewrite failed, keeping the original: {e}",
              file=sys.stderr, flush=True)
        return caption

    reworded = strip_em_dashes((raw or "").strip())
    if not reworded or problems_in(reworded):
        print(f"warning: caption still contains {'; '.join(problems)} after a "
              "rewrite, keeping the original", file=sys.stderr, flush=True)
        return caption

    # The rewrite's keep-every-handle instruction lives only in REWRITE_PROMPT,
    # so the pass added to enforce one rule can silently break a harder one:
    # delete a credit Dan promised somebody, or invent a handle pointing at a
    # stranger's account (#475). Both are checkable, and unlike the generate
    # path there is a known-good caption in hand, so the rewrite is refused
    # rather than reported (L5).
    damage = rewrite_lost_a_credit(caption, reworded, tag_handles=tag_handles,
                                   name_mentions=name_mentions)
    if damage:
        print(f"warning: the caption ban rewrite {', '.join(damage)}; keeping "
              "the original, which still contains "
              f"{'; '.join(problems)}", file=sys.stderr, flush=True)
        return caption
    return reworded


def _reinsert_skipped(values: list, kept_indices: list[int], total: int) -> list:
    """Put per-photo values back at their original positions.

    `values` has one entry per photo that was sent; the result has one per
    photo the caller started with, with an empty string where a photo was
    skipped. Alignment is the whole point: an off-by-one here attaches a real
    alt text to the wrong photograph, which reads as correct and is not.
    """
    out: list = [""] * total
    for slot, original_index in enumerate(kept_indices):
        if slot < len(values) and original_index < total:
            out[original_index] = values[slot]
    return out


def format_for_post(result: dict[str, Any]) -> str:
    """Render the caption + hashtags as it would actually be posted."""
    caption = result["caption"]
    tags = " ".join(result.get("hashtags", []))
    return f"{caption}\n\n{tags}".rstrip()



def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a caption for one post")
    parser.add_argument("--event", required=True, help="Event name")
    # Optional: an event can have no organisation (#689). Defaulting to empty
    # rather than refusing, because the caption pipeline's job then is to say
    # nothing about one rather than to stop.
    parser.add_argument("--org", default="", help="Organization (may be empty)")
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
