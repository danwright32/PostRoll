"""The default AI path is the metered Anthropic API, not the free CLI (#85).

The PRD claimed "$0 API cost via Claude Code" in three places and the package
docstring said "no API costs". Neither was true of the shipped app: the Swift
app stores an API key in the Keychain and passes it to every Python call, so
`_needs_cli` returns False and the billed SDK path is what actually runs.

This pins the real selection logic so the corrected docs can't drift back.
"""

from __future__ import annotations

from postroll.ai.claude_client import _needs_cli


def test_a_set_api_key_means_the_metered_sdk_path(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")

    assert _needs_cli(None) is False, "this is the shipped app's normal case, and it bills"
    assert _needs_cli(["Read"]) is False


def test_no_api_key_falls_back_to_the_cli(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

    assert _needs_cli(None) is True


def test_a_cli_only_tool_forces_the_cli_even_with_a_key(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")

    assert _needs_cli(["WebSearch"]) is True
    assert _needs_cli(["WebFetch"]) is True


def test_the_docs_do_not_claim_the_ai_is_free():
    from pathlib import Path
    import postroll.ai as ai_pkg

    assert "no API costs" not in (ai_pkg.__doc__ or "").split("used to claim")[0]

    prd = (Path(__file__).resolve().parents[1] / "postroll-prd.md").read_text()
    assert "Claude Code: $0" not in prd
    assert "there are no ongoing API costs" not in prd
