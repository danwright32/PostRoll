"""#213: the harness that judges the subscription path against the metered one.

The evidence for the subscription transport is two captions and three OCR runs
on one event, which is not enough to decide anything. This runs the SAME work
down both paths and reports what differs: the output, the wall clock, and what
each one spends.

Record and replay rather than two independent runs. Every AI call in the app
funnels through `claude_client.run_prompt`, so one metered pass captures the
exact prompts a real week makes, and the subscription pass replays those same
prompts. Two separate generations would differ in their inputs as well as their
transports, and there would be no way to tell which caused a difference.

Nothing here may reach a paid API. The runner is injected at every seam and the
tests pass a fake, so a harness bug cannot spend money (L2).
"""

from __future__ import annotations

import pytest

from tools import compare_transports as ct


def _record(step="captions", transport="sdk", seconds=1.0, output="hello",
            images=0, error=None, model="claude-sonnet-4-6", prompt="write it"):
    return ct.CallRecord(
        step=step, model=model, prompt=prompt, image_count=images,
        transport=transport, seconds=seconds, output=output, error=error)


# ── capturing a run ──────────────────────────────────────────────────────────


def test_a_capture_records_every_call_with_what_it_cost_in_time():
    calls = []
    runner = ct.RecordingRunner(
        lambda prompt, **kw: f"answered {prompt}",
        clock=iter([0.0, 2.5, 10.0, 11.0]).__next__,
        sink=calls.append)

    runner("first", step="captions", model="claude-sonnet-4-6")
    runner("second", step="blog", model="claude-sonnet-4-6")

    assert [c.step for c in calls] == ["captions", "blog"]
    assert [c.seconds for c in calls] == [2.5, 1.0]
    assert calls[0].output == "answered first"


def test_a_call_that_fails_is_recorded_rather_than_dropped():
    # A step left with no trace is indistinguishable from one never attempted,
    # so the run would report as clean while having lost work (L47).
    calls = []

    def boom(prompt, **kw):
        raise RuntimeError("the model refused")

    runner = ct.RecordingRunner(boom, clock=iter([0.0, 3.0]).__next__,
                                sink=calls.append)

    with pytest.raises(RuntimeError):
        runner("first", step="captions")

    assert len(calls) == 1
    assert calls[0].error == "the model refused"
    assert calls[0].output == ""
    assert calls[0].seconds == 3.0


def test_a_capture_that_recorded_nothing_is_not_a_successful_baseline():
    # Finding zero calls arrives exactly when the run did not happen, which is
    # the moment a clean verdict is most likely to be believed (L98).
    with pytest.raises(ct.NothingCaptured):
        ct.compare([], [])


# ── replaying it on the other transport ──────────────────────────────────────


def test_replay_sends_the_same_prompts_the_baseline_actually_made():
    baseline = [_record(step="captions", prompt="caption this"),
                _record(step="blog", prompt="write the post")]
    seen = []

    replayed = ct.replay(baseline, runner=lambda prompt, **kw: seen.append(prompt) or "ok",
                         clock=iter([0.0, 1.0, 1.0, 3.0]).__next__)

    assert seen == ["caption this", "write the post"]
    assert [r.seconds for r in replayed] == [1.0, 2.0]


def test_replay_refuses_a_call_the_subscription_path_cannot_carry():
    # The subscription transport routes through the CLI, which cannot attach
    # images. Replaying such a call would send the prompt with the photographs
    # missing and get back plausible text invented from nothing.
    baseline = [_record(step="ocr", images=4, prompt="read this programme")]
    seen = []

    replayed = ct.replay(baseline, runner=lambda prompt, **kw: seen.append(prompt) or "ok",
                         clock=iter([0.0, 1.0]).__next__)

    assert seen == [], "a call carrying images must not be sent"
    assert replayed[0].error and "image" in replayed[0].error
    assert replayed[0].output == ""


def test_a_refused_call_is_never_counted_as_matching_output():
    baseline = [_record(step="ocr", images=4, output="the real programme text")]
    candidate = ct.replay(baseline, runner=lambda prompt, **kw: "ok",
                          clock=iter([0.0, 1.0]).__next__)

    report = ct.compare(baseline, candidate)
    row = report.rows[0]

    assert row.verdict == "refused"
    assert not row.identical


# ── the report ───────────────────────────────────────────────────────────────


def test_identical_output_is_reported_as_identical():
    baseline = [_record(step="blog", output="the same words")]
    candidate = [_record(step="blog", output="the same words",
                         transport="cli", seconds=4.0)]

    row = ct.compare(baseline, candidate).rows[0]

    assert row.identical
    assert row.verdict == "identical"
    assert row.seconds_delta == pytest.approx(3.0)


def test_different_output_is_reported_with_the_difference_visible():
    baseline = [_record(step="blog", output="a night at the opera")]
    candidate = [_record(step="blog", output="a night at the ballet",
                         transport="cli")]

    row = ct.compare(baseline, candidate).rows[0]

    assert not row.identical
    assert row.verdict == "differs"
    assert "opera" in row.diff and "ballet" in row.diff


def test_a_step_missing_from_the_replay_is_reported_not_skipped():
    baseline = [_record(step="captions"), _record(step="blog")]
    candidate = [_record(step="captions")]

    report = ct.compare(baseline, candidate)

    assert [r.step for r in report.rows] == ["captions", "blog"]
    assert report.rows[1].verdict == "missing"


