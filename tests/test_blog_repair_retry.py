"""#1160: retrying a repair the app could not finish.

Two of the five outcomes tell Dan to try again in as many words. `blocked` says
the app could not reach the model or could not read the photograph; `not_reached`
says the pass ran out of time before this one. Until now no control retried,
so the panel named a recovery step nothing could perform and left him facing
the same panel with no way forward (L109). Rule 1 removed every other signal,
so that panel is the only place this state appears at all.

A retry is a FRESH pass over just those markers, not a resumed one: the round
cap is per pass and the pass is already re-entrant.

`only` is the whole mechanism, and it has to be a restriction on SELECTION
rather than on the photo paths handed in. Restricting the paths instead looks
equivalent and is not: a marker with no path is `blocked`, so every marker the
retry was not about would come back reported as a failure it never had.
"""

from __future__ import annotations

import pytest
from PIL import Image

from postroll.ai.blog_findings import RepairState
from postroll.ai.blog_repair import repair_alt_text

VENUE = "The Green Room 42"
PROGRAM = {"performers": [{"name": "Kate DiGangi"}], "pieces": []}
P1 = "It's a night that started late and ran long, and the room stayed full."
GOOD = ("Kate DiGangi sings into a microphone at The Green Room 42 with one "
        "hand raised and the band lit blue behind her")
BAD = "A male performer sings"


@pytest.fixture
def photos(tmp_path):
    def _make(*names):
        out = {}
        for i, name in enumerate(names):
            path = tmp_path / name
            Image.new("RGB", (40, 30), (10 + i, 20, 30)).save(path)
            out[name] = str(path)
        return out
    return _make


def _body(*names: str) -> str:
    parts = [P1]
    for name in names:
        parts.append(f"[PHOTO: {name} | {BAD}]")
        parts.append(P1)
    return "\n\n".join(parts)


def _run(body, files, *, only=None, answers=None):
    seen = []

    def runner(prompt, *, timeout, image_paths, image_labels, step):
        seen.append(image_labels[0])
        return {"alt": GOOD}

    result = repair_alt_text(
        body, program=PROGRAM, venue=VENUE, photo_paths=files, runner=runner,
        now=lambda: 0.0, deadline=1_000_000.0, max_rounds=1, only=only)
    return result, seen


def test_without_only_every_failing_marker_is_attempted(photos):
    """The control. Without it, a retry that attempted nothing would pass every
    test below (L159)."""
    files = photos("a.jpg", "b.jpg", "c.jpg")
    result, seen = _run(_body("a.jpg", "b.jpg", "c.jpg"), files)
    assert sorted(seen) == ["a.jpg", "b.jpg", "c.jpg"]
    assert sorted(result.selected) == ["a.jpg", "b.jpg", "c.jpg"]


def test_only_restricts_the_pass_to_the_markers_named(photos):
    files = photos("a.jpg", "b.jpg", "c.jpg")
    result, seen = _run(_body("a.jpg", "b.jpg", "c.jpg"), files, only=["b.jpg"])
    assert seen == ["b.jpg"]
    assert result.selected == ["b.jpg"]


def test_a_marker_outside_only_is_not_reported_as_a_failure(photos):
    """The trap this design exists to avoid. Restricting the PHOTO PATHS looks
    like the same thing and is not: a marker with no path is `blocked`, so
    every marker the retry was not about would come back carrying a failure it
    never had."""
    files = photos("a.jpg", "b.jpg", "c.jpg")
    result, _seen = _run(_body("a.jpg", "b.jpg", "c.jpg"), files, only=["b.jpg"])
    assert "a.jpg" not in result.states
    assert "c.jpg" not in result.states
    assert result.states["b.jpg"] is RepairState.REPAIRED


def test_only_naming_a_marker_that_is_already_clean_attempts_nothing(photos):
    """A retry is judged by the CURRENT body, never by the state that named it.
    A marker repaired since is not re-repaired."""
    files = photos("a.jpg", "b.jpg")
    body = "\n\n".join([P1, f"[PHOTO: a.jpg | {GOOD}]", P1,
                        f"[PHOTO: b.jpg | {BAD}]", P1])
    result, seen = _run(body, files, only=["a.jpg"])
    assert seen == []
    assert result.selected == []
    assert result.ran is True


def test_only_naming_a_marker_that_is_not_in_the_post_attempts_nothing(photos):
    files = photos("a.jpg")
    result, seen = _run(_body("a.jpg"), files, only=["gone.jpg"])
    assert seen == []
    assert result.selected == []
    assert result.ran is True


def test_an_empty_only_list_is_not_the_same_as_no_restriction(photos):
    """`None` means every failing marker; an empty list means none were named,
    and the two must not collapse into each other. A retry that was handed no
    markers must do nothing, not repair the whole post."""
    files = photos("a.jpg", "b.jpg")
    result, seen = _run(_body("a.jpg", "b.jpg"), files, only=[])
    assert seen == []
    assert result.selected == []


def test_only_matches_a_marker_however_its_filename_is_spelled(photos):
    """Filenames are compared FOLDED everywhere else in the pass, because a
    marker differing only in which quote or dash was typed names the same file.
    A retry keyed on the raw spelling would silently match nothing."""
    files = photos("a.jpg")
    result, seen = _run(_body("a.jpg"), files, only=["A.JPG"])
    assert seen == ["a.jpg"]
    assert result.selected == ["a.jpg"]


# --- the entry point the control calls -------------------------------------

import json
from pathlib import Path

from postroll.ai.retry_blog_repair import retry_blog_repair


