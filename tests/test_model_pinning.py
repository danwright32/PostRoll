"""#472: both transports must send the same, concrete model.

Model pinning stopped at the transport boundary. The SDK path resolves the
alias through `_MODEL_ALIASES` before it builds the request; `_run_cli` passed
the raw string straight into the `claude -p --model` argv, so the installed
Claude Code CLI decided what "sonnet" meant.

That is the pinning hole with teeth. The subscription switch (#212) routes
EVERY call through the CLI path, so flipping it silently changed which model
answered, and the compare-transports harness that exists to judge that switch
was comparing two different models while reporting on one (L25, L28).

What this file does NOT do is invent a date suffix. The premise that the two
4-6 ids are undated aliases the vendor re-points does not hold: Anthropic's
model catalog lists no dated snapshot for `claude-sonnet-4-6` or
`claude-opus-4-6`, and states that the ids are complete as written and a date
must never be appended. A snapshot change arrives as a new version number
(`claude-opus-4-7`), not as a silent re-point of `claude-opus-4-6`. The
floating names are the bare words this module maps FROM, and the fix for those
is to resolve them everywhere, which is what is asserted below.
"""

from __future__ import annotations

import json

import pytest

from postroll.ai import claude_client, transport


#: Ids that really exist. An alias resolving to anything outside this set is
#: either a typo or an invented dated snapshot, and both 404 at request time,
#: which is a failure Dan meets as a dead run rather than as a wrong model.
KNOWN_IDS = {
    "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-opus-5",
    "claude-sonnet-4-6", "claude-sonnet-5",
    "claude-haiku-4-5", "claude-haiku-4-5-20251001",
    "claude-fable-5",
}


# ── the aliases themselves ────────────────────────────────────────────────────

@pytest.mark.parametrize("alias", sorted(claude_client._MODEL_ALIASES))
def test_every_alias_resolves_to_a_model_that_exists(alias):
    assert claude_client._resolve_model(alias) in KNOWN_IDS


@pytest.mark.parametrize("alias", sorted(claude_client._MODEL_ALIASES))
def test_no_alias_resolves_to_a_bare_floating_name(alias):
    # "sonnet" reaching a request is the whole defect: whoever receives it
    # picks the model, and that choice is invisible here.
    assert claude_client._resolve_model(alias) not in {"sonnet", "opus", "haiku"}


def test_a_concrete_id_is_passed_through_untouched():
    assert claude_client._resolve_model("claude-opus-5") == "claude-opus-5"


# ── the CLI path resolves too ─────────────────────────────────────────────────

def _cli_model_for(alias, monkeypatch):
    """Run the real CLI path and report the --model argument it sent."""
    seen: dict = {}

    def fake_run(cmd, **kwargs):
        seen["cmd"] = cmd

        class Result:
            returncode = 0
            stdout = "an answer"
            stderr = ""
        return Result()

    monkeypatch.setattr(claude_client.subprocess, "run", fake_run)
    claude_client._run_cli("a prompt", timeout=60, allowed_dirs=None,
                           allowed_tools=None, model=alias)
    cmd = seen["cmd"]
    return cmd[cmd.index("--model") + 1]


@pytest.mark.parametrize("alias", sorted(claude_client._MODEL_ALIASES))
def test_the_cli_call_sends_the_resolved_model(alias, monkeypatch):
    # Driving the real subprocess path rather than asserting the helper, for
    # the reason #212's test gives: asserting the helper alone passes happily
    # while nothing calls it.
    assert _cli_model_for(alias, monkeypatch) == claude_client._resolve_model(alias)


@pytest.mark.parametrize("alias", sorted(claude_client._MODEL_ALIASES))
def test_no_bare_alias_reaches_the_cli(alias, monkeypatch):
    assert _cli_model_for(alias, monkeypatch) in KNOWN_IDS


def test_the_cli_passes_a_concrete_id_through_unchanged(monkeypatch):
    assert _cli_model_for("claude-opus-5", monkeypatch) == "claude-opus-5"


# ── the two transports agree ──────────────────────────────────────────────────

@pytest.mark.parametrize("alias", sorted(claude_client._MODEL_ALIASES))
def test_both_transports_ask_for_the_same_model(alias, monkeypatch):
    """The comparison harness is worth nothing if the two sides differ.

    Not a self-agreeing check (L70): the SDK side is read out of the request
    the SDK path actually builds, and the CLI side out of the argv the CLI path
    actually runs, so a change to either one alone fails here.
    """
    sdk_seen: dict = {}

    class FakeMessages:
        def create(self, **kwargs):
            sdk_seen["model"] = kwargs["model"]

            class Block:
                type = "text"
                text = "an answer"

            class Msg:
                content = [Block()]
                usage = None
                stop_reason = "end_turn"
            return Msg()

    class FakeClient:
        messages = FakeMessages()

    monkeypatch.setattr(claude_client.anthropic, "Anthropic",
                        lambda **kw: FakeClient())
    monkeypatch.setattr(claude_client.usage_log, "record", lambda **kw: None)
    claude_client._run_sdk("a prompt", timeout=60, image_paths=None,
                           image_labels=None, model=alias)

    assert sdk_seen["model"] == _cli_model_for(alias, monkeypatch)


# ── the argv shape the resolution rides in ────────────────────────────────────

def test_cli_command_still_puts_the_model_where_the_cli_reads_it(tmp_path):
    settings = tmp_path / "settings.json"
    settings.write_text(json.dumps({"hooks": {}}), encoding="utf-8")

    cmd = transport.cli_command(binary="claude", model="claude-opus-5",
                                settings_path=settings)

    assert cmd[cmd.index("--model") + 1] == "claude-opus-5"
