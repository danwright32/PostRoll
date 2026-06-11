"""Tests for the Claude CLI client wrapper.

These cover the deterministic parts (JSON extraction, brand voice load,
subprocess error handling) by mocking the subprocess. They don't require
the real `claude` binary to be installed.
"""

from __future__ import annotations

import json
import subprocess
from unittest.mock import patch

import pytest

from postroll.ai import claude_client
from postroll.ai.claude_client import (
    BRAND_VOICE_PATH,
    ClaudeError,
    _extract_json,
    load_brand_voice,
    run_json_prompt,
    run_prompt,
)


# === JSON extraction ===


def test_extract_json_plain_object():
    assert _extract_json('{"a": 1}') == {"a": 1}


def test_extract_json_plain_array():
    assert _extract_json('[1, 2, 3]') == [1, 2, 3]


def test_extract_json_with_fences():
    text = '```json\n{"a": 1, "b": [2, 3]}\n```'
    assert _extract_json(text) == {"a": 1, "b": [2, 3]}


def test_extract_json_with_bare_fences():
    text = '```\n{"x": "y"}\n```'
    assert _extract_json(text) == {"x": "y"}


def test_extract_json_with_leading_commentary():
    text = 'Here is the JSON you requested:\n\n{"key": "value"}\n\nLet me know if you need more.'
    assert _extract_json(text) == {"key": "value"}


def test_extract_json_nested_braces():
    text = 'prefix {"outer": {"inner": {"deep": true}}} suffix'
    assert _extract_json(text) == {"outer": {"inner": {"deep": True}}}


def test_extract_json_unparseable_raises():
    with pytest.raises(ClaudeError, match="Could not parse JSON"):
        _extract_json("this is not json at all")


# === Brand voice ===


def test_brand_voice_file_exists():
    assert BRAND_VOICE_PATH.exists()


def test_load_brand_voice_returns_text():
    text = load_brand_voice()
    assert isinstance(text, str)
    assert len(text) > 100
    # Sanity check that key sections survived
    assert "Dan Wright" in text
    assert "Captions" in text or "captions" in text.lower()


# === Subprocess wrapper ===


class _FakeCompleted:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


def test_run_prompt_returns_stdout():
    with patch.object(
        subprocess, "run", return_value=_FakeCompleted(stdout="hello world\n")
    ):
        assert run_prompt("any prompt") == "hello world"


def test_run_prompt_raises_on_nonzero_exit():
    with patch.object(
        subprocess,
        "run",
        return_value=_FakeCompleted(returncode=2, stderr="boom"),
    ):
        with pytest.raises(ClaudeError, match="exited 2"):
            run_prompt("any prompt")


def test_run_prompt_raises_on_empty_output():
    with patch.object(
        subprocess, "run", return_value=_FakeCompleted(stdout="")
    ):
        with pytest.raises(ClaudeError, match="empty output"):
            run_prompt("any prompt")


def test_run_prompt_raises_when_binary_missing():
    with patch.object(subprocess, "run", side_effect=FileNotFoundError()):
        with pytest.raises(ClaudeError, match="not found"):
            run_prompt("any prompt")


def test_run_prompt_raises_on_timeout():
    with patch.object(
        subprocess,
        "run",
        side_effect=subprocess.TimeoutExpired(cmd="claude", timeout=1),
    ):
        with pytest.raises(ClaudeError, match="timed out"):
            run_prompt("any prompt", timeout=1)


def test_run_prompt_with_images_and_no_api_key_raises(monkeypatch):
    """The CLI fallback cannot attach images; a vision call without an API
    key must fail loudly instead of generating fabricated output."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    with pytest.raises(ClaudeError, match="ANTHROPIC_API_KEY"):
        run_prompt("describe these", image_paths=["/tmp/x.jpg"])


def test_run_prompt_with_images_and_cli_tools_raises(monkeypatch):
    """Images plus CLI-only tools route to the CLI, which would drop the
    images silently. Must raise rather than proceed."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    with pytest.raises(ClaudeError, match="WebSearch"):
        run_prompt("x", image_paths=["/tmp/x.jpg"], allowed_tools=["WebSearch"])


def test_run_json_prompt_parses_response():
    payload = json.dumps({"caption": "x", "hashtags": ["#a"]})
    with patch.object(
        subprocess, "run", return_value=_FakeCompleted(stdout=payload)
    ):
        result = run_json_prompt("any prompt")
    assert result == {"caption": "x", "hashtags": ["#a"]}


def test_run_prompt_passes_allowed_dirs_and_tools(tmp_path):
    """--add-dir and --allowedTools should appear in the subprocess command."""
    captured = {}

    def fake_run(cmd, **kwargs):
        captured["cmd"] = cmd
        captured["input"] = kwargs.get("input")
        return _FakeCompleted(stdout="ok")

    with patch.object(subprocess, "run", side_effect=fake_run):
        run_prompt(
            "the prompt",
            allowed_dirs=[tmp_path],
            allowed_tools=["Read"],
        )

    cmd = captured["cmd"]
    # Standard prefix
    assert cmd[0].endswith("claude")
    assert "-p" in cmd
    # Permission flags wired
    assert "--add-dir" in cmd
    assert str(tmp_path.resolve()) in cmd
    assert "--allowedTools" in cmd
    assert "Read" in cmd
    # Prompt goes via stdin, not argv (variadic flags would eat it)
    assert "the prompt" not in cmd
    assert captured["input"] == "the prompt"


def test_run_prompt_omits_permission_flags_when_unspecified():
    """No --add-dir or --allowedTools when caller doesn't pass them."""
    captured = {}

    def fake_run(cmd, **kwargs):
        captured["cmd"] = cmd
        captured["input"] = kwargs.get("input")
        return _FakeCompleted(stdout="ok")

    with patch.object(subprocess, "run", side_effect=fake_run):
        run_prompt("the prompt")

    cmd = captured["cmd"]
    assert "--add-dir" not in cmd
    assert "--allowedTools" not in cmd
    assert cmd == [cmd[0], "-p", "--model", "sonnet"]
    assert captured["input"] == "the prompt"