def _manifest(body, files, markers):
    return {"body": body, "photo_paths": list(files.values()),
            "markers": markers, "program": PROGRAM, "venue": VENUE}


def _fake_runner(answer=GOOD):
    seen = []

    def runner(prompt, *, timeout, image_paths, image_labels, step):
        seen.append(image_labels[0])
        return {"alt": answer}
    return runner, seen


def test_the_entry_point_repairs_only_the_markers_it_was_given(photos):
    files = photos("a.jpg", "b.jpg")
    runner, seen = _fake_runner()
    result = retry_blog_repair(**_manifest(_body("a.jpg", "b.jpg"), files,
                                           ["b.jpg"]), runner=runner)
    assert seen == ["b.jpg"]
    assert GOOD in result["body"]
    assert result["body"].count(BAD) == 1, "a marker outside the retry changed"


def test_the_entry_point_reports_what_it_actually_did(photos):
    """A retry that repaired nothing and one that was never run must not read
    the same (L98). Rule 1 removed every other signal, so this is the only
    place the outcome appears."""
    files = photos("a.jpg")
    runner, _seen = _fake_runner()
    result = retry_blog_repair(**_manifest(_body("a.jpg"), files, ["a.jpg"]),
                               runner=runner)
    assert result["retry"]["ran"] is True
    assert result["retry"]["selected"] == 1
    assert result["retry"]["repaired"] == 1


def test_a_retry_that_repairs_nothing_says_so_rather_than_reporting_success(photos):
    files = photos("a.jpg")

    def refusing(prompt, *, timeout, image_paths, image_labels, step):
        return {"alt": BAD}          # still breaks the rules that selected it

    result = retry_blog_repair(**_manifest(_body("a.jpg"), files, ["a.jpg"]),
                               runner=refusing)
    assert result["retry"]["ran"] is True
    assert result["retry"]["selected"] == 1
    assert result["retry"]["repaired"] == 0
    assert result["body"].count(BAD) == 1


def test_the_entry_point_returns_findings_for_the_body_it_produced(photos):
    """What the panel renders has to be about the body the retry ended with,
    never the one it started from."""
    files = photos("a.jpg")
    runner, _seen = _fake_runner()
    result = retry_blog_repair(**_manifest(_body("a.jpg"), files, ["a.jpg"]),
                               runner=runner)
    codes = [f["code"] for f in result["findings"]]
    assert not any(c.startswith("alt_text_") for c in codes), codes


def test_a_retry_naming_no_markers_is_refused_rather_than_repairing_everything(photos):
    """An empty marker list reaching the whole-post path is the dangerous
    failure: the control exists to redo a few, and a bug that redid all of them
    would pay for the whole post again without being asked."""
    files = photos("a.jpg", "b.jpg")
    runner, seen = _fake_runner()
    with pytest.raises(ValueError, match="no markers"):
        retry_blog_repair(**_manifest(_body("a.jpg", "b.jpg"), files, []),
                          runner=runner)
    assert seen == []


def test_the_body_is_required(photos):
    files = photos("a.jpg")
    runner, _seen = _fake_runner()
    with pytest.raises(ValueError):
        retry_blog_repair(**_manifest("", files, ["a.jpg"]), runner=runner)


# --- the marker a finding is about, carried rather than parsed -------------

from postroll.ai.blog_findings import Finding, finding_entry
from postroll.ai.blog_quality import check_blog_targeted


def test_a_finding_entry_carries_the_marker_it_is_about():
    """The retry control needs to know WHICH markers to retry.

    Parsing the filename back out of `detail` was the alternative, and `Target`
    says in as many words why it does not work: `detail` embeds the offending
    text, it truncates at 90 characters, and `stacked_photos` formats it with
    no filename in it at all. A control built on that reads a filename out of
    prose and silently matches nothing the day a message is reworded.
    """
    entry = finding_entry(Finding("alt_text_length", "m", "d"),
                          target="a.jpg")
    assert entry["target"] == "a.jpg"


def test_a_finding_entry_with_no_target_still_carries_the_key():
    """Unconditional in the returned literal (#1132). A key present only when
    set takes the payload out of the contract's reach entirely."""
    entry = finding_entry(Finding("repeated_construction", "m", "d"))
    assert entry["target"] == ""


def test_the_target_is_the_checkers_own_and_not_a_second_reading(photos):
    """Read from `check_blog_targeted`, which is where a finding's target is
    decided, so the control retries exactly the marker the checker named."""
    body = _body("a.jpg")
    pairs = [(f, t) for f, t in check_blog_targeted(body, program=PROGRAM,
                                                    venue=VENUE)
             if f.code.startswith("alt_text_")]
    assert pairs, "the fixture fired no alt text finding"
    for finding, target in pairs:
        assert finding_entry(finding, target=target.key)["target"] == "a.jpg"


import ast

AI_DIR = Path("postroll/ai")


@pytest.mark.parametrize("module", ["generate_blog.py", "revise_blog.py",
                                    "swap_blog_photos.py",
                                    "retry_blog_repair.py"])
def test_every_blog_path_sends_the_target_with_each_finding(module):
    """Built is not wired (L3).

    A payload field that only one path fills is worse than one nothing fills:
    the control appears on drafts from one route and silently does nothing on
    the others, and nothing says why.
    """
    tree = ast.parse((AI_DIR / module).read_text(encoding="utf-8"))
    calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)
             and getattr(n.func, "id", None) == "finding_entry"]
    assert calls, f"{module} builds no finding entries"
    for call in calls:
        assert any(kw.arg == "target" for kw in call.keywords), (
            f"{module} line {call.lineno}: a finding is sent with no target, "
            f"so the retry control cannot tell which marker it is about")
