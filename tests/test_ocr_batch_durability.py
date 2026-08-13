"""#479: a multi-batch OCR run must not lose batches it already paid for.

Two gaps, both on exactly the large programmes batching exists for.

**A dropped batch was silent.** A batch whose response came back as a non-dict
was recorded as None and merged away to nothing: no retry, no warning, no gap
marker. The single-batch path gets a reinforced-prompt retry and a list salvage
for the same failure; a batch got neither. The later fallbacks only fire when a
field is EMPTY, so a partially filled field from the other batches suppresses
recovery entirely, and the result is a cast list read from fewer pages than the
programme has, with nothing on screen saying so (the failure #200 and #215 name
as the worst available).

**Everything already paid for died with the run.** Each batch costs a 600s call
and lived only in memory. An exception on batch four, or the app's 1800s
watchdog SIGTERM, discarded the three that had finished and the retry paid for
them again. That is the defect generate_week fixed for captions with per-day
persistence (#206, L5), never swept to here.

So: each batch retries like its single-batch sibling, one batch failing is its
own failure boundary rather than the end of the run (L73), a batch that cannot
be read says which pages went unread, and what has finished is on disk before
the next call starts.
"""

from __future__ import annotations

import json
from unittest.mock import patch

import pytest
from PIL import Image

from postroll.ai import ocr_program


@pytest.fixture
def pages(tmp_path):
    def _make(count: int) -> list[str]:
        made = []
        for i in range(count):
            p = tmp_path / f"page{i}.png"
            Image.new("RGB", (40, 30), (30 * i % 255, 60, 90)).save(p)
            made.append(str(p))
        return made
    return _make


def _one_batch_per_page(paths, **kw):
    return [[str(p)] for p in paths]


def _run(pages_, answers, *, output_path=None):
    """Run OCR with each page its own batch and a scripted answer per call."""
    calls: list[str] = []
    supply = list(answers)

    def fake_run_json(prompt, **kw):
        calls.append(prompt)
        nxt = supply.pop(0) if supply else {}
        if isinstance(nxt, Exception):
            raise nxt
        return nxt

    with patch("postroll.ai.ocr_program.batch_images", side_effect=_one_batch_per_page), \
         patch("postroll.ai.ocr_program.run_json_prompt", side_effect=fake_run_json), \
         patch("postroll.ai.ocr_program.stitch_notes", side_effect=lambda d, **kw: d):
        data = ocr_program.extract_program(pages_, output_path=output_path)
    return data, calls


def _perf(name):
    return {"performers": [{"name": name, "role": "soloist"}],
            "pieces": [], "scenes": []}


def _names(data):
    return sorted(p["name"] for p in data.get("performers", []))


# ── a dropped batch is retried, not merged away ───────────────────────────────

def test_a_batch_that_answers_with_the_wrong_shape_is_retried(pages):
    _, calls = _run(pages(2), [["not a dict"], _perf("Retried"), _perf("B")])

    assert any("MUST be a single JSON object" in c for c in calls), (
        "the batch got no reinforced retry, which its single-batch sibling does")


def test_a_retried_batch_contributes_what_it_finally_read(pages):
    data, _ = _run(pages(2), [["not a dict"], _perf("Recovered"), _perf("B")])

    assert "Recovered" in _names(data)


def test_a_list_answer_is_salvaged_the_way_a_single_batch_is(pages):
    # A programme page with notes but no cast list comes back as a bare array.
    performers = [{"name": "Salvaged", "role": "soloist"}]
    data, _ = _run(pages(2), [performers, performers, _perf("B")])

    assert "Salvaged" in _names(data)


def test_a_batch_that_cannot_be_read_says_which_pages_went_unread(pages, capsys):
    _run(pages(3), ["junk", "junk still", _perf("B"), _perf("C")])

    err = capsys.readouterr().err
    assert "page0.png" in err, err
    assert "1 of 3" in err or "batch 1" in err.lower()


def test_the_other_batches_survive_a_batch_that_cannot_be_read(pages):
    # A page that could not be read is a gap, not a reason to discard the
    # pages that could.
    data, _ = _run(pages(3), ["junk", "junk still", _perf("B"), _perf("C")])

    assert _names(data) == ["B", "C"]


# ── one batch failing is its own boundary ─────────────────────────────────────

