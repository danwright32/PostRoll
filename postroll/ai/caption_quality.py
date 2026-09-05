"""Hard, checkable caption rules enforced in code (#110).

The caption prompt bans engagement bait and the generic second person, and the
blog already enforces its equivalent bans after the model has answered. Captions
relied on the prompt alone, and a rule that lives only in a prompt is a hope
(#199).

These are strings, not judgements: they either appear or they do not, so a regex
settles it and there is no need to ask the model whether it obeyed. The model is
still needed for the REWRITE, because deleting the offending phrase outright
would leave a caption with a hole in it.

Deliberately NOT enforced here: the ban on ending with a generic question. That
is a shape rather than a string, and a regex for it would either miss the ones
phrased differently or fire on a legitimate sentence that happens to end in a
question mark. A check that cries wolf gets ignored (L36).
"""

from __future__ import annotations

import re


#: Scroll-pattern engagement bait. Written out rather than assembled from parts
#: so the list reads as what it bans.
BANNED_PHRASE_RE = re.compile(
    r"link in bio"
    r"|swipe (?:up|to see|for)"
    r"|dm me"
    r"|drop a comment"
    r"|tag someone",
    re.IGNORECASE,
)

#: The reader being addressed. Handles are excluded because "@youngpeopleschorus"
#: is an account name, not an address, and a word merely containing the letters
#: is not a match either.
_SECOND_PERSON_RE = re.compile(r"(?<![@\w])you(?:r|rs|'re|’re)?(?![\w])", re.IGNORECASE)

#: Anything inside quotes is somebody on stage speaking, which is a fact about
#: the night rather than the caption talking to the reader.
_QUOTED_SPAN_RE = re.compile(r'["“][^"”]*["”]')


def banned_phrases_in(caption: str) -> list[str]:
    """Every banned phrase present, as it appears, or an empty list.

    Returns what was found rather than a bool: the rewrite has to be told which
    phrase to remove, and a warning that cannot name the problem is not
    actionable.
    """
    return [m.group(0) for m in BANNED_PHRASE_RE.finditer(caption or "")]


def has_generic_second_person(caption: str) -> bool:
    """Whether the caption addresses the reader outside of quoted speech."""
    unquoted = _QUOTED_SPAN_RE.sub("", caption or "")
    return bool(_SECOND_PERSON_RE.search(unquoted))


def problems_in(caption: str) -> list[str]:
    """Plain descriptions of everything a caption breaks, for the rewrite ask."""
    problems: list[str] = []
    phrases = banned_phrases_in(caption)
    if phrases:
        quoted = ", ".join(f'"{p}"' for p in phrases)
        problems.append(f"engagement bait ({quoted})")
    if has_generic_second_person(caption):
        problems.append('the generic second person ("you", "your")')
    return problems


REWRITE_PROMPT = """\
Reword this Instagram caption by Dan Wright, a documentary photographer of
live performance, to remove {problems}.

Change as little as possible: keep every fact, every @ handle exactly as
written, the same length and the same plain register. Do not add a call to
action, a question, or anything in its place. Return ONLY the reworded caption,
nothing else.

Caption:
{caption}
"""


