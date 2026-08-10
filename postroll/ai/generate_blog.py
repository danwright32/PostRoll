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
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

from .ai_tells import (
    BLOG_HUMANIZER_EXTRA_BANS,
    BLOG_VOICE_EXTRA_CHECKS,
    build_review_prompt,
    build_voice_review_prompt,
    is_humanizer_available,
    load_humanizer_rules,
    markers_preserved_validator,
    strip_em_dashes,
)
from .claude_client import run_json_prompt, run_prompt, run_review_pass, load_brand_voice, ClaudeError
from .progress import ProgressWriter
from .blog_quality import check_blog
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg


# Shared prose rules — imported by revise_blog.py so both prompts stay in sync.
# Update here; revise_blog picks up the change automatically.
BLOG_WRITING_RULES = """\
- STRUCTURAL: CONTINUOUS NARRATIVE, NOT IMAGE BY IMAGE. THIS IS THE
  MOST IMPORTANT RULE IN THIS DOCUMENT. The blog post is prose that
  flows from topic to topic. Images are interspersed at moments where
  they fit, but the prose must work independently of them. STRUCTURAL
  TEST: if every [PHOTO:] marker is removed from the draft, the
  remaining text must still read as a continuous narrative about the
  night, not a slideshow with the captions taken away. BANNED
  structure: a paragraph for each photo where every paragraph follows
  the same template (name the scene, say what Dan noticed, add a
  photographic observation, move to the next photo). That is extended
  alt text, not a blog post. SECOND TEST: do multiple paragraphs in a
  row open by naming a different performer, scene, or piece ("Di Zhu
  was working through the kitchen scene...", "Christopher Sutton's
  therapist scenes had a different physical logic...", "Later they
  staged the confrontation...")? If yes, the post is organized around
  the images and must be rewritten as flowing prose where Dan moves
  through the night by thought, not by image queue. The prose decides
  which photos attach to it, never the reverse.
- DECIDE THE THROUGH-LINE BEFORE DRAFTING. Before writing a word,
  decide the ONE thing this post is about: the single idea the
  photographer was working out during the shoot (e.g. what reads at
  this distance when the stage is this full, how a solo voice holds
  inside a packed ensemble, what a fixed position lets him catch and
  what it costs). Every paragraph should advance or complicate that
  idea. Performers, photos, and technical details are EVIDENCE for
  the through-line, not the organizing principle themselves. The
  photo-by-photo habit is a symptom of having nothing to say and
  defaulting to a list; a real thesis is what makes the stacking
  resolve itself. If you cannot name the through-line in one
  sentence, you are not ready to draft.
- DE-DUPLICATE THE THROUGH-LINE ITSELF. Once the post has a
  through-line, each paragraph must ADVANCE it, not restate it. If
  two paragraphs make the same point about the idea (e.g. two
  soloists each illustrating "one voice against the ensemble," or two
  wide frames each saying "the wide shot carries the scale"), combine
  them or cut one. The same observation must not appear three times
  wearing different clothes. Variety of subject does NOT justify
  repetition of point. This is the next failure after the roster is
  broken: the model stops repeating the words and starts repeating
  the concept, attaching the through-line to each performer in turn.
  Catch it by naming the point each paragraph makes; if two
  paragraphs make the same point, they are one paragraph.
- STATE THE THROUGH-LINE ONCE, AT THE TOP, AND LET THE REST OF THE
  POST DEMONSTRATE IT. Saying it again later is not reinforcement, it
  is repetition. A corrected draft made the same point four times (in
  the opening, again at "What I noticed in the first few minutes",
  again at "the performer kept earning moments I hadn't set up for",
  and again in the closing line). Three of those four were cuts.
- DO NOT BUILD A THESIS THE SHOOT DID NOT EARN. If the honest spine
  is positional ("here is where I could stand"), say that plainly. Do
  not upgrade it into a claim about the nature of the work. An
  inflated thesis is the most common way this post stops being true.
- NO PARAGRAPH EXISTS TO INTRODUCE THE IMAGE BELOW IT. Paragraphs are
  about the show or about the working conditions. Photos sit near the
  relevant copy without being narrated by it. BANNED shape: "The
  ODYSSEUS suitcase showed up in a few frames as a kind of running
  visual anchor" is a caption wearing a paragraph.
- CONSOLIDATE RELATED WORKING DETAILS IN ONE PLACE. Do not split the
  same subject (where Dan could stand and move) across the top and
  the bottom of the post.
- EVERY CLAIM ABOUT THE VENUE, THE SETUP OR WHO ARRANGED IT IS
  VERIFIED BEFORE IT GOES IN. Assumed provenance is a fabrication.
  Use only what the program and enrichment data actually say. If the
  billing, the presenter or the pairing is not in the data, leave it
  out rather than approximating it.
- VERIFY CHARACTER ATTRIBUTIONS. A performer holding a prop is not
  automatically the title character. A corrected draft wrote "playing
  Odysseus with a prop staff"; the character was Aegyptius. If the
  data does not say who a performer is playing in a given moment, do
  not name the character.
- NEVER INVENT NUMBERS. No count in the source data means no number
  in the post. BANNED: "thirty seconds to reposition". This is
  checked in code after generation and reported.
- ANY CLAIM TRACED TO THE PERFORMER MUST ACTUALLY COME FROM THE
  PERFORMER OR FROM PUBLISHED MATERIALS. BANNED: "a lifelong one by
  his own account" when nothing in the data says so.
- POSITION IS AN INPUT TO THE WHOLE POST, NOT ONE SENTENCE. When
  where Dan shot from changes, every downstream sentence changes too,
  including the alt text. A draft that had him "working around the
  edge of the seated audience, moving when Medeiros moved" when he
  actually shot from the back of the house needed three or four
  further edits, in the photo markers as well as the prose.
- POSITION IS ONE RECORDED FACT FOR THE WHOLE SHOOT, AND EVERY POST
  FROM THAT SHOOT INHERITS IT. Never infer where Dan stood from what
  the photos look like. A close frame means a long lens, not a close
  photographer. Two posts from one night at Greenwich House Theater
  contradicted each other because the second narrated position from
  the images: BANNED, all from that draft, "The stage was close, the
  audience was close", "I was working within reach of what was
  happening", "I was close enough that I didn't have to choose
  between the group frame and the individual face". He shot both
  halves from the back of the house. If the position is not in the
  data given to you, write nothing about position at all.
- AN OPENING BUILT ON AN INVENTED POSITION CANNOT BE PATCHED. If the
  position claims come out of the opening paragraph, the opening has
  nothing left holding it up and must be rebuilt from the through-line
  rather than repaired sentence by sentence.
- NEVER GROUP PERFORMERS BY GENDER OR ANY OTHER DEMOGRAPHIC, AND
  NEVER TRAIL OFF INTO "AND THE OTHERS". Name everyone or name no
  one. BANNED: "The female performers in the cast, Ladibree, Safa,
  and the others". This is checked in code after generation.
- DO NOT READ THE VENUE'S PRE-EXISTING SETUP AS EVIDENCE ABOUT THE
  PRODUCTION. What was already in the room is the theater's, not a
  statement about the work. BANNED: "the set behind them still
  clearly a workshop-stage setup rather than a finished production
  design". That is a fabrication and a knock on the client at once.
- THE PRACTICAL VALUE PARAGRAPH MUST NOT NARRATE THE PHOTOS OR TELL
  THE READER WHAT THEY PROVE. BANNED: "A wide shot of the full cast
  at the stands shows the scope. A close frame of Suero mid-verse
  shows who this is and why it matters." The point about what the
  images are for carries that beat on its own.
- EACH PHOTO MUST MATCH THE COPY IT SITS NEXT TO. A draft said the
  night ended with the full cast at the stands and placed a single
  guitarist under it. Check every marker against the paragraph above
  it before returning.
- NO INFERRED INNER STATES IN THE BODY EITHER, not only in alt text.
  BANNED: "Not performing for the room but working something out",
  "the concentration was right there on the surface", "deeply
  focused". Write the visible gesture and stop.
- CUT SENTENCES THAT SOUND LIKE OBSERVATIONS BUT STATE NOTHING.
  BANNED: "I held on the moment and let it run", "moving when
  Medeiros moved", "Medeiros didn't stay in one register for long".
  TEST: if removing the sentence loses no information, it was never
  carrying any.
- CUT INTERPRETATION OF THE PHOTO. Do not tell the reader what an
  image reads as or what was real in it. BANNED: "The mess was real,
  the concentration was real, and the image reads as both at once."
- CUT BALANCED ANTITHESIS, PULL-QUOTE SHAPES AND APHORISMS ABOUT THE
  NATURE OF AMBITIOUS PROJECTS. BANNED shape: "ambitious in the way
  that projects nobody's quite done before tend to be".
- DO NOT REVIEW THE PERFORMANCE. Assessment is not the photographer's
  lane. BANNED: "a performance that was already this fully realized".
- DO NOT CRITICISE THE CLIENT'S STAGE OR SETUP, even when factually
  accurate. BANNED: "is a small room", "what looked like the contents
  of several storage units". Both read as knocks on the venue and the
  set to the people who booked the shoot.
- USE THE SAME CONSTRUCTION ONCE. A corrected draft ran "something
  between a game show host and a Greek chorus" and "something between
  a stadium and a temple" in one post. Two is one too many. This is
  checked in code after generation.
- THE MERGE IS THE EXPECTED MOVE. When multiple performers illustrate
  the same observation, the STRONG move is to combine them into one
  paragraph that uses two photos, or to feature one and let the
  others appear in the prose without their own beat. Defaulting to
  one-performer-per-paragraph is the failure mode EVEN WHEN THE
  WRITING IS GOOD. Giving each person a paragraph is not the safe
  default once the post has a thesis; it is the roster habit
  reasserting itself. Merge first, and only split when two performers
  genuinely advance the through-line in different directions.
- PARAGRAPH COUNT IS A HARD REQUIREMENT. 10 to 12 short paragraphs.
  Not 8. Not 9. Not 13. If a draft comes in under 10, it has almost
  certainly let one of two things crowd out a real beat: a methodology
  block (see rule below) or paragraphs that run long because they
  string two or three observations together that should have been
  separate. Count paragraphs in the draft. If under 10, find the long
  paragraphs and split them at natural seams.
- PHOTO COUNT IS NOT PARAGRAPH COUNT. The number of body paragraphs
  must NOT equal or closely match the number of attached photos. If
  you find yourself writing one paragraph per photo, you've written a
  captioned slideshow, not a blog post. Some photos anchor moments
  that span multiple paragraphs. Some paragraphs have no photo. Aim
  for 3-4 anchor moments across 10-12 paragraphs, with photos placed
  where they illustrate something already in motion in the prose.
  CONCRETE FLOOR: at least 3 paragraphs must have no photo attached.
  After drafting, count the photoless paragraphs. If fewer than 3, you
  have not broken the slideshow structure: consolidate two
  photo-anchored moments into a single paragraph and free up the space.
- HARD BAN: More than half of all paragraphs may not be primarily
  about Dan's positioning, waiting, or compositional decisions. The
  event is the story. Approach is woven in. If you count 7 paragraphs
  and 5 of them start with "I was watching," "I held on," or "I
  moved," you've written a shooting log. Recount and rebalance.
- OBSERVATIONAL AND DIRECT, NOT LITERARY OR CRITICAL. Dan's voice is
  plain. He describes what he saw, where he was, what he did. He does
  NOT describe what a scene "meant" or "conveyed" or "carried", and he
  does NOT name abstract qualities like "domesticity", "friction",
  "register", "geometry" as the subject of a sentence. Heavy
  descriptions of meaning are theater critic voice, not Dan's voice.
  Banned shapes from a recent failed draft: "the domesticity of the
  moment sat oddly against what I knew was coming later in the play",
  "that friction was already in how she was holding the character
  when nothing much was happening yet", "the geometry of it told the
  story better together than it would have apart". Replace each with
  what was literally happening in the frame: who was where, what they
  were doing, what gesture or line they were on, what angle Dan held.
  If the observation cannot be said in plain physical terms, it is
  invention dressed as insight. Cut it.
- NO LITERARY TRIPLET ESCALATION TO INTRODUCE THEMES. Listing three
  things in a rhythm where the third item escalates from concrete to
  abstract is a literary tell. Banned shape verbatim from a recent
  draft: "Pearl and Evelyn across a kitchen counter, across a table,
  eventually across much less distance than either of them would
  choose." The "eventually [abstraction]" beat after two concrete
  items is the move that turns observation into thematic framing.
  Same pattern in any form: "across A, across B, eventually across
  C", "first X, then Y, ultimately Z", "at the counter, at the
  table, finally [emotional abstraction]". When introducing what a
  show is about, describe what was literally happening on stage, not
  the arc of how a relationship intensified. Dan reports physical
  things he can point to in the photos. He does NOT narrate the
  trajectory of a play.
- NO METHODOLOGY BLOCKS. Do not summarize Dan's working approach as a
  block of principles. Banned shape (verbatim from a recent failed
  draft): "I was moving freely through the space the whole time.
  Floor level, across the set, occasionally close enough that the
  cast could see me in their sightlines. I wasn't trying to
  disappear; I was trying to stay out of the decisions." That
  paragraph is Dan performing the role of Dan rather than describing
  what he did. If a paragraph reads as a self-conscious account of
  his method or a list of working principles, fold any specific
  detail into the moment it actually came up in and cut the rest.
  Approach must be DISTRIBUTED across the post, never concentrated
  in one block. See modified beat 3 in the required structure above.
- METHODOLOGY LINES STILL COUNT WHEN SCATTERED. The rule above
  forbids concentrating Dan's approach into a standalone paragraph.
  It does NOT mean methodology sentences are fine if distributed
  one at a time through the post. A standalone methodology
  sentence anywhere is still a tell. Banned shape from a recent
  draft: "I'm not looking for posed photos. I'm watching for the
  phrases where the body does something the music is also doing."
  That is an aphoristic statement of approach, not a description
  of a specific frame. RELATED FAILURE: a setup sentence whose
  only purpose is to scaffold a methodology line. Banned shape:
  "With this much variety in performers and repertoire, fixed at
  the back for the full program, the work is figuring out which
  moments will read at that distance and being ready when they
  arrive." When the methodology line gets cut, the setup goes with
  it. Also banned: "that kind of concentrated physicality is exactly
  what I'm looking for," tacked on after a frame already showed it.
  Naming what Dan is "looking for" is the methodology tell; the
  description does the work, so cut the line. TEST: does the sentence
  describe what happened in a specific frame Dan placed in the post,
  or does it state a general principle of how Dan works? If general
  principle, cut. Same shape regardless of wording: "the question is
  whether the individual moments are going to read at that distance,"
  especially as the last sentence of the opening paragraph, is this
  same banned move. The sentence before it already set the condition.
- NO SEMICOLONS FOR DRAMATIC JUXTAPOSITION. Two parallel short
  clauses joined by a semicolon to create a tension and resolution
  effect are an AI tell. Banned examples from a recent failed draft:
  "I wasn't trying to disappear; I was trying to stay out of the
  decisions", "She wasn't performing for the camera; she was just in
  it". The same instinct that reaches for an em dash reaches for that
  semicolon construction. Replace with a period or a comma. If the
  contrast collapses without the semicolon, the contrast itself was
  engineered and one of the two clauses is the one to keep.
- NO banned hype words (stunning, magical, breathtaking, unforgettable, etc.).
- NO AI tells (in a world where, it's not just X it's Y, rule-of-three tics).
- NO false intimacy about what performers were feeling.
- Open with a specific observation, NOT "Last Saturday I had the pleasure of...".
- Close with one short, useful sentence. No hard sell. The CTA must use specific
  language grounded in this post, not vague gestures like "this kind of attention"
  or "this kind of work." Name the actual thing: "photography that's watching the
  stage, not waiting for a pose" is better than "photography that pays this kind
  of attention to what happens on stage."
  The CTA should not arrive as a non-sequitur from the last paragraph about the
  performance. Before the ask, an optional transitional beat may place Dan in the
  room. CRITICAL: that bridge sentence must NOT restate anything already
  established earlier in the post. If the opening line already placed Dan at the
  back of the hall (or behind the audience, or in any specific working position),
  do NOT pivot back to "I was at the back of Stern for the full program" or
  similar before the CTA. That is restatement masquerading as a transition and
  reads as a manufactured bridge. The bridge, when it appears, must do NEW work:
  a fresh working detail (what Dan was waiting for, the specific frame he was
  holding for, what he was watching past the conductor for). If no fresh detail
  earns its place, drop the bridge entirely and let the CTA follow directly from
  the final performance observation. Closing options: [last observation] →
  [optional fresh working detail, never restatement] → [CTA].
- FACTUAL ACCURACY — CRITICAL: Only attribute conducting, soloist roles,
  speaking roles, voice parts (soprano/alto/tenor/bass), instruments, or
  any specific performance duty to a named individual if the program text
  EXPLICITLY states it. Do NOT infer from a person's title, billing order,
  or presence on stage that they took a particular role in the performance.
  If the program lists "Jennifer Lucy Cook — composer/arranger" and her
  pieces appear on the program, that does NOT mean she conducted them. And
  you cannot tell from a photo who sings which part or where they stood:
  "Kiki Porter on alto, Kate Logan on soprano, Munya Fashu-Kanu on tenor"
  is fabricated unless the program assigns those parts. Likewise do not
  place named people on stage ("the section leaders were visible at the
  front") unless a specific photo clearly shows it. When attribution is
  uncertain, name the people without assigning a part or position, or
  describe what is visible in the photos instead.
- NOT a program breakdown. Do NOT move piece by piece through the repertoire
  as if reviewing a setlist. The program notes and repertoire are context, not
  an outline. Pick the two or three moments that actually say something and
  build the post around those. A piece that isn't worth a specific observation
  doesn't need a paragraph. CLARIFICATION: avoiding a piece-by-piece recap
  does NOT mean omitting piece titles. When you describe a specific moment,
  name the piece it came from if the program data supports it. An original
  work composed by the ensemble is always worth naming: it's the detail that
  makes the documentation specific to this organization and this night, not
  interchangeable with any other choir concert.
- NOT a sequential walkthrough of ensembles either. For multi-ensemble events
  (festivals, showcases, combined choirs), do NOT give each ensemble its own
  intro sentence followed by a detail paragraph in performance order. That
  template (name the ensemble, describe a moment, move to the next ensemble,
  repeat) reads as a structured recap and is a known LLM tell. Pick the two or
  three moments from the night that produced the strongest photographic or
  narrative material, regardless of which ensemble they came from, and arrange
  the post around those. An ensemble that didn't produce a specific photographic
  moment for Dan doesn't need a paragraph; mention it in passing or omit it.
  Human storytellers move between moments by interest, not by chronology.
- NO gestural phrases: "that kind of X," "this kind of Y," "that sort of thing."
  Name what the X actually is. If you wrote "that kind of history reads as ease,"
  say what the history IS and why it produces ease.
- NO VAGUE DESCRIPTORS THAT GESTURE AT MEANING. Phrases that point toward a
  feeling or quality without delivering the specific thing being noticed are
  BANNED. Examples: "had a different feel", "a different energy", "something
  else entirely", "the most photographically useful stretch of the night", "a
  particular quality", "carried something", "a range of expression", "a
  range of engagement" (a range of WHAT? name it). Replace each with the literal
  visible or logistical thing: a smaller ensemble means fewer bodies on the
  risers; a conductor stepping closer to the choir; a flutist visible at center
  stage with the chorus framing behind; a soloist lit against a dark scrim;
  arms gesturing wide, mouths open, the moment readable from a long lens at
  the back of the hall. If you cannot name the visible or logistical detail,
  the sentence is filler and should be cut.
- NO COMPARATIVE PUTDOWNS. Never imply that any part of a performance was
  visually dull, uninteresting to photograph, less compelling, or in any way
  lesser than another part. Banned phrasings: "for once I had something besides
  X to work with", "finally something to work with at that distance", "the X
  was the most photographically useful stretch of the night", "the rest of the
  program gave me less to work with", or any superlative that elevates one
  moment by implying the others were thin. The audience for this blog includes
  the ensembles and organizers Dan would be tagging as collaborators. Even a
  factual observation about photographic difficulty (rows of static faces, a
  long static piece) becomes a slight when written as a contrast against
  something more interesting. If a moment was a strong photographic
  opportunity, describe what made it strong on its own merits (the gesture,
  the staging, the proximity, the lighting), not by what other moments lacked.
- DON'T NARRATE THE BUSINESS CASE. The "practical value" beat is required
  (presenters reading this should understand why this kind of documentation
  matters for grants, season decks, archive, press kits), but it must be
  IMPLIED by what the photos contain and how Dan describes working them, not
  stated to the reader as exposition. BANNED phrasings: "for ensembles making
  their Carnegie debut, the photos are part of how they tell the story
  afterward, to their own communities, to grant committees", "these images end
  up in season announcements", "this is the kind of photo that goes in a press
  kit", or any sentence that explains to the reader why the photos matter to
  the client. Trust the audience (a presenter, director, or production
  manager) to understand the value from the working detail; spelling it out is
  the model breaking the fourth wall. Banned example from a recent draft:
  "The photos from a night like this end up doing work nobody could have
  predicted when they booked the concert." That narrates the business case
  AND is vague. When a specific value sentence precedes it ("YNYC is the
  only documentation that'll ever exist of the first performance"), that
  specific line is the ending; cut the vague business-case one. Also
  banned: "The closer frames are the ones that end up in grant decks and
  season announcements." Naming where the files go is the business case
  stated outright. Cut it; the working observations stand on their own.
- PRACTICAL VALUE IS FOR THE DECISION-MAKER, NOT THE FAMILIES. The
  practical value beat is written for the person who booked the
  concert, not for the performers' families. The audience for this
  paragraph is a director, development officer, or marketing
  coordinator who needs to show results to a board or grant committee.
  "The families will treasure these photos" is the wrong frame
  entirely. That's a given. What matters to the decision-maker is what
  the organization does with the documentation after the night is over.
- NO soft-landing abstractions as substitutes for specific observations: "room to
  open up," "landed differently," "carried the room." If you need to explain what
  you mean in the next sentence, fold the explanation forward into this sentence
  and cut the abstraction. This includes vague internal-state placeholders
  mid-paragraph: "something had shifted," "something changed," "something was
  different," "I could tell something." These are the model reaching for an
  observation it doesn't have. If you can name what you saw (posture, spacing,
  volume, faces forward), name it. If you can't name it, cut the sentence. "The
  posture of the group told me something had shifted" is a hard ban. "The group
  stood straighter, chins up" is what the sentence wants to be.
- HARD BAN: no soft-landing sentence at the end of a paragraph that
  gestures at a conclusion without delivering one. "It's a hard moment
  to miss if you're ready for it" adds nothing after three sentences
  that already showed the moment. Same with "That's when I was most
  aware of where I was standing relative to the stage" tacked on after
  the observation already landed, and value-claim landings like "I find
  those images hold up well over time" after a specific description.
  The specific sentence before it ("they're dressed down, concentrating,
  occasionally stopping mid-phrase") is the ending. If the last sentence
  of a paragraph could be deleted without losing meaning, delete it.
- NO inanimate objects performing human actions: "The hall took it," "the room
  held," "the stage gave." Rewrite with a human subject or cut the sentence.
- NO ACOUSTIC OR ARCHITECTURAL METAPHOR FOR VOLUME. Do not describe how
  a room or space responds to sound as a way of conveying that a piece
  was loud or full. "The walls had nowhere to put the sound," "the room
  absorbed it," "the ceiling caught it." These are music-critic
  constructions dressed up as spatial observations. If a piece reached
  full volume and that mattered photographically, say what changed in
  the frame: the choir opened up, Becker's gesture widened, the faces
  changed. Describe what Dan saw, not what the architecture did with
  the sound.
- FIRST PERSON IS REQUIRED. Dan ("I", "my") must be present from the OPENING
  paragraph through the body. A draft where Dan only appears in the second-to-
  last paragraph is broken. He's the subject of the post — a photographer
  writing about working a show — not an observer who shows up at the end. If
  a paragraph could appear in a music review by anyone, rewrite it from
  Dan's perspective behind the camera ("I framed for…", "I waited on the
  conductor's downbeat to…", "from where I was at house left…").
- HARD BAN: do not address a hypothetical photographer or reader with
  "you" as a generic stand-in for Dan. "You're always choosing between
  the wide frame and the face" is Dan's observation stated in the wrong
  person. Rewrite as "I'm always choosing." Every observation about how
  to photograph this kind of event belongs to Dan specifically, not to
  a generalized reader. If a sentence could appear in a photography
  how-to article, it's in the wrong register. This includes
  mid-sentence drift. "I was watching the conductors, not just for
  their cues, but because you can see in someone's body..." is a
  violation: the sentence opens with "I" and switches to "you" before
  the observation lands. The observation belongs to Dan. Finish the
  sentence in his voice: "...because I could see in someone's body
  whether the relationship was working." This also includes embedded
  instructional forms: "that's the condition you're working inside,"
  "that's what you're looking at," "that's what you're dealing with."
  Any sentence where "you" stands in for Dan describing his own working
  conditions is the same violation, a first-person observation stated
  in the wrong person. Rewrite as "that was the condition I was working
  inside," or cut entirely. VERIFICATION STEP: before
  returning the draft, scan the text for every instance of the word
  "you" or "your." Each one is a violation UNLESS it appears in the CTA
  ("if you're planning…") or inside a direct quote. There are no other
  valid uses. Rewrite every other instance in first person before
  returning. Do this scan internally; the output stays valid JSON with
  no added commentary.
- NO music-critic authority. Dan is a photographer in the room, not a
  reviewer. Banned phrasings:
  • "you could hear the difference between X and Y"
  • "the room had that settled quality a [thing] gets when…"
  • "what makes this performance memorable is…"
  • Any sentence that confidently judges the artistic merit of a performance
    as if Dan were a seasoned critic. He can describe what he saw and heard;
    he doesn't pronounce on quality.
- NO DESCRIBING THE SOUND OR QUALITY OF SOMEONE'S PLAYING. Dan works a
  long lens from the back, and the post is about what he could SEE, not
  what the music sounded like. BANNED: register ("a directness in the
  upper register," "working in the lower register"), tone, dynamics,
  intonation, and any judgment of how well someone played ("a focus
  that's hard to fake," "clean attacks," "a warm sound"). Those describe
  sound, not a photograph. Replace each with the visible physical
  gesture: a bow arm fully extended on a downstroke, fingers moving
  across the keys, a head bent close over the instrument, a horn's bell
  raised. If it can't be pointed to in a specific frame, cut it.
- NO single-word pivot sentences for literary effect. "Not sloppy, present.",
  "Loud. Then quiet.", "Stillness." — these are LLM tells. Use complete
  sentences. If a clause feels like it wants to stand alone for drama, fold
  it back into the prior sentence. This includes antithesis fragments like
  "Not managing a choir but leading one." Fold it into the previous sentence:
  "Both arms, mouth open, calling for something specific, not managing a
  choir but leading one." It also includes comma-list noun-phrase fragments
  with no verb: "Forty singers on the risers, a multilingual program,
  accompaniment that pushed the sound somewhere." Make it a real sentence:
  "It was a full set: a multilingual program and accompaniment that pushed
  the sound somewhere." This applies even when the fragment leads into a
  longer clause: "Both arms, mouth open, asking for something without
  rushing toward it" is still a fragment. Fold it forward into a real
  sentence: "Her conducting in those passages was unhurried, both arms
  open, mouth moving, asking for something without rushing toward it."
- NO constructed cleverness. Sentences that sound profound but are really
  pattern-matched music writing — "the audience came to listen rather than
  to be seen listening," "the silence before the applause was its own
  movement" — are banned. Replace with a concrete, specific thing Dan
  actually noticed while working. This includes paradox and "the whole
  point" turns: "That's a real constraint and also the whole point." Cut
  it; the concrete sentence before it (what the wide frame shows that a
  tight frame can't) is the observation. It also includes rhetorical
  question-and-answer constructions: "The question is whether they're
  adding or just getting in the way. With the chancel fully lit and the
  ensemble spread across the steps, they add." Cut the staged question
  and its payoff; state the plain version ("the ceiling and stone
  columns are always in the background, and with the chancel lit and the
  choir across the steps, they're worth keeping in the frame").
- HARD BAN: no sentence that sounds like a photography critic
  summarizing a technique. "That kind of
  synchronized-but-not-synchronized energy shows up in a still in a way
  that close unison singing doesn't" is the pattern: it reaches for a
  precise-sounding observation about the medium rather than describing
  what Dan actually saw. Replace with what was in the frame.
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
- OPENING. The opening must be a specific working observation tied to
  THIS event — what the room, the stage setup, or the ensemble's
  particular challenge meant for how Dan was going to shoot. NOT
  ambient scene-setting ("the hall was filling up"), NOT a date or
  venue introduction. The opening paragraph should tell someone who
  hires photographers something about the conditions Dan walked into.
  BANNED vague opener: "Milbank Chapel is a particular kind of room."
  "A particular kind of [X]" is a gesture, not an observation. Do not
  open with a physical measurement or spatial description of the venue
  as the first observation either. "The nave is long" and "the altar
  end is genuinely far away" are statements of architectural fact, not
  working observations; they read like a location scout's notes. The
  opening must connect the venue's physical condition to the
  photographic problem it created THAT night, not describe the room as
  if orienting a first-time visitor. "A long nave means the choir is
  small in the frame and the architecture fills in around them" is a
  working observation; "The nave is long" is a fact. Lead with the
  condition-and-its-consequence, not the bare measurement.
- WRITE IN PROGRAM ORDER unless there is a clear photographic reason to
  deviate. If you do deviate (e.g. a later piece produced the most
  photographically interesting moments), acknowledge the move briefly
  rather than pretending the chronology doesn't matter.
- DESCRIBE, don't categorize. "A solo cellist presents a different
  photographic problem than a duo" reads as an LLM reaching for a
  precise-sounding framing. Same with photography-teacher lines that
  state a general principle of the craft: "In a closer frame, two
  instruments in the same plane give a kind of layering a solo string
  player doesn't." Just describe what changed and what Dan did about
  it: "with no second player to anchor the frame, I was working with
  one person and whatever he gave me," or "I held on Lyon in the
  foreground and let the second violinist resolve into the background."
  This also includes transitional sentences mid-paragraph that explain
  what a compositional choice "does" or how it "reads": "that reads
  differently than a choir frame alone," "that gives the frame more
  life," "that's what makes it work." They explain to the reader what
  to see instead of showing it. Cut them. If the observation before the
  explanatory sentence is good, it doesn't need the explanation. Same
  with explanatory tails about what the venue or access "offers": "that's
  the kind of access the venue offers when the choir opens up near the
  chancel," tacked after a concrete frame (a singer mid-phrase, arms
  out, the gold ironwork soft behind her). Cut the tail; the frame is it.
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
  I stood." This also covers defensive meta-commentary that answers an
  accusation nobody made: "I wasn't manufacturing that background. It
  was just there." Cut both sentences; the observation about what the
  background gave the shot stands on its own.
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
  sentences is wrong — keep it conversational. Do NOT pad the CTA with
  context the post already established. After a paragraph that already
  laid out the premieres, "especially one with new work or premieres"
  in the CTA is redundant; cut it. "If there's a choral concert coming
  up, I'd be glad to talk through what coverage looks like" is cleaner.
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
- APHORISM CAP, REINFORCED. The cap above is a hard ceiling, NOT a
  target. DEFAULT POSITION IS ZERO. A recent failed draft accumulated
  four lines that read like pull quotes in a single post: "The
  geometry of it told the story better together than it would have
  apart", "It's a hard image to look at, which means it's doing its
  job", "Three positions in the space, three distinct states", "You
  end up with images that feel like they happened". Every one of
  those reads as written for the poster. Four in one post is the AI
  pattern the cap exists to prevent. If a draft has more than one
  such line, the post is broken and the punchy lines must be cut or
  folded into the surrounding prose. Real observations are messier
  than this. If every paragraph ends on a tidy summarizing beat, the
  model is pattern matching to AI blog voice rather than reporting
  what Dan saw.
- DILUTING A BANNED SHAPE IS NOT A FIX. When a pull quote like "It's
  a hard image to look at, which means it's doing its job" is banned,
  do NOT produce "It's not an easy image to sit with" by deleting a
  clause. Same SHAPE: a short evaluative summary line that lands at
  the end of a paragraph describing an image. The shape is the tell,
  not the specific words. Banned shapes regardless of phrasing:
    * "It's [a hard / not an easy] image to [look at / sit with]"
    * "[That / It] is doing its job"
    * "[This / That] is the kind of image that [belongs / lives /
      ends up] in [a press kit / a grant deck / season decks]"
    * "It's a shot that shows the scope of the thing," or any sentence
      that tells the reader how to read the photo. The image and its
      alt text already do that work.
    * Any one sentence verdict on what an image accomplishes,
      delivered after describing the image.
  If a remark about an image's usefulness needs to be made, say it
  inside a sentence that is also doing other work. Standalone
  evaluations of images that land at the end of a paragraph are
  tells, no matter how they are worded.
- NO PUNCHY KICKERS AT THE END OF A PARAGRAPH. A standalone short
  sentence tacked onto the end of a paragraph that lands as
  emphasis rather than information is the kicker pattern, even if
  the paragraph above it is otherwise clean. Banned examples from
  a recent draft: "That's the one I kept" (after describing a
  violinist with bow vertical and eyes shut), "No waiting
  required" (after describing a singer who walked out with arms
  already open). TEST: remove the final sentence. Does the
  paragraph still describe what happened? If yes, the final
  sentence was a kicker and must be cut. Kickers are how the
  model signals "this is the point" to the reader. Real prose
  trusts the description to land on its own. Another banned example:
  "Both ends covered." (tacked on after a sentence that already
  summarized the frames Dan got). Cut it entirely; the prior sentence
  or the CTA carries the ending. This also covers crafted pull-quote
  closers like "it's the frame I'd have waited all morning for" after
  describing the frame, or "it's the kind of frame that doesn't ask
  anything of me except patience" after listing what was in the shot.
  The description ("Na alone, mid-phrase, bow arm fully extended on a
  down stroke") is the ending; cut the pull quote.
- NO SUMMARY SENTENCE AFTER A CONCRETE LIST. When a sentence
  enumerates concrete elements ("Toth on the floor, De Mornay at the
  table, Zhu across the room with her arm extended"), STOP. Do NOT
  follow it with an abstracting sentence that names what the list
  added up to ("Three distinct positions in the space, each one
  clear"). The list IS the description. The summary line is the
  model making sure the reader got the point. Real prose lets the
  list stand. If the next sentence in a draft begins with "Three X"
  or "Two Y" or "All Z" after a list of those Xs or Ys or Zs, cut
  it.
- PHOTO PLACEMENT IS AFTER THE PARAGRAPH, NEVER BEFORE. Every
  [PHOTO: ...] marker is placed AFTER the paragraph that introduces
  or describes the photo's subject. Reader gets the verbal setup
  first, then the image. Mixing conventions (some markers before
  their paragraph, some after) is a broken pattern. The unit order
  in the post is always: text paragraph that names or describes the
  scene, blank line, [PHOTO: ...] marker, blank line, next text
  paragraph. Never marker first then descriptive paragraph after.
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
  Banned example from a recent draft: "The wide shot tells where this
  happened and what the scale was. The close one tells who was in the
  room." Two matched sentences, each assigning a tidy meaning to a
  shot. Cut both.
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
- NO KNOWLEDGE BEYOND THE PHOTOS AND PROGRAM. The selected photos and
  the program data are everything the writer knows about this event.
  Do NOT describe moments, sounds, exchanges, or details the photos
  don't capture, and NEVER say so out loud. "Between pieces there were
  moments the photos don't show" is self-contradictory: if a photo
  doesn't show it, there's no way to know it happened. The photos are
  the reason the writer knows anything here. Every observation must
  trace to a specific photo or to the program. If it can't, cut it.
  This includes the writer's own backstory: the model knows nothing
  about Dan's schedule, expectations, or how he came to shoot this, so
  "a program I didn't expect to be shooting when the season started" is
  invented and reads as a non-sequitur. Cut it. NEVER write the model's
  own uncertainty into the post: "here's someone I didn't place from the
  program," "I'm not sure who this is." Either identify the person from
  the program data or describe them without a name. The reader never
  sees the writer's doubt.
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
    • "Her conducting style is physical and unguarded, both arms
      moving when she's asking for something, mouth open, not managing
      from a distance." A conductor's "style," what she does "when"
      she asks for something, how she works in general, is exactly
      this banned generalization. The model has a few stills, not a
      catalogue of how she conducts.
    • "McGonnell on clarinet was very still by comparison, which made
      the contrast work." Comparing one player's stillness to another's
      is fabrication, Dan can't verify from the back of the house who
      was stiller, and "which made the contrast work" is a verdict on
      top of it. Describe only what one frame shows.
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
- HARD BAN: do not describe a performer's physical playing technique
  or body position in detail unless it is directly visible and
  verifiable in the photo attached to that paragraph. "McGonnell plays
  close to the stand, very still in her upper body, all the movement in
  the hands" is the pattern: it describes how someone plays as a
  general characteristic, not what a specific photo shows. Dan doesn't
  know from the back of the house whether a player always plays that
  way, and he can't verify it from a single rehearsal frame. If a
  physical detail isn't clearly visible in the photo attached to that
  paragraph, cut it.
- NO INFERRING HABITUAL BEHAVIOR FROM A SINGLE PHOTO. "She plays close
  to the stand" describes a habit. A single rehearsal frame shows one
  moment. The present-tense generalization ("she plays," "he holds,"
  "she keeps") is the tell. Write only what the photo shows in that
  moment, not what it implies about how a performer generally works.
- NO INVENTED TEMPORAL PRECISION. Do not add performance-specific
  details that sound plausible but aren't verifiable from the photos or
  program data. "I got it in the second verse," "the third time
  through," "about halfway through the piece." These are invented
  precision. If you don't know when in the piece the moment happened,
  don't specify. "I got it" is enough.
- NO INVENTED COUNTS. Do not state how many singers or musicians were in a
  choir or ensemble ("forty singers," "a choir of forty-some") unless the
  program data gives the number. You cannot count a full choir reliably and
  a wrong number is a fabrication. Use "the full choir" or "the ensemble."
  Only count a small group that is fully and clearly visible in a specific
  photo, and make the count match that frame.
- NO INFERRING STAGING OR BLOCKING FROM A PHOTO'S COMPOSITION. Three
  singers with hands raised on the risers are on the risers. Do not
  describe them as having stepped forward, moved to a mic, or otherwise
  changed position unless the program data or a mic stand visible in
  the frame confirms it. What a photo shows is not necessarily the
  result of deliberate staging.
- HARD BAN (blog body): do not describe clothing colors, shirt colors,
  or physical appearance details visible in the photos. "The girl in
  the orange hoodie," "the boy in red," "yellow top, white ruffled
  blouse." These belong in alt text, not the blog. The blog body
  describes what the moment was, what Dan was watching for, or what
  made the frame worth keeping. If a sentence could be written by
  someone looking at the photo with no other context, it belongs in
  alt text instead. When you don't have a real observational detail to
  anchor a paragraph, write less rather than filling the space with
  visual inventory. This applies to multi-subject paragraphs as well as
  single-subject ones. A paragraph that moves through three performers
  describing each one's position, instrument angle, and physical
  relationship to the stand is a visual inventory of the frame, not a
  photographer's observation. "McGonnell on clarinet, Weiner with the
  bell raised, Balliett behind them, the instrument cutting up into the
  shot" is alt text distributed across sentences. The blog body should
  describe what Dan was watching for and why the configuration mattered
  to him, not catalog what each person was doing with their instrument.
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
  Also banned: "I'm patient for that kind of shot and I hold until the
  alignment is right," tacked onto the end of a paragraph. That narrates
  the approach, not a specific frame. Cut it. Same with "That distinction
  shows up if I'm patient enough to wait for it" after a real observation
  ("not performing a smile but genuinely in it"). The observation already
  landed; cut the patience/waiting tail.
- NO FABRICATING DAN'S POSITION OR MOVEMENT. Do not invent that Dan
  changed position to explain a close frame. A long lens gets a tight
  shot from a fixed spot, so "I moved up toward the front for that
  section" is usually invented and adds nothing. Assert a position only
  when the photo's angle requires it (an elevated wide shot means he
  was up in a balcony) or when a real, specific reason for moving is
  part of the moment. A bare positional note with no reason: cut it.
- HARD BAN: a paragraph that describes a shooting angle or position as
  "useful" (or "worked," "gave me options," "was the move") without
  showing what it produced is methodology narration. "The
  conductor-facing angle from house center was useful during sections
  with a smaller subset" names a technique without delivering an
  observation. Either show what that angle gave in a specific frame
  (what was in it, what it let Dan catch) or cut the paragraph entirely.
- HARD BAN: every paragraph must contain at least one contraction. No
  exceptions. Dan's voice uses "I'm", "I've", "didn't", "wasn't",
  "couldn't", "it's", "that's" throughout. A paragraph with zero
  contractions reads clinical and formal. That's a voice failure. If
  you finish a paragraph and there's no contraction in it, rewrite
  before moving on. Watch the opening paragraph especially: a four-
  sentence opener with no contractions reads as prepared remarks, not
  someone telling you about a shoot. BLOCKING GATE: before returning,
  go through the draft paragraph by paragraph and, for each one, find
  the contraction it contains. If any paragraph has none, rewrite it
  before returning. A draft returned with any paragraph still missing a
  contraction has not finished this pass. Do this paragraph-by-paragraph
  check as an INTERNAL scratchpad only: do NOT print the list or any
  commentary, the returned output must be only the post, valid JSON.
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
  not arriving with the crowd.
- NEVER STRUCTURE THE BLOG AS A SEQUENCE OF SUBJECT-THEN-PHOTO
  PARAGRAPHS (one performer introduced, their photo cued, repeat).
  Photo placements fall where the prose naturally arrives at a
  moment, not the other way around. Photos do not drive paragraph
  order. Distribute working and technical details across the whole
  post rather than bundling one detail into each photo's setup. A
  draft can pass every voice rule above and still stack captions;
  this is a stated requirement, not something to infer.
  THIS CANNOT BE SATISFIED COSMETICALLY by making the sentences flow
  while still walking one performer per paragraph. The post must be
  organized around a single observation or through-line, NOT around
  a roster of who was on stage. Do NOT give each performer their own
  paragraph-plus-photo. Group, combine, or skip. If three soloists
  illustrate the same point, they can share a paragraph, or two of
  them can go uncaptioned in the prose. A reader should not be able
  to reconstruct the lineup card from the paragraph order. ASK of
  every paragraph: why is this one before that one? If the only
  answer is "that's the order I'm listing people in," the post is a
  roster and must be restructured. If paragraphs map one-to-one onto
  photos, the post is built backward and must be rewritten so the
  prose leads and the photos follow.
- STATE EACH CENTRAL OBSERVATION ONCE. If an observation about the
  shoot is central (your vantage point, the lighting, the scale, a
  recurring constraint), state it once and state it well. Do not
  restate the same observation across multiple paragraphs in varied
  wording. The model anchors on a framing device and repeats it;
  catch the second and third restatements and cut them. The reader
  should encounter the back-of-the-hall position, the long lens, or
  the room's scale as a single clear beat, not as a refrain.
- THE CLOSING CTA CARRIES FORWARD A SPECIFIC IDEA OR DETAIL FROM
  THE POST rather than listing generic event types or restating
  services. It should feel like the natural end of THIS particular
  post, not a template footer. "Offers conversation" is satisfied by
  the blandest possible version unless the CTA reaches back to
  something the post actually established and carries it the last
  step. If the CTA could be pasted onto any other post unchanged, it
  has not done this.
- CUT SELF-NARRATING FILLER that explains your own process without
  adding information, e.g. "that's all I had to work with,"
  "something I've found holds true across events like this," "that's
  what X earns." These read as voice but are padding. The model
  treats this register as authentic Dan when it is actually empty.
  Each of these sentences narrates that an observation is happening
  instead of delivering one. Cut them and let the concrete sentence
  beside them carry the moment.
- FAVOR WHAT YOU SAW AND HEARD OVER LOGISTICS. The strongest
  paragraphs are about the performance itself, what the music was
  doing, what a moment looked like, not about camera mechanics. Lead
  with the seeing. Let technical detail support it, not dominate it.
  Mechanics-heavy paragraphs are where the draft drifts into
  gear-blog territory. When a paragraph is mostly gear and position,
  find the thing on stage it was built to catch and make that the
  lead.\
"""


