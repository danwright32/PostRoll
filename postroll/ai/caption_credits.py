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

from .blog_quality import Finding

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


def _offered(tag_handles) -> set[str]:
    return {norm_handle(h) for h in (tag_handles or []) if str(h).strip()}


def foreign_handles(caption: str, *, tag_handles=None) -> list[str]:
    """Handles in the caption that were never offered, first appearance first.

    Reported once each however often they appear: the problem is the account,
    not the number of times it was named.
    """
    offered = _offered(tag_handles)
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
    for handle in tag_handles or []:
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

    Ordered with the invented handles first: a missing credit is a caption Dan
    has to add a name to, while an invented one is already pointing at somebody
    else's account.
    """
    findings: list[Finding] = []
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
