"""Worked examples for the alt text repair prompt (#1161).

Phase 5c specified few shot examples and the first build sent rules only. These
are three of Dan's OWN corrections, taken verbatim from
`tests/fixtures/blog_corrections/`, not written to look like his.

They are held here rather than read from the fixtures at run time for one
reason: the fixtures are test data, and a prompt that reads them makes the
shipped behaviour depend on a directory that exists to be edited freely.
`tests/test_blog_repair_examples.py` closes that gap by asserting every pair
below is genuinely one of the recorded corrections, so this file cannot drift
into examples nobody made.

Every example is FILTERED, not merely chosen. A prompt that bans a thing and
then demonstrates it teaches the demonstration, and the demonstration outweighs
the instruction (L270). `expectations.json` records in Dan's own words that his
corrected `-92` marker still fires `alt_text_inferred_state` ("grinning toward
the audience"), which is one of the codes this repairer exists to fix, so that
correction is deliberately absent. The test asserts the filter removes
something, because a filter that removes nothing is a comment.

The three cover different failures on purpose: an inferred inner state, an
appearance descriptor standing in for a name, and a description far over the
word band that had to lose words without losing the picture.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Example:
    """One correction, with the event it belongs to.

    `venue` and `performers` are carried because the rules the example has to
    clear are relative to them: `alt_text_missing_venue` and
    `alt_text_missing_performer` cannot be judged without knowing which venue
    and which people the post was about.
    """
    before: str
    after: str
    venue: str
    performers: tuple[str, ...]


_BLUDLINE = ("Fermin Suero, Jr.", "Pete White", "Phil Richardson",
             "Alaman Diadhiou", "Ladibree", "Safa", "Alex Manuel",
             "Taylor Fagins", "Maxwell Beer", "Mitch Marois")
_GREENWICH = "Greenwich House Theater"

EXAMPLES: tuple[Example, ...] = (
    # An inferred inner state ("deeply focused") and a person named by
    # appearance ("A guitarist in a blue striped jacket").
    Example(
        before="A guitarist in a blue striped jacket bent forward over a pale "
               "green electric guitar, eyes closed, deeply focused, with "
               "another musician partially visible behind him",
        after="Pete White bent over a pale green electric guitar in a blue "
              "striped jacket at Greenwich House Theater, another musician "
              "behind him",
        venue=_GREENWICH, performers=_BLUDLINE),
    # A person named by appearance and gender ("A bearded performer"), where
    # the clothing stays because it is what the photograph shows.
    Example(
        before="A bearded performer in a white shirt and orange head "
               "covering, arms raised with hands spread open, mouth open "
               "mid-performance, with another performer at a mic stand "
               "slightly behind him",
        after="Fermin Suero, Jr. in a white shirt and orange head covering, "
              "arms raised and hands open mid-verse, at Greenwich House "
              "Theater",
        venue=_GREENWICH, performers=_BLUDLINE),
    # Thirty five words down to nineteen, keeping what the picture shows.
    Example(
        before="Five performers on a darkly lit stage in a wide shot, arms "
               "raised and gesturing expressively at mic stands, with chairs "
               "and set pieces behind them and a blue-lit wall of frames in "
               "the background",
        after="Wide view of five BLUDLINE performers at mic stands under blue "
              "stage light at Greenwich House Theater, arms raised",
        venue=_GREENWICH, performers=_BLUDLINE),
)
