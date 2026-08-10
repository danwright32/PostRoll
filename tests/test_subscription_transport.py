"""#212: run on Dan's Claude Code subscription, behind a switch that reverts.

Off by default. The paid Anthropic API stays the default path, and one
environment variable flips the whole app onto the subscription and back, because
the app draws on the same allowance Dan uses for his own Claude Code work and
he has to be able to take it back instantly.

**Session isolation is the part that is not obvious.** `claude -p` inherits the
user's own Claude Code configuration. Dan's personal hooks wrote an issue-review
banner into the middle of the JSON the app parses, and the first spike failed
outright on that. `--settings` with hooks disabled fixes it while keeping the
subscription login, whereas pointing at a clean config directory loses the login
entirely, since auth and config share a directory.

That failure is invisible in ordinary testing: it works perfectly on a machine
with no hooks and breaks on Dan's. So these assert the isolation is REQUESTED,
which is the thing that can silently go missing, rather than only that a call
succeeded on a machine where its absence would not show.
"""

from __future__ import annotations

import json

import pytest

from postroll.ai import transport
from postroll.ai.transport import Request


@pytest.fixture(autouse=True)
def clean_env(monkeypatch):
    monkeypatch.delenv("POSTROLL_USE_SUBSCRIPTION", raising=False)
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-test-not-a-real-key")


# ── the switch ────────────────────────────────────────────────────────────────

def test_the_paid_api_is_still_the_default():
    # Off by default is the whole safety property: nothing starts spending Dan's
    # own allowance because a flag was forgotten.
    assert transport.choose_transport(Request(prompt="hello")).transport == "sdk"
    assert not transport.subscription_enabled()


def test_the_switch_routes_everything_through_the_subscription(monkeypatch):
    monkeypatch.setenv("POSTROLL_USE_SUBSCRIPTION", "1")
    choice = transport.choose_transport(Request(prompt="hello"))
    assert choice.transport == "cli"
    assert "subscription" in choice.reason.lower()


def test_turning_it_off_goes_straight_back_to_the_paid_path(monkeypatch):
    monkeypatch.setenv("POSTROLL_USE_SUBSCRIPTION", "0")
    assert transport.choose_transport(Request(prompt="hello")).transport == "sdk"


def test_an_unset_or_junk_value_is_off_rather_than_on(monkeypatch):
    # The stored default of a spending gate is its OFF value, so forgetting to
    # set it produces the safe state.
    for value in ("", "no", "false", "maybe"):
        monkeypatch.setenv("POSTROLL_USE_SUBSCRIPTION", value)
        assert not transport.subscription_enabled(), f"{value!r} turned it on"


def test_the_switch_does_not_override_a_request_that_needs_the_cli_anyway(monkeypatch):
    # WebSearch has always forced the CLI. The subscription switch must not
    # change WHY that happens, or the reason shown to Dan becomes wrong.
    monkeypatch.delenv("POSTROLL_USE_SUBSCRIPTION", raising=False)
    choice = transport.choose_transport(
        Request(prompt="x", allowed_tools=("WebSearch",)))
    assert choice.transport == "cli"
    assert "WebSearch" in choice.reason


# ── session isolation ─────────────────────────────────────────────────────────

def test_the_isolated_settings_disable_hooks():
    # The measured failure: a personal hook wrote a banner into the middle of
    # the JSON the app parses.
    payload = json.loads(transport.isolated_settings_json())
    assert payload.get("hooks") == {}, (
        "hooks are not disabled, so whatever the user has configured runs "
        "inside the app's own calls and can write into the output it parses")


def test_the_isolated_settings_do_not_move_the_config_directory():
    # Auth and config share a directory, so a clean config directory loses the
    # subscription login and the whole point with it.
    raw = transport.isolated_settings_json()
    assert "CLAUDE_CONFIG_DIR" not in raw
    assert "configDir" not in raw


