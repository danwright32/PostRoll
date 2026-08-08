"""What a week of generation actually costs on the metered path (#207).

The whole subscription-transport effort exists to stop paying per token, and
nobody has ever measured what that bill is. The red team's standing objection
on the plan was exactly this: the saving being chased is unquantified, so there
is no way to judge whether the added latency is worth it.

Every AI call in the app funnels through one SDK call, so usage is recorded
there and totalled per event.

The failure path that matters most is an UNPRICED model. Pricing a model we
have no rate for as zero would quietly under-report the bill, and under-report
it hardest in exactly the case where someone changed the model, which is when
the number matters. An unpriced call must therefore be counted and reported as
unpriced, never folded in at zero. Same for a log line that cannot be read: a
skipped line is indistinguishable from a call that never happened.
"""

from __future__ import annotations

import json
import os

import pytest

from postroll.ai import usage_log
from postroll.ai.usage_log import Usage


def _u(model="claude-sonnet-4-6", inp=1000, out=500, **kw):
    return Usage(model=model, input_tokens=inp, output_tokens=out, **kw)


# ── pricing ───────────────────────────────────────────────────────────────────

def test_a_known_model_is_priced_from_its_published_rate():
    # claude-sonnet-4-6 is $3.00 / $15.00 per million.
    cost = usage_log.cost_usd(_u(inp=1_000_000, out=1_000_000))

    assert cost == pytest.approx(18.0)


def test_the_model_the_app_actually_pins_is_priced():
    """The aliases in claude_client resolve to these; an unpriced one would
    make every real run report as unpriced."""
    from postroll.ai.claude_client import _MODEL_ALIASES, _resolve_model

    for alias in _MODEL_ALIASES:
        model = _resolve_model(alias)
        assert usage_log.cost_usd(_u(model=model)) is not None, \
            f"{alias} resolves to {model}, which has no price"


def test_a_dated_snapshot_id_is_priced_as_its_base_model():
    dated = usage_log.cost_usd(_u(model="claude-haiku-4-5-20251001"))
    base = usage_log.cost_usd(_u(model="claude-haiku-4-5"))

    assert dated == base


def test_an_unpriced_model_costs_none_rather_than_zero():
    assert usage_log.cost_usd(_u(model="claude-some-future-model")) is None


def test_cached_tokens_are_priced_at_their_own_rates():
    """Cache reads are ~0.1x input and writes ~1.25x; pricing them as ordinary
    input would misstate any future caching work."""
    plain = usage_log.cost_usd(_u(inp=1_000_000, out=0))
    cached = usage_log.cost_usd(_u(inp=0, out=0, cache_read_tokens=1_000_000))

    assert cached < plain
    assert cached == pytest.approx(plain * 0.1)


# ── recording ─────────────────────────────────────────────────────────────────

def test_a_recorded_call_lands_on_disk_with_its_step_and_event(tmp_path):
    log = tmp_path / "usage.jsonl"

    usage_log.record(_u(), step="caption", event="decoda-2026-08-08", path=log)

    line = json.loads(log.read_text().strip())
    assert line["step"] == "caption"
    assert line["event"] == "decoda-2026-08-08"
    assert line["input_tokens"] == 1000
    assert line["cost_usd"] == pytest.approx(usage_log.cost_usd(_u()))


def test_recording_appends_rather_than_replacing(tmp_path):
    log = tmp_path / "usage.jsonl"

    usage_log.record(_u(), step="caption", path=log)
    usage_log.record(_u(), step="blog", path=log)

    assert len(log.read_text().strip().splitlines()) == 2


def test_a_failed_write_warns_and_does_not_break_the_generation(tmp_path, capsys):
    """Accounting must never take down a paid-for run."""
    unwritable = tmp_path / "nope" / "deep" / "usage.jsonl"
    unwritable.parent.mkdir(parents=True)
    unwritable.parent.chmod(0o500)
    try:
        ok = usage_log.record(_u(), step="caption", path=unwritable)
    finally:
        unwritable.parent.chmod(0o700)

    assert ok is False, "a write failure must be reported to the caller"
    assert "usage" in capsys.readouterr().err.lower(), \
        "a silently dropped record makes the total quietly wrong"


# ── summarising ───────────────────────────────────────────────────────────────

