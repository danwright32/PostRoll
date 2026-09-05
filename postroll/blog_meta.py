"""The post metadata that is not the post: SEO description and details block.

Every generated post ships ``<meta name="description" content="">``. Squarespace
falls back to ``og:description``, which takes the opening prose, so the summary
search engines and AI crawlers see for the Whitacre post is "The hall wasn't
open yet. Singers in black were already out on 57th Street...". Good writing,
useless as a summary. The one hand-written post on the site that HAS a
description proves the mechanism: filling the field fixes both tags (#283).

There is also no plain factual statement anywhere on a post of who photographed
what, where and when. ``BLOG_STRUCTURE`` bans that opening deliberately and
correctly, which is why the fact block has to come from somewhere else.

**Neither string may live inside the post body.** Three things break if it does,
all confirmed by reading the source:

1. ``_fix_missing_contractions`` (``postroll/ai/generate_blog.py``) sends every
   prose paragraph without a contraction to Claude to be reworded. A fact block
   never has one, so deterministic code would hand it to an LLM to rewrite.
2. The second-person guard exempts the LAST prose paragraph, because the CTA is
   allowed to say "your season". A block after the CTA makes the CTA no longer
   last, so the guard starts rewriting the closing line of every revised post.
3. ``blog_quality`` counts any non-``[PHOTO:`` block as prose, and the
   invented-number check then flags the date. The code already records what
   that costs: "flagging them is what taught Dan to ignore this check (#226)".

So these are separate fields, rendered at copy and export time only, and a test
derives from the source that nothing under ``postroll/ai`` imports this module.

Mirrors ``PostRollApp/Sources/Services/BlogMeta.swift``. The two are kept in
parity by hand, so ``tests/fixtures/blog_meta.json`` states the cases once and
both sides assert against it (#104, #186).
"""

from __future__ import annotations

from typing import Optional

#: Squarespace shows a description between these lengths. Outside the band the
#: field is either refused or truncated mid-sentence, and neither is visible
#: from inside the app, so `check_description` raises rather than shipping one.
SEO_MIN_CHARS = 50
SEO_MAX_CHARS = 300

#: Closes the description. Constant rather than derived, and long enough on its
#: own that the 50 character floor cannot be breached by a sparse event.
BRAND_TAIL = "Concert and theater photography in New York by Dan Wright."

PHOTOGRAPHER = "Dan Wright"

#: Month names spelled out here rather than taken from a locale formatter. Both
#: languages must produce the same bytes, and a locale-dependent month name is
#: exactly the drift the shared fixture exists to prevent.
MONTHS = (
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
)

#: How each shoot type is named in prose. The prose has to match what Dan
#: actually witnessed: calling a photo call a performance is a factual error
#: about the evening, not a wording preference.
#:
#: Keys are `ShootType.pythonValue` in `PostRollApp/Sources/Models/Event.swift`.
#: An unmapped value raises rather than printing a raw enum name into the page
#: metadata, so a case added on the Swift side and not mirrored here is caught.
SHOOT_TYPE_LABELS = {
    "performance": "Performance",
    "photo_call": "Photo call",
    "rehearsal": "Rehearsal",
    "rehearsal_and_performance": "Rehearsal and performance",
}

#: The characters the global writing rule bans, as escapes so this file has
#: nothing for the pre-push style hook to catch. They are stripped at intake
#: because the hook only ever reads source, never runtime output: an event name
#: Dan typed with an em dash would otherwise ship one into the page metadata.
_EM_DASH = "\u2014"
_EN_DASH = "\u2013"


class DescriptionOutOfBand(ValueError):
    """A description that Squarespace would refuse or truncate.

    Its own type rather than a bare ValueError so a caller can tell a length
    problem from a malformed date, and the message names the length measured
    because "the description is wrong" is not an actionable message.
    """


def check_description(text: str) -> str:
    """Return `text`, or raise if it is outside Squarespace's band.

    Fails loud rather than returning a truncated or padded string: a silently
    corrected description is indistinguishable from a correct one, and the
    field is invisible from inside the app.
    """
    length = len(text)
    if length < SEO_MIN_CHARS or length > SEO_MAX_CHARS:
        raise DescriptionOutOfBand(
            f"description is {length} characters; Squarespace shows "
            f"{SEO_MIN_CHARS} to {SEO_MAX_CHARS}: {text!r}")
    return text


