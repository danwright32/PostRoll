"""#352: a run says which path it took, and an unintended one is not silent.

`choose_transport` already composes a sentence explaining WHY it picked a
transport, and `Choice.reason` says outright that routing which cannot explain
itself cannot be debugged. Nothing read it.

So the app fell back to the CLI whenever the key was missing or unusable and
said nothing. That is not theoretical: the stored key was truncated from
2026-08-09 (#348), so everything ran on the CLI for two days. #213 then measured
what that path costs, roughly five times the wall clock, 57% of a week, and
output shaped by instructions that are not the app's (#354). A silent fall back
to it is a defect, not a convenience.
"""

from __future__ import annotations

import pytest

from postroll.ai import transport


@pytest.fixture(autouse=True)
def clean_env(monkeypatch):
    monkeypatch.delenv(transport.SUBSCRIPTION_ENV, raising=False)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)


def _request() -> transport.Request:
    return transport.Request(prompt="write it", step="blog")


def test_the_paid_path_is_the_intended_one(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-" + "A" * 101)

    choice = transport.choose_transport(_request())

    assert choice.transport == "sdk"
    assert transport.is_fallback(choice) is False


def test_running_on_the_cli_for_want_of_a_key_is_a_fallback():
    # Nobody chose this. It happens because the key is missing or unusable,
    # which is exactly the state that went unnoticed for two days.
    choice = transport.choose_transport(_request())

    assert choice.transport == "cli"
    assert transport.is_fallback(choice) is True


def test_the_subscription_switch_is_a_choice_not_a_fallback(monkeypatch):
    # Deliberately turning it on is not the same condition and must not be
    # reported as though something went wrong.
    monkeypatch.setenv(transport.SUBSCRIPTION_ENV, "1")

    choice = transport.choose_transport(_request())

    assert choice.transport == "cli"
    assert transport.is_fallback(choice) is False


def test_a_call_needing_web_tools_is_not_a_fallback(monkeypatch):
    # enrich_program genuinely needs the CLI, so it is the right path rather
    # than a degraded one.
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-" + "A" * 101)
    choice = transport.choose_transport(
        transport.Request(prompt="p", allowed_tools=("WebSearch",)))

    assert choice.transport == "cli"
    assert transport.is_fallback(choice) is False


def test_the_fallback_explains_itself_in_words():
    # The reason already exists and was being thrown away. Whatever surfaces
    # this has to have something to show.
    choice = transport.choose_transport(_request())

    assert "ANTHROPIC_API_KEY" in choice.reason
    assert transport.fallback_warning(choice)
    assert "slower" in transport.fallback_warning(choice).lower()


def test_there_is_no_warning_when_nothing_went_wrong(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-" + "A" * 101)

    assert transport.fallback_warning(transport.choose_transport(_request())) is None


# ── and something actually says it (L46: a field with no reader is not a fix) ──


def test_the_warning_reaches_stderr_when_a_call_falls_back(monkeypatch, capsys):
    from postroll.ai import claude_client

    monkeypatch.setattr(claude_client, "_run_cli", lambda prompt, **kw: "answered")
    transport.reset_fallback_notice()

    claude_client.run_prompt("write it", step="blog", model="sonnet")

    assert "nobody asked for" in capsys.readouterr().err


def test_it_says_so_once_and_not_on_every_call(monkeypatch, capsys):
    # Fourteen calls in a week. Repeating this on each would train Dan to skim
    # past it, which is how a real warning stops working (L36).
    from postroll.ai import claude_client

    monkeypatch.setattr(claude_client, "_run_cli", lambda prompt, **kw: "answered")
    transport.reset_fallback_notice()

    for _ in range(3):
        claude_client.run_prompt("write it", step="blog", model="sonnet")

    assert capsys.readouterr().err.count("nobody asked for") == 1


def test_nothing_is_said_when_the_intended_path_runs(monkeypatch, capsys):
    from postroll.ai import claude_client

    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-" + "A" * 101)
    monkeypatch.setattr(claude_client, "_run_sdk", lambda prompt, **kw: "answered")
    transport.reset_fallback_notice()

    claude_client.run_prompt("write it", step="blog", model="sonnet")

    assert capsys.readouterr().err == ""