def test_a_summary_totals_the_calls_and_the_dollars(tmp_path):
    log = tmp_path / "usage.jsonl"
    usage_log.record(_u(inp=1_000_000, out=0), step="caption", path=log)
    usage_log.record(_u(inp=1_000_000, out=0), step="blog", path=log)

    s = usage_log.summarize(path=log)

    assert s.calls == 2
    assert s.input_tokens == 2_000_000
    assert s.cost_usd == pytest.approx(6.0)


def test_a_summary_breaks_the_spend_down_by_step(tmp_path):
    log = tmp_path / "usage.jsonl"
    usage_log.record(_u(), step="caption", path=log)
    usage_log.record(_u(), step="caption", path=log)
    usage_log.record(_u(), step="ocr", path=log)

    s = usage_log.summarize(path=log)

    assert s.by_step["caption"].calls == 2
    assert s.by_step["ocr"].calls == 1


def test_a_summary_can_be_scoped_to_one_event(tmp_path):
    log = tmp_path / "usage.jsonl"
    usage_log.record(_u(), step="caption", event="a", path=log)
    usage_log.record(_u(), step="caption", event="b", path=log)

    assert usage_log.summarize(path=log, event="a").calls == 1


def test_an_unpriced_call_is_counted_as_unpriced_not_as_free(tmp_path):
    log = tmp_path / "usage.jsonl"
    usage_log.record(_u(model="claude-sonnet-4-6", inp=1_000_000, out=0),
                     step="caption", path=log)
    usage_log.record(_u(model="claude-some-future-model", inp=1_000_000, out=0),
                     step="caption", path=log)

    s = usage_log.summarize(path=log)

    assert s.calls == 2
    assert s.unpriced_calls == 1, \
        "an unpriced call folded in at zero makes the bill read lower than it is"
    assert s.cost_usd == pytest.approx(3.0), "only the priced call may be totalled"
    assert not s.complete, "a total missing a call's cost must not read as final"


def test_an_unreadable_line_is_counted_rather_than_skipped(tmp_path):
    log = tmp_path / "usage.jsonl"
    usage_log.record(_u(), step="caption", path=log)
    with log.open("a", encoding="utf-8") as fh:
        fh.write("{ this is not json\n")

    s = usage_log.summarize(path=log)

    assert s.calls == 1
    assert s.unreadable_lines == 1
    assert not s.complete


def test_a_line_missing_its_numbers_does_not_read_as_a_zero_cost_call(tmp_path):
    """A partial write (a crash mid-append) must not quietly total as free."""
    log = tmp_path / "usage.jsonl"
    with log.open("w", encoding="utf-8") as fh:
        fh.write(json.dumps({"step": "caption", "model": "claude-sonnet-4-6"}) + "\n")

    s = usage_log.summarize(path=log)

    assert s.unreadable_lines == 1
    assert s.calls == 0


def test_a_summary_of_a_log_that_does_not_exist_is_empty_and_complete(tmp_path):
    s = usage_log.summarize(path=tmp_path / "absent.jsonl")

    assert s.calls == 0
    assert s.cost_usd == 0.0
    assert s.complete


# ── where the log lives ───────────────────────────────────────────────────────

def test_the_log_follows_the_app_data_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("POSTROLL_DATA_DIR", str(tmp_path))

    assert usage_log.default_log_path().parent == tmp_path


# ── attributing a week's spend to its event ───────────────────────────────────

def test_a_week_run_labels_its_calls_with_the_event(tmp_path, monkeypatch):
    """Without this every call records against no event, and 'what did this
    week cost' has no answer, which is the whole question #207 asks."""
    import postroll.ai.generate_week as gw

    monkeypatch.delenv("POSTROLL_EVENT", raising=False)
    photo = tmp_path / "p.jpg"
    photo.write_bytes(b"\xff\xd8\xff\xdb" + b"0" * 64)
    seen = []

    def run(*, day, **kwargs):
        seen.append(os.environ.get("POSTROLL_EVENT"))
        return {"caption": "c", "hashtags": [], "alt_texts": [], "scene_labels": []}

    monkeypatch.setattr(gw, "generate_caption", run)
    gw.generate_week({
        "event": "Music from Inside", "org": "O", "venue": "V",
        "date": "2026-08-08", "program": {"performers": [], "pieces": []},
        "days": {"sunday": {"photos": [str(photo)]}}, "blog_photos": [],
    }, tmp_path / "out.json")

    assert seen and all(s == "Music from Inside 2026-08-08" for s in seen), \
        f"calls ran with event {seen!r}"