# -- alt text (#1068) --------------------------------------------------------
#
# Blog alt text is checked six ways and social caption alt text was checked in
# no way at all, so every description reaching Instagram, Facebook, Bluesky and
# Pinterest was whatever the model returned, unexamined.
#
# THREE of the six transfer. Which ones was decided by measurement, not by
# reading: run over the 319 alt texts in the live store on 2026-09-02, with each
# day's post type taken from `posting_preset.post_type`, the blog's rules fire
# at these rates on real, shipped, largely correct captions.
#
#     names a performer                92%   NOT transferred
#     names the venue                  77%   NOT transferred (42% on reels)
#     appearance instead of the name   30%   NOT transferred
#     length outside the band          17%   transferred
#     inferred inner state              5%   transferred
#     empty                             0%   transferred
#
# The three that are out are out for a reason, recorded here so their absence
# reads as a decision rather than as a gap nobody got to (L129). The performer
# rule is infeasible on social: a carousel of eight photos from a forty
# performer concert cannot name somebody in every one, which is why it fires on
# nine in ten. The venue rule is a blog convention, and loosening it to accept
# any part of a compound venue rescues only 5% of its hits. The appearance rule
# catches real things, but the alternative it implies IS the performer rule, so
# it asks for something that cannot be done here. Any of them would put a
# finding on most posts, and a panel that fires on everything is one that gets
# skimmed (L36).
#
# The MATCHER comes from `blog_quality` rather than being copied, so "an
# inferred inner state" has ONE definition across both paths. Two same named
# rules either side of a boundary are never compared and drift indefinitely
# (L263).
#
# It was the word lists alone until #1224, with the matching built on them
# written out here as well. That is the half measure that makes drift likely:
# the shared lists look like the single source of truth, so a change to how
# they are APPLIED lands in whichever file the author had open (L370).

from typing import Any                                   # noqa: E402

from .blog_findings import Finding                       # noqa: E402
from .blog_quality import inferred_state_hits            # noqa: E402


def check_caption_alt_texts(
        alt_texts: list, *, band: tuple[int, int] | None,
        photo_names: list[str] | None = None) -> list[Finding]:
    """Every checkable rule a post's alt texts break.

    `band` is the (minimum, maximum) word count THIS post type's own alt
    instruction asks for, passed in rather than looked up, so this stays a leaf
    and the instruction remains the single place the numbers are stated (L41).
    None switches the length rule off; `generate_captions` has a test asserting
    every instruction states a range, which is what keeps that unreachable
    (L113).

    `photo_names` positionally names the photograph each alt text describes. A
    finding about one of eight descriptions is unusable without saying which one
    (L80), and the position is the fallback when the names are not to hand.
    Deliberately tolerant of a short name list: keeping the two in step is
    somebody else's job, and a check that crashes when an upstream invariant
    slipped reports nothing at all about the rest (L215).
    """
    names = list(photo_names or [])
    found: list[Finding] = []

    for index, raw in enumerate(alt_texts or []):
        where = names[index] if index < len(names) else str(index + 1)
        found.extend(check_one_alt_text(raw, band=band, where=where))

    return found


def check_one_alt_text(raw: Any, *, band: tuple[int, int] | None,
                       where: str) -> list[Finding]:
    """Every checkable rule ONE alt text breaks.

    Extracted so a repair pass can re-run exactly the rules that selected an
    alt text, rather than a second copy of them that reads the same and drifts
    (#1155, L263). Its acceptance check is literally this call: rewrite, re-run,
    refuse if any finding remains.

    `where` names the photograph this description belongs to, because a finding
    about one of eight descriptions is unusable without saying which one (L80).
    """
    alt = "" if raw is None else str(raw)
    found: list[Finding] = []

    if not alt.split():
        found.append(Finding(
            "alt_text_empty",
            "This photo has no alt text, so the picture is described to "
            "nobody who cannot see it.",
            where))
        # Nothing else can be said about a description that is not there,
        # and saying it is also too short would be a second finding about
        # one fault (L260).
        return found

    words = len(alt.split())
    if band and not (band[0] <= words <= band[1]):
        found.append(Finding(
            "alt_text_length",
            f"Alt text for this post should be {band[0]} to {band[1]} words.",
            f"{where}: {words} words. {alt[:90]}"))

    # The same matcher the blog path uses, not a copy of it (#1224).
    hits = inferred_state_hits(alt.lower())
    if hits:
        found.append(Finding(
            "alt_text_inferred_state",
            "Alt text describes what the camera recorded, not what someone "
            "felt.",
            f"{where}: {', '.join(hits)} in '{alt[:80]}'"))

    return found
