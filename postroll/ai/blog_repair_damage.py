"""Why a repaired blog post is worse than the one it replaces (#1129).

Dan's rule 1 for the repair pass is that repairs are SILENT: nothing on the
review panel says a repair happened, so nothing on the panel invites him to
check one. Every human check the old design rested on is gone, and this module
is what replaces it.

Pure text. No model call, and no import that can reach `run_prompt`, which is
why the prose predicates moved into `blog_prose` and the finding vocabulary into
`blog_findings`. A gate that could itself call a model is a gate nobody can
trust to be cheap, deterministic, or available.

`touched` is what the repair was LICENSED to change: a set of folded marker
filenames and a set of prose paragraph positions. Every check is scoped by it,
and each says what `touched` licenses it to ignore. Scoping only some of them
was the earlier draft's defect: check 2 then refused every photo swap, including
a correct one, and the swap's fallback would have looked like the design working
while the saving never happened once (L159, L142).

Ten reasons, each a distinct sentence naming its own cause (L11). An empty list
means the revision is not worse, which is not the same as it being better.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

from .ai_tells import strip_em_dashes
from .blog_prose import (
    block_holds_marker,
    prose_indices_with_second_person,
    prose_indices_without_contractions,
)
from .blog_quality import (
    ALT_MIN_WORDS,
    _fold_filename,
    _markers,
    _prose_paragraphs,
    check_blog_targeted,
)
from .caption_credits import rewrite_lost_a_credit


@dataclass(frozen=True)
class Touched:
    """What one repair attempt was allowed to change.

    `markers` holds FOLDED filenames, and it holds a swap's OUTGOING keys as
    well as its incoming ones: a swap replaces the filenames it was given, so
    both sides of that replacement are licensed.

    `paragraphs` indexes into the PROSE-only paragraph list, the same list
    `Target` uses, so adding or removing a photo marker does not renumber what
    a repair was licensed to touch.
    """
    markers: frozenset[str] = field(default_factory=frozenset)
    paragraphs: frozenset[int] = field(default_factory=frozenset)

    @classmethod
    def marker(cls, *names: str) -> "Touched":
        """The commonest case: one alt text rewrite, licensed by filename."""
        return cls(markers=frozenset(_fold_filename(n) for n in names))


#: Words carrying no identity, stripped from both sides before the retention
#: floor is measured. Deliberately small: the floor is calibrated against the
#: real corrections with THIS list in place, so growing it later without
#: re-measuring moves the floor's meaning without moving its number.
_STOPWORDS = frozenset("""
a an and are as at be been by for from had has have he her hers him his in into
is it its of on or our she that the their them there these they this to was
were with
""".split())

_WORD_RE = re.compile(r"[A-Za-z][A-Za-z'’]*")
_CAP_TOKEN_RE = re.compile(r"\b[A-Z][A-Za-z'’]*")
#: What ends a sentence, or opens one, so the token after it is capitalised for
#: position rather than because it names anybody.
_SENTENCE_EDGE = '.!?:;\n"“”([|'

#: How much of an alt text's own content a rewrite must keep, as a share.
#:
#: MEASURED, not chosen (L172, L316). Over the 55 known-good corrections this
#: repo holds (14 from the two correction fixtures, paired by folded filename,
#: plus the 41 differing pairs in the stored events), retention runs min 0.18,
#: p05 0.29, median 0.52, max 0.96.
#:
#: Re-measure rather than argue:
#:     venv/bin/python tools/measure_alt_text_retention.py
_RETENTION_FLOOR = 0.15

#: The floor that actually separates a husk from a rewrite, and why the share
#: above is not enough on its own.
#:
#: The plan asked for a share floor and said a husk's retention is "near zero".
#: Measured, it is not. Dan's tightest correction keeps 4 of 22 content words
#: (0.18) and is a genuine re-description: "A male performer wearing a sparkly
#: ATHENA headband and a red jersey" becomes "Joseph Medeiros in a rhinestone
#: ATHENA headband and red TELEMACHUS jersey". A husk written to pass every
#: other check, "Kate DiGangi at The Green Room 42 during the performance on
#: stage in the room with the band", keeps 2 of 11, which is 0.18 as well.
#:
#: So the SHARE cannot tell them apart, at any threshold, and a floor set to
#: catch the husk would refuse Dan's own work. Three more dimensions were
#: measured and none separated them either: new content words added, total
#: content words in the rewrite, and (kept + new) over the original's length.
#: What does separate them is the ABSOLUTE count against a long original: every
#: one of the 55 keeps at least 4 content words, and every husk keeps at most 2.
#:
#: Stated plainly, because it is the honest limit of this check: it refuses a
#: rewrite that carries almost none of a long original's words. A husk written
#: to carry three of them would pass, and nothing here would catch it. That is
#: why the acceptance check in the repair pass re-runs the alt text rules and
#: why `alt_text_empty` exists: three nets over one hole, none of them complete.
_RETENTION_LONG_ENOUGH = 8
_RETENTION_MIN_KEPT = 3

#: Below this many content words in the original there is nothing to measure.
_RETENTION_MIN_WORDS = 4

#: Written as escapes, never as the characters themselves. The pre push style
#: gate scans added lines for a dash or an emoji and cannot tell the line that
#: BANS one from a line that uses one, which is the gate working correctly. An
#: escape leaves the file holding no literal character for it to catch.
_DASHES_AND_EMOJI = re.compile(
    "[\u2014\u2013\u2012\u2015"                  # em, en, figure, horizontal
    "\U0001F300-\U0001FAFF\u2600-\u27BF\ufe0f]"  # emoji and their selector
)


def _content_words(text: str, *, drop: set[str]) -> list[str]:
    return [w for w in (t.casefold() for t in _WORD_RE.findall(text or ""))
            if w not in _STOPWORDS and w not in drop]


def _identity_tokens(*texts: Any) -> set[str]:
    """Every word the repair is allowed to keep saying, case folded."""
    out: set[str] = set()
    for text in texts:
        for word in _WORD_RE.findall(_flatten(text)):
            low = word.casefold()
            out.add(low)
            for suffix in ("'s", "’s", "s'", "s’"):
                if low.endswith(suffix):
                    out.add(low[:-len(suffix)])
    return out


def _flatten(value: Any) -> str:
    """Every string inside a program dict, a list of names, or a plain string."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return " ".join(_flatten(v) for v in value.values())
    if isinstance(value, (list, tuple, set, frozenset)):
        return " ".join(_flatten(v) for v in value)
    return str(value)


