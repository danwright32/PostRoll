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

_CONSTRUCTION = re.compile(r"something between .+? and ", re.IGNORECASE)


@dataclass(frozen=True)
class Finding:
    code: str
    message: str
    detail: str


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
        if performers and not any(p.lower() in low for p in performers):
            findings.append(Finding(
                "alt_text_missing_performer",
                "Every alt text names the performer rather than 'a male performer'.",
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
    prose = " ".join(_prose_paragraphs(body))
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