def test_an_exception_in_one_batch_does_not_take_the_others(pages):
    from postroll.ai.claude_client import ClaudeError

    data, _ = _run(pages(3),
                   [_perf("A"), ClaudeError("network went away"), _perf("C")])

    assert _names(data) == ["A", "C"]


def test_an_exception_in_one_batch_is_reported(pages, capsys):
    from postroll.ai.claude_client import ClaudeError

    _run(pages(2), [_perf("A"), ClaudeError("network went away")])

    assert "network went away" in capsys.readouterr().err


def test_every_batch_failing_is_not_a_silent_empty_result(pages):
    from postroll.ai.claude_client import ClaudeError

    with pytest.raises(ClaudeError):
        _run(pages(2), [ClaudeError("down"), ClaudeError("down")])


# ── what finished is on disk before the next call ─────────────────────────────

def test_each_finished_batch_is_persisted_before_the_next_one_starts(pages, tmp_path):
    out = tmp_path / "program.json"
    seen: list[list[str]] = []

    def fake_run_json(prompt, **kw):
        # Read the file WHILE the run is in flight: what is on disk when the
        # next call begins is exactly what a SIGTERM here would leave behind.
        if out.exists():
            seen.append(sorted(
                p["name"] for p in
                json.loads(out.read_text()).get("performers", [])))
        else:
            seen.append([])
        return _perf(f"P{len(seen)}")

    with patch("postroll.ai.ocr_program.batch_images", side_effect=_one_batch_per_page), \
         patch("postroll.ai.ocr_program.run_json_prompt", side_effect=fake_run_json), \
         patch("postroll.ai.ocr_program.stitch_notes", side_effect=lambda d, **kw: d):
        ocr_program.extract_program(pages(3), output_path=out)

    # Only the first three calls are the batches; the run then tops up the
    # prose fields with its own focused calls, which are not batches and have
    # nothing of their own to protect.
    assert seen[:3] == [[], ["P1"], ["P1", "P2"]], seen


def test_a_crash_partway_leaves_the_paid_batches_on_disk(pages, tmp_path):
    from postroll.ai.claude_client import ClaudeError

    out = tmp_path / "program.json"

    # A failure that is NOT one bad batch: something that takes the whole run
    # down after two batches have been paid for.
    def fake_run_json(prompt, **kw):
        fake_run_json.n = getattr(fake_run_json, "n", 0) + 1
        if fake_run_json.n <= 2:
            return _perf(f"P{fake_run_json.n}")
        raise KeyboardInterrupt("watchdog")

    with patch("postroll.ai.ocr_program.batch_images", side_effect=_one_batch_per_page), \
         patch("postroll.ai.ocr_program.run_json_prompt", side_effect=fake_run_json), \
         patch("postroll.ai.ocr_program.stitch_notes", side_effect=lambda d, **kw: d):
        with pytest.raises(KeyboardInterrupt):
            ocr_program.extract_program(pages(4), output_path=out)

    saved = json.loads(out.read_text())
    assert sorted(p["name"] for p in saved["performers"]) == ["P1", "P2"], (
        "two batches were paid for and are gone")


def test_the_finished_file_holds_every_batch(pages, tmp_path):
    out = tmp_path / "program.json"
    data, _ = _run(pages(3), [_perf("A"), _perf("B"), _perf("C")],
                   output_path=out)

    assert _names(json.loads(out.read_text())) == ["A", "B", "C"]
    assert _names(data) == ["A", "B", "C"]


def test_no_output_path_still_works(pages):
    # The library call and the CLI both use this; only one of them has a file.
    data, _ = _run(pages(2), [_perf("A"), _perf("B")])

    assert _names(data) == ["A", "B"]


def test_a_single_batch_run_writes_nothing_extra(pages, tmp_path):
    # One batch has nothing to protect: the run either finishes or has produced
    # nothing at all, so it must not pay an extra write per call.
    out = tmp_path / "program.json"
    writes: list[int] = []

    real_write = ocr_program._write_partial

    def counting(path, data):
        writes.append(1)
        real_write(path, data)

    with patch.object(ocr_program, "_write_partial", side_effect=counting):
        with patch("postroll.ai.ocr_program.run_json_prompt",
                   side_effect=lambda *a, **k: _perf("A")), \
             patch("postroll.ai.ocr_program.batch_images",
                   side_effect=lambda paths, **kw: [[str(p) for p in paths]]):
            ocr_program.extract_program(pages(2), output_path=out)

    assert writes == []
