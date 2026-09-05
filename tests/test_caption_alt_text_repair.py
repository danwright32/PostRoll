"""The caption alt text checks can repair themselves (#1155).

The blog checks repair and say what they tried; the caption checks could only
report. Both sides already share `Finding` and `finding_entry`, so the
vocabulary was common while the behaviour was not, and Phase 4 widened the
shared payload with a `repair` field that every caption finding carried empty.

This is the blog repairer's shape on a caption's alt texts: the rules that
SELECTED an alt text are the rules that accept the rewrite, the damage gate
that protects a blog alt text protects this one, and every seam the blog pass
takes (the runner, the clock, the deadline) is taken here so no test reaches a
model or waits on one.

The states are the blog's five and mean the same things, because they invite
the same actions: `tried` says the app will not get it next time either,
`blocked` says try again.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image

from postroll.ai.blog_findings import RepairState
from postroll.ai.caption_repair import repair_caption_alt_texts

BAND = (12, 25)


@pytest.fixture
def photo(tmp_path) -> str:
    path = tmp_path / "DSC4821.jpg"
    Image.new("RGB", (60, 40), (40, 60, 80)).save(path)
    return str(path)


def clock():
    """A clock that does not move, so a deadline is whatever the test says."""
    return 1000.0


def repair(alt_texts, *, photo_paths, answers=None, band=BAND, deadline=9_000.0,
           program=None, venue="The Green Room 42", say=None):
    """Drive the pass with a scripted model."""
    replies = list(answers or [])

    def runner(_prompt, **_kwargs):
        if not replies:
            raise AssertionError("the pass asked for more rewrites than the "
                                 "test scripted")
        answer = replies.pop(0)
        if isinstance(answer, Exception):
            raise answer
        return {"alt": answer}

    return repair_caption_alt_texts(
        alt_texts, band=band, photo_paths=photo_paths,
        program=program or {"performers": [{"name": "Kate DiGangi"}]},
        venue=venue, runner=runner, now=clock, deadline=deadline, say=say)


# ── it repairs what it selects ───────────────────────────────────────────────


def test_a_short_alt_text_is_rewritten_and_the_finding_goes(photo):
    short = "Kate at the piano"
    good = ("Kate DiGangi at a grand piano singing into a handheld microphone "
            "under a single spotlight on a dark stage")

    outcome = repair([short], photo_paths=[photo], answers=[good])

    assert outcome.alt_texts == [good]
    assert outcome.states == {0: RepairState.REPAIRED}
    assert outcome.ran is True


def test_an_alt_text_that_breaks_nothing_is_never_sent(photo):
    fine = ("Kate DiGangi at a grand piano singing into a handheld microphone "
            "under a single spotlight")

    outcome = repair([fine], photo_paths=[photo], answers=[])

    assert outcome.selected == []
    assert outcome.alt_texts == [fine]


def test_a_rewrite_that_still_breaks_the_rule_is_refused(photo):
    """The acceptance check is the selecting check, re-run. A rewrite that
    still fails it is `tried`: the app had its go and did not get there."""
    short = "Kate at the piano"

    outcome = repair([short], photo_paths=[photo],
                     answers=["Kate at the piano still", "Kate again briefly"])

    assert outcome.states == {0: RepairState.TRIED}
    assert outcome.alt_texts == [short], "the refused rewrite was kept"


def test_a_husk_is_refused_by_the_damage_gate(photo):
    """A rewrite can satisfy every rule and describe nothing. That is what the
    shared gate is for, and it is the same one the blog pass uses."""
    # The original breaks the length rule, so the pass selects it. The husk
    # SATISFIES that rule, which is the point: it clears the check that
    # selected it and describes nothing the camera recorded, so only the gate
    # can refuse it.
    original = ("Kate DiGangi in a black dress at a grand piano singing into a "
                "handheld microphone under a spotlight")
    husk = "Kate DiGangi at The Green Room 42 during the performance on stage"

    outcome = repair([original], photo_paths=[photo], answers=[husk, husk],
                     band=(10, 16))

    assert outcome.states == {0: RepairState.TRIED}
    assert outcome.alt_texts == [original]


# ── what it does when it cannot ──────────────────────────────────────────────


def test_a_photograph_that_is_not_on_disk_blocks_rather_than_tries(tmp_path):
    """Blocked, not tried: nothing was paid for, there was nothing to attach,
    and this is worth trying again once the file is back (L11)."""
    outcome = repair(["Kate at the piano"],
                     photo_paths=[str(tmp_path / "gone.jpg")], answers=[])

    assert outcome.states == {0: RepairState.BLOCKED}


def test_a_model_that_cannot_be_reached_blocks(photo):
    from postroll.ai.claude_client import ClaudeError

    outcome = repair(["Kate at the piano"], photo_paths=[photo],
                     answers=[ClaudeError("network")])

    assert outcome.states == {0: RepairState.BLOCKED}


def test_an_alt_text_with_no_photograph_at_all_is_unavailable(photo):
    """The revise path's shape: it carries filenames and no paths, so there is
    no photograph to attach and never will be on that run. Different from a
    file that has gone missing, which is worth retrying (#1132)."""
    outcome = repair(["Kate at the piano"], photo_paths=[], answers=[])

    assert outcome.states == {0: RepairState.UNAVAILABLE}


def test_the_deadline_stops_the_pass_rather_than_the_process(photo):
    """Everything left is `not_reached`, which is a different answer from the
    app having tried and failed."""
    outcome = repair(["Kate at the piano", "Kate again here"],
                     photo_paths=[photo, photo], answers=[], deadline=1000.0)

    assert set(outcome.states.values()) == {RepairState.NOT_REACHED}


def test_every_selected_alt_text_ends_in_a_state(photo):
    """Total over the selection, so a pass cannot leave one silently unjudged
    (L98)."""
    outcome = repair(["Kate at the piano", "Kate again here"],
                     photo_paths=[photo, photo],
                     answers=["Kate DiGangi at a grand piano singing into a "
                              "handheld microphone under one spotlight",
                              "Kate DiGangi standing at the microphone with "
                              "one hand raised under a blue wash"])

    assert sorted(outcome.states) == outcome.selected
    assert all(state in RepairState for state in outcome.states.values())


# ── what a finding shows afterwards ──────────────────────────────────────────


def test_a_surviving_finding_carries_what_the_pass_did(photo):
    from postroll.ai.caption_quality import check_caption_alt_texts

    outcome = repair(["Kate at the piano"], photo_paths=[photo],
                     answers=["Kate at the piano still", "Kate once more"])
    findings = check_caption_alt_texts(outcome.alt_texts, band=BAND,
                                       photo_names=["DSC4821.jpg"])

    assert findings, "the fixture stopped failing, so this proves nothing"
    assert outcome.repair_for(findings[0]) is RepairState.TRIED


def test_a_finding_the_pass_never_selected_reads_as_never_attempted(photo):
    """Which renders exactly as every caption finding does today."""
    from postroll.ai.blog_findings import Finding

    outcome = repair(["Kate at the piano"], photo_paths=[photo],
                     answers=["Kate DiGangi at a grand piano singing into a "
                              "handheld microphone under one spotlight"])

    other = Finding("caption_credit_missing", "m", "somebody else")
    assert outcome.repair_for(other) is RepairState.NEVER


def test_a_pass_that_never_ran_is_not_a_clean_post(photo):
    """A post with nothing to repair and a pass that never started must not
    read the same (L98)."""
    outcome = repair([], photo_paths=[], answers=[])

    assert outcome.ran is False


# ── it is wired into the caption path (#1155) ───────────────────────────────


def test_the_caption_path_repairs_and_reports_what_it_did(photo, monkeypatch):
    """Built is not wired (L3). This drives `generate_caption` itself, with
    every model call stubbed, and asserts the alt text it SHIPS is the repaired
    one and the finding that survives carries what the pass did.
    """
    from postroll.ai import generate_captions as gc

    short = "Kate at the piano"
    better = ("Kate DiGangi at a grand piano singing into a handheld "
              "microphone under one spotlight on a dark stage")

    def stub(prompt, **kwargs):
        if kwargs.get("step") == "caption_repair_alt_text":
            return {"alt": better}
        return {"caption": "It's a caption about the night.",
                "hashtags": ["#dwphotony"],
                "alt_texts": [short],
                "scene_labels": [None]}

    monkeypatch.setattr(gc, "run_json_prompt", stub)
    monkeypatch.setattr(gc, "run_review_pass", lambda *a, **k: None)

    result = gc.generate_caption(
        event="Spring Gala", org="Decoda", venue="The Green Room 42",
        date="2026-04-05", day="wednesday", photo_paths=[photo],
        program={"performers": [{"name": "Kate DiGangi"}]},
        post_type="feed_photo", skip_humanizer=True, skip_voice_pass=True,
        repair_deadline=9e12)

    assert result["alt_texts"] == [better], result["alt_texts"]
    assert not [f for f in result["findings"]
                if f["code"].startswith("alt_text_")], result["findings"]


def test_the_caption_path_runs_no_repair_without_a_budget(photo, monkeypatch):
    """A pass with no deadline is the one route able to carry a week run past
    its ceiling, so no budget means no calls at all (L227)."""
    from postroll.ai import generate_captions as gc

    short = "Kate at the piano"
    asked: list[str] = []

    def stub(prompt, **kwargs):
        asked.append(str(kwargs.get("step")))
        return {"caption": "It's a caption about the night.",
                "hashtags": ["#dwphotony"],
                "alt_texts": [short],
                "scene_labels": [None]}

    monkeypatch.setattr(gc, "run_json_prompt", stub)
    monkeypatch.setattr(gc, "run_review_pass", lambda *a, **k: None)

    result = gc.generate_caption(
        event="Spring Gala", org="Decoda", venue="The Green Room 42",
        date="2026-04-05", day="wednesday", photo_paths=[photo],
        program={"performers": [{"name": "Kate DiGangi"}]},
        post_type="feed_photo", skip_humanizer=True, skip_voice_pass=True)

    assert "caption_repair_alt_text" not in asked
    assert result["alt_texts"] == [short]
    # And the finding says the pass could not be run rather than that the app
    # tried and failed.
    states = {f["repair"] for f in result["findings"]
              if f["code"].startswith("alt_text_")}
    assert states == {"not_reached"}, states
