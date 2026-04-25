"""
PostRoll — Blog Post Generator

Generates a Squarespace-ready blog draft for one event in Dan Wright's
brand voice. 10-12 short paragraphs, continuous prose, no headings, with
photo placement markers the GUI can match against actual photos later.

Inputs:
- Event metadata (event name, organization, venue, date)
- Full OCR output dict from ocr_program (uses everything)
- List of selected photo paths (4-7 photos)

Output:
    {
      "title": "Blog post title",
      "body": "Markdown body with [PHOTO: ...] markers inline",
      "photo_count": 5
    }

Usage:
    python -m postroll.ai.generate_blog \\
        --event "Sing Play" \\
        --org "DCINY" \\
        --venue "Carnegie Hall" \\
        --date 2026-04-05 \\
        --program path/to/program.json \\
        --photo path/to/p1.jpg --photo path/to/p2.jpg --photo path/to/p3.jpg \\
        --photo path/to/p4.jpg --photo path/to/p5.jpg \\
        --output output/blog.md
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
    build_review_prompt,
    build_voice_review_prompt,
    is_humanizer_available,
    load_humanizer_rules,
)
from .claude_client import run_json_prompt, load_brand_voice, ClaudeError
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


# Shared prose rules — imported by revise_blog.py so both prompts stay in sync.
# Update here; revise_blog picks up the change automatically.
BLOG_WRITING_RULES = """\
- NO banned hype words (stunning, magical, breathtaking, unforgettable, etc.).
- NO AI tells (in a world where, it's not just X it's Y, rule-of-three tics).
- NO false intimacy about what performers were feeling.
- Open with a specific observation, NOT "Last Saturday I had the pleasure of...".
- Close with one short, useful sentence. No hard sell. The CTA must use specific
  language grounded in this post — not vague gestures like "this kind of attention"
  or "this kind of work." Name the actual thing: "photography that's watching the
  stage, not waiting for a pose" is better than "photography that pays this kind
  of attention to what happens on stage."
  The CTA cannot arrive as a non-sequitur from the last paragraph about the
  performance. Before the ask, there must be a short transitional beat that places
  Dan in the room — a quiet, factual sentence about what he was doing there while
  all of this was happening. Something like: "I was at the back of the hall for
  most of the night, working quietly while all of that happened." That bridge is
  not optional. The closing moves: [last observation about the performance] →
  [one sentence placing Dan in the room] → [CTA].
- FACTUAL ACCURACY — CRITICAL: Only attribute conducting, soloist roles,
  speaking roles, or any specific performance duties to a named individual
  if the program text EXPLICITLY states it. Do NOT infer from a person's
  title, billing order, or presence on stage that they took a particular
  role in the performance. If the program lists "Jennifer Lucy Cook —
  composer/arranger" and her pieces appear on the program, that does NOT
  mean she conducted them. When attribution is uncertain, describe what is
  visible in the photos instead of asserting a role.
- NOT a program breakdown. Do NOT move piece by piece through the repertoire
  as if reviewing a setlist. The program notes and repertoire are context, not
  an outline. Pick the two or three moments that actually say something and
  build the post around those. A piece that isn't worth a specific observation
  doesn't need a paragraph.
- NO gestural phrases: "that kind of X," "this kind of Y," "that sort of thing."
  Name what the X actually is. If you wrote "that kind of history reads as ease,"
  say what the history IS and why it produces ease.
- NO soft-landing abstractions as substitutes for specific observations: "room to
  open up," "landed differently," "carried the room." If you need to explain what
  you mean in the next sentence, fold the explanation forward into this sentence
  and cut the abstraction.
- NO inanimate objects performing human actions: "The hall took it," "the room
  held," "the stage gave." Rewrite with a human subject or cut the sentence.
- FIRST PERSON IS REQUIRED. Dan ("I", "my") must be present from the OPENING
  paragraph through the body. A draft where Dan only appears in the second-to-
  last paragraph is broken. He's the subject of the post — a photographer
  writing about working a show — not an observer who shows up at the end. If
  a paragraph could appear in a music review by anyone, rewrite it from
  Dan's perspective behind the camera ("I framed for…", "I waited on the
  conductor's downbeat to…", "from where I was at house left…").