def _marker_map(body: str) -> dict[str, tuple[str, str]]:
    return {_fold_filename(name): (name, alt) for name, alt in _markers(body)}


def _marker_keys(body: str) -> list[str]:
    return [_fold_filename(name) for name, _alt in _markers(body)]


def _retained_share(before: str, after: str, *, drop: set[str]) -> tuple[float, int, int]:
    """How much of `before`'s own content `after` still carries.

    Measured in content words, which is the unit the meaning lives in. Lines and
    characters both move when a sentence is merely re-worded, and comparing in
    either would refuse a legitimate rewrite while passing a gutted one (L278).
    """
    was = _content_words(before, drop=drop)
    now = set(_content_words(after, drop=drop))
    if not was:
        return 1.0, 0, 0
    kept = sum(1 for w in was if w in now)
    return kept / len(was), kept, len(was)


def _introduced_names(prior_span: str, revised_span: str, *,
                      known: set[str]) -> list[str]:
    """Capitalised tokens the revision introduced that nothing can adjudicate.

    Narrowed to what the source data can actually answer for (L104, L93). The
    un-narrowed form, any capitalised token absent from the prior text plus the
    program plus the venue, is answered by every sentence opener: measured
    through this predicate over the 20 stored generated/final body pairs it
    fires on 16 of them, on words like "But", "When", "Those" and "I'm".

    So a token capitalised because it OPENS a sentence is not a candidate:
    nothing about its case says it names anybody, and the program data cannot
    adjudicate a common noun. A name introduced at the very start of a span is
    still caught by its second token, which is not sentence initial. A single
    invented word standing alone at the start is not caught, and that is the
    honest edge of what this can decide.

    Measured through the committed predicate over the 55 known-good corrections:
    0 fire, including Dan's correction of "the outdoor Wagner Park stage" to
    "the outdoor stage at Robert F. Wagner Jr. Park", which the un-narrowed form
    with an incomplete known set would have refused (#1137).
    """
    prior_words = _identity_tokens(prior_span)
    out: list[str] = []
    for match in _CAP_TOKEN_RE.finditer(revised_span or ""):
        before = (revised_span[:match.start()]).rstrip()
        if not before or before[-1] in _SENTENCE_EDGE:
            continue
        token = match.group(0)
        low = token.casefold()
        stems = {low} | {low[:-2] for suffix in ("'s", "’s", "s'", "s’")
                         if low.endswith(suffix)}
        if stems & known or stems & prior_words:
            continue
        out.append(token)
    return out


