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
