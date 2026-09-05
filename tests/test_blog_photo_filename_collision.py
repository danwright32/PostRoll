"""#1130 (Phase 2a): two photographs cannot share one label.

Both blog scripts build `photo_filenames` by stripping the `NNN_` staging prefix
off each staged basename, so two source photos from different folders sharing a
basename produce two identical labels. `_marker_filename_findings` then folds
them into one dict key and the pair silently collapses: one photograph becomes
unreportable as never placed.

Today that is a quiet hole in a report. For the repairer it is fatal. Attaching
the photograph means resolving a marker filename back to ONE file on disk, and
under a collision it attaches the wrong one, which reads as correct and is not.

So the scripts refuse, loudly, before any paid call (L75). The message names
both full source paths, because "two photos share a name" is not something
anyone can act on without knowing which two.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image

from postroll.ai import generate_blog as gb
from postroll.ai import retry_blog_repair as retry
from postroll.ai import revise_blog as revise
from postroll.ai import swap_blog_photos as swap


@pytest.fixture
def colliding(tmp_path):
    """The same basename in two folders, which is an ordinary way to shoot."""
    made = []
    for folder in ("day 1", "day 2"):
        directory = tmp_path / folder
        directory.mkdir()
        path = directory / "DSC4821.jpg"
        Image.new("RGB", (60, 40), (40, 60, 80)).save(path)
        made.append(str(path))
    return made


@pytest.fixture
def distinct(tmp_path):
    made = []
    for i, folder in enumerate(("day 1", "day 2")):
        directory = tmp_path / folder
        directory.mkdir()
        path = directory / f"DSC482{i}.jpg"
        Image.new("RGB", (60, 40), (40, 60, 80)).save(path)
        made.append(str(path))
    return made


def _refuse_paid_calls(monkeypatch, module):
    def refuse(*args, **kwargs):
        raise AssertionError(
            "a paid call was made AFTER a collision that should have refused; "
            "the refusal has to come before the money is spent (L75)")
    monkeypatch.setattr(module, "run_json_prompt", refuse)


def test_generation_refuses_two_photographs_that_share_a_name(colliding, monkeypatch):
    _refuse_paid_calls(monkeypatch, gb)

    with pytest.raises(ValueError) as caught:
        gb.generate_blog(event="E", org="O", venue="V", date="2026-04-05",
                         program={"performers": [], "pieces": []},
                         photo_paths=colliding,
                         skip_humanizer=True, skip_voice_pass=True)

    message = str(caught.value)
    for path in colliding:
        assert path in message, (
            f"the refusal does not name {path}. Two photos sharing a name is "
            f"not actionable without knowing which two: {message}")


def test_the_swap_refuses_two_photographs_that_share_a_name(colliding, monkeypatch):
    _refuse_paid_calls(monkeypatch, swap)

    with pytest.raises(ValueError) as caught:
        swap.swap_blog_photos(body="Some prose.\n\n[PHOTO: old.jpg | old alt]",
                              photo_paths=colliding)

    message = str(caught.value)
    for path in colliding:
        assert path in message, message


def test_a_name_differing_only_in_punctuation_still_collides(tmp_path, monkeypatch):
    """Folded, not compared raw.

    `repair_marker_filenames` folds typographic quotes onto ASCII ones, so two
    files whose names differ only that way resolve to the same marker and the
    repairer cannot tell which to attach. Comparing raw names would let exactly
    the pair the fold creates through.
    """
    _refuse_paid_calls(monkeypatch, swap)
    made = []
    for folder, name in (("a", 'Cast “Live”.jpg'), ("b", 'Cast "Live".jpg')):
        directory = tmp_path / folder
        directory.mkdir()
        path = directory / name
        Image.new("RGB", (60, 40), (40, 60, 80)).save(path)
        made.append(str(path))

    with pytest.raises(ValueError) as caught:
        swap.swap_blog_photos(body="Some prose.\n\n[PHOTO: old.jpg | old alt]",
                              photo_paths=made)
    assert "Cast" in str(caught.value)


@pytest.mark.parametrize("module,call", [
    ("generate", "generate"),
    ("swap", "swap"),
])
def test_distinct_names_are_not_refused(distinct, module, call, monkeypatch):
    """The control. A refusal that fires on every run refuses nothing (L159)."""
    if call == "generate":
        monkeypatch.setattr(gb, "run_json_prompt",
                            lambda *a, **k: {"body": "It's a paragraph.",
                                             "photo_count": 2})
        gb.generate_blog(event="E", org="O", venue="V", date="2026-04-05",
                         program={"performers": [], "pieces": []},
                         photo_paths=distinct,
                         skip_humanizer=True, skip_voice_pass=True)
    else:
        monkeypatch.setattr(swap, "run_json_prompt",
                            lambda *a, **k: {"body": "It's a paragraph.",
                                             "photo_count": 2})
        swap.swap_blog_photos(body="It's prose.\n\n[PHOTO: old.jpg | old alt]",
                              photo_paths=distinct)


# ── the paths that did not refuse (#1364) ───────────────────────────────────


def test_a_revision_refuses_two_photographs_that_share_a_name(colliding, monkeypatch):
    """The revise path takes the same filenames and resolves markers back
    through the same fold, and it was the one blog path that never asked.

    Its own comment says a revision "is a live path back into the blog" and so
    "runs the same deterministic checks the first pass does". This is one of
    those checks and it was absent (#1364).
    """
    _refuse_paid_calls(monkeypatch, revise)

    with pytest.raises(ValueError) as caught:
        revise.revise_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            existing={"title": "T", "body": "Some prose.\n\n[PHOTO: DSC4821.jpg | alt]"},
            feedback="tighten it",
            photo_filenames=[Path(p).name for p in colliding],
            photo_paths=colliding,
            skip_humanizer=True, skip_voice_pass=True)

    message = str(caught.value)
    for path in colliding:
        assert path in message, message


def test_a_revision_from_a_build_that_sends_no_paths_still_runs(colliding, monkeypatch):
    """An app build that predates the key sends no paths, and a revision must
    not fail on one. The absence is not evidence of a collision, and refusing
    on it would take the whole feature away from that build (L214)."""
    monkeypatch.setattr(revise, "run_json_prompt",
                        lambda *a, **k: {"body": "It's a paragraph.\n\n"
                                                 "[PHOTO: DSC4821.jpg | alt]"})

    result = revise.revise_blog(
        event="E", org="O", venue="V", date="2026-04-05",
        program={"performers": [], "pieces": []},
        existing={"title": "T", "body": "Some prose.\n\n[PHOTO: DSC4821.jpg | alt]"},
        feedback="tighten it",
        photo_filenames=[Path(p).name for p in colliding],
        skip_humanizer=True, skip_voice_pass=True)

    assert result["body"]


def test_a_retry_refuses_two_photographs_that_share_a_name(colliding, monkeypatch):
    """`retry_blog_repair` builds the repairer's filename to path mapping with
    a dict comprehension, so a collision is already gone by the time the
    repairer has it: one photograph is silently missing and a marker naming it
    attaches the other (#1364, L30)."""
    def refuse(*args, **kwargs):
        raise AssertionError("a paid call was made after a collision")
    monkeypatch.setattr(retry, "run_json_prompt", refuse)

    with pytest.raises(ValueError) as caught:
        retry.retry_blog_repair(
            body="Some prose.\n\n[PHOTO: DSC4821.jpg | alt]",
            photo_paths=colliding, markers=["DSC4821.jpg"])

    message = str(caught.value)
    for path in colliding:
        assert path in message, message


def test_a_retry_with_distinct_names_reaches_the_repairer(distinct, monkeypatch):
    """The control: a refusal that fires on every run refuses nothing (L159).

    The repairer is replaced by something that says it was reached, so this
    asserts the run got PAST the refusal rather than merely that it failed
    somewhere else."""
    def reached(*args, **kwargs):
        raise RuntimeError("reached the repairer")
    monkeypatch.setattr(retry, "repair_alt_text", reached)

    with pytest.raises(RuntimeError) as caught:
        retry.retry_blog_repair(
            body="Some prose.\n\n[PHOTO: DSC4820.jpg | alt]",
            photo_paths=distinct, markers=["DSC4820.jpg"])

    assert "reached the repairer" in str(caught.value)


# ── every path into the repairer, not the three somebody remembered (#1364) ──

REPO_ROOT = Path(__file__).resolve().parent.parent
AI = REPO_ROOT / "postroll" / "ai"

#: Where the refusal belongs: the repairer resolves a marker's filename back to
#: one file on disk, so a caller that hands it a colliding pair makes it attach
#: the wrong photograph.
REPAIRER = "repair_alt_text"
REFUSAL = "refuse_colliding_filenames"


def _calls(tree) -> set[str]:
    import ast
    named = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Name):
                named.add(func.id)
            elif isinstance(func, ast.Attribute):
                named.add(func.attr)
    return named


def modules_that_reach_the_repairer() -> dict[str, set[str]]:
    """Every module under postroll/ai that calls the alt text repairer."""
    import ast
    found = {}
    for path in sorted(AI.glob("*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        called = _calls(tree)
        if REPAIRER in called and path.name != "blog_repair.py":
            found[path.name] = called
    return found


def test_the_sweep_finds_the_paths_into_the_repairer():
    """The positive control. A sweep matching nothing would report every caller
    as refusing, which is the state this check exists to end (L98, L100)."""
    found = modules_that_reach_the_repairer()
    assert len(found) >= 3, (
        f"only {sorted(found)} reach the repairer, against the three that did "
        "when this was written (generate, swap, retry), so this is reading a "
        "renamed function rather than the app")


@pytest.mark.parametrize("module", sorted(modules_that_reach_the_repairer()))
def test_every_caller_of_the_repairer_refuses_a_collision_first(module):
    """Fixed as a class rather than an instance (L30).

    Three modules reach the repairer and two of them refused; `retry_blog_repair`
    built the filename to path mapping with a dict comprehension and never
    asked, so a colliding pair was already one key before the repairer saw it.
    The repairer itself cannot check: by the time it holds the mapping the pair
    has collapsed, which is why the refusal belongs at every entrance rather
    than in the room.
    """
    assert REFUSAL in modules_that_reach_the_repairer()[module], (
        f"{module} calls {REPAIRER} without calling {REFUSAL} first, so two "
        f"photographs sharing a basename fold into one mapping key: one is "
        f"silently missing and a marker naming it attaches the other, which "
        f"reads as correct and is not (#1130, #1364)")