def blog_repair_damage(
        prior: str,
        revised: str,
        *,
        program: dict[str, Any] | None = None,
        venue: str = "",
        venue_context: str = "",
        org: str = "",
        photo_filenames: list[str] | None = None,
        touched: Touched | None = None,
        expected_marker_keys: list[str] | None = None,
) -> list[str]:
    """The reasons `revised` is worse than `prior`, or an empty list.

    `expected_marker_keys` is the swap path's manifest: the ordered folded
    filenames the post is supposed to end up placing. Given it, check 2 compares
    the touched markers against that rather than against the input, because a
    swap legitimately replaces the filenames it was given.

    `venue_context` is separate from `venue` because it has to be. Measured on
    the stored events: the Battery Dance Festival event carries an EMPTY venue
    and its real one, "Robert F. Wagner Jr. Park", only in `venueContext`, so a
    known set built from `venue` alone answers for the wrong event.
    """
    touched = touched or Touched()
    reasons: list[str] = []

    prior_markers, revised_markers = _marker_map(prior), _marker_map(revised)
    prior_prose, revised_prose = _prose_paragraphs(prior), _prose_paragraphs(revised)
    known = _identity_tokens(program, venue, venue_context, org, photo_filenames)

    # -- 1. a finding the repair introduced ----------------------------------
    #
    # A multiset of (code, target), never a set of codes. `alt_text_length` and
    # `alt_text_missing_venue` fire once per marker, so a second instance of an
    # already present code is the commonest way a whole body repair gets worse,
    # and a set cannot see it.
    #
    # Deliberately NOT scoped by `touched`, and this is looser than the plan in
    # exactly one direction. The plan said an untouched target may not change AT
    # ALL; this refuses only an INCREASE, anywhere. Checks 2, 3 and 4 already
    # hold every untouched span byte for byte, so the only way an untouched
    # marker's findings can move is a rule about the relationship BETWEEN
    # markers, and there that movement is downward: rewriting one marker can
    # clear `alt_text_repeated_opening` from two others. Refusing that would be
    # refusing the repair for working.
    def counted(body: str) -> dict[tuple[str, str, str, int], int]:
        out: dict[tuple[str, str, str, int], int] = {}
        for finding, target in check_blog_targeted(
                body, program=program, venue=venue,
                photo_filenames=photo_filenames):
            key = (finding.code, target.kind, target.key, target.index)
            out[key] = out.get(key, 0) + 1
        return out

    was, now = counted(prior), counted(revised)
    for key, count in sorted(now.items()):
        if count <= was.get(key, 0):
            continue
        code, kind, target_key, _index = key
        where = target_key or "the post"
        reasons.append(
            f"the repair introduced a {code} finding on {where}: it went from "
            f"{was.get(key, 0)} to {count}")

    # -- 2. the order of the markers it was not allowed to touch -------------
    #
    # The repo's only marker guard sorts (`ai_tells.markers_preserved_validator`),
    # so it cannot see a reorder at all. This compares the ordered list.
    kept_before = [k for k in _marker_keys(prior) if k not in touched.markers]
    kept_after = [k for k in _marker_keys(revised) if k not in touched.markers]
    if kept_before != kept_after:
        reasons.append(
            "the repair changed the order or the membership of the photo "
            f"markers it was not allowed to touch: {kept_before} became "
            f"{kept_after}")
    if expected_marker_keys is not None:
        got = _marker_keys(revised)
        want = [_fold_filename(k) for k in expected_marker_keys]
        if got != want:
            reasons.append(
                "the post does not place the photographs the swap was asked "
                f"for: expected {want}, got {got}")

    # -- 3. a retained marker that changed by one byte -----------------------
    for key, (name, alt) in prior_markers.items():
        if key in touched.markers:
            continue
        after = revised_markers.get(key)
        if after is None:
            continue  # already reported by check 2
        if after != (name, alt):
            reasons.append(
                f"the repair altered the marker for {name}, which it was not "
                "allowed to touch")

    # -- 4. a prose paragraph that changed by one byte -----------------------
    #
    # What finally verifies the swap prompt's own "Do NOT change any prose"
    # instruction, which nothing has ever verified: that path calls the model
    # with no validator at all.
    for i, paragraph in enumerate(prior_prose):
        if i in touched.paragraphs:
            continue
        if i >= len(revised_prose):
            reasons.append(f"the repair deleted prose paragraph {i}")
        elif revised_prose[i] != paragraph:
            reasons.append(
                f"the repair rewrote prose paragraph {i}, which it was not "
                "allowed to touch")
    if len(revised_prose) > len(prior_prose):
        reasons.append(
            f"the repair added {len(revised_prose) - len(prior_prose)} prose "
            "paragraph(s) that were not in the post")

    # -- 5. a touched alt text that lost what it was describing --------------
    #
    # The check the earlier draft did not have, and its absence made rule 9
    # reachable straight through the design (L283, L278). Checks 1 to 4 are all
    # negatives over the OUTPUT; nothing compared what a touched span RETAINED.
    #
    # An alt text gutted to a rule-satisfying husk ("Kate DiGangi at The Green
    # Room 42 during the performance on stage in the room", 15 words, describing
    # nothing the camera recorded) clears every alt rule with zero findings,
    # clears check 1 (fewer findings), clears checks 2 to 4 (the marker is
    # touched), and clears check 6, because that asks its question over the
    # WHOLE body and the performer's name survives elsewhere in the post.
    #
    # The venue and performer names are stripped from BOTH sides first, so a
    # rewrite is not credited for keeping the words every alt text has to carry.
    for key in sorted(touched.markers):
        before = prior_markers.get(key)
        after = revised_markers.get(key)
        if before is None or after is None:
            continue
        share, kept, total = _retained_share(before[1], after[1], drop=known)
        gutted = total >= _RETENTION_MIN_WORDS and (
            share < _RETENTION_FLOOR
            or (total >= _RETENTION_LONG_ENOUGH and kept < _RETENTION_MIN_KEPT))
        if gutted:
            reasons.append(
                f"the rewritten alt text for {after[0]} kept {kept} of the "
                f"{total} things the original said about the photograph "
                f"({share:.0%}), below the floor measured on Dan's own "
                "corrections: it describes the picture less than the text it "
                "replaced")
        if len(strip_em_dashes(after[1]).split()) < ALT_MIN_WORDS:
            reasons.append(
                f"the rewritten alt text for {after[0]} is shorter than the "
                f"{ALT_MIN_WORDS} word minimum")

    # -- 6. a credit the repair dropped, or a handle it introduced -----------
    #
    # Asked as the blog's own question, through the caption checker that already
    # implements it, rather than through a second copy (L263).
    #
    # `tag_handles=[]` disables its dropped-handle half deliberately: a blog has
    # no required tag list, and the half that matters here is the introduced
    # one, which fires on an @token present in the revision and absent from the
    # input. `name_mentions` carries every name a blog can lose.
    #
    # This answers the NAME-DROPPED half of rule 9. Check 5 answers the
    # description-gutted half; neither is enough alone.
    names = _every_name(program, venue, venue_context, org)
    for problem in rewrite_lost_a_credit(prior, revised, tag_handles=[],
                                         name_mentions=names):
        reasons.append(f"the repair {problem}")

    # -- 7. a capitalised name the source data cannot account for ------------
    for key in sorted(touched.markers):
        before, after = prior_markers.get(key), revised_markers.get(key)
        if after is None:
            continue
        introduced = _introduced_names(before[1] if before else "", after[1],
                                       known=known | _identity_tokens(prior))
        if introduced:
            reasons.append(
                f"the rewritten alt text for {after[0]} names "
                f"{', '.join(sorted(set(introduced)))}, which appears nowhere "
                "in the post it replaced or in the program data")

    # -- 8. second person or a contraction free paragraph put back -----------
    #
    # `_fix_second_person` and `_fix_missing_contractions` run once, at
    # generation, and never again, so anything a repair puts back ships. Their
    # own predicates, not a copy (L263).
    for label, predicate in (
            ("addresses the reader", prose_indices_with_second_person),
            ("has no contraction in it", prose_indices_without_contractions)):
        added = set(predicate(revised)) - set(predicate(prior))
        if added:
            reasons.append(
                f"the repair left a paragraph that {label}, which the "
                "generation pass had already fixed and never runs again")

    # -- 9. a dash or an emoji ----------------------------------------------
    introduced_marks = sorted(set(_DASHES_AND_EMOJI.findall(revised))
                              - set(_DASHES_AND_EMOJI.findall(prior)))
    if introduced_marks:
        reasons.append(
            "the repair introduced a dash or emoji that Dan's writing rules "
            f"forbid: {' '.join(introduced_marks)}")

    # -- 10. a paragraph holding an inline marker ----------------------------
    #
    # Checked once here, on the span, rather than remembered by every repairer
    # (L274). #998 recorded why: rewriting such a paragraph sends the marker to
    # a model and splices back whatever comes out, and a marker dropped that way
    # is a photograph silently gone from the post with nothing reported.
    for i in sorted(touched.paragraphs):
        if i < len(prior_prose) and block_holds_marker(prior_prose[i]):
            reasons.append(
                f"the repair was licensed to rewrite prose paragraph {i}, which "
                "holds a photo marker inline; rewriting it can lose the "
                "photograph with nothing reported (#998)")

    return reasons


def _every_name(program: dict[str, Any] | None, venue: str,
                venue_context: str, org: str) -> list[str]:
    """Every name a blog post can lose, for check 6's question.

    Performers, ensembles named in the program, the organisation and the venue.
    Single words are dropped: a one word "name" matches inside other words and
    would have the check refusing rewrites over a coincidence (L104).
    """
    names: list[str] = []
    for person in (program or {}).get("performers") or []:
        for key in ("name", "ensemble", "group"):
            value = str((person or {}).get(key, "") or "").strip()
            if value:
                names.append(value)
    for extra in (org, venue, venue_context):
        value = str(extra or "").strip()
        if value:
            names.append(value)
    return [n for n in dict.fromkeys(names) if len(n.split()) > 1]
