"""A week generation must be able to stop, and must never lose what it finished (#206).

Two defects, found by the plan-council reality check:

1. Every day and the blog sit inside a broad `except Exception`
   (generate_week.py:257 and :282). A condition that makes continuing
   pointless or harmful, a usage cap being the motivating case, is caught
   there, filed as that day's error, and the loop carries on to the next day
   and then the blog, hammering a wall it has already hit. Dan's requirement
   is that such a run STOPS and asks him.

2. Results are written once, after the loop (:293). Anything that stops the
   process before that point, including the app's own 1800s watchdog SIGTERM,
   destroys days that were already generated and already paid for, even
   though the per-day "done" lines at :256 show they succeeded.

The tests below use a fake caption generator, so they cost nothing and can
exercise the failure paths that a real run almost never reaches.
"""

from __future__ import annotations

import json

import pytest

import postroll.ai.generate_week as gw
from postroll.ai.generate_week import FatalGenerationError


def _manifest(tmp_path, days=("sunday", "monday", "tuesday", "wednesday")):
    photo = tmp_path / "p.jpg"
    photo.write_bytes(b"\xff\xd8\xff\xdb" + b"0" * 64)
    return {
        "event": "E", "org": "O", "venue": "V", "date": "2026-08-08",
        "program": {"performers": [], "pieces": []},
        "days": {d: {"photos": [str(photo)]} for d in days},
        "blog_photos": [],
    }


def _fake_caption(order, fail_on=None, fatal_on=None):
    """A stand-in for generate_caption that records which days were attempted."""
    def run(*, day, **kwargs):
        order.append(day)
        if fatal_on and day == fatal_on:
            raise FatalGenerationError("usage limit reached")
        if fail_on and day == fail_on:
            raise RuntimeError("ordinary failure")
        return {"caption": f"{day} caption", "hashtags": [], "alt_texts": [],
                "scene_labels": []}
    return run


# ── 1. a fatal condition stops the run ────────────────────────────────────────

def test_a_fatal_error_stops_the_run_instead_of_carrying_on(tmp_path, monkeypatch):
    order = []
    monkeypatch.setattr(gw, "generate_caption", _fake_caption(order, fatal_on="monday"))
    out = tmp_path / "out.json"

    with pytest.raises(FatalGenerationError):
        gw.generate_week(_manifest(tmp_path), out)

    assert "tuesday" not in order, "the run continued past the wall it had already hit"
    assert "wednesday" not in order


def test_a_fatal_error_does_not_then_attempt_the_blog(tmp_path, monkeypatch):
    order = []
    monkeypatch.setattr(gw, "generate_caption", _fake_caption(order, fatal_on="sunday"))
    blog_called = []
    monkeypatch.setattr(gw, "generate_blog",
                        lambda **kw: blog_called.append(1) or {"title": "t", "body": "b"})
    manifest = _manifest(tmp_path)
    manifest["blog_photos"] = [str(tmp_path / "p.jpg")]
    out = tmp_path / "out.json"

    with pytest.raises(FatalGenerationError):
        gw.generate_week(manifest, out)

    assert not blog_called, "the blog ran after the run should have stopped"


# ── 2. nothing already generated is lost ──────────────────────────────────────

def test_work_finished_before_a_fatal_error_is_on_disk(tmp_path, monkeypatch):
    order = []
    monkeypatch.setattr(gw, "generate_caption", _fake_caption(order, fatal_on="tuesday"))
    out = tmp_path / "out.json"

    with pytest.raises(FatalGenerationError):
        gw.generate_week(_manifest(tmp_path), out)

    assert out.exists(), "everything generated before the stop was thrown away"
    saved = json.loads(out.read_text())
    assert saved["sunday"]["caption"] == "sunday caption"
    assert saved["monday"]["caption"] == "monday caption"


def test_the_saved_result_says_it_is_incomplete_and_why(tmp_path, monkeypatch):
    monkeypatch.setattr(gw, "generate_caption", _fake_caption([], fatal_on="monday"))
    out = tmp_path / "out.json"

    with pytest.raises(FatalGenerationError):
        gw.generate_week(_manifest(tmp_path), out)

    saved = json.loads(out.read_text())
    assert saved.get("complete") is False, "a partial run must not read as a finished one"
    assert "usage limit" in (saved.get("stopped_reason") or "")


def test_each_day_is_written_as_it_finishes(tmp_path, monkeypatch):
    """So a process killed mid-run (the app's own watchdog SIGTERMs at 1800s)
    still leaves the days that had completed."""
    out = tmp_path / "out.json"
    seen_after_monday = {}

    def run(*, day, **kwargs):
        if day == "tuesday":
            # Whatever is on disk at this point is what a kill here would leave.
            seen_after_monday["saved"] = json.loads(out.read_text()) if out.exists() else None
        return {"caption": f"{day} caption", "hashtags": [], "alt_texts": [],
                "scene_labels": []}

    monkeypatch.setattr(gw, "generate_caption", run)
    gw.generate_week(_manifest(tmp_path), out)

    saved = seen_after_monday["saved"]
    assert saved is not None, "nothing was on disk two days in"
    assert saved["sunday"]["caption"] == "sunday caption"
    assert saved["monday"]["caption"] == "monday caption"


# ── 3. ordinary failures keep today's behaviour ───────────────────────────────

def test_an_ordinary_error_still_lets_the_rest_of_the_week_run(tmp_path, monkeypatch):
    order = []
    monkeypatch.setattr(gw, "generate_caption", _fake_caption(order, fail_on="monday"))
    out = tmp_path / "out.json"

    gw.generate_week(_manifest(tmp_path), out)

    assert "wednesday" in order, "one bad day must not abandon the week"
    saved = json.loads(out.read_text())
    assert saved["errors"]["monday"]
    assert saved["monday"] is None
    assert saved["wednesday"]["caption"] == "wednesday caption"


def test_a_completed_run_is_marked_complete(tmp_path, monkeypatch):
    monkeypatch.setattr(gw, "generate_caption", _fake_caption([]))
    out = tmp_path / "out.json"

    gw.generate_week(_manifest(tmp_path), out)

    saved = json.loads(out.read_text())
    assert saved.get("complete") is True
    assert saved.get("stopped_reason") in (None, "")
