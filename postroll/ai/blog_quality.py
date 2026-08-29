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
from dataclasses import dataclass
from typing import Any

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
class Finding:
    code: str
    message: str
    detail: str


def finding_entry(finding: Finding) -> dict[str, str]:
    """One finding, in exactly the fields the app decodes (#274).

    Three modules built this dict by hand, so a field added to Finding reached
    the app from whichever of them was remembered. One derivation, and the
    payload contract has one place to read.
    """
    return {"code": finding.code, "message": finding.message, "detail": finding.detail}


def _markers(body: str) -> list[tuple[str, str]]:
    return [(m.group(1).strip(), m.group(2).strip()) for m in _PHOTO_MARKER.finditer(body)]


def _marker_filename_findings(markers: list[tuple[str, str]],
                              photo_filenames: list[str] | None) -> list[Finding]:
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

    findings: list[Finding] = []
    placed: set[str] = set()
    for name, _alt in markers:
        key = name.casefold()
        if key in sent:
            placed.add(key)
            continue
        findings.append(Finding(
            "blog_marker_unknown_photo",
            "A photo marker names a file that was not one of the photos sent, "
            "so no image will appear there.",
            name))

    for key, name in sent.items():
        if key not in placed:
            findings.append(Finding(
                "blog_marker_missing_photo",
                "A photo chosen for this post was never placed in it.",
                name))
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


def _prose_paragraphs(body: str) -> list[str]:
    out = []
    for block in body.split("\n\n"):
        text = block.strip()
        if text and not text.startswith("[PHOTO:"):
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


def names_a_group(alt: str) -> bool:
    """Whether the alt text credits an ensemble by count and name (#227)."""
    return GROUP_CREDIT.search(alt) is not None


def check_blog(body: str, *, program: dict[str, Any] | None = None,
               venue: str = "",
               photo_filenames: list[str] | None = None) -> list[Finding]:
    """Every objectively checkable rule the corrected draft broke.

    `photo_filenames` is the list of names the model was actually shown, in
    the exact spelling its `Photo N:` labels used. Without it the filename
    rules below are skipped rather than guessed at: a caller with no list
    (a revision re-checking an existing body) must not have every marker
    reported as naming an unknown photo.
    """
    findings: list[Finding] = []
    markers = _markers(body)
    findings += _marker_filename_findings(markers, photo_filenames)
    performers = [str(p.get("name", "")).strip()
                  for p in (program or {}).get("performers") or []
                  if str(p.get("name", "")).strip()]

    # 18. length band
    for name, alt in markers:
        words = len(alt.split())
        if words and not (ALT_MIN_WORDS <= words <= ALT_MAX_WORDS):
            findings.append(Finding(
                "alt_text_length",
                f"Alt text must be {ALT_MIN_WORDS} to {ALT_MAX_WORDS} words.",
                f"{name}: {words} words. {alt[:90]}"))

    # 17. name the venue and a performer in every marker
    for name, alt in markers:
        low = alt.lower()
        if venue and venue.lower() not in low:
            findings.append(Finding(
                "alt_text_missing_venue",
                "Every alt text names the venue.",
                f"{name}: {alt[:90]}"))
        named = any(p.lower() in low for p in performers)
        if performers and not named and not names_a_group(alt):
            findings.append(Finding(
                "alt_text_missing_performer",
                "Every alt text names the performer, or credits the group by "
                "count and ensemble name when there are too many to name.",
                f"{name}: {alt[:90]}"))

    # 20. vary the opening
    openings: dict[str, list[str]] = {}
    for name, alt in markers:
        key = " ".join(alt.lower().split()[:3])
        if key:
            openings.setdefault(key, []).append(name)
    for key, names in openings.items():
        if len(names) > MAX_SHARED_OPENINGS:
            findings.append(Finding(
                "alt_text_repeated_opening",
                "Vary how the alt text opens; more than two markers share a start.",
                f"{len(names)} markers open '{key}': {', '.join(names)}"))

    # 19. no inferred inner states
    for name, alt in markers:
        low = alt.lower()
        hits = [w for w in INFERRED_STATE if re.search(rf"\b{re.escape(w)}\b", low)]
        hits += [m.group(0) for pat in DIRECTED_INTENT
                 for m in [re.search(pat, low)] if m]
        if hits:
            findings.append(Finding(
                "alt_text_inferred_state",
                "Alt text describes what the camera recorded, not what someone felt.",
                f"{name}: {', '.join(hits)} in '{alt[:80]}'"))

    # 29. alt text names the person, never their appearance or gender
    for name, alt in markers:
        low = alt.lower()
        hits = [m.group(0) for pat in APPEARANCE_DESCRIPTOR
                for m in [re.search(pat, low)] if m]
        if hits:
            findings.append(Finding(
                "alt_text_appearance_descriptor",
                "Alt text names the person, never their appearance or gender.",
                f"{name}: {', '.join(hits)} in '{alt[:80]}'"))

    # 8. never invent numbers
    known = _program_numbers(program, venue)
    paragraphs = _prose_paragraphs(body)
    prose = " ".join(paragraphs)
    # A count the surrounding prose supports is derivable, not invented (#226).
    known |= _counts_supported_by_names(paragraphs, program)
    # Numerals that are part of a title carry no quantity at all.
    known |= {m.group(1) for m in _TITLE_LABEL.finditer(prose)}
    seen: set[str] = set()
    for token in re.findall(r"\b\d+\b", prose):
        if token not in known and token not in seen:
            seen.add(token)
            findings.append(Finding(
                "invented_number",
                "No count in the source data means no number in the post.",
                f"'{token}' does not appear in the program data"))
    for word in _NUMBER_WORDS:
        if word in _NUMBER_ALLOWED or word in known or word in seen:
            continue
        if re.search(rf"\b{word}\b", prose, re.IGNORECASE):
            seen.add(word)
            findings.append(Finding(
                "invented_number",
                "No count in the source data means no number in the post.",
                f"'{word}' does not appear in the program data"))

    # 24. no demographic grouping of performers
    for pat in DEMOGRAPHIC_GROUPING:
        m = re.search(pat, prose, re.IGNORECASE)
        if m:
            findings.append(Finding(
                "demographic_grouping",
                "Name every performer or name none; do not group them by "
                "gender or trail off into 'and the others'.",
                f"'{m.group(0)}' in '{prose[max(0, m.start() - 30):m.end() + 30]}'"))

    # 16. use a construction once
    uses = _CONSTRUCTION.findall(prose)
    if len(uses) > 1:
        findings.append(Finding(
            "repeated_construction",
            "Use a construction once; 'something between X and Y' appears more than once.",
            f"{len(uses)} uses: {'; '.join(u.strip() for u in uses)}"))

    # 4. photo placement
    blocks = [b.strip() for b in body.split("\n\n") if b.strip()]
    for earlier, later in zip(blocks, blocks[1:]):
        if earlier.startswith("[PHOTO:") and later.startswith("[PHOTO:"):
            findings.append(Finding(
                "stacked_photos",
                "Two photos with no prose between them.",
                f"{earlier[:48]} then {later[:48]}"))
    prose_before_first = 0
    for block in blocks:
        if block.startswith("[PHOTO:"):
            break
        prose_before_first += 1
    if markers and prose_before_first > 2:
        findings.append(Finding(
            "late_first_photo",
            "The first photo comes after more than two paragraphs.",
            f"{prose_before_first} paragraphs before the first marker"))

    return findings
