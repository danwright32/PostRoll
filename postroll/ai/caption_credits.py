"""The caption's handle and name rules, checked in code (#475).

Two rules in the caption prompt are the ones that cost real money when they
break, and both were asked for and never checked:

  * every handle in `tag_handles` and every name in `name_mentions` has to
    appear in the finished caption. These are the credits Dan told a client,
    a venue or a performer they would get;
  * no @ handle may appear that was not offered. Instagram resolves a handle
    to whoever owns it, so a guessed one tags a stranger, and the prompt calls
    that out as a hard rule precisely because the model can produce a
    plausible handle for any name it has been given.

Both are exactly checkable against lists the caller already holds, so they are
settled here rather than by asking the model whether it obeyed. A rule that
lives only in a prompt is a hope (#199, L27).

These REPORT rather than rewrite, for the reason blog_quality gives: nobody can
supply the handle that should have been there, and deleting an invented one out
of the middle of a sentence leaves a caption reading around a hole. Naming it
lets Dan fix it on the review screen in seconds, and the review screen is
already where a caption goes before it is posted.

The one place a repair IS available is the ban rewrite, which hands a caption
to a second model call and gets a new one back. There the original is still in
hand, so `generate_captions` refuses a rewrite that fails these checks and
keeps what it had, the same way it already refuses an empty one (L5).
"""

from __future__ import annotations

import re

from ..caption_blocks import is_handle_shaped
from .blog_findings import Finding

#: An @ handle as it appears in caption text. A dot is legal inside a handle
#: (@safa.wav) but never ends one, so the trailing punctuation of the sentence
#: it sits in is stripped separately by `norm_handle`.
HANDLE_RE = re.compile(r"@[A-Za-z0-9._]+")

#: Punctuation that can close the sentence a handle was written into.
_TRAILING = ".,;:!?)…"


def norm_handle(token: str) -> str:
    """Comparison form for a handle: no @, no case, no trailing punctuation.

    The handle book stores some entries bare and some with the @, and Instagram
    treats handles case insensitively, so neither difference is a fabricated
    handle and neither may read as one.
    """
    return str(token).strip().casefold().lstrip("@").rstrip(_TRAILING)


def malformed_tag_handles(tag_handles) -> list[str]:
    """Tag list entries that cannot be an Instagram handle at all (#899).

    A performer row carrying its company's display name in the handle field put
    "@DPR Dance" into a caption bound for Instagram, and this module read it as
    two separate defects, neither of them the real one: a stranger tag on the
    fragment `@dpr`, because `HANDLE_RE` cannot match a value containing a
    space, and a credit missing forever, because `@dpr dance` can never appear
    in a caption in a form anything here recognises.

    Both are findings about the TAG LIST, and the second is the worse kind: it
    can never be cleared by anything Dan does to the caption, so it would be
    reported on every future run of an event carrying that row (L111).

    First spelling kept, later case-insensitive repeats dropped: the problem is
    the entry, not how many lists it reached.
    """
    out: list[str] = []
    seen: set[str] = set()
    for raw in (tag_handles or []):
        text = str(raw).strip()
        if not text or is_handle_shaped(text):
            continue
        key = text.casefold()
        if key in seen:
            continue
        seen.add(key)
        out.append(text)
    return out


def _usable(tag_handles) -> list[str]:
    """The entries that can be compared against a caption at all."""
    return [h for h in (tag_handles or [])
            if str(h).strip() and is_handle_shaped(h)]


def _supplied_fragments(tag_handles) -> set[str]:
    """Every handle a malformed entry PUT IN FRONT OF THE MODEL.

    An entry that is not handle shaped still carries handle shaped pieces, and
    those are what a caption written from it contains: "@DPR Dance" is written
    into the caption whole and read back as `@dpr`, and an org field holding
    "@bludlineodyssey presented by @matchbookfestival" carries two real
    accounts. Accusing the caption of inventing any of them is accusing the
    model of a choice the pipeline made for it, and the finding that names the
    entry itself already says what is wrong.
    """
    fragments: set[str] = set()
    for entry in malformed_tag_handles(tag_handles):
        for token in HANDLE_RE.findall("@" + str(entry).lstrip("@")):
            key = norm_handle(token)
            if key:
                fragments.add(key)
    return fragments