def test_a_subscription_call_asks_for_the_isolated_settings(tmp_path):
    cmd = transport.cli_command(
        binary="claude", model="claude-opus-5", settings_path=tmp_path / "s.json")
    assert "--settings" in cmd, (
        "no --settings flag, so the call inherits the user's own hooks. This "
        "passes on a machine with no hooks and breaks on Dan's, which is why "
        "it is asserted here rather than left to a live run")
    assert cmd[cmd.index("--settings") + 1] == str(tmp_path / "s.json")


def test_the_settings_flag_survives_the_other_flags(tmp_path):
    cmd = transport.cli_command(
        binary="claude", model="claude-opus-5", settings_path=tmp_path / "s.json",
        allowed_dirs=[tmp_path], allowed_tools=["WebSearch"])
    assert "--settings" in cmd
    assert "--add-dir" in cmd and "--allowedTools" in cmd
    # -p must stay first after the binary: it is what makes this non-interactive,
    # and an interactive call inside the app would hang forever.
    assert cmd[1] == "-p"


def test_the_settings_file_is_valid_json_the_cli_can_read():
    # Written to disk and handed to another process, so a payload that is not
    # JSON fails at the far end with a message about our own file.
    json.loads(transport.isolated_settings_json())


# ── the isolation reaches the real call, not just the helper ──────────────────

def test_the_real_cli_call_writes_and_passes_an_isolating_settings_file(monkeypatch):
    """The test #212 asks for: one that fails if the isolation goes missing.

    Asserting the helper alone would pass while nothing called it. This drives
    the actual subprocess path and reads the file that was handed to the CLI, so
    it fails on the machine where the absence would otherwise be invisible.
    """
    from postroll.ai import claude_client

    seen: dict = {}

    def fake_run(cmd, **kwargs):
        seen["cmd"] = cmd
        index = cmd.index("--settings")
        # Read it WHILE the call is in flight: it lives in a temp directory that
        # is deleted the moment the call returns, so reading it afterwards would
        # be reading nothing and passing for the wrong reason.
        seen["settings"] = json.loads(
            open(cmd[index + 1], encoding="utf-8").read())

        class Result:
            returncode = 0
            stdout = "an answer"
            stderr = ""
        return Result()

    monkeypatch.setattr(claude_client.subprocess, "run", fake_run)

    out = claude_client._run_cli(
        "a prompt", timeout=60, allowed_dirs=None,
        allowed_tools=["WebSearch"], model="claude-opus-5")

    assert out == "an answer"
    assert "--settings" in seen["cmd"], (
        "the shipping CLI call does not isolate itself from the user's config, "
        "so a personal hook can write into the output the app parses")
    assert seen["settings"]["hooks"] == {}


def test_the_settings_file_does_not_outlive_the_call(monkeypatch):
    # Nothing persists on disk to go stale, be edited by hand, or be picked up
    # by a later call that expected different isolation.
    from postroll.ai import claude_client

    captured: dict = {}

    def fake_run(cmd, **kwargs):
        captured["path"] = cmd[cmd.index("--settings") + 1]

        class Result:
            returncode = 0
            stdout = "ok"
            stderr = ""
        return Result()

    monkeypatch.setattr(claude_client.subprocess, "run", fake_run)
    claude_client._run_cli("p", timeout=10, allowed_dirs=None,
                           allowed_tools=None, model="claude-opus-5")

    import os
    assert not os.path.exists(captured["path"])


def test_the_swift_mirror_of_the_switch_name_agrees():
    """Swift exports this variable to force one run onto the paid path (#257).

    It cannot import the Python constant, so the name is restated there. A
    mismatch is silent in the worst way: the override would export a variable
    nothing reads, and a run Dan paid for on purpose would quietly go back to
    the subscription.
    """
    from pathlib import Path

    swift = (Path(__file__).resolve().parent.parent
             / "PostRollApp" / "Sources" / "Services" / "HaltedWeek.swift").read_text()
    assert f'static let subscriptionEnv = "{transport.SUBSCRIPTION_ENV}"' in swift, (
        f"Swift no longer mirrors {transport.SUBSCRIPTION_ENV}; the paid-path "
        f"override would export a name Python does not read")
