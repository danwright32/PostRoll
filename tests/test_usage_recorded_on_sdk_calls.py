"""Usage is recorded where every AI call actually goes through (#207).

`_run_sdk` is the single seam: captions, OCR, blog, enrichment, every selector
and every review pass reach the API through it. Recording anywhere else would
measure part of the bill and report it as the whole.

The failure paths matter more than the happy one here, because this is
bookkeeping wrapped around work that has already been paid for:

* a broken log must not kill the generation, and
* a response carrying no usage must not be recorded as a zero-token call,
  which would read as a free call rather than an unmeasured one.
"""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from postroll.ai import claude_client as cc
from postroll.ai.claude_client import ClaudeError, run_prompt


def _fake_client(usage=SimpleNamespace(input_tokens=1200, output_tokens=340,
                                       cache_creation_input_tokens=0,
                                       cache_read_input_tokens=0)):
    message = SimpleNamespace(
        stop_reason="end_turn",
        content=[SimpleNamespace(text='{"ok": true}')],
        usage=usage,
    )

    class FakeMessages:
        def create(self, **kwargs):
            return message

    class FakeClient:
        def __init__(self, **kwargs):
            self.messages = FakeMessages()

    return FakeClient


@pytest.fixture
def log(tmp_path, monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    monkeypatch.setenv("POSTROLL_DATA_DIR", str(tmp_path))
    monkeypatch.delenv("POSTROLL_EVENT", raising=False)
    return tmp_path / "usage.jsonl"


def test_a_normal_call_is_recorded_with_its_tokens_and_step(log):
    with patch.object(cc.anthropic, "Anthropic", _fake_client()):
        run_prompt("hi", step="caption")

    line = json.loads(log.read_text().strip())
    assert line["step"] == "caption"
    assert line["input_tokens"] == 1200
    assert line["output_tokens"] == 340
    assert line["cost_usd"] > 0


def test_the_event_is_recorded_so_a_week_can_be_totalled(log, monkeypatch):
    monkeypatch.setenv("POSTROLL_EVENT", "decoda-2026-08-08")

    with patch.object(cc.anthropic, "Anthropic", _fake_client()):
        run_prompt("hi", step="caption")

    assert json.loads(log.read_text().strip())["event"] == "decoda-2026-08-08"


def test_json_calls_are_recorded_too(log):
    with patch.object(cc.anthropic, "Anthropic", _fake_client()):
        cc.run_json_prompt("hi", step="ocr")

    assert json.loads(log.read_text().strip())["step"] == "ocr"


def test_a_call_with_no_step_still_records_rather_than_going_unmeasured(log):
    with patch.object(cc.anthropic, "Anthropic", _fake_client()):
        run_prompt("hi")

    assert json.loads(log.read_text().strip())["input_tokens"] == 1200


# ── failure paths ─────────────────────────────────────────────────────────────

def test_a_broken_usage_log_does_not_break_the_generation(log, monkeypatch, capsys):
    """The answer has already been paid for; losing it over bookkeeping would
    cost more than the record is worth."""
    def boom(*a, **kw):
        raise OSError("disk full")

    monkeypatch.setattr(cc.usage_log, "record", boom)

    with patch.object(cc.anthropic, "Anthropic", _fake_client()):
        assert run_prompt("hi", step="caption") == '{"ok": true}'


def test_a_response_with_no_usage_warns_instead_of_recording_zeros(log, capsys):
    """A zero-token line would total as a free call. An unmeasured call has to
    look unmeasured."""
    message = SimpleNamespace(
        stop_reason="end_turn",
        content=[SimpleNamespace(text="ok")],
    )

    class FakeMessages:
        def create(self, **kwargs):
            return message

    class FakeClient:
        def __init__(self, **kwargs):
            self.messages = FakeMessages()

    with patch.object(cc.anthropic, "Anthropic", FakeClient):
        assert run_prompt("hi", step="caption") == "ok"

    assert not log.exists(), "a call with no token counts was recorded as free"
    assert "usage" in capsys.readouterr().err.lower()


def test_a_failed_call_records_nothing_rather_than_a_phantom_charge(log):
    class FakeMessages:
        def create(self, **kwargs):
            raise cc.anthropic.APIError("boom", request=None, body=None)

    class FakeClient:
        def __init__(self, **kwargs):
            self.messages = FakeMessages()

    with patch.object(cc.anthropic, "Anthropic", FakeClient):
        with pytest.raises(ClaudeError):
            run_prompt("hi", step="caption")

    assert not log.exists()


def test_review_passes_are_attributed_to_themselves(log):
    """Voice and humanizer passes are two extra billed calls per caption. If
    they recorded as 'unknown' the breakdown would hide the biggest multiplier
    on the week's bill."""
    seen = {}

    def runner(prompt, **kw):
        seen.update(kw)
        return {"caption": "revised"}

    cc.run_review_pass("p", {"caption": "draft"}, label="humanizer", runner=runner)

    assert seen.get("step") == "review:humanizer"


def test_a_truncated_response_still_records_the_tokens_it_burned(log):
    """max_tokens raises, but the tokens were spent and are on the bill."""
    message = SimpleNamespace(
        stop_reason="max_tokens",
        content=[SimpleNamespace(text="cut off mid")],
        usage=SimpleNamespace(input_tokens=900, output_tokens=16384,
                              cache_creation_input_tokens=0,
                              cache_read_input_tokens=0),
    )

    class FakeMessages:
        def create(self, **kwargs):
            return message

    class FakeClient:
        def __init__(self, **kwargs):
            self.messages = FakeMessages()

    with patch.object(cc.anthropic, "Anthropic", FakeClient):
        with pytest.raises(ClaudeError, match="truncated"):
            run_prompt("hi", step="blog")

    assert json.loads(log.read_text().strip())["output_tokens"] == 16384