def _offered(tag_handles) -> set[str]:
    return {norm_handle(h) for h in _usable(tag_handles) if str(h).strip()}


def foreign_handles(caption: str, *, tag_handles=None) -> list[str]:
    """Handles in the caption that were never offered, first appearance first.

    Reported once each however often they appear: the problem is the account,
    not the number of times it was named.
    """
    offered = _offered(tag_handles) | _supplied_fragments(tag_handles)
    found: list[str] = []
    seen: set[str] = set()
    for token in HANDLE_RE.findall(caption or ""):
        key = norm_handle(token)
        if not key or key in offered or key in seen:
            continue
        seen.add(key)
        found.append("@" + key)
    return found


def missing_credits(caption: str, *, tag_handles=None, name_mentions=None) -> list[str]:
    """Required handles and names absent from the caption, in the order given.

    Handles are compared as handles, so "@dciny" written mid sentence still
    counts. Names are compared as plain text, because that is exactly how the
    prompt asks for them to appear.
    """
    text = caption or ""
    present = {norm_handle(t) for t in HANDLE_RE.findall(text)}
    low = text.casefold()

    absent: list[str] = []
    # `_usable` rather than the raw list: an entry that is not handle shaped
    # cannot appear in a caption in a form this reads, so requiring it reports
    # it absent from every caption ever written, and no edit clears it (#899).
    # `malformed_tag_handles` names it once instead.
    for handle in _usable(tag_handles):
        key = norm_handle(handle)
        if key and key not in present:
            absent.append("@" + key)
    for name in name_mentions or []:
        wanted = str(name).strip()
        if wanted and wanted.casefold() not in low:
            absent.append(wanted)
    return absent


def credit_findings(caption: str, *, tag_handles=None, name_mentions=None) -> list[Finding]:
    """Everything either rule caught, in the shape the app already decodes.

    Ordered with the tag list first, then the invented handles: an entry that
    is not a handle is upstream of both other rules and explains what they
    would otherwise report as the caption's fault. After that, a missing credit
    is a caption Dan has to add a name to, while an invented one is already
    pointing at somebody else's account.
    """
    findings: list[Finding] = []
    for entry in malformed_tag_handles(tag_handles):
        findings.append(Finding(
            "caption_tag_list_not_a_handle",
            "Something that is not an Instagram handle was offered to this "
            "caption as one, so whoever it names has been credited by a "
            "mention that goes nowhere. Correct the handle on the performer "
            "or clear it, and they will be credited by name instead.",
            entry))
    for handle in foreign_handles(caption, tag_handles=tag_handles):
        findings.append(Finding(
            "caption_foreign_handle",
            "This caption tags a handle that was not on the tag list, so it "
            "may belong to somebody else. Check it or remove it.",
            handle))
    for credit in missing_credits(caption, tag_handles=tag_handles,
                                  name_mentions=name_mentions):
        findings.append(Finding(
            "caption_missing_credit",
            "A credit that was asked for is not in this caption.",
            credit))
    return findings


def rewrite_lost_a_credit(original: str, reworded: str, *,
                          tag_handles=None, name_mentions=None) -> list[str]:
    """Why a rewritten caption is worse than the one it replaces, or nothing.

    Judged against the ORIGINAL rather than against the tag lists alone: a
    credit the first pass already failed to include is a finding about that
    pass, and refusing every rewrite over it would leave the engagement bait
    the rewrite exists to remove. What is refused here is the rewrite MAKING it
    worse: losing a credit the original had, or introducing a handle it did not.
    """
    problems: list[str] = []

    had = {norm_handle(t) for t in HANDLE_RE.findall(original or "")}
    kept = {norm_handle(t) for t in HANDLE_RE.findall(reworded or "")}
    for handle in tag_handles or []:
        key = norm_handle(handle)
        if key and key in had and key not in kept:
            problems.append(f"dropped the required credit @{key}")
    for handle in sorted(kept - had):
        problems.append(f"introduced the handle @{handle}")

    low_before = (original or "").casefold()
    low_after = (reworded or "").casefold()
    for name in name_mentions or []:
        wanted = str(name).strip().casefold()
        if wanted and wanted in low_before and wanted not in low_after:
            problems.append(f"dropped the required credit {str(name).strip()}")
    return problems