def _clean(raw: Optional[str]) -> str:
    """Trim, and replace banned dashes with punctuation that is allowed.

    A spaced dash is a sentence break, so it becomes a comma; a tight one joins
    two words, so it becomes a space. Stripped rather than deleted, so the
    words on either side survive.
    """
    text = (raw or "").strip()
    for dash in (_EM_DASH, _EN_DASH):
        text = text.replace(f" {dash} ", ", ")
        text = text.replace(dash, " ")
    return " ".join(text.split())


def format_date(iso: str) -> str:
    """`2026-04-04` becomes `April 4, 2026`.

    Refuses anything it cannot read rather than printing it raw: a malformed
    date reaching the description would be published as the summary of the post.
    """
    parts = (iso or "").strip().split("-")
    if len(parts) != 3:
        raise ValueError(f"date must be ISO yyyy-mm-dd, got {iso!r}")
    try:
        year, month, day = (int(p) for p in parts)
    except ValueError:
        raise ValueError(f"date must be ISO yyyy-mm-dd, got {iso!r}") from None
    if not 1 <= month <= 12 or not 1 <= day <= 31:
        raise ValueError(f"date is not a real date: {iso!r}")
    return f"{MONTHS[month - 1]} {day}, {year}"


def shoot_type_label(shoot_type: str) -> str:
    """How this shoot is named in prose, or a raise if it is not a known one."""
    label = SHOOT_TYPE_LABELS.get((shoot_type or "").strip())
    if label is None:
        raise ValueError(
            f"unknown shoot type {shoot_type!r}; known: "
            f"{sorted(SHOOT_TYPE_LABELS)}")
    return label


def _org_worth_naming(name: str, org: str, venue: str) -> str:
    """The org, unless naming it would just repeat something already said.

    Two cases, both of which read as a stutter in a one-sentence summary:
    an org with the same name as the event (the rule
    `postroll/media/brand_text.detail_lines` already applies to the templates),
    and an org with the same name as the venue, which is every resident company
    at its own theater.
    """
    if not org:
        return ""
    folded = org.casefold()
    if folded == name.casefold() or folded == venue.casefold():
        return ""
    return org


def _venue_phrase(venue: str, venue_context: str) -> str:
    """`Stern Auditorium, Carnegie Hall`, or whichever half exists."""
    return ", ".join(part for part in (venue_context, venue) if part)


def _compose(*, lead: str, name: str, org: str, venue_phrase: str,
             date_display: str) -> str:
    text = lead
    if name:
        text += f" of {name}"
    if org:
        # No leading comma when there is no name, or the sentence opens with
        # "photographs , presented by".
        text += f", presented by {org}" if name else f" presented by {org}"
    if venue_phrase:
        text += f" at {venue_phrase}"
    return f"{text}, {date_display}. {BRAND_TAIL}"


def seo_description(*, name: str, org: str, venue: str, venue_context: str,
                    date: str, shoot_type: str) -> str:
    """The `<meta name="description">` for one post, always inside the band.

    Shortens by a declared ladder rather than a blind truncation, so what gets
    dropped is the least useful fact rather than whatever happened to be last:
    the room goes first, then the organisation, and only then is the event name
    cut at a word boundary. The date and venue always survive.
    """
    name = _clean(name)
    org = _clean(org)
    venue = _clean(venue)
    venue_context = _clean(venue_context)
    lead = f"{shoot_type_label(shoot_type)} photographs"
    date_display = format_date(date)
    org = _org_worth_naming(name, org, venue)

    ladder = (
        (name, org, _venue_phrase(venue, venue_context)),
        (name, org, _venue_phrase(venue, "")),
        (name, "", _venue_phrase(venue, "")),
    )
    for try_name, try_org, try_venue in ladder:
        text = _compose(lead=lead, name=try_name, org=try_org,
                        venue_phrase=try_venue, date_display=date_display)
        if len(text) <= SEO_MAX_CHARS:
            return check_description(text)

    # Still too long, so the event name itself is the problem. Cut it to the
    # budget the rest of the sentence leaves, at a word boundary, so the
    # summary never ends mid-word.
    fixed = len(_compose(lead=lead, name="", org="",
                         venue_phrase=_venue_phrase(venue, ""),
                         date_display=date_display))
    budget = SEO_MAX_CHARS - fixed - len(" of ")
    trimmed = name[:max(budget, 0)].rsplit(" ", 1)[0].rstrip(" ,.")
    return check_description(_compose(
        lead=lead, name=trimmed, org="",
        venue_phrase=_venue_phrase(venue, ""), date_display=date_display))


