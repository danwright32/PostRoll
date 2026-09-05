"""Deterministic backstops for the blog correction rules (#201).

Dan hand-corrected a generated post and the edit was close to a rewrite. Prompt
text alone will not hold these rules (this repo's standing
deterministic-enforcement rule), so the objectively checkable ones are asserted
here, after generation, in the same spirit as `_fix_second_person`.

Most of these REPORT rather than rewrite, which is the deliberate difference
from the `_fix_*` helpers. Most cannot be auto-fixed without inventing
something: nobody can supply the true number that replaces an invented one, and
alt text cannot be rewritten without seeing the photograph. Quoting the
offending text lets Dan fix it in seconds; silently rewriting would stack a
second guess on the first.

The exception is `repair_marker_filenames` (#962), and it is an exception for a
reason that does not generalise: the true spelling is already in hand. A marker
differing from a real filename only in which quote or dash was typed names that
file, so correcting it invents nothing, and the alternative was handing Dan
fourteen findings, from one substituted character, that he could only fix by
retyping the app's own data. Where it would have to guess, it refuses and lets
the check report instead.

Only the objectively checkable rules live here. The judgement ones (thesis
discipline, no performance review, no criticism of the venue, no interpretation
of the photo) stay in BLOG_WRITING_RULES and BLOG_STRUCTURE, because a regex
cannot tell an observation from an assessment.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from typing import Any, Callable

# Re-exported so the eight test files and three scripts importing the pair out
# of here are untouched by the move (#1128). The definitions live in a leaf
# module; this file is the checker, not the vocabulary.
from .ai_tells import strip_em_dashes
from .blog_findings import Finding, finding_entry

__all__ = ["Finding", "finding_entry", "check_blog", "filenames_used_by",
           "repair_marker_filenames", "repair_marker_placement",
           "shared_opening_groups", "names_a_group", "ALT_MIN_WORDS", "ALT_MAX_WORDS",
           "MAX_SHARED_OPENINGS", "MAX_PROSE_BEFORE_FIRST_PHOTO"]

#: How many prose blocks may precede the first photograph.
#:
#: Read by the `late_first_photo` check AND by the repair that moves the marker
#: (#1154). Written once because the repair's destination IS this threshold: a
#: second literal here is a number the two halves can disagree about, and they
#: would disagree by moving a marker to a position the check still refuses
#: (L41).
MAX_PROSE_BEFORE_FIRST_PHOTO = 2

#: Alt text length band. Was 15 to 35 in the prompt, which ran long on every
#: marker of the corrected draft.
ALT_MIN_WORDS = 15
ALT_MAX_WORDS = 25

#: How many markers may share an opening before it reads as a template. The
#: corrected draft opened six of seven markers with "A male performer".
MAX_SHARED_OPENINGS = 2

#: Words that read as a claim about someone's inner life rather than what the
#: camera recorded.
INFERRED_STATE = (
    "concentration", "focused", "focus", "intense", "intently", "thoughtful",
    "pensive", "joyful", "joyous", "emotional", "passionate", "confident",
    "nervous", "serene", "contemplative", "determined", "lost in",
)

#: Phrases that read a visible expression as being AIMED at someone. The
#: expression is in the frame; who it was meant for is not. From the corrected
#: draft: "grinning toward the audience".
DIRECTED_INTENT = (
    r"grinning (?:toward|towards|at)", r"smiling (?:toward|towards|at)",
    r"looking (?:knowingly|pointedly)", r"gesturing (?:knowingly|pointedly)",
    r"playing (?:to|toward|towards) the (?:audience|crowd|camera)",
)

#: Rule 24: performers are named, never collected into a demographic group.
#: From the BLUDLINE draft: "The female performers in the cast, Ladibree,
#: Safa, and the others". Name everyone or name no one.
DEMOGRAPHIC_GROUPING = (
    r"\band the others\b",
    r"\bthe (?:female|male) (?:performers?|singers?|dancers?|musicians?|"
    r"actors?|vocalists?|cast)\b",
    r"\bthe (?:women|men|girls|boys) (?:in|of) the "
    r"(?:cast|group|ensemble|show|band|chorus)\b",
)

#: Rule 29: alt text names the person. A descriptor standing in for a name is
#: reported even when a performer is also named in the same marker, because the
#: descriptor is the thing to replace.
APPEARANCE_DESCRIPTOR = (
    r"\ba (?:young |older |tall |short |slim )*(?:wo)?man\b",
    r"\b(?:male|female) (?:performers?|singers?|dancers?|musicians?|"
    r"actors?|vocalists?)\b",
    r"\ba (?:bearded|blonde|blond|brunette|red-haired|grey-haired|gray-haired|"
    r"dark-haired)\b",
    r"\ba (?:girl|boy)\b",
)

_PHOTO_MARKER = re.compile(r"\[PHOTO:\s*([^\|\]]+?)\s*\|\s*([^\]]*)\]", re.DOTALL)

_NUMBER_WORDS = (
    "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    "ten", "eleven", "twelve", "fifteen", "twenty", "thirty", "forty", "fifty",
    "sixty", "hundred", "thousand", "dozen",
)

#: Numbers that are idiom rather than measurement, so they are not claims.
_NUMBER_ALLOWED = {"one", "two", "second", "first"}

#: A numeral immediately after one of these is part of a NAME, not a count:
#: "Matchbook Spark Vol. 2", "Book 2 of Homer's Odyssey", "Symphony No. 4".
#: There is no quantity being claimed, so there is nothing to be wrong about,
#: and flagging them is what taught Dan to ignore this check (#226).
_TITLE_LABEL = re.compile(
    r"\b(?:vol|volume|book|part|no|op|act|scene|chapter|movement|"
    r"symphony|concerto|suite|sonata|nocturne|etude|prelude|"
    r"canto|episode|session|series)\.?\s+(\d+)\b",
    re.IGNORECASE,
)

_CONSTRUCTION = re.compile(r"something between .+? and ", re.IGNORECASE)


@dataclass(frozen=True)
class Target:
    """What a finding is ABOUT, in a form that survives rewriting it (#1129).

    `Finding` is three strings and `detail` embeds the offending text, so a
    finding's identity moves the moment that text is rewritten. The damage gate
    compares the findings before a repair against the findings after it, and the
    repair pass caps attempts per target. Both need a key that does not move
    when the text does, and a round counter keyed on finding identity would
    restart at zero on every attempt and never reach its cap while reading as a
    cap (L344).

    `detail` cannot be parsed back into one: `alt[:90]` truncates, and
    `stacked_photos` gives `f"{earlier[:48]} then {later[:48]}"` with no block
    index at all. So it is recorded where the finding is built.

    kind is "marker" (key is the FOLDED filename, which survives a rewrite of
    the alt text and folds a near miss onto the file it names), "prose" (index
    into the prose-only paragraph list, so adding or removing a marker does not
    renumber what a repair was licensed to touch), or "body" (the whole post:
    a rule about arrangement rather than about one span).
    """
    kind: str
    key: str = ""
    index: int = -1


def _markers(body: str) -> list[tuple[str, str]]:
    return [(m.group(1).strip(), m.group(2).strip()) for m in _PHOTO_MARKER.finditer(body)]


def _marker_filename_findings(
        markers: list[tuple[str, str]],
        photo_filenames: list[str] | None) -> list[tuple[Finding, Target]]:
    """Markers naming a photo that was never sent, and photos never placed (#477).

    The prompt's hardest photo rule is the filename one, and it had no check at
    all: the pass 2 and pass 3 validator only pins those passes to whatever
    pass 1 produced, so a name invented in pass 1 was preserved faithfully to
    the review screen.

    Both directions are reported because both lose a photograph. A name that
    was never sent matches no file when the app lines markers up against the
    real photos, so that image silently does not appear in the post; a photo
    with no marker is one Dan picked for the post and never sees in it.

    Compared without case: a case difference is not a different photo on this
    filesystem, and reporting it would be the check crying wolf (L36).
    """
    if not photo_filenames:
        return []

    sent = {str(name).strip().casefold(): str(name).strip()
            for name in photo_filenames if str(name).strip()}
    if not sent:
        return []

    findings: list[tuple[Finding, Target]] = []
    placed: set[str] = set()
    for name, _alt in markers:
        key = name.casefold()
        if key in sent:
            placed.add(key)
            continue
        findings.append((Finding(
            "blog_marker_unknown_photo",
            "A photo marker names a file that was not one of the photos sent, "
            "so no image will appear there.",
            name), Target("marker", _fold_filename(name))))

    for key, name in sent.items():
        if key not in placed:
            findings.append((Finding(
                "blog_marker_missing_photo",
                "A photo chosen for this post was never placed in it.",
                name), Target("marker", _fold_filename(name))))
    return findings


#: Characters a model routinely substitutes when it copies a filename out of a
#: `Photo N:` label: typographic quotes become ASCII ones, the several unicode
#: dashes become a hyphen, the several unicode spaces become a space. Written as
#: escapes rather than literals so this file holds no dash the style gate has to
#: tell apart from a dash used as punctuation.
_PUNCTUATION_FOLD = str.maketrans({
    "\u201c": '"', "\u201d": '"', "\u201e": '"', "\u201f": '"', "\u2033": '"',
    "\u2018": "'", "\u2019": "'", "\u201a": "'", "\u201b": "'", "\u2032": "'",
    "\u2010": "-", "\u2011": "-", "\u2012": "-", "\u2013": "-",
    "\u2014": "-", "\u2015": "-", "\u2212": "-",
    "\u00a0": " ", "\u2007": " ", "\u2009": " ", "\u202f": " ",
})


def _fold_filename(name: str) -> str:
    """A filename reduced to what two spellings of the SAME file share.

    Composed and decomposed accents are one file on this filesystem, and so is
    a name whose only difference is which quote or dash character was typed.
    `check_blog` already folds case for the same reason, and this is the rest
    of that same fold.

    NFC rather than NFKC deliberately: NFKC would also collapse ligatures and
    fullwidth forms, which are genuinely different names, and a fold that is
    too generous attaches the wrong photograph.
    """
    text = unicodedata.normalize("NFC", str(name).strip())
    return " ".join(text.translate(_PUNCTUATION_FOLD).split()).casefold()


def refuse_colliding_filenames(photo_filenames: list[str],
                               source_paths: list[str]) -> None:
    """Refuse two photographs that would be shown under one label (#1130).

    Both blog scripts build `photo_filenames` by stripping the `NNN_` staging
    prefix off each staged basename, so two source photos from different
    folders sharing a basename produce two identical labels, which is an
    ordinary way to shoot: `day 1/DSC4821.jpg` and `day 2/DSC4821.jpg`.

    `_marker_filename_findings` folds them into one dict key and the pair
    silently collapses, so one photograph becomes unreportable as never placed.
    That is a quiet hole in a report today. For the repairer it is fatal:
    attaching the photograph means resolving a marker filename back to ONE file
    on disk, and under a collision it attaches the wrong one, which reads as
    correct and is not.

    Folded rather than compared raw, for the reason `repair_marker_filenames`
    folds: two names differing only in which quote was typed resolve to the same
    marker, so comparing raw would let through exactly the pair the fold makes.

    Raised BEFORE any paid call, and naming both full source paths, because
    "two photos share a name" is not actionable without knowing which two (L75).
    """
    seen: dict[str, str] = {}
    for name, source in zip(photo_filenames, source_paths):
        key = _fold_filename(name)
        # The SAME file listed twice is not this defect and is not refused
        # here. It is one photograph placed twice, so resolving a marker back
        # to a file attaches the right picture either way; what this exists to
        # stop is one label standing for two DIFFERENT photographs, where the
        # resolution is a coin toss and the wrong one reads as correct.
        if key in seen and seen[key] != source:
            raise ValueError(
                f"Two photographs would be shown to the model under the same "
                f"name, {name!r}, so a marker naming it cannot be resolved back "
                f"to one file and the wrong photograph would be attached:\n"
                f"  {seen[key]}\n  {source}\n"
                f"Rename one of them, or pick a different frame.")
        seen.setdefault(key, source)


def filenames_used_by(body: str,
                      photo_filenames: list[str] | None) -> list[str]:
    """Which of the available photos this body actually places (#962).

    An event's photo list is the photos AVAILABLE to a post, not the photos IN
    it: `generate_blog` subsamples to seven when more are assigned, and the
    DiGangi event holds twelve. A later pass checked against all twelve reports
    the five nobody chose as never placed, every time, which is the check
    crying wolf (L36) and the exact trained-to-skim failure #962 is about.

    Folded the same way `repair_marker_filenames` folds, so a marker that is a
    near miss still counts as placing its photo rather than dropping it out of
    the set and reintroducing the false alarm one file at a time.
    """
    if not body or not photo_filenames:
        return []
    written = {_fold_filename(name) for name, _alt in _markers(body)}
    return [str(name).strip() for name in photo_filenames
            if str(name).strip() and _fold_filename(name) in written]


#: How many leading words of an alt text count as its OPENING.
#:
#: Named because the repair pass has to group markers by exactly what the rule
#: groups them by. A second literal here is a number the check and the repair
#: can disagree about, and they would disagree by licensing a component the
#: check does not believe in (L41).
_OPENING_WORDS = 3


def _openings(body: str) -> dict[str, list[str]]:
    """Every distinct opening in the body, to the markers that use it."""
    out: dict[str, list[str]] = {}
    for name, alt in _markers(body):
        key = " ".join(alt.lower().split()[:_OPENING_WORDS])
        if key:
            out.setdefault(key, []).append(name)
    return out


def shared_opening_groups(body: str) -> list[list[str]]:
    """Markers the opening rule names TOGETHER, as groups (#1159).

    `alt_text_repeated_opening` is the only alt text rule that is a fact about
    the relationship between markers rather than about one marker's text, so it
    is the only one where rewriting a marker changes another marker's findings.
    The repair pass needs the group in order to select it as one target and to
    licence it as one in the damage gate.

    Read from the same `_openings` the check reads, so a group the pass acts on
    is exactly a group the check would report. Two readings of one rule drift,
    and drift here means licensing a component the checker does not believe in.
    """
    return [names for names in _openings(body).values()
            if len(names) > MAX_SHARED_OPENINGS]


@dataclass(frozen=True)
class Placement:
    """What the placement repair did to a body, and what it declined to do.

    Both halves, because they are opposite outcomes and only one of them is
    visible afterwards. A MOVE changes what Dan published, silently. A REFUSAL
    is reported by `check_blog` on the panel, but the panel is transient while
    the condition persists, so without recording it the fact that the app
    looked at a stack and declined vanishes when the post ships (L98, L126).

    `moved` and `refused` each hold (filename, the rule that fired) and can
    never name the same marker: a marker is placed or it is not.
    """
    body: str
    moved: list[tuple[str, str]] = field(default_factory=list)
    refused: list[tuple[str, str]] = field(default_factory=list)


def repair_marker_placement(body: str) -> Placement:
    """Move a misplaced photo marker to a position derived from the post.

    The second exception to this module's report-only rule, and it is an
    exception for the same narrow reason `repair_marker_filenames` is: nothing
    is invented. No prose is written, no prose is removed, and no photograph
    changes its position relative to another photograph. All that moves is
    which paragraph a marker sits beside, and both destinations are read off
    the rules themselves rather than judged:

    - `stacked_photos` is two markers with no prose between them, so the second
      belongs after the next prose block. That is the only position that clears
      the finding without disturbing any other marker.
    - `late_first_photo` is more than `MAX_PROSE_BEFORE_FIRST_PHOTO` prose
      blocks before the first photograph, so the marker belongs immediately
      after that many. The destination is the threshold the rule states.

    Where there is no derived destination it REFUSES rather than guessing, which
    is the failure #998 records: a stack at the very end of a post has no prose
    below it to move into, so it stays put and `check_blog` goes on reporting it
    (L98). A partly repaired stack is reported too, for the same reason.

    Returns a `Placement`: the repaired body, every marker it MOVED, and every
    marker it REFUSED to move. The refusals are reported rather than dropped
    (#1172), because `check_blog` saying the stack is still there and the app
    recording that it looked and declined are different facts, and only the
    second one survives publication.
    """
    if not body:
        return Placement(body)

    # Split so the SEPARATORS survive, because a move must not reformat the
    # rest of the post (#1170). A separator belongs to the GAP rather than to
    # either block: blocks are reordered by a move and the gaps stay where they
    # are, so the post keeps its own rhythm and the content moves through it.
    # That is the only reading that survives a reorder without inventing a
    # separator for a block whose neighbours have changed.
    pieces = re.split(r"(\n{2,})", body)
    blocks = [b.strip() for b in pieces[::2] if b.strip()]
    separators = [s for b, s in zip(pieces[::2], pieces[1::2]) if b.strip()]

    def is_marker(block: str) -> bool:
        return block.startswith("[PHOTO:")

    if not any(is_marker(b) for b in blocks):
        return Placement(body)

    moves: list[tuple[str, str]] = []

    # `late_first_photo` runs FIRST, because it moves a marker EARLIER and can
    # therefore create a stack. Running it second would leave that stack behind
    # with nothing to clear it, and the pass would report a finding it had just
    # introduced.
    prose_before_first = 0
    for block in blocks:
        if is_marker(block):
            break
        prose_before_first += 1
    if prose_before_first > MAX_PROSE_BEFORE_FIRST_PHOTO:
        marker = blocks.pop(prose_before_first)
        blocks.insert(MAX_PROSE_BEFORE_FIRST_PHOTO, marker)
        moves.append((_marker_name(marker), "late_first_photo"))

    # Then the stacks, in one forward pass. A marker that would land on top of
    # another is held back and released after the next prose block, so a run of
    # N stacked markers is dealt out across the next N-1 paragraphs in order.
    # Holding them in a queue rather than moving one at a time is what keeps
    # photographs in their original order: swapping the pair repeatedly walks a
    # later photograph in front of an earlier one.
    placed: list[str] = []
    waiting: list[str] = []
    for block in blocks:
        if is_marker(block):
            if waiting or (placed and is_marker(placed[-1])):
                waiting.append(block)
            else:
                placed.append(block)
            continue
        placed.append(block)
        if waiting:
            marker = waiting.pop(0)
            placed.append(marker)
            moves.append((_marker_name(marker), "stacked_photos"))
    # Whatever is still waiting ran out of prose to move into. It goes back
    # where it was, in order, and is reported rather than placed somewhere
    # nobody derived.
    # Whatever is still waiting had nowhere derived to go. It is REPORTED, not
    # silently dropped: that is the half nothing else records (#1172).
    refused = [(_marker_name(m), "stacked_photos") for m in waiting]
    placed.extend(waiting)

    if not moves:
        # Untouched means untouched: rebuilding would normalise whitespace on a
        # body this had no reason to rewrite.
        return Placement(body, [], refused)
    return Placement(_rejoin(placed, separators), moves, refused)


def _rejoin(blocks: list[str], separators: list[str]) -> str:
    """`blocks` in their new order, through the gaps the post already had.

    The separators are used POSITIONALLY: gap one keeps whatever gap one was,
    whichever block now sits after it. Rebuilding with a fixed `"\n\n"`
    normalised every gap in a post the repair had only one reason to touch, and
    nothing reported it because the repair names only the markers it moved
    (#1170, L340).

    A short separator list is padded rather than raising: the two are built
    from one split so they cannot disagree, and a body ending in a separator
    would otherwise lose its last block to an IndexError.
    """
    gaps = list(separators) + ["\n\n"] * max(0, len(blocks) - 1 - len(separators))
    out = []
    for index, block in enumerate(blocks):
        out.append(block)
        if index < len(blocks) - 1:
            out.append(gaps[index])
    return "".join(out)


def repair_marker_filenames(
        body: str,
        photo_filenames: list[str] | None) -> tuple[str, list[tuple[str, str]]]:
    """Correct marker filenames that are near misses of a real one (#962).

    Measured on Dan's DiGangi post: the photographs carry typographic quotes in
    their names and every one of the seven markers was written with ASCII ones,
    so `check_blog` reported all seven markers as naming a file that was never
    sent AND all seven photos as never placed. Fourteen of his twenty three
    checks, from one punctuation difference, and the two lists rendered in the
    panel as the same seven filenames printed twice.

    This is the `_fix_wrong_names` shape, not the report-only shape: the true
    spelling is in hand, so nothing is being invented and no model is called.

    Refuses in the two cases where it would be inventing:

    - a name that folds to nothing sent was genuinely made up, and snapping it
      to the nearest file would put the wrong photograph under prose written
      about a different one
    - a fold matching two sent files names a family, not a member (L521), so
      neither is chosen

    Returns the repaired body and every (was, now) pair. An empty list means
    there was nothing to repair, which is a different outcome from a repair
    that was refused, and the refused ones are still reported by `check_blog`
    running afterwards (L98).
    """
    if not body or not photo_filenames:
        return body, []

    exact: set[str] = set()
    by_fold: dict[str, set[str]] = {}
    for raw in photo_filenames:
        name = str(raw).strip()
        if not name:
            continue
        exact.add(name.casefold())
        by_fold.setdefault(_fold_filename(name), set()).add(name)

    corrections: list[tuple[str, str]] = []

    def _repair(match: "re.Match[str]") -> str:
        written = match.group(1).strip()
        if written.casefold() in exact:
            return match.group(0)
        candidates = by_fold.get(_fold_filename(written)) or set()
        if len(candidates) != 1:
            return match.group(0)
        correct = next(iter(candidates))
        corrections.append((written, correct))
        # Replaced inside THIS marker only, and only its first occurrence,
        # which is the filename: a whole-body replace would rewrite the prose
        # and any alt text quoting the same string (#109).
        return match.group(0).replace(written, correct, 1)

    return _PHOTO_MARKER.sub(_repair, body), corrections


def _prose_index_of(paragraphs: list[str], needle: str) -> int:
    """Which prose paragraph a prose-level finding is about (#1129).

    Indexed into the PROSE-only list, never into `body.split("\n\n")`, so
    adding or removing a photo marker does not renumber the paragraphs a repair
    was licensed to touch.

    -1 when no paragraph holds it, which happens when the match spans a
    paragraph boundary: the prose these rules search is the paragraphs joined
    by a space. Answered as "no paragraph" rather than as paragraph 0, because
    a wrong index would licence a repair to rewrite a paragraph the finding is
    not about (L215).
    """
    low = str(needle).casefold()
    for i, paragraph in enumerate(paragraphs):
        if low in paragraph.casefold():
            return i
    return -1


def _marker_name(block: str) -> str:
    """The filename in a block that starts with a marker, or the block itself."""
    match = _PHOTO_MARKER.search(block)
    return match.group(1).strip() if match else block



def outside_markers(body: str, apply: Callable[[str], str]) -> str:
    """`body` with `apply` run on the prose BETWEEN photo markers, never on one.

    A `[PHOTO: file.jpg | alt]` marker is not prose. Its filename names a real
    file on disk and its alt text is judged against the photograph, so a rule
    written about Dan's writing must not reach either.

    Code that decided this by looking at the CONTAINER, the whole body or a
    whole paragraph, got it wrong in both directions the moment one container
    held both (L361). `_fix_wrong_names` substituted over the whole body and
    rewrote a filename into a file that does not exist (#975);
    `_prose_paragraphs` dropped a block only when the WHOLE block began with a
    marker, so one at the end of a paragraph leaked in and one at the start took
    the prose after it out (#1163).

    Each prose span is offered SEPARATELY rather than joined, so a pattern
    cannot match across a marker: a whole-body regex otherwise reads a filename
    and the sentence after it as one run.

    The repo learned this once already. #109 moved `_fix_second_person` and
    `_fix_missing_contractions` onto paragraph splicing for exactly this reason
    and did not carry it to their sibling, which is how #975 survived.
    """
    out: list[str] = []
    at = 0
    for match in _PHOTO_MARKER.finditer(body):
        out.append(apply(body[at:match.start()]))
        out.append(match.group(0))
        at = match.end()
    out.append(apply(body[at:]))
    return "".join(out)


def _prose_paragraphs(body: str) -> list[str]:
    """The body's blocks that are not purely a photo marker, markers KEPT.

    This is the INDEXED list: `blog_repair_damage` licenses a repairer to
    rewrite paragraph N of it, and refuses when that paragraph holds a marker
    inline, because rewriting one sends the marker to a model and splices back
    whatever comes out (#998). Both of those need the marker still in the text
    and need the indices stable, so this deliberately keeps the old block
    semantics.

    The prose RULES want the opposite and take `prose_text_of` below. Serving
    both from one function is what #1163 asked for and what a first attempt
    did: stripping markers here made the inline-marker refusal unreachable,
    because a block that no longer holds a marker can never be found to hold
    one (L109, a refusal that cannot be spoken).
    """
    out = []
    for block in body.split("\n\n"):
        text = block.strip()
        if text and not text.startswith("[PHOTO:"):
            out.append(text)
    return out


def prose_text_of(body: str) -> list[str]:
    """The same blocks with every marker CUT OUT, for the rules about writing.

    Markers are removed by SPAN, which is what made the block test wrong in
    both directions before #1163 (L361): one at the END of a block leaked in,
    so every prose rule read a filename as words Dan wrote, and one at the
    START took the prose after it out, so those words were checked by nothing.

    Measured 2026-09-01 over the 21 stored bodies: 7 markers leaked on one
    post, which is 8 of the 32 `invented_number` firings, a quarter of that
    rule's entire rate, every one a false positive on a filename like
    `-189.jpg`. Nothing was dropped out, which is reachable rather than
    occurring.
    """
    out = []
    for block in body.split("\n\n"):
        text = _PHOTO_MARKER.sub(" ", block).strip()
        if text:
            out.append(text)
    return out


def _program_numbers(program: dict[str, Any] | None, venue: str) -> set[str]:
    """Every number token that legitimately appears in the source data.

    A number in the body that is not here was invented, because the generator
    is given the program and nothing else that carries a count.
    """
    blob = [venue or ""]
    for piece in (program or {}).get("pieces") or []:
        blob += [str(piece.get("title", "")), str(piece.get("composer", ""))]
    for person in (program or {}).get("performers") or []:
        blob += [str(person.get("name", "")), str(person.get("voice_or_instrument", ""))]
    for key in ("prose", "notes", "program_notes"):
        if isinstance((program or {}).get(key), str):
            blob.append(program[key])
    text = " ".join(blob).lower()
    found = set(re.findall(r"\d+", text))
    found |= {w for w in _NUMBER_WORDS if re.search(rf"\b{w}\b", text)}
    return found


#: Digit form for each counting word, so "Eight" and "8" are one fact.
_WORD_FOR_COUNT = {
    1: "one", 2: "two", 3: "three", 4: "four", 5: "five", 6: "six",
    7: "seven", 8: "eight", 9: "nine", 10: "ten", 11: "eleven", 12: "twelve",
}


def _counts_supported_by_names(paragraphs: list[str],
                               program: dict[str, Any] | None) -> set[str]:
    """Counts the prose itself accounts for, per paragraph.

    "Eight people at mic stands" is not invented when the same paragraph names
    eight people. Measured on the real bludline correction (#204, #226), where
    the paragraph names exactly eight of the programme's TEN performers.

    That ten is why this counts names in the paragraph rather than the size of
    the cast: blessing a number for matching the cast size would have accepted
    this one for a reason that is not true, and would then accept a genuinely
    wrong count in any post whose cast happens to be that size.

    Only performers the programme actually lists are counted, so a paragraph
    cannot talk its own number up with ordinary capitalised words.
    """
    performers = [str(p.get("name", "")).strip()
                  for p in (program or {}).get("performers") or []
                  if str(p.get("name", "")).strip()]
    if not performers:
        return set()

    # Match on any single part of a name: the prose routinely uses a surname
    # alone ("Suero and White"), a stage name, or a fuller form than the
    # programme carries ("Alexander Manuel" for "Alex Manuel").
    parts_by_performer = [
        {part.lower().strip(".,") for part in name.replace(",", " ").split()
         if len(part.strip(".,")) > 2}
        for name in performers
    ]

    allowed: set[str] = set()
    for para in paragraphs:
        words = {w.lower().strip(".,;:!?()") for w in para.split()}
        named = sum(1 for parts in parts_by_performer if parts & words)
        if named:
            allowed.add(str(named))
            if (word := _WORD_FOR_COUNT.get(named)):
                allowed.add(word)
    return allowed


# #227: a group too big to name gets a count and the ensemble name.
#
# Rule 29 (name people, never appearance) and rule 18 (15 to 25 words) are in
# genuine tension on a frame holding eight performers: naming everyone cannot
# fit. Dan's decision is the form his own corrected BLUDLINE post reached for,
# "Four BLUDLINE performers at mic stands".
#
# The count must be a real one. A vague quantifier ("several women in black") is
# the same failure to look at the photograph that "a male performer" is, so it
# buys no exemption. The ensemble name is required too: "Four performers at mic
# stands" credits nobody, and crediting is the point.
_COUNT_WORDS = (
    r"\d{1,3}|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|"
    r"thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty"
)
_GROUP_NOUNS = (
    r"performers|singers|dancers|musicians|players|members|choristers|actors|"
    r"vocalists|instrumentalists|soloists"
)
# The count is matched case-insensitively ("Four" opens the sentence) while the
# ensemble stays case-SENSITIVE: requiring a capital is what separates "Four
# BLUDLINE performers" from "Four performers", which credits nobody.
GROUP_CREDIT = re.compile(
    rf"\b(?i:{_COUNT_WORDS})\s+((?:[A-Z][\w'&.\-]*\s+){{1,3}})(?i:{_GROUP_NOUNS})\b"
)



def inferred_state_hits(low: str) -> list[str]:
    """What in `low` describes an inner state rather than what the camera saw.

    One matcher for both callers. `INFERRED_STATE` and `DIRECTED_INTENT` were
    shared and the matching built on them was not: these lines existed here and
    again in `caption_quality`, byte for byte (#1224).

    Sharing the word lists while copying the matcher is the half measure that
    makes divergence likely: the lists LOOK like the single source of truth, so
    a change to how they are APPLIED, a word boundary, case folding, a new
    pattern family, is made in whichever file the author had open, and a shared
    NAME reads as evidence of shared BEHAVIOUR so nobody compares the two again
    (L263, L370).

    Only the matching is shared. Both callers build their own `Finding`, since
    they word them differently and target them differently, a marker filename
    against a photo name or position.

    `low` is expected already lowercased, as both call sites have it to hand.
    """
    hits = [w for w in INFERRED_STATE if re.search(rf"\b{re.escape(w)}\b", low)]
    hits += [m.group(0) for pat in DIRECTED_INTENT
             for m in [re.search(pat, low)] if m]
    return hits


def names_a_group(alt: str) -> bool:
    """Whether the alt text credits an ensemble by count and name (#227)."""
    return GROUP_CREDIT.search(alt) is not None


def check_alt_text(name: str, alt: str, *, venue: str = "",
                   performers: list[str] | None = None) -> list[Finding]:
    """The six rules about ONE marker's alt text (#1133).

    Extracted so the repair pass can re-run exactly the rules that selected a
    marker, rather than a second copy of them that reads the same and drifts
    (L263). Its acceptance check is literally this call: rewrite, re-run, refuse
    if any finding remains or any new code appears.

    Returns findings in MARKER major order (all of one marker's, in rule order).
    `check_blog` buckets and re-emits them rule major, which is the order it has
    always used and which `tests/test_blog_findings_golden.py` pins.

    Deliberately NOT covering `alt_text_repeated_opening`: that is a fact about
    the RELATIONSHIP between markers, not about one of them, and it stays in
    `check_blog` where it can see them all.
    """
    performers = performers or []
    found: list[Finding] = []

    # 18. length band, and the marker with nothing in it at all.
    #
    # The empty case is its own code (#1129). This rule used to read
    # `if words and not (MIN <= words <= MAX)`, and that leading `words and`
    # exempted a zero-word alt text from the band. Every other alt rule searches
    # the text for something, so an empty one matched nothing and fired nothing:
    # a marker whose description had been deleted produced no finding at all.
    #
    # Harmless while nothing rewrote alt text. The repair pass does, and its
    # acceptance check is "re-run these rules and refuse if any finding
    # remains", so the shortest path to an accepted repair was deleting the
    # words.
    #
    # Counted AFTER `strip_em_dashes`, which is the arithmetic every acceptance
    # check downstream depends on. That substitutes ", " for any dash not
    # between digits, so a dash joined token becomes two tokens; all three blog
    # paths strip before they check, so a count taken before the strip has the
    # repairer and the checker measuring different numbers on the same body,
    # which turns the round cap into a silent give up rather than a refusal.
    words = len(strip_em_dashes(alt).split())
    if not words:
        found.append(Finding(
            "alt_text_empty",
            "This photo has no alt text, so the picture is described to "
            "nobody who cannot see it.",
            name))
    elif not (ALT_MIN_WORDS <= words <= ALT_MAX_WORDS):
        found.append(Finding(
            "alt_text_length",
            f"Alt text must be {ALT_MIN_WORDS} to {ALT_MAX_WORDS} words.",
            f"{name}: {words} words. {alt[:90]}"))

    # 17. name the venue and a performer in every marker
    low = alt.lower()
    if venue and venue.lower() not in low:
        found.append(Finding(
            "alt_text_missing_venue",
            "Every alt text names the venue.",
            f"{name}: {alt[:90]}"))
    named = any(p.lower() in low for p in performers)
    if performers and not named and not names_a_group(alt):
        found.append(Finding(
            "alt_text_missing_performer",
            "Every alt text names the performer, or credits the group by "
            "count and ensemble name when there are too many to name.",
            f"{name}: {alt[:90]}"))

    # 19. no inferred inner states
    hits = inferred_state_hits(low)
    if hits:
        found.append(Finding(
            "alt_text_inferred_state",
            "Alt text describes what the camera recorded, not what someone felt.",
            f"{name}: {', '.join(hits)} in '{alt[:80]}'"))

    # 29. alt text names the person, never their appearance or gender
    hits = [m.group(0) for pat in APPEARANCE_DESCRIPTOR
            for m in [re.search(pat, low)] if m]
    if hits:
        found.append(Finding(
            "alt_text_appearance_descriptor",
            "Alt text names the person, never their appearance or gender.",
            f"{name}: {', '.join(hits)} in '{alt[:80]}'"))

    return found


def check_blog(body: str, *, program: dict[str, Any] | None = None,
               venue: str = "",
               photo_filenames: list[str] | None = None) -> list[Finding]:
    """Every objectively checkable rule the corrected draft broke.

    `photo_filenames` is the list of names the model was actually shown, in
    the exact spelling its `Photo N:` labels used. Without it the filename
    rules below are skipped rather than guessed at: a caller with no list
    (a revision re-checking an existing body) must not have every marker
    reported as naming an unknown photo.

    Delegates to `check_blog_targeted` and drops the targets, so the frozen
    `Finding`, `finding_entry`, the bridge payload contract, the Swift side and
    every test file importing this are untouched by #1129 adding them.
    """
    return [finding for finding, _target in check_blog_targeted(
        body, program=program, venue=venue, photo_filenames=photo_filenames)]


def check_blog_targeted(
        body: str, *, program: dict[str, Any] | None = None,
        venue: str = "",
        photo_filenames: list[str] | None = None,
) -> list[tuple[Finding, Target]]:
    """`check_blog`, plus what each finding is ABOUT (#1129).

    Same findings, same order. See `Target` for why a finding cannot answer
    that question about itself.
    """
    findings: list[tuple[Finding, Target]] = []
    markers = _markers(body)
    findings += _marker_filename_findings(markers, photo_filenames)
    performers = [str(p.get("name", "")).strip()
                  for p in (program or {}).get("performers") or []
                  if str(p.get("name", "")).strip()]

    # The six per-marker alt text rules, extracted so the repairer can re-run
    # EXACTLY the rules that selected a marker rather than a second copy of
    # them (#1133, L263). See `check_alt_text`.
    #
    # Re-emitted RULE major, which is the order `check_blog` has always used: a
    # length loop over every marker, then venue and performer, then the openings
    # pass, then inferred state, then appearance. Calling a per-marker function
    # once per marker produces MARKER major order and changes the ordered list,
    # so the output is bucketed by code and re-emitted in the original order.
    # `tests/test_blog_findings_golden.py` is what proves this, against a golden
    # recorded from the code before the extraction.
    by_marker: list[tuple[str, list[Finding]]] = [
        (name, check_alt_text(name, alt, venue=venue, performers=performers))
        for name, alt in markers
    ]

    def emit(*codes: str) -> None:
        for name, found in by_marker:
            for finding in found:
                if finding.code in codes:
                    findings.append(
                        (finding, Target("marker", _fold_filename(name))))

    # The length rule was a loop of its own over every marker, so both its codes
    # come first, all of them, before anything else.
    emit("alt_text_empty", "alt_text_length")
    # Venue and performer were ONE loop, so they interleave PER MARKER: venue,
    # performer, venue, performer. Emitting them as two buckets is a different
    # order, and the golden caught exactly that on the first attempt.
    emit("alt_text_missing_venue", "alt_text_missing_performer")

    # 20. vary the opening
    for key, names in _openings(body).items():
        if len(names) > MAX_SHARED_OPENINGS:
            # Names several markers in one finding, which is why the repair
            # pass groups markers into connected components: rewriting one of
            # them changes another's finding set. Targeted on the FIRST, so the
            # finding has a stable key; the component is what actually gets
            # attempted (#1129).
            findings.append((Finding(
                "alt_text_repeated_opening",
                "Vary how the alt text opens; more than two markers share a start.",
                f"{len(names)} markers open '{key}': {', '.join(names)}"),
                Target("marker", _fold_filename(names[0]))))

    # Two separate loops in the original, so two separate passes here.
    emit("alt_text_inferred_state")
    emit("alt_text_appearance_descriptor")

    # 8. never invent numbers
    known = _program_numbers(program, venue)
    # The rules read Dan's WRITING, so markers are cut out (#1163).
    paragraphs = prose_text_of(body)
    prose = " ".join(paragraphs)
    # A count the surrounding prose supports is derivable, not invented (#226).
    known |= _counts_supported_by_names(paragraphs, program)
    # Numerals that are part of a title carry no quantity at all.
    known |= {m.group(1) for m in _TITLE_LABEL.finditer(prose)}
    seen: set[str] = set()
    for token in re.findall(r"\b\d+\b", prose):
        if token not in known and token not in seen:
            seen.add(token)
            findings.append((Finding(
                "invented_number",
                "No count in the source data means no number in the post.",
                f"'{token}' does not appear in the program data"),
                Target("prose", token, _prose_index_of(paragraphs, token))))
    for word in _NUMBER_WORDS:
        if word in _NUMBER_ALLOWED or word in known or word in seen:
            continue
        if re.search(rf"\b{word}\b", prose, re.IGNORECASE):
            seen.add(word)
            findings.append((Finding(
                "invented_number",
                "No count in the source data means no number in the post.",
                f"'{word}' does not appear in the program data"),
                Target("prose", word, _prose_index_of(paragraphs, word))))

    # 24. no demographic grouping of performers
    for pat in DEMOGRAPHIC_GROUPING:
        m = re.search(pat, prose, re.IGNORECASE)
        if m:
            findings.append((Finding(
                "demographic_grouping",
                "Name every performer or name none; do not group them by "
                "gender or trail off into 'and the others'.",
                f"'{m.group(0)}' in '{prose[max(0, m.start() - 30):m.end() + 30]}'"),
                Target("prose", m.group(0), _prose_index_of(paragraphs, m.group(0)))))

    # 16. use a construction once
    uses = _CONSTRUCTION.findall(prose)
    if len(uses) > 1:
        # The whole post: the rule is that the construction appears MORE THAN
        # ONCE, which is a fact about the body and not about either paragraph.
        findings.append((Finding(
            "repeated_construction",
            "Use a construction once; 'something between X and Y' appears more than once.",
            f"{len(uses)} uses: {'; '.join(u.strip() for u in uses)}"),
            Target("body")))

    # 4. photo placement
    blocks = [b.strip() for b in body.split("\n\n") if b.strip()]
    for earlier, later in zip(blocks, blocks[1:]):
        if earlier.startswith("[PHOTO:") and later.startswith("[PHOTO:"):
            findings.append((Finding(
                "stacked_photos",
                "Two photos with no prose between them.",
                f"{earlier[:48]} then {later[:48]}"),
                Target("marker", _fold_filename(_marker_name(later)))))
    prose_before_first = 0
    for block in blocks:
        if block.startswith("[PHOTO:"):
            break
        prose_before_first += 1
    if markers and prose_before_first > MAX_PROSE_BEFORE_FIRST_PHOTO:
        findings.append((Finding(
            "late_first_photo",
            "The first photo comes after more than two paragraphs.",
            f"{prose_before_first} paragraphs before the first marker"),
            Target("marker", _fold_filename(markers[0][0]))))

    return findings