- NO music-critic authority. Dan is a photographer in the room, not a
  reviewer. Banned phrasings:
  • "you could hear the difference between X and Y"
  • "the room had that settled quality a [thing] gets when…"
  • "what makes this performance memorable is…"
  • Any sentence that confidently judges the artistic merit of a performance
    as if Dan were a seasoned critic. He can describe what he saw and heard;
    he doesn't pronounce on quality.
- NO single-word pivot sentences for literary effect. "Not sloppy, present.",
  "Loud. Then quiet.", "Stillness." — these are LLM tells. Use complete
  sentences. If a clause feels like it wants to stand alone for drama, fold
  it back into the prior sentence.
- NO constructed cleverness. Sentences that sound profound but are really
  pattern-matched music writing — "the audience came to listen rather than
  to be seen listening," "the silence before the applause was its own
  movement" — are banned. Replace with a concrete, specific thing Dan
  actually noticed while working.
- NO rhythmic paired short declaratives in every paragraph. If two adjacent
  paragraphs both end with two short clipped sentences, rewrite one. Vary
  sentence length and shape so the prose doesn't sound like it has a beat.
- AUDIENCE = performing-arts directors and presenters who might hire Dan.
  NOT general classical-music fans. The post must include the "approach"
  beat (how Dan worked the room) and the "practical value" beat (why
  documentation of this kind of event matters for grants / season decks /
  portfolios / press kits). Skipping either means the post fails its job.