#: What a search result actually shows. Google truncates around 60 characters
#: and Squarespace accepts 100, so the useful ceiling is the smaller one: a
#: title cut by the search engine loses the photographer, which is the half the
#: page is trying to be found for (#1368).
SEO_TITLE_MAX_CHARS = 60


class TitleTooLong(ValueError):
    """A title the ceiling could not be met for, raised rather than shipped."""


def check_title(text: str) -> str:
    """A title inside the ceiling, or a refusal naming the length it measured.

    Raised rather than returned and truncated: a title cut by Squarespace is
    cut where the character count falls rather than where the sentence ends,
    and nothing inside the app would show that it happened (#1368, L12).
    """
    if len(text) > SEO_TITLE_MAX_CHARS:
        raise TitleTooLong(
            f"title is {len(text)} characters, over the "
            f"{SEO_TITLE_MAX_CHARS} a search result shows: {text!r}")
    return text


def seo_title(*, name: str, org: str, venue: str) -> str:
    """The page title for one post, always inside the ceiling.

    Squarespace leaves this field empty by default and builds the page title
    from the post title and the site's title format, and PostRoll's post titles
    are shaped for the blog rather than for a search result: a long venue name
    pushes the photographer and the event off the end (#1368).

    Three facts, in the order somebody searching would recognise them: what the
    event was, where it was, and who photographed it. Shortened by a declared
    ladder rather than a blind cut, so the venue goes before the photographer
    does and the name is cut last, at a word boundary.

    The organisation stands in for a missing event name rather than leaving a
    hole, and a post with neither is still a correct shorter title rather than
    a string with an empty half (L67).
    """
    name = _clean(name)
    org = _clean(org)
    venue = _clean(venue)
    subject = name or _org_worth_naming(name, org, venue) or ""

    ladder = (
        (subject, venue, True),
        (subject, "", True),
        (subject, venue, False),
        (subject, "", False),
    )
    for try_subject, try_venue, credited in ladder:
        text = _compose_title(try_subject, try_venue, credited)
        if text and len(text) <= SEO_TITLE_MAX_CHARS:
            return check_title(text)

    # The subject itself is the problem, so it is cut to the budget the rest
    # leaves, at a word boundary, and never mid word.
    fixed = len(_compose_title("", "", True))
    trimmed = subject[:max(SEO_TITLE_MAX_CHARS - fixed, 0)]
    trimmed = trimmed.rsplit(" ", 1)[0].rstrip(" ,.") if " " in trimmed else trimmed
    return check_title(_compose_title(trimmed, "", True))


def _compose_title(subject: str, venue: str, credited: bool) -> str:
    """`Perpetual Light at Carnegie Hall | Dan Wright`, or whichever half is
    there. Empty when there is nothing to name at all, which the caller reads
    as this rung of the ladder not applying."""
    left = " at ".join(part for part in (subject, venue) if part)
    if not left:
        return PHOTOGRAPHER if credited else ""
    return f"{left} | {PHOTOGRAPHER}" if credited else left


def details_block(*, name: str, org: str, venue: str, venue_context: str,
                  date: str, shoot_type: str, event_url: str) -> str:
    """The plain factual statement of who photographed what, where and when.

    One `label: value` per line. A line whose value is missing is omitted
    entirely rather than printed empty: a label with nothing after it reads as
    a fact that failed to load rather than one the event does not have.
    """
    name = _clean(name)
    org = _clean(org)
    venue = _clean(venue)
    venue_context = _clean(venue_context)
    lines = [
        ("Event", name),
        ("Presented by", _org_worth_naming(name, org, venue)),
        ("Venue", _venue_phrase(venue, venue_context)),
        ("Date", format_date(date)),
        ("Photographed", shoot_type_label(shoot_type)),
        # The event page, which is where the program lives. Not the
        # photographer's own site: this block is rendered ON that site.
        ("Program", _clean(event_url)),
        ("Photographer", PHOTOGRAPHER),
    ]
    return "\n".join(f"{label}: {value}" for label, value in lines if value)
