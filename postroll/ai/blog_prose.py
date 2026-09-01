"""Pure text questions about a blog body, reachable without a model runner.

These three predicates decide which paragraphs a rewriter may touch, and they
lived in `generate_blog.py` beside the rewriters that ask them. That file
imports `run_json_prompt`, so any module wanting to ask the same questions had
to import a model runner to do it.

The damage gate (#1129) asks all three, and it is defined by having no model
call and no import that can reach one: it runs over a repair's output to decide
whether the repair made the post worse, and a gate that could itself call a
model is a gate nobody can trust to be cheap or deterministic.

So the predicates move here and `generate_blog` imports them back. One
definition rather than two that read the same and drift apart (L263): two
same-named functions on either side of a boundary are never compared, and every
caller on each side reads as correct in isolation the whole time.

The names lose their leading underscore, because they are shared now.
`generate_blog` keeps its private aliases so its own call sites and the guard
mutation entries anchored on them are untouched.
"""

from __future__ import annotations

import re


# --- Contractions ------------------------------------------------------------
# Dan's voice uses contractions throughout. Possessive 's does not count as one,
# which is why the third branch lists the words rather than matching any 's.
CONTRACTION_RE = re.compile(
    r"\b\w+n['’]t\b"                          # didn't, wasn't, isn't, don't
    r"|\b\w+['’](?:m|re|ve|ll|d)\b"           # I'm, they're, I've, we'll, I'd
    r"|\b(?:it|that|there|here|what|he|she|who|let|where|how|"
    r"nothing|something)['’]s\b",             # it's, that's, there's (not poss.)
    re.IGNORECASE,
)

# --- Second person -----------------------------------------------------------
# The closing call to action and quoted speech are allowed to address the
# reader; generic "you" in the body is not.
SECOND_PERSON_RE = re.compile(r"\b(?:you|your|you're|yours)\b", re.IGNORECASE)
QUOTED_SPAN_RE = re.compile(r'["“][^"”]*["”]')


def prose_indices_without_contractions(body: str) -> list[int]:
    """Positions in ``body.split("\\n\\n")`` of prose paragraphs with no
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
        if not CONTRACTION_RE.search(s):
            out.append(i)
    return out


def paragraphs_without_contractions(body: str) -> list[str]:
    """Prose paragraphs (not [PHOTO:] markers) that contain no contraction.
    Possessive 's does not count as a contraction."""
    offenders: list[str] = []
    for p in body.split("\n\n"):
        s = p.strip()
        if not s or s.startswith("[PHOTO:"):
            continue
        if not CONTRACTION_RE.search(s):
            offenders.append(s)
    return offenders


def prose_indices_with_second_person(body: str) -> list[int]:
    """Positions in ``body.split("\\n\\n")`` of prose paragraphs that address
    the reader, excluding the closing call to action. See
    `prose_indices_without_contractions` for why positions and not text.
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
        unquoted = QUOTED_SPAN_RE.sub("", parts[i].strip())
        if SECOND_PERSON_RE.search(unquoted):
            out.append(i)
    return out


def paragraphs_with_second_person(body: str) -> list[str]:
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
        unquoted = QUOTED_SPAN_RE.sub("", p)
        if SECOND_PERSON_RE.search(unquoted):
            offenders.append(p)
    return offenders


def block_holds_marker(block: str) -> bool:
    """Whether a paragraph carries a photo marker ANYWHERE in it (#998).

    CONTAINS, not starts with. Every index builder here already excludes a
    block that STARTS with a marker, so a refusal keyed on the start can never
    fire, and the case that actually reaches the rewriters is the inline one: a
    marker part way through a paragraph, which is prose to the index builders
    and a marker to everything else.

    The bare opening rather than the full `[PHOTO: name | alt]` pattern,
    because a marker missing its pipe is not something a rewriter may hand to a
    model either. It still names a photograph, and losing it loses the picture
    just the same.

    One predicate for every rewriter and for the damage gate, so there is one
    definition of this question rather than several that read the same and can
    drift (L263).
    """
    return "[PHOTO:" in block