# The 5-beat blog structure — the single authoritative source. Injected into
# the Pass 1 generation prompt (PROMPT_TEMPLATE) and the revise prompt. This
# is deliberately NOT duplicated in brand-voice.md: the voice (Pass 2) and
# humanizer (Pass 3) passes clean prose without restructuring, so they don't
# need the beat list, and keeping a second copy is what let the Approach beat
# drift out of sync. revise_blog.py imports this so both stay aligned.
BLOG_STRUCTURE = """\
**Required structure (all five beats, in order):**
  1. Venue / opening — drop the reader into the room from where Dan was
     working. One specific observation. NOT "Last [day] I had the…"
  2. Performance — two or three specific moments worth a paragraph
     each, from a photographer's perspective. NOT a piece-by-piece recap.
  3. Approach — how Dan worked the room, distributed. Working details
     (position decisions, choices about when to move, what he was
     watching for) are woven into the paragraphs where those decisions
     actually happened. There is no standalone approach block. If every
     working detail in the post can be lifted out into one self-contained
     section, it's wrong.
  4. Practical value — why documentation of an event like this matters
     to the kind of org that put it on (grant decks, season announcements,
     artist portfolios, archive). 1 paragraph.
  5. Closing + CTA — one sentence placing Dan in the room, then ONE
     short specific CTA.

If beats 3 (approach), 4 (practical value), or 5 (the closing CTA) are
missing, the post has failed. They are non-negotiable. The post MUST end
with the CTA, never on the program list or the practical-value paragraph.\
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

**THE TEST EVERY BODY PARAGRAPH MUST PASS (most important rule here).**
The failure that ruins these drafts is a paragraph that just describes
what's in the attached photo, with Dan absent. BANNED, all real
failures: "Timothy Smith is at the Steinway here, singing into a mic,
turned toward the choir"; "That's the conductor mid-gesture, both arms
out, mouth open"; "This tighter frame gets two singers, both mouths
open." Naming what is visible (who, clothing, position, instrument,
expression) is ALT TEXT. It already lives in the [PHOTO:] marker. It
must NOT be the body.

Every body paragraph must instead carry a WORKING OBSERVATION: Dan's
perspective behind the camera. Where he worked from, what the venue or
the moment made hard, what he was watching for, why a frame was worth
keeping, what a piece or the program meant for how he shot it. The photo
illustrates; the paragraph is Dan's thinking.

This is NOT a license to fabricate, and it is NOT a reason to retreat to
bare description. Your SAFE LANE is photographer method that's reasonable
from the photo plus the venue: a tight shot from the back means a long
lens; a sharp foreground with a soft choir behind means a focus choice;
waiting on a riser edge means watching for a gesture. That working
framing is grounded and encouraged. Write the observation; let the alt
text hold the description.

TEST each paragraph: if it could have been written by someone who only
saw the photo and was never in the room working it, it's description,
rewrite it as a working observation or cut it. Pointing words ("here,"
"this frame," "in another photo," "that's the conductor") are a tell
that you're describing the image instead of writing about the night.

**SECOND TEST: TRUST THE OBSERVATION, DON'T DECORATE IT (also critical).**
Once a sentence reports what Dan saw or did, STOP. Do NOT follow it with a
sentence that explains it, sells it, teaches the craft, or sums it up as a
line that sounds quotable. These keep slipping in, every one must be cut and
the paragraph must end on the concrete observation:
- Pull-quote / verdict closers: "Those frames don't ask much of me except
  being there and not blinking."
- Photography-teacher / craft-principle lines: "Holding both in the same
  frame is harder than it sounds."
- Business-case / sell lines, and fragments dressed as punchlines: "the set
  has both: the riser frames and the solo frames"; "Different tools for
  different needs."
- Methodology narration: "I'm patient for that kind of shot and I hold until
  the alignment is right"; "that angle was the thing to hold"; "I stayed with
  that configuration for a stretch."
- Constructed cleverness / aphorism: "I'm always watching for the moments
  when a choir stops being a group and becomes a collection of people."
- Paired dramatic fragments: "The challenge wasn't reach. It was choosing."
  Fold into one plain sentence ("The challenge was choosing when to pull
  back and when to move in tight").
TEST: if a sentence could be lifted out and printed on a poster, or if it
only explains or sells what the sentence before it already showed, cut it.
The description is the ending.

**THIRD TEST: NO INNER STATES (also critical).** A photo shows an
expression; it does NOT show what anyone felt, heard, or thought. Cut every
claim about a feeling or mental state and keep only the visible gesture.
Banned, all real failures: "a smile that wasn't performing anything"; "he
was just genuinely pleased with what he was hearing"; "he was clearly in the
piece." Write what's visible instead (mouth open, eyes up, hand raised, head
back) and stop there. If a sentence asserts a feeling you'd need to be inside
the person to know, cut it.

{blog_structure}

Follow the blog post rules in the brand voice above EXACTLY — 10-12
short paragraphs, continuous prose, no headings, no bullets, no section
breaks.

Event details:
- Event name: {event}
- Organization: {org}  ← write this name EXACTLY as given when you name
  the organization. Do not abbreviate, expand, re-order, or drop words
  (e.g. "Teachers College Singers' Workshop" must not become "Teachers
  The Singers' Workshop").
- Venue: {venue}{venue_context_line}
- Date: {date}
- Shoot type: {shoot_type}  ← CRITICAL: the prose MUST match what Dan
  actually witnessed.
{event_url_line} See the "Honor what Dan actually witnessed"
  section in the brand voice above. If shoot_type is photo_call or
  rehearsal, do NOT describe an audience, applause, a curtain call, or
  the arc of a performance. Frame it honestly as the access Dan had.
  ALSO: for photo_call, rehearsal, and dress_rehearsal, treat the
  Repertoire list below as the PLANNED program, not a transcript of
  what Dan heard. See "Rehearsals: the program is a plan, not a
  setlist" in the brand voice. Do NOT walk piece-by-piece through the
  program and do NOT describe how individual works sounded unless a
  photo clearly anchors that piece.

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
- ALWAYS place a [PHOTO: ...] marker AFTER the paragraph that
  introduces or describes the photo's subject, NEVER BEFORE.
  Reader reads the verbal setup, then sees the image. Order of
  every unit: text paragraph, blank line, [PHOTO: ...], blank
  line, next text paragraph. Mixed conventions (some markers
  before their paragraph, some after) are a broken pattern and
  the post must be rewritten until every marker follows its
  paragraph.
- Place each photo in the prose at a moment where it makes sense — a
  reference to a specific piece, performer, or moment that the photo
  shows.
- Use this EXACT format on its own line between paragraphs:
    [PHOTO: filename.jpg | alt text description of what is in the photo]
  The filename MUST be copied verbatim from the `Photo N: …` label
  attached to that specific image — do NOT reorder, swap, or
  hallucinate filenames. The alt text MUST describe what is actually
  visible in THAT image (the one whose label you copied), 15-25 words:
  who, what, where, lighting, gestures. If the photo is of a poster,
  building exterior, empty stage, or program book, say so — do not
  describe a performance that is not in the frame.
  NAME THE PERFORMER AND THE VENUE IN EVERY MARKER. Write "Joseph
  Medeiros ... at Greenwich House Theater", never "A male performer".
  A corrected draft had "A male performer" seven times and named the
  venue in none of them.
  NAME PEOPLE BY NAME, NEVER BY APPEARANCE OR GENDER. "A woman in a
  striped top" becomes "Safa"; "A bearded performer in a white shirt"
  becomes "Fermin Suero, Jr.". This is checked in code after
  generation.
  A GROUP TOO BIG TO NAME GETS A COUNT AND THE ENSEMBLE NAME. Once
  naming everyone in the frame would not fit the word band, write the
  number of people and who they are as a group: "Four BLUDLINE
  performers at mic stands", "Eight Greenwich House singers on the
  risers". Count them, do not guess. Never fall back to appearance or
  gender for a group either: "several women in black" is the same
  defect at a larger scale. Name individuals whenever they DO fit,
  which for two or three people they normally will.
  VARY THE OPENING. Do not start more than two markers the same way.
  NO INFERRED INNER STATES. Describe what the camera recorded, not
  what somebody felt or who an expression was aimed at. BANNED: "in
  intense concentration", "with focused expression", "grinning toward
  the audience". A grin is visible; who it was for is not. Example:
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


# --- Deterministic name backstop ------------------------------------------
# The model occasionally hallucinates a wrong first name for a known person
# ("Beth Becker" when the program lists "Nicole Becker"). The program data has
# the canonical name, so this corrects "Wrong Surname" -> "Right Surname" in
# code (no LLM call), only when the surname maps to exactly one first name.
_NAME_PAIR_RE = re.compile(r"\b([A-Z][a-z]+)\s+([A-Z][a-z]+)\b")
_NAME_ROLE_WORDS = {
    "Artistic", "Assistant", "Choir", "Music", "Director", "Teacher",
    "Teachers", "Intern", "Conductor", "Conductors", "Piano", "Percussion",
    "Spring", "Concert", "Community", "College", "Chapel", "Hall", "University",
}


def _canonical_first_names(program: dict[str, Any]) -> dict[str, str]:
    """surname -> the single canonical first name found in the program data.
    Only surnames with exactly one first name are returned, so corrections
    stay unambiguous."""
    seen: dict[str, set[str]] = {}
    sources: list[str] = []
    for p in program.get("performers", []) or []:
        name = (p.get("name") or "").strip()
        if name:
            sources.append(name)
    for key in ("production_details", "organization_notes", "program_notes", "venue_notes"):
        val = program.get(key)
        if isinstance(val, str):
            sources.append(val)
    for src in sources:
        for first, last in _NAME_PAIR_RE.findall(src):
            if first in _NAME_ROLE_WORDS or last in _NAME_ROLE_WORDS:
                continue
            seen.setdefault(last, set()).add(first)
    return {last: next(iter(fs)) for last, fs in seen.items() if len(fs) == 1}


_CAP_WORD_BEFORE_RE = re.compile(r"[A-Z][a-z]+\s+$")
_CAP_WORD_AFTER_RE = re.compile(r"^\s+[A-Z][a-z]+")
_PLACE_PREPOSITION_RE = re.compile(r"\b(?:in|at|of|near|to|from)\s+$")


def _fix_wrong_names(body: str, program: dict[str, Any]) -> str:
    """Correct hallucinated first names against the program data. A surname the
    program ties to one first name is forced to that name wherever the body
    pairs it with a different first name.

    Guards: a pair inside a longer capitalized run ("Alice Tully Hall",
    "Mary Jane Smith") or following a location preposition ("in New York")
    is a place name, title, or multi part name, not a hallucinated first
    name, and is left alone. A skipped correction is harmless; a false
    substitution corrupts prose, so the guards err toward not replacing.
    Every substitution is printed to stderr so changes stay visible."""
    canon = _canonical_first_names(program)
    if not canon:
        return body

    def _repl(m: "re.Match[str]") -> str:
        first, last = m.group(1), m.group(2)
        correct = canon.get(last)
        if not correct or correct == first:
            return m.group(0)
        before = body[: m.start()]
        after = body[m.end():]
        if _CAP_WORD_BEFORE_RE.search(before) or _CAP_WORD_AFTER_RE.match(after):
            return m.group(0)
        if _PLACE_PREPOSITION_RE.search(before):
            return m.group(0)
        print(
            f"name backstop: '{first} {last}' -> '{correct} {last}'",
            file=sys.stderr, flush=True,
        )
        return f"{correct} {last}"

    return _NAME_PAIR_RE.sub(_repl, body)


# --- Per-paragraph contraction backstop ------------------------------------
# Dan's voice uses contractions throughout. A full-body "add contractions"
# rewrite proved unreliable (the model copied a long body back unedited). This
# version works PER PARAGRAPH: it detects the contraction-free prose paragraphs
# in code (regex, possessives excluded) and rewords ONLY those, one short call
# each, then splices the result back. Small focused calls the model actually
# applies. Falls back to the original paragraph on any failure.
_CONTRACTION_RE = re.compile(
    r"\b\w+n['’]t\b"                          # didn't, wasn't, isn't, don't
    r"|\b\w+['’](?:m|re|ve|ll|d)\b"           # I'm, they're, I've, we'll, I'd
    r"|\b(?:it|that|there|here|what|he|she|who|let|where|how|"
    r"nothing|something)['’]s\b",             # it's, that's, there's (not poss.)
    re.IGNORECASE,
)

_CONTRACTION_PARAGRAPH_PROMPT = """\
Reword this single paragraph from a blog post by Dan Wright, a photographer,
so it contains at least one natural contraction (I'm, I've, didn't, wasn't,
it's, that's, there's). Change as little as possible: keep the meaning, the
facts, the first-person voice, and any [PHOTO: ...] marker exactly. Do not add
observations and do not introduce a generic "you." Return ONLY the reworded
paragraph, nothing else.

PARAGRAPH:
{paragraph}"""


def _prose_indices_without_contractions(body: str) -> list[int]:
    """Positions in ``body.split("\n\n")`` of prose paragraphs with no
    contraction.

    Positions rather than text, because the caller has to put a rewrite back
    and a text search covers the whole body including the ``[PHOTO:]`` markers
    (#109). A marker whose alt text repeats a sentence from the prose then
    takes the rewrite, which damages the alt text and leaves the prose exactly
    as it was.
    """
    out: list[int] = []
    for i, part in enumerate(body.split("\n\n")):
        s = part.strip()
        if not s or s.startswith("[PHOTO:"):
            continue
        if not _CONTRACTION_RE.search(s):
            out.append(i)
    return out


def _paragraphs_without_contractions(body: str) -> list[str]:
    """Prose paragraphs (not [PHOTO:] markers) that contain no contraction.
    Possessive 's does not count as a contraction."""
    offenders: list[str] = []
    for p in body.split("\n\n"):
        s = p.strip()
        if not s or s.startswith("[PHOTO:"):
            continue
        if not _CONTRACTION_RE.search(s):
            offenders.append(s)
    return offenders


# --- Per-paragraph second-person backstop -----------------------------------
# The BLOG_SECOND_PERSON_SCAN prompt rule keeps leaking generic "you" into
# final drafts. Like contractions, this is checkable in code: detect the
# offending paragraphs deterministically and reword only those, one focused
# call each. The CTA (final prose paragraph) and quoted speech are allowed
# to address the reader.
_SECOND_PERSON_RE = re.compile(r"\b(?:you|your|you're|yours)\b", re.IGNORECASE)
_QUOTED_SPAN_RE = re.compile(r'["“][^"”]*["”]')

_SECOND_PERSON_PARAGRAPH_PROMPT = """\
Reword this single paragraph from a blog post by Dan Wright, a photographer,
so it contains no second person ("you", "your"): recast it in Dan's first
person or neutral phrasing. Change as little as possible: keep the meaning,
the facts, and any [PHOTO: ...] marker exactly. Return ONLY the reworded
paragraph, nothing else.

PARAGRAPH:
{paragraph}"""


def _prose_indices_with_second_person(body: str) -> list[int]:
    """Positions in ``body.split("\n\n")`` of prose paragraphs that address
    the reader, excluding the closing call to action. See
    `_prose_indices_without_contractions` for why positions and not text.
    """
    parts = body.split("\n\n")
    prose = [i for i, part in enumerate(parts)
             if part.strip() and not part.strip().startswith("[PHOTO:")]
    if not prose:
        return []
    cta = prose[-1]
    out: list[int] = []
    for i in prose:
        if i == cta:
            continue
        unquoted = _QUOTED_SPAN_RE.sub("", parts[i].strip())
        if _SECOND_PERSON_RE.search(unquoted):
            out.append(i)
    return out


def _paragraphs_with_second_person(body: str) -> list[str]:
    """Prose paragraphs (not markers, not the closing CTA) that address the
    reader outside of quoted speech."""
    paras = [p.strip() for p in body.split("\n\n") if p.strip()]
    prose = [p for p in paras if not p.startswith("[PHOTO:")]
    if not prose:
        return []
    cta = prose[-1]
    offenders: list[str] = []
    for p in prose:
        if p is cta:
            continue
        unquoted = _QUOTED_SPAN_RE.sub("", p)
        if _SECOND_PERSON_RE.search(unquoted):
            offenders.append(p)
    return offenders


def _fix_second_person(body: str) -> str:
    """Reword each second-person prose paragraph (one focused call each),
    then splice it back. Leaves a paragraph unchanged if the call fails or
    the rewrite still contains second person."""
    body = (body or "").strip()
    parts = body.split("\n\n")
    offenders = _prose_indices_with_second_person(body)
    if not offenders:
        return body
    for index in offenders:
        original = parts[index].strip()
        try:
            raw = run_prompt(
                _SECOND_PERSON_PARAGRAPH_PROMPT.format(paragraph=original),
                timeout=120,
                step="blog",
            )
        except ClaudeError:
            continue
        blocks = [b.strip() for b in (raw or "").split("\n\n") if b.strip()]
        candidates = [b for b in blocks if not _SECOND_PERSON_RE.search(b)]
        if not candidates:
            continue
        reworded = max(candidates, key=len)
        if "[PHOTO:" not in reworded and len(reworded) < len(original) * 2 + 80:
            # By position: the paragraph the check judged is the one that
            # changes, and a marker can never be at a prose index (#109).
            parts[index] = reworded
    body = "\n\n".join(parts)
    leftover = _paragraphs_with_second_person(body)
    if leftover:
        print(
            f"warning: {len(leftover)} paragraph(s) still contain second person",
            file=sys.stderr,
        )
    return body


def _fix_missing_contractions(body: str) -> str:
    """Reword each contraction-free prose paragraph (one focused call each) so
    it carries a contraction, then splice it back. Returns the corrected body;
    leaves a paragraph unchanged if the call fails or doesn't add one."""
    body = (body or "").strip()
    parts = body.split("\n\n")
    offenders = _prose_indices_without_contractions(body)
    if not offenders:
        return body
    for index in offenders:
        original = parts[index].strip()
        try:
            raw = run_prompt(
                _CONTRACTION_PARAGRAPH_PROMPT.format(paragraph=original),
                timeout=120,
                step="blog",
            )
        except ClaudeError:
            continue
        # Guard against any preamble: keep the contraction-bearing block.
        blocks = [b.strip() for b in (raw or "").split("\n\n") if b.strip()]
        candidates = [b for b in blocks if _CONTRACTION_RE.search(b)]
        if not candidates:
            continue
        reworded = max(candidates, key=len)
        if "[PHOTO:" not in reworded and len(reworded) < len(original) * 2 + 80:
            parts[index] = reworded
    body = "\n\n".join(parts)
    leftover = _paragraphs_without_contractions(body)
    if leftover:
        print(
            f"warning: {len(leftover)} paragraph(s) still without a contraction",
            file=sys.stderr,
        )
    return body


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
    progress: ProgressWriter | None = None,
) -> dict[str, Any]:
    """Generate a blog post draft for one event.

    Accepts JPEG, PNG, and HEIC photos. HEIC is converted via sips.

    shoot_type controls how the prose frames what Dan witnessed. Common
    values: "performance", "rehearsal_and_performance", "photo_call",
    "rehearsal", "dress_rehearsal". Any other string is passed through
    verbatim to the prompt for unusual cases.

    Pipeline: draft → voice pass → humanizer pass, then a deterministic
    name-correction backstop. The quality of the post comes from the Pass 1
    generation prompt (BLOG_WRITING_RULES + BLOG_STRUCTURE) and the voice /
    humanizer review; the heavy LLM "review passes" were removed because on
    full-length drafts the model returned the body near-unedited.
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
                staged = _convert_heic_to_jpeg(path, tmp_path, prefix=f"{i:03d}_")
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

        # Each pass is a separate Claude call with its own multi-minute
        # timeout, and the run says nothing in between. Naming the pass as it
        # starts is what lets the app show still-alive rather than one spinner
        # that looks the same whether this is working or dead (#96).
        say = (progress or ProgressWriter(None))

        # === Pass 1: generate the draft ===
        say.step("Blog: writing the draft")
        prompt = PROMPT_TEMPLATE.format(
            brand_voice=brand_voice_text,
            blog_structure=BLOG_STRUCTURE,
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
            step="blog:photo_choice",
        )

        if not isinstance(data, dict):
            raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

        blog_shape = (
            "{body: string with [PHOTO: filename.jpg | alt text]"
            " markers preserved exactly as-is, photo_count: integer}"
        )

        # === Pass 2: voice review (does this actually sound like Dan?) ===
        if not skip_voice_pass:
            say.step("Blog: checking it sounds like you")
            voice_prompt = build_voice_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                brand_voice=brand_voice_text,
                output_shape_description=blog_shape,
                extra_checks=BLOG_VOICE_EXTRA_CHECKS,
            )
            data = run_review_pass(
                voice_prompt, data, label="voice", timeout=600,
                runner=run_json_prompt, validate=markers_preserved_validator,
            )

        # === Pass 3: humanizer — always last, non-negotiable ===
        # Runs after the voice pass so it catches any AI tells the voice pass
        # introduced. skip_humanizer exists for tests only.
        if not skip_humanizer and is_humanizer_available(humanizer_path):
            say.step("Blog: removing AI tells")
            humanizer_rules = load_humanizer_rules(humanizer_path)
            review_prompt = build_review_prompt(
                draft_json=json.dumps(data, ensure_ascii=False, indent=2),
                humanizer_rules=humanizer_rules,
                brand_voice=brand_voice_text,
                output_shape_description=blog_shape,
                extra_hard_bans=BLOG_HUMANIZER_EXTRA_BANS,
            )
            data = run_review_pass(
                review_prompt, data, label="humanizer", timeout=600,
                runner=run_json_prompt, validate=markers_preserved_validator,
            )

    # Title is deterministic — "{event} at {venue}" — so Claude doesn't need
    # to spend tokens (or risk drifting tone) on it. Falls back to whatever
    # Claude returned only if either piece of metadata is missing.
    # Backstops: deterministic em dash strip, deterministic name correction
    # (pure regex), then per-paragraph second-person and contraction fixes
    # (one focused call per offending paragraph, which the model reliably
    # edits, unlike a full-body rewrite).
    final_body = strip_em_dashes(data.get("body", "").strip())
    final_body = _fix_wrong_names(final_body, program)
    final_body = _fix_second_person(final_body)
    final_body = _fix_missing_contractions(final_body)

    # Deterministic backstops for the rules a prompt cannot hold (#201).
    # These REPORT rather than rewrite: nobody can supply the true number that
    # replaces an invented one, and alt text cannot be rewritten without seeing
    # the photograph. Reported loudly so a draft is never quietly shipped with
    # them, and returned so the review screen can show exactly what to fix.
    findings = check_blog(final_body, program=program, venue=venue)
    for f in findings:
        print(f"[generate_blog] CHECK {f.code}: {f.message} ({f.detail})",
              flush=True, file=sys.stderr)

    deterministic_title = _build_blog_title(event=event, venue=venue)
    return {
        "title": deterministic_title or data.get("title", "").strip(),
        "body": final_body,
        "photo_count": len(resolved),
        "findings": [{"code": f.code, "message": f.message, "detail": f.detail}
                     for f in findings],
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
