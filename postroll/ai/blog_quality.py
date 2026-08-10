"""Deterministic backstops for the blog correction rules (#201).

Dan hand-corrected a generated post and the edit was close to a rewrite. Prompt
text alone will not hold these rules (this repo's standing
deterministic-enforcement rule), so the objectively checkable ones are asserted
here, after generation, in the same spirit as `_fix_second_person`.

These REPORT rather than rewrite, which is the deliberate difference from the
`_fix_*` helpers. Most cannot be auto-fixed without inventing something: nobody
can supply the true number that replaces an invented one, and alt text cannot be
rewritten without seeing the photograph. Quoting the offending text lets Dan fix
it in seconds; silently rewriting would stack a second guess on the first.

Only the objectively checkable rules live here. The judgement ones (thesis
discipline, no performance review, no criticism of the venue, no interpretation
of the photo) stay in BLOG_WRITING_RULES and BLOG_STRUCTURE, because a regex
cannot tell an observation from an assessment.
"""

from __future__ import annotations

import re
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
               venue: str = "") -> list[Finding]:
    """Every objectively checkable rule the corrected draft broke."""
    findings: list[Finding] = []
    markers = _markers(body)
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