- NO musicology / composer biography / premiere history / work history
  (who a piece was written for, when, by whom, what the dedication was)
  UNLESS the fact directly explains a photographic decision Dan made.
  Music facts are not photography voice. If you find yourself writing
  two factual sentences in a row about a piece, you're filling space —
  cut it. The good version folds at most one detail into a photographer's
  thought ("Crosett has played the Franck extensively, and you can hear
  that in how settled he was in it"), not a paragraph of program-note
  recitation.
- OPEN with something Dan noticed while setting up or working the room —
  a texture of the space, a quality of the audience, something that set
  the conditions for his work that night. NOT a fact about the venue's
  capacity, the date, or the program lineup. Journalism ledes ("Weill
  Recital Hall seats around 268 people, and on a Monday night in April
  it was close to full") are banned. Drop the reader directly into Dan's
  working perspective.
- WRITE IN PROGRAM ORDER unless there is a clear photographic reason to
  deviate. If you do deviate (e.g. a later piece produced the most
  photographically interesting moments), acknowledge the move briefly
  rather than pretending the chronology doesn't matter.
- DESCRIBE, don't categorize. "A solo cellist presents a different
  photographic problem than a duo" reads as an LLM reaching for a
  precise-sounding framing. Just describe what changed and what Dan
  did about it: "with no second player to anchor the frame, I was
  working with one person and whatever he gave me."
- WHEN LISTING practical uses for the photographs (grants, season
  decks, archive, portfolios, press kits), name TWO OR THREE naturally
  — never four-or-more strung together. Exhaustive use-case lists are
  a tell that the model is hitting every possibility instead of
  picking the right ones for this event.
- NO PARENTHETICAL HEDGES. Phrases like "or at least that's what I was
  seeing from where I stood", "from what I could tell", "as best I could
  judge" sound like a machine second-guessing itself mid-sentence. If
  the observation is worth making, make it directly. Cut everything
  after the comma: "I found myself waiting longer between frames than
  I usually do" beats "I found myself waiting longer between frames
  than I usually do, or at least that's what I was seeing from where
  I stood."
- LEAD WITH THE OBSERVATION, not the descriptor. If a paragraph opens
  with a factual sentence about the piece ("Four movements, cyclic, the
  piano part carried over from the original violin sonata") and the
  observation Dan was actually noticing comes second, REVERSE THEM. The
  observation comes first, the relevant detail folds in after if it
  earns its place.
- LEAD WITH THE STRONGEST LINE in any paragraph that has one. If a
  paragraph contains a sentence that genuinely sounds like Dan ("the
  photographer is not invisible", "you can't fake being settled in a
  piece"), that sentence is the LEAD of the paragraph — not buried
  three sentences in after logistics. Logistics flow from the line, not
  the other way around.
- DAN SHOOTS AT CARNEGIE HALL REGULARLY. Never write about Carnegie Hall
  or any of its rooms (Stern Auditorium, Weill Recital Hall, Zankel Hall)
  as if Dan is encountering them for the first time or orienting an
  unfamiliar reader. He has been in those rooms dozens of times. Banned
  framings: "Weill Recital Hall is a particular kind of room to work
  in", "Carnegie Hall, where I was shooting…", anything that introduces
  the venue. Write from familiarity. If the venue is worth noting at
  all, note what was specific or different about THIS particular night
  in that space — not what the space is like in general. A presenter
  reading the post should hear someone who knows the building, not a
  visitor.

  FACTUAL CONSTRAINT — CARNEGIE HALL POSITIONING: At Carnegie Hall,
  Dan is required to shoot from BEHIND THE AUDIENCE at the back of
  the hall. He is NOT allowed to move from that area during the
  performance. This means:
    • No "I shifted from house left to center" / "I moved closer for
      the second piece" / "I worked from the wings" / any narrative
      where Dan is roaming the hall during a Carnegie show.
    • The shooting angle is always long lens from the back. If
      describing the position, frame it factually: "from the back
      of the hall, where Carnegie keeps its photographers" /
      "behind the last row" / "shooting long from the rear of the
      house".
    • The constraint itself is worth one specific mention in the
      Approach beat when relevant — it's part of how Dan thinks
      about working a Carnegie shoot ("at Carnegie I'm fixed at
      the back, so the work is figuring out which moments will
      read at that distance").
    • At OTHER venues (Chain Theatre, Lincoln Center off-stages,
      smaller halls) Dan does move freely; this rule applies to
      Carnegie Hall specifically.
- THE CTA. ONE TO TWO short sentences, max. NO sub-clauses padding the
  pitch. NO listing the client's use cases ("for your grant deck,
  season announcement, OR portfolio"). NO run-on shapes that try to
  cover every possible event type and outcome in one sentence. "Get
  in touch" / "Reach out" / "Contact me" are too blunt; vague openers
  like "I'd be glad to hear from you" are too unfocused. The CTA
  should sound like Dan opening a conversation about THIS event type
  specifically, then stop. Good shapes:
    • "I'd be glad to talk through what that looks like for your
      season."
    • "Happy to send a fuller portfolio if it would help."
    • "If something similar is on your calendar, let me know."
  Vary the shape across posts. If the previous post used "I'd be
  glad to talk…", pick a different opener this time. Selling > 2
  sentences is wrong — keep it conversational.
- NO ANNOUNCING THE OBSERVATION. Never write "I noticed", "I could see",
  "I realized", "I saw that", "what struck me", "what caught my eye",
  "the first thing I saw", or any similar construction that announces
  the act of perceiving before stating what was perceived. Make the
  observation directly. "Weill was close to full on a Monday night.
  Not the count — the particular quiet of an audience that had
  already settled into listening." beats "I noticed when I walked in
  that Weill was close to full…"
- LITERARY VERBS reaching beyond Dan's register are out. "Accumulate"
  ("wait and let something accumulate"), "register" ("the silence
  registered"), "settle" used as a flourish, "land" used about
  feelings. Dan's register is plain and physical. "Wait and see what
  builds" beats "wait and let something accumulate". When in doubt,
  use a shorter, more concrete verb.
- PHOTO-USE FRAMING. Avoid "recapping the event" or any framing that
  reduces Dan's photos to a record-of-what-happened. The point is
  long-term usefulness — debuts, season openers, residencies, runs,
  showcases all produce material that ends up in grant decks, season
  announcements, artist portfolios, archive, press kits. "Coverage of
  a single night" beats "recap of the event". Match the frame to the
  event type — a debut recital isn't a "recap"; it's a launch
  document.
- VERIFY PROGRAM ORDER AGAINST THE OCR DATA before drafting. The
  pieces appear in the prompt in the order they appeared on the
  printed program. If your draft moves a piece earlier or later for
  pacing reasons, that's a deliberate choice you must acknowledge.
  Silently reordering pieces ("Beethoven → Moya → Shostakovich →
  Franck" when the program ran "Beethoven → Shostakovich → Moya →
  Franck") is a factual error — the night Dan worked had a real
  shape, and the post should reflect it.
- NO STATING OBVIOUS PHYSICAL PROPERTIES OF THE VENUE as if they were
  observations. Audiences face the stage, performers are lit, the hall
  is quiet during music, applause comes between pieces — these are
  defaults of any concert hall and don't carry meaning when stated.
  If you're reaching for a sentence about how attentive the audience
  was, the quality of the listening, or the atmosphere in the room,
  say THAT specific thing directly. Don't substitute a spatial or
  physical description ("the hall faced forward", "the stage was
  bright") that's true of every concert and means nothing on its own.
- NO INSTAGRAM HANDLES in the blog body. Blog posts go on Dan's website,
  not on Instagram — handles like "@rainercello" or "@carnegiehall"
  read as social-media residue and don't help a reader on the website.
  Refer to people and organizations by their actual names. Handles are
  a captions-only thing.
- NO FILLER PHRASE "DOING SOMETHING SPECIFIC" or "doing something
  particular" or "doing something interesting" followed by a
  description. Skip the meta-clause and go straight to the description.
  "Crosett's bow arm in that movement ran long and deliberate, very
  little hurry." beats "Crosett's bow arm was doing something specific
  in that movement — it ran long and deliberate…". The meta-clause is
  filler that announces an observation is coming.
- VENUE-DESCRIPTOR PHRASING. "Not a sold-out crush" / "a sold-out
  crush" / "a packed house" — words like "crush" aren't in Dan's
  register, and stock phrases for full audiences read generic. If the
  count matters, say it plainly ("close to full", "not a sellout but
  close"). Better still: cut the audience-size clause entirely if the
  next sentence carries the opening on its own.
- NO CONSTRUCTED QUALIFIERS. Adverb+adjective combinations that sound
  precise but aren't how anyone actually talks: "performatively
  expectant", "quietly attentive in that particular way", "almost
  ceremonially still", "deliberately unhurried". These are LLM tells
  — they reach for a precision that real speech doesn't have. Cut
  the qualifier or replace with a plain word. "The audience was
  attentive" or just describe what they did. If you can't picture a
  human saying the phrase out loud in a normal sentence, don't write
  it.
- NO META-CONNECTOR SENTENCES like "this sets up a certain kind of
  shooting condition", "this creates a particular kind of frame",
  "what this means for the photographer is…", "the upshot is…". They
  announce that an explanation is coming and add no information. The
  next sentence is the actual point — make it lead. Cut the meta
  connector entirely.
- NO APHORISTIC UNIVERSAL STATEMENTS. "The camera question is always
  whose moment it is", "with a solo performer it always comes down
  to X", "in a recital like this the work is really about Y" —
  sentences that turn one shoot into a universal rule of photography
  read as generated wisdom, not Dan thinking out loud. Dan describes
  THIS show, not the eternal truths of concert photography. Cut
  any sentence that frames a takeaway as universal.
- TRANSCRIPTIONS / ARRANGEMENTS / ORCHESTRATIONS / EDITIONS are
  musicology, not photography voice. "The Delsart transcription
  with the piano part carried over intact from the original violin
  version", "Liszt's piano transcription of the Beethoven symphony",
  "the Schoenberg edition" — NEVER include facts about who arranged
  or transcribed a piece, what the original instrumentation was, or
  which edition was performed UNLESS it directly explains a
  photographic decision Dan made. This is a stricter version of the
  general musicology ban: arrangement and transcription history is
  the form the model keeps reaching for as filler. Cut every time.
- AT MOST ONE PUNCHY / APHORISTIC SENTENCE PER POST. If a sentence
  reads like it was crafted to be a pull quote ("Those are the frames
  I was after, not the big gestures but the exchanges.", "They're a
  launch document.", "The work isn't to be invisible — it's to be
  ignored."), one is fine. Two is suspicious. Three is a pattern and
  the post is broken. Real observations don't land this neatly this
  often. If a draft has multiple punchy beats, fold all but one into
  the surrounding prose. Punchy sentences earn their place when
  they're rare.
- NO PAIRED DECLARATIVE CLOSES. Do not end a paragraph with two short
  back-to-back sentences where the second one lands as a punchline or
  conclusion. Patterns like "X is Y. It should Z." / "X happened.
  That's what matters." / "I made the frame. The rest was timing." —
  cut the second sentence. The preceding paragraph almost always does
  the job without it. The closer is the LLM signaling "this is the
  point" instead of trusting the prose.
- NO ENGINEERED PARALLELISM. Avoid clean A/B structures where both
  halves are roughly equal length and land symmetrically. "Hardest
  to earn and easiest to lose." / "Quiet to notice, loud to remember."
  / "Slow to start, fast to finish." These read as crafted rather than
  observed. Break the symmetry (different lengths, different rhythms)
  or cut the sentence. If you're tempted to write a balanced "X to A
  and Y to B" construction, you're probably writing toward an effect.
- NO ATMOSPHERIC PLACEHOLDERS. Adjective or noun phrases chosen to
  evoke atmosphere instead of describing something specific:
  "that particular density", "a certain quality of light", "a kind
  of silence", "a particular sort of attention", "that specific
  weight". Replace with the actual thing being described or cut. If
  the next sentence has to explain what you meant, fold the
  explanation forward and drop the placeholder.
- THE UNDERLYING TEST for any sentence that feels nicely turned: does
  this describe something that happened, or does it describe how the
  writing wants to sound? If the answer is the second, rewrite or cut.
  Dan writes from observations, not toward effects.
- NO FABRICATED BODY LANGUAGE OR PERFORMANCE-WIDE POSTURE. The model
  has the photos and the program — NOT footage of the full
  performance. Sentences that describe how a performer moves over the
  course of the night, how they carry themselves on stage in general,
  or how their physical presence compares between performers are
  fabrications and BANNED. Examples:
    • "Asunción plays with a composure that holds still even when
      the velocity in his hands doesn't: bent toward the keys,
      shoulders not moving much."
    • "Crosett was looser, more visible in his relationship to the
      music."
    • "Her bow arm relaxed as the night went on."
    • "He kept his shoulders square through the long phrases."
  These claim sustained observation Dan made with his eyes during the
  performance — the model wasn't there. Even if a photo happens to
  show a moment that supports the claim, generalizing it across the
  performance is invention.

  WHAT YOU CAN WRITE: observations grounded in a SPECIFIC photo Dan
  is placing in the post. "In this frame his bow arm is fully extended
  on a downstroke" is fine — the photo shows that. "Crosett spent the
  whole Largo with his bow arm running long" is not — the model
  doesn't know what happened during the rest of the Largo.

  When in doubt: describe what's in the photo, not what the
  performer was like across the evening. If you find yourself
  comparing two performers' physicality or summarizing how someone
  moved over time, you're fabricating.
- NO NARRATING PROFESSIONAL DISCIPLINE. Banned: "I moved positions
  twice, both times between pieces, never during." / "I kept my
  shutter speed conservative." / "I stayed where I was for longer
  than I usually would." / "I worked quietly from the back." These
  signal competence to the reader instead of letting the work do it.
  Technique enters the post WHEN IT SERVES A SPECIFIC MOMENT — "the
  Largo went so quiet I had to give up on the shutter sound and shoot
  through the rests" is a story; "I was conscious of my shutter
  noise" is performance. Cut every "I [did professional thing]"
  sentence that doesn't have a specific photographic moment attached.
- USE CONTRACTIONS NATURALLY. Dan's voice uses "I'm", "I've", "didn't",
  "wasn't", "couldn't", "it's", "that's" throughout. If a paragraph
  has zero contractions across multiple sentences, rewrite it — that's
  a strong LLM tell. Especially watch the opening paragraph: a four-
  sentence opener with no contractions reads as someone delivering
  prepared remarks, not someone telling you about a shoot.
- NO PRESS-RELEASE FRAMING OF CLIENTS. Banned: any sentence that
  sounds like an organization wrote it about themselves. "The FilAm
  Music Foundation's American Recital Debut Award puts emerging
  soloists on the Weill stage at a moment that actually matters for
  their career" is a press-release sentence dropped into a first-
  person blog. If an organization needs context, bring it in through
  Dan's experience of them ("I'd shot two FilAm events before this
  one and the format is always tight: one artist, one room, one
  evening"), not through a summary of their mission, programming
  vision, or career-development goals.
- VARY PARAGRAPH LENGTH AGGRESSIVELY. Avoid the metronomic rhythm
  of "scene-setting paragraph → photo → scene-setting paragraph →
  photo". Some paragraphs should be a single short sentence. Some
  thoughts should carry across two or three paragraphs without a
  photo break. Sometimes jump from a performance observation to a
  logistical aside and back. If every paragraph in the draft is
  3-4 sentences, the structure is too regular — break the rhythm.
- DAN ARRIVES BEFORE THE AUDIENCE. He is the working photographer,
  not a ticketholder. He's in the room scouting angles, talking with
  the production team, and watching the hall fill up — not arriving
  to a settled house. Phrasings like "by the time I was in position",
  "by the time I got there", "as I walked in", "when I arrived"
  imply he showed up late or as a concertgoer and are banned. If the
  audience filling in is part of the opening observation, frame it
  from the working perspective: "I was set up at house left as the
  hall filled in" or "the room had nearly filled by the start of the
  first piece" — Dan watching it happen, not joining it. The reader
  should always sense Dan was there before showtime doing his job,
  not arriving with the crowd.\
"""


PROMPT_TEMPLATE = """\
{brand_voice}

---

Your task: write a blog post draft for Dan Wright's photography website
about an event he photographed.

**Audience.** This post is written for performing-arts directors,
presenters, producers, and managers — people who hire concert/theater
photographers for their season decks, grant applications, press kits,
and artist portfolios. They are NOT general classical-music fans. They
do NOT need a music-criticism review. They need to know: was Dan in the
room, did he notice the right things, would he be unobtrusive at our
event, and is his work usable for our marketing/archive needs?

**Voice.** First person from the opening paragraph onward. Dan ("I",
"my") is the subject of every paragraph — a photographer working the
show. If a paragraph reads like a review with Dan absent, you've drifted
from the brand voice. Rewrite from behind the camera.

**Required structure (all five beats, in order):**
  1. Venue / opening — drop the reader into the room from where Dan was
     working. One specific observation. NOT "Last [day] I had the…"
  2. Performance — two or three specific moments worth a paragraph
     each, from a photographer's perspective. NOT a piece-by-piece recap.
  3. Approach — how Dan worked the room (position, choices, what he was
     watching for, how he stayed out of the way). 1–2 paragraphs.
  4. Practical value — why documentation of an event like this matters
     to the kind of org that put it on (grant decks, season announcements,
     artist portfolios, archive). 1 paragraph.
  5. Closing + CTA — one sentence placing Dan in the room, then ONE
     short specific CTA.

If beats 3 (approach) and 4 (practical value) are missing, the post has
failed. They are non-negotiable.

Follow the blog post rules in the brand voice above EXACTLY — 10-12
short paragraphs, continuous prose, no headings, no bullets, no section
breaks.

Event details:
- Event name: {event}
- Organization: {org}
- Venue: {venue}{venue_context_line}
- Date: {date}
- Shoot type: {shoot_type}  ← CRITICAL: the prose MUST match what Dan
  actually witnessed.
{event_url_line} See the "Honor what Dan actually witnessed"
  section in the brand voice above. If shoot_type is photo_call or
  rehearsal, do NOT describe an audience, applause, a curtain call, or
  the arc of a performance. Frame it honestly as the access Dan had.

Performers (from program OCR):
{performers}

Repertoire (from program OCR):
{pieces}

Organization notes (from program OCR — use this to add depth, ONCE,
naturally, not as a press release paragraph):
{organization_notes}

Program notes (from program OCR — composer/piece context to weave into
the discussion of each piece):
{program_notes}

Venue notes (from program OCR):
{venue_notes}

Production details (director, creative team, run dates, tour info):
{production_details}

Other printed content (from program OCR):
{other}

Photos selected for this post ({photo_count} total). Each image
attached to this message is preceded by a `Photo N: filename.jpg`
text block that names it EXACTLY. The order of the images and of this
list is identical: the first attached image is the first item, the
second image is the second item, and so on. READ EACH IMAGE so the
prose can refer to what's actually visible in it, and use the
filename from that image's own label when you write its [PHOTO:]
marker — never guess a filename and never invent visuals.
{photo_list}

Photo placement rules:
- Place each photo in the prose at a moment where it makes sense — a
  reference to a specific piece, performer, or moment that the photo
  shows.
- Use this EXACT format on its own line between paragraphs:
    [PHOTO: filename.jpg | alt text description of what is in the photo]
  The filename MUST be copied verbatim from the `Photo N: …` label
  attached to that specific image — do NOT reorder, swap, or
  hallucinate filenames. The alt text MUST describe what is actually
  visible in THAT image (the one whose label you copied), 15-35 words:
  who, what, where, lighting, gestures. If the photo is of a poster,
  building exterior, empty stage, or program book, say so — do not
  describe a performance that is not in the frame. Example:
    [PHOTO: 003_DSC4821.jpg | Conductor leading a full chorus from the
    podium at Carnegie Hall, arms raised mid-phrase, blue stage light
    behind the choir risers]
- Use ALL {photo_count} photos. Spread them through the post — not
  clustered at the start or end.

Return JSON ONLY (no markdown fences around the outer object, no
commentary) in this shape. The title is set deterministically by the
caller as "{{event}} at {{venue}}" — do not write one. Just emit body
and photo_count:

{{
  "body": "Markdown body. 10-12 short paragraphs separated by blank lines. [PHOTO: filename.jpg | alt text] markers placed inline on their own lines. Closes with one quiet, useful CTA.",
  "photo_count": {photo_count}
}}

Reminders:
{blog_writing_rules}
- Inside the JSON "body" string, escape newlines as \\n so the JSON parses cleanly.
"""


def _format_performers(performers: list[dict[str, Any]]) -> str:
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
        notes = p.get("notes")
        line = f"- {composer} — {title}"
        if notes:
            line += f"\n    notes: {notes}"
        lines.append(line)
    return "\n".join(lines)


def generate_blog(
    *,
    event: str,
    org: str,
    venue: str,
    date: str,
    program: dict[str, Any],
    photo_paths: list[str | Path],
    shoot_type: str = "performance",
    event_url: str = "",
    venue_context: str = "",
    humanizer_path: str | Path | None = None,
    skip_humanizer: bool = False,
    skip_voice_pass: bool = False,
) -> dict[str, Any]:
    """Generate a blog post draft for one event.

    Accepts JPEG, PNG, and HEIC photos. HEIC is converted via sips.

    shoot_type controls how the prose frames what Dan witnessed. Common
    values: "performance", "rehearsal_and_performance", "photo_call",
    "rehearsal", "dress_rehearsal". Any other string is passed through
    verbatim to the prompt for unusual cases.

    Pipeline: draft → voice pass → humanizer pass (3 passes total,
    matching the caption pipeline). The humanizer is always the final
    pass so nothing downstream can re-introduce AI tells.
    skip_humanizer / skip_voice_pass exist for tests only.
    """
    # Auto-select up to 7 photos when more are provided (blog photos are now
    # auto-derived from all Sunday/Monday/Wednesday assignments).
    if len(photo_paths) > 7:
        step = len(photo_paths) / 7
        photo_paths = [photo_paths[round(i * step)] for i in range(7)]

    if len(photo_paths) < 1:
        raise ValueError("No blog photos provided")

    with tempfile.TemporaryDirectory(prefix="postroll-blog-") as tmp:
        tmp_path = Path(tmp)
        resolved: list[str] = []
        for i, p in enumerate(photo_paths):
            path = Path(p).expanduser().resolve()
            if not path.exists():
                raise FileNotFoundError(f"Photo not found: {path}")
            if path.suffix.lower() in HEIC_SUFFIXES:
                staged = _convert_heic_to_jpeg(path, tmp_path)
            else:
                staged = tmp_path / f"{i:03d}_{path.name}"
                shutil.copy2(path, staged)
            resolved.append(str(staged))

        # Show clean filenames (without the 000_ staging prefix) in the
        # prompt so [PHOTO:] markers use the original name. The same clean
        # names are passed as image_labels so each attached image is preceded
        # by a `Photo N: filename.jpg` block, anchoring the file ↔ image
        # correspondence unambiguously.
        photo_filenames = [
            Path(p).name.split('_', 1)[1] if '_' in Path(p).name else Path(p).name
            for p in resolved
        ]
        photo_list = "\n".join(f"- {n}" for n in photo_filenames)

        brand_voice_text = load_brand_voice()

        event_url_line = (
            f"- Event page URL (additional context): {event_url}"
            if event_url else ""
        )
        # Specific room inside the venue (e.g. Weill Recital Hall inside Carnegie
        # Hall) — used only for prose context. Graphics still show top-level venue.
        venue_context_line = (
            f" — performed in {venue_context.strip()}"
            if venue_context and venue_context.strip() else ""
        )

        # === Pass 1: generate the draft ===
        prompt = PROMPT_TEMPLATE.format(
            brand_voice=brand_voice_text,
            blog_writing_rules=BLOG_WRITING_RULES,
            event=event,
            org=org,
            venue=venue,
            venue_context_line=venue_context_line,
            date=date,
            shoot_type=shoot_type,
            event_url_line=event_url_line,
            performers=_format_performers(program.get("performers", [])),
            pieces=_format_pieces(program.get("pieces", [])),
            organization_notes=program.get("organization_notes") or "(none)",
            program_notes=program.get("program_notes") or "(none)",
            venue_notes=program.get("venue_notes") or "(none)",
            production_details=program.get("production_details") or "(none)",
            other=program.get("other") or "(none)",
            photo_count=len(resolved),
            photo_list=photo_list,
        )

        data = run_json_prompt(
            prompt,
            timeout=600,
            image_paths=resolved,
            image_labels=photo_filenames,
        )

        if not isinstance(data, dict):
            raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

        blog_shape = (
            "{body: string with [PHOTO: filename.jpg | alt text]"
            " markers preserved exactly as-is, photo_count: integer}"
        )

        # === Pass 2: voice review (does this actually sound like Dan?) ===
        if not skip_voice_pass:
            voice_prompt = build_voice_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                brand_voice=brand_voice_text,
                output_shape_description=blog_shape,
            )
            data = run_json_prompt(voice_prompt, timeout=600)
            if not isinstance(data, dict):
                raise ClaudeError(
                    f"Voice pass returned {type(data).__name__}, expected JSON object"
                )

        # === Pass 3: humanizer — always last, non-negotiable ===
        # Runs after the voice pass so it catches any AI tells the voice pass
        # introduced. skip_humanizer exists for tests only.
        if not skip_humanizer and is_humanizer_available(humanizer_path):
            humanizer_rules = load_humanizer_rules(humanizer_path)
            review_prompt = build_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                humanizer_rules=humanizer_rules,
                brand_voice=brand_voice_text,
                output_shape_description=blog_shape,
            )
            data = run_json_prompt(review_prompt, timeout=600)
            if not isinstance(data, dict):
                raise ClaudeError(
                    f"Humanizer pass returned {type(data).__name__}, expected JSON object"
                )

    # Title is deterministic — "{event} at {venue}" — so Claude doesn't need
    # to spend tokens (or risk drifting tone) on it. Falls back to whatever
    # Claude returned only if either piece of metadata is missing.
    deterministic_title = _build_blog_title(event=event, venue=venue)
    return {
        "title": deterministic_title or data.get("title", "").strip(),
        "body": data.get("body", "").strip(),
        "photo_count": len(resolved),
    }


def _build_blog_title(event: str, venue: str) -> str:
    """Format the blog post title as '{event} at {venue}'. Returns an empty
    string if either piece is missing; the caller falls back to whatever
    Claude generated in that case."""
    e = (event or "").strip()
    v = (venue or "").strip()
    if not e and not v:
        return ""
    if not v:
        return e
    if not e:
        return v
    return f"{e} at {v}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a blog post draft")
    parser.add_argument("--event", required=True, help="Event name")
    parser.add_argument("--org", required=True, help="Organization")
    parser.add_argument("--venue", required=True, help="Venue")
    parser.add_argument("--date", required=True, help="Event date (YYYY-MM-DD)")
    parser.add_argument(
        "--program",
        type=Path,
        required=True,
        help="Path to program JSON from ocr_program",
    )
    parser.add_argument(
        "--shoot-type",
        default="performance",
        help="What Dan actually witnessed: performance, rehearsal_and_performance, photo_call, rehearsal, dress_rehearsal, or free text",
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
        help="Photo to embed (repeat 4-7 times)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Where to write the blog draft (defaults to stdout)",
    )
    args = parser.parse_args()

    program = json.loads(args.program.read_text(encoding="utf-8"))

    try:
        result = generate_blog(
            event=args.event,
            org=args.org,
            venue=args.venue,
            date=args.date,
            program=program,
            photo_paths=args.photo,
            shoot_type=args.shoot_type,
            humanizer_path=args.humanizer_path,
            skip_humanizer=args.skip_humanizer,
        )
    except (ClaudeError, FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        # Write the markdown body to .md and the metadata alongside
        args.output.write_text(
            f"# {result['title']}\n\n{result['body']}\n", encoding="utf-8"
        )
        meta_path = args.output.with_suffix(".json")
        meta_path.write_text(
            json.dumps(result, indent=2, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
        print(f"wrote {args.output}")
        print(f"wrote {meta_path}")
    else:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