def test_the_summary_totals_the_wall_clock_of_each_path():
    baseline = [_record(step="a", seconds=2.0), _record(step="b", seconds=3.0)]
    candidate = [_record(step="a", seconds=5.0, transport="cli"),
                 _record(step="b", seconds=6.0, transport="cli")]

    report = ct.compare(baseline, candidate)

    assert report.baseline_seconds == 5.0
    assert report.candidate_seconds == 11.0


def test_the_summary_says_how_much_of_the_week_the_subscription_can_take():
    # The decision #213 exists for. If most of a week's work carries images,
    # the subscription path cannot take it however good its text output is.
    baseline = [_record(step="ocr", images=6), _record(step="alt", images=3),
                _record(step="blog", images=0)]

    report = ct.compare(baseline, ct.replay(
        baseline, runner=lambda prompt, **kw: "ok",
        clock=iter([0.0, 1.0]).__next__))

    assert report.calls_carrying_images == 2
    assert report.calls_total == 3


# ── the cost estimate, before anything is spent ──────────────────────────────


def test_the_estimate_reports_itself_incomplete_for_an_unpriced_model():
    # An unpriced model folded in at zero would under-report the bill hardest
    # in exactly the case where somebody changed the model.
    estimate = ct.estimate_usd([_record(model="claude-from-the-future")], tokens_per_call=1000)

    assert estimate.complete is False
    assert "claude-from-the-future" in estimate.unpriced


# ── the recorder is wired to a seam every caller really passes through ───────


def test_the_recorder_intercepts_a_call_made_through_a_direct_import(monkeypatch):
    """Built is not wired (L3).

    `generate_blog` and `generate_captions` do
    `from .claude_client import run_prompt`, which binds the function into their
    own namespace at import time. A recorder patching `claude_client.run_prompt`
    would never see those calls, and would hand back a clean empty capture,
    which is indistinguishable from a week where nothing was generated.
    """
    from postroll.ai import claude_client
    from postroll.ai import generate_blog

    # BOTH seams, not just the one this test expects to be taken. Stubbing only
    # the SDK seam let the router send this to the real CLI, which ran for three
    # and a half minutes on Dan's own allowance and came back carrying his
    # personal hooks' output. A test that reaches a paid service when its
    # routing assumption is wrong is not isolated, it is lucky (L2).
    for seam in ct.SEAMS:
        monkeypatch.setattr(claude_client, seam,
                            lambda prompt, **kw: "from the fake model")
    # Pin the routing so this test is about the recorder rather than about
    # whichever transport the machine running it happens to resolve to.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "not-a-real-key")
    monkeypatch.delenv("POSTROLL_USE_SUBSCRIPTION", raising=False)
    records, restore = install_recorder_under_test(claude_client)
    try:
        # Called through the binding generate_blog captured at import, which is
        # the path the real blog generator uses.
        answer = generate_blog.run_prompt("write the post", step="blog",
                                          model="claude-sonnet-4-6")
    finally:
        restore()

    assert answer == "from the fake model"
    assert [r.step for r in records] == ["blog"], (
        "the recorder is patched somewhere the app does not actually go through")


def install_recorder_under_test(claude_client):
    return ct.install_recorder(claude_client, clock=iter([0.0, 1.0] * 40).__next__)


def test_a_cli_routed_call_is_recorded_against_its_real_step(monkeypatch):
    """Both transports label their calls, so the report lines up (#343).

    This matters most under the subscription switch, which routes EVERY call
    through the CLI: a step lost here would collapse the whole comparison onto
    one unnamed row at exactly the point per step attribution is needed.
    """
    from postroll.ai import claude_client
    from postroll.ai import generate_blog

    for seam in ct.SEAMS:
        monkeypatch.setattr(claude_client, seam, lambda prompt, **kw: "answered")
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)   # forces the CLI route
    records, restore = install_recorder_under_test(claude_client)
    try:
        generate_blog.run_prompt("write the post", step="blog", model="sonnet")
    finally:
        restore()

    assert [(r.transport, r.step) for r in records] == [("cli", "blog")]


def test_every_seam_the_recorder_patches_is_a_real_function_on_the_client():
    # A seam named here that does not exist would be patched onto the module as
    # a new attribute, intercept nothing, and leave the capture empty while the
    # recorder reported itself installed.
    from postroll.ai import claude_client

    for seam in ct.SEAMS:
        assert callable(getattr(claude_client, seam, None)), (
            f"claude_client has no {seam} to record through")


def test_restoring_puts_the_real_functions_back(monkeypatch):
    # A recorder left installed would keep wrapping every later call in the
    # process, and a comparison run must not change how the app behaves after it.
    from postroll.ai import claude_client

    before = claude_client._run_sdk
    _, restore = install_recorder_under_test(claude_client)
    assert claude_client._run_sdk is not before
    restore()

    assert claude_client._run_sdk is before


def test_the_estimate_prices_a_known_model():
    estimate = ct.estimate_usd([_record(model="claude-sonnet-4-6")],
                               tokens_per_call=1_000_000)

    assert estimate.complete is True
    assert estimate.usd > 0
