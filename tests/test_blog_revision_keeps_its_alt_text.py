"""#1131: a revision may not rewrite the alt text it was told to preserve.

`revise_blog` is under orders to keep every `[PHOTO: filename | alt text]`
marker verbatim, and nothing checked it. Three separate holes:

  * the pass 1 call at `revise_blog.py` had NO validator at all, so whatever it
    returned went straight into the voice pass;
  * the two review passes use `markers_preserved_validator`, which SORTS the
    filenames and never reads the alt text, so a pass that rewrote every
    description while keeping every filename passed;
  * nothing anywhere compared the ORDER of the markers, so a photograph moving
    to a different point in the post, with the prose written about it staying
    put, was invisible.

The splice closes the first two by making the instruction unnecessary: the alt
text is restored from the incoming body. The ordered validator closes the third.

This is a bug fix that costs nothing and needs no photograph, and it would be
worth shipping even if the repair pass were cancelled.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai import revise_blog as rb


PROSE = "It's a paragraph about the evening, and the room didn't empty early."
A = "[PHOTO: a.jpg | Alt one describing exactly what the first photograph shows]"
B = "[PHOTO: b.jpg | Alt two describing exactly what the second photograph shows]"
EXISTING = "\n\n".join([PROSE, A, PROSE, B, PROSE])


def _revise(returned_body, **kw):
    captured = {}

    def fake(prompt, timeout=600, **kwargs):
        captured.setdefault("validators", []).append(kwargs.get("validate"))
        return {"title": "T", "body": returned_body}

    with patch.object(rb, "run_json_prompt", side_effect=fake):
        result = rb.revise_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            existing={"title": "T", "body": EXISTING},
            feedback="tighten the middle",
            skip_humanizer=True, skip_voice_pass=True, **kw)
    return result, captured


def test_a_rewritten_alt_text_is_restored_verbatim():
    rewritten = EXISTING.replace(
        "Alt one describing exactly what the first photograph shows",
        "Something the model decided to write instead")
    result, _ = _revise(rewritten)

    assert A in result["body"], (
        "the revision kept the model's alt text for a marker it was told to "
        "preserve verbatim")
    assert B in result["body"]


def test_every_rewritten_alt_text_is_restored_not_just_the_first():
    rewritten = (EXISTING
                 .replace("Alt one describing exactly what the first photograph shows",
                          "Made up one")
                 .replace("Alt two describing exactly what the second photograph shows",
                          "Made up two"))
    result, _ = _revise(rewritten)

    assert A in result["body"] and B in result["body"]


def test_the_count_of_rewritten_markers_is_reported(capsys):
    """The splice destroys the evidence it was needed, so the count is the
    only thing that says the instruction was ignored (L340)."""
    rewritten = (EXISTING
                 .replace("Alt one describing exactly what the first photograph shows",
                          "Made up one")
                 .replace("Alt two describing exactly what the second photograph shows",
                          "Made up two"))
    _revise(rewritten)

    printed = capsys.readouterr().err
    assert "2" in printed and "marker" in printed.lower(), printed


def test_a_revision_that_preserved_everything_reports_no_drift(capsys):
    _revise(EXISTING)

    printed = capsys.readouterr().err
    assert "RESTORED" not in printed, (
        f"a clean revision reported drift, so the count means nothing: {printed}")


def test_the_prose_the_revision_actually_changed_is_kept():
    """The control. A splice that also reverted the prose would undo the
    revision itself, which is the one thing this path exists to do (L159)."""
    revised_prose = "It's a tighter paragraph now, and it didn't take long."
    rewritten = EXISTING.replace(PROSE, revised_prose)
    result, _ = _revise(rewritten)

    assert revised_prose in result["body"]
    assert A in result["body"]


def test_what_the_first_call_returns_is_checked_at_all(capsys):
    """It was not, so a pass 1 that dropped or moved a marker was preserved
    faithfully by the two later passes and reached the review screen.

    Asserted as a property of the RUN rather than as a `validate=` argument:
    `run_json_prompt` takes no validator, so the equivalent is checking what it
    returned. A test written against the argument would pass on a call that
    accepted a validator and never ran it (L3).
    """
    reordered = "\n\n".join([PROSE, B, PROSE, A, PROSE])
    _revise(reordered)

    printed = capsys.readouterr().err
    assert "reordered" in printed, (
        f"pass 1 reordered two markers and nothing said so: {printed}")


def test_a_reordered_marker_is_refused_by_the_validator():
    """Sorting hides this, and the repo's only marker validator sorts."""
    from postroll.ai.revise_blog import ordered_markers_validator

    reordered = "\n\n".join([PROSE, B, PROSE, A, PROSE])
    assert ordered_markers_validator(EXISTING, {"body": reordered}) is not None
    assert ordered_markers_validator(EXISTING, {"body": EXISTING}) is None


def test_the_ordered_validator_still_refuses_a_dropped_marker():
    from postroll.ai.revise_blog import ordered_markers_validator

    dropped = "\n\n".join([PROSE, A, PROSE])
    assert ordered_markers_validator(EXISTING, {"body": dropped}) is not None


def test_a_marker_the_model_dropped_leaves_the_revision_usable(capsys):
    """A dropped marker cannot be spliced back without inventing a position,
    so the run says so rather than guessing, and still returns a draft."""
    dropped = "\n\n".join([PROSE, B, PROSE])
    result, _ = _revise(dropped)

    assert result["body"], "the revision was lost entirely"
    printed = capsys.readouterr().err
    assert "a.jpg" in printed, printed


def test_a_dropped_marker_reaches_the_PANEL_not_only_stderr():
    """L148: a reason written only to stderr dies with the run.

    The splice cannot put a dropped marker back without inventing a position
    for it, so the revision returns a draft that is missing a photograph. That
    is a real loss, and the surface Dan actually reads has to carry it: a
    `PythonBridgeError` log keeps 500 shared lines and a single blog run already
    prints 23 CHECK lines, so the stderr line is gone within days while the post
    keeps the hole.
    """
    dropped = "\n\n".join([PROSE, B, PROSE])
    captured = {}

    def fake(prompt, timeout=600, **kwargs):
        return {"title": "T", "body": dropped}

    with patch.object(rb, "run_json_prompt", side_effect=fake):
        captured["result"] = rb.revise_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            existing={"title": "T", "body": EXISTING},
            feedback="tighten the middle",
            photo_filenames=["a.jpg", "b.jpg"],
            skip_humanizer=True, skip_voice_pass=True)

    findings = captured["result"]["findings"]
    assert any(f["code"] == "blog_marker_missing_photo" and "a.jpg" in f["detail"]
               for f in findings), (
        "the revision lost a photograph and the findings panel says nothing "
        f"about it, so the only record died with the process: {findings}")
