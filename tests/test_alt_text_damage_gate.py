"""One rewritten alt text, judged by the rules the blog gate already applies
(#1155).

The blog repair pass refuses a rewrite that describes the photograph less than
the text it replaced, that introduces a name nothing can adjudicate, or that
carries a dash or an emoji. Those rules are about ONE alt text against its
predecessor, and they were reachable only through `blog_repair_damage`, which
takes a whole body of markers.

The caption paths have alt texts in a list and no markers at all, so a caption
repairer either got the same rules or a second set that reads the same and
drifts (L263, L370). It gets these.

The constants stay where they were measured: `_RETENTION_FLOOR` and its
companions come from 55 of Dan's own corrections, and this shares them rather
than choosing new ones.
"""

from __future__ import annotations

from postroll.ai.blog_repair_damage import alt_text_damage


def test_an_ordinary_rewrite_is_not_refused():
    """The control. A gate that refuses every rewrite refuses nothing, because
    nothing ever gets past it to be judged (L159).

    Dan's own tightest correction, from the 55 the floor was measured on: it
    keeps 4 of 22 content words and is a genuine re-description rather than a
    husk. The programme carries the performer and the piece, which is what
    makes the two proper nouns adjudicable.
    """
    assert alt_text_damage(
        "A male performer wearing a sparkly ATHENA headband and a red jersey",
        "Joseph Medeiros in a rhinestone ATHENA headband and red TELEMACHUS jersey",
        program={"performers": [{"name": "Joseph Medeiros"}],
                 "pieces": [{"title": "TELEMACHUS"}]},
        venue="The Green Room 42") == []


def test_a_husk_that_carries_almost_none_of_the_original_is_refused():
    """The failure the retention floor was measured for: a rewrite that clears
    every rule while describing nothing the camera recorded."""
    reasons = alt_text_damage(
        "Kate DiGangi in a black dress at a grand piano, singing into a "
        "handheld microphone under a spotlight",
        "Kate DiGangi at The Green Room 42 during the performance on stage",
        program={"performers": [{"name": "Kate DiGangi"}]},
        venue="The Green Room 42")

    assert reasons, "a husk cleared the gate"
    assert "describes the picture less" in " ".join(reasons)


def test_a_name_the_rewrite_invented_is_refused():
    """Nothing in the event data can adjudicate a name that was not there, and
    an invented one in alt text is a claim about who is in the photograph."""
    reasons = alt_text_damage(
        "A dancer in a red jersey lifting one arm on a dark stage",
        "A dancer in a red jersey beside Marcus Webb on a dark stage",
        program={"performers": [{"name": "Joseph Medeiros"}]},
        venue="The Green Room 42")

    assert any("Marcus" in reason or "Webb" in reason for reason in reasons), reasons


def test_a_name_the_programme_knows_is_not_an_invention():
    assert alt_text_damage(
        "A dancer in a red jersey lifting one arm on a dark stage",
        "Joseph Medeiros in a red jersey lifting one arm on a dark stage",
        program={"performers": [{"name": "Joseph Medeiros"}]},
        venue="") == []


def test_a_dash_or_an_emoji_the_rewrite_introduced_is_refused():
    # The dash is an ESCAPE, never the character. The pre push style gate reads
    # added lines and cannot tell the line that tests for one from the line
    # that uses one, which is the gate working correctly.
    reasons = alt_text_damage(
        "A dancer in a red jersey on a dark stage",
        "A dancer in a red jersey \u2014 on a dark stage",
        program=None, venue="")

    assert any("dash" in reason for reason in reasons), reasons


def test_a_short_original_is_not_measured_for_retention():
    """Below a handful of content words there is nothing to measure, and a
    floor applied to two words would refuse every rewrite of a stub.

    The rewrite deliberately introduces no proper noun: this is about the
    retention rule alone, and a name would be refused by the rule above it,
    which would make this pass for the wrong reason (L159).
    """
    assert alt_text_damage("A dancer.",
                           "a dancer mid leap on a dark stage under one light",
                           program=None, venue="") == []
