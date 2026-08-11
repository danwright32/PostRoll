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


def test_a_failure_reported_on_stdout_is_not_thrown_away():
    """#296: the CLI splits its failures across both streams.

    Measured against 2.1.227 on 2026-08-10. A runtime failure reports on
    STDOUT: `claude -p --model definitely-not-a-real-model` exits 1 with "There's
    an issue with the selected model" on stdout, while stderr carried an
    unrelated context-window warning. A usage cap is a runtime condition, so
    keeping stderr alone meant the cap halt could never fire and the
    unrecognised-failures log would record the wrong text, wasting the one
    sample #258 needs.
    """
    with patch.object(
        subprocess,
        "run",
        return_value=_FakeCompleted(
            returncode=1,
            stdout="There's an issue with the selected model (bogus).",
            stderr="unrelated warning about the context window",
        ),
    ):
        with pytest.raises(ClaudeError) as caught:
            run_prompt("any prompt")

    assert "issue with the selected model" in str(caught.value)


def test_a_failure_reported_on_stderr_is_still_kept():
    # Startup and config failures do come out on stderr: `--settings
    # /nonexistent.json` exits 1 with "Error: Settings file not found" there.
    # Preferring stdout must not lose this half.
    with patch.object(
        subprocess,
        "run",
        return_value=_FakeCompleted(
            returncode=1, stdout="", stderr="Error: Settings file not found: /nope.json"),
    ):
        with pytest.raises(ClaudeError, match="Settings file not found"):
            run_prompt("any prompt")


def test_the_reason_comes_before_the_noise():
    # cap_signals matches substrings over this text, and stderr is known to
    # carry warnings unrelated to the failure. Ordering the stream that holds
    # the reason first keeps a stray phrase from being what a matcher sees
    # first.
    with patch.object(
        subprocess,
        "run",
        return_value=_FakeCompleted(
            returncode=1, stdout="usage limit reached", stderr="auto-compact will keep"),
    ):
        with pytest.raises(ClaudeError) as caught:
            run_prompt("any prompt")

    message = str(caught.value)
    assert message.index("usage limit reached") < message.index("auto-compact")


def test_a_failure_with_nothing_on_either_stream_says_so():
    # An exit code with no text is a different fact from a message, and a
    # blank tail would read as a message that failed to load.
    with patch.object(
        subprocess, "run", return_value=_FakeCompleted(returncode=137),
    ):
        with pytest.raises(ClaudeError, match="no output on either stream"):
            run_prompt("any prompt")


def test_a_cap_on_stdout_is_recognised_end_to_end():
    """The whole point: the halt has to be able to fire.

    Classifying the raised message is what `generate_week` does, so this is the
    real path rather than a stub of it.
    """
    from postroll.ai import cap_signals

    with patch.object(
        subprocess,
        "run",
        return_value=_FakeCompleted(
            returncode=1, stdout="Usage limit reached", stderr="auto-compact will keep"),
    ):
        with pytest.raises(ClaudeError) as caught:
            run_prompt("any prompt")

    assert cap_signals.should_halt(cap_signals.classify(str(caught.value)))


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
    # --settings is NOT a permission flag and is always present: it isolates the
    # call from the user's own Claude Code hooks, which otherwise write into the
    # output this app parses (#212).
    assert cmd[:4] == [cmd[0], "-p", "--model", "sonnet"]
    assert cmd[4] == "--settings"
    assert len(cmd) == 6, f"unexpected extra flags: {cmd[6:]}"
    assert captured["input"] == "the prompt"


# === Review pass fallback ===


def test_run_review_pass_keeps_prior_draft_on_failure():
    """A transient API failure in a review pass must not discard the
    already generated draft."""
    from postroll.ai.claude_client import run_review_pass

    prior = {"caption": "the paid-for draft", "hashtags": ["#a"]}

    def failing_runner(prompt, timeout=300, **kwargs):
        raise ClaudeError("overloaded")

    result = run_review_pass("review it", prior, label="voice", runner=failing_runner)
    assert result == prior


def test_run_review_pass_keeps_prior_draft_on_non_dict():
    from postroll.ai.claude_client import run_review_pass

    prior = {"caption": "draft"}
    result = run_review_pass(
        "review it", prior, label="humanizer", runner=lambda p, timeout=300, **kw: ["wrong shape"]
    )
    assert result == prior


def test_run_review_pass_returns_revision_on_success():
    from postroll.ai.claude_client import run_review_pass

    prior = {"caption": "draft"}
    revised = {"caption": "improved draft"}
    result = run_review_pass(
        "review it", prior, label="voice", runner=lambda p, timeout=300, **kw: revised
    )
    assert result == revised


# === Image block downscaling ===


def test_image_block_downscales_oversized_photos(tmp_path):
    """Full resolution photos must be downscaled to the API's server side
    cap before base64 encoding; larger uploads only risk 413 errors."""
    import base64
    import io
    from PIL import Image
    from postroll.ai.claude_client import MAX_IMAGE_EDGE, _image_block

    src = tmp_path / "big.jpg"
    Image.new("RGB", (6000, 4000), (90, 70, 60)).save(src, quality=95)

    block = _image_block(src)
    decoded = base64.standard_b64decode(block["source"]["data"])
    with Image.open(io.BytesIO(decoded)) as out:
        assert max(out.size) == MAX_IMAGE_EDGE
        # Aspect ratio preserved
        assert abs(out.size[0] / out.size[1] - 1.5) < 0.01
    assert block["source"]["media_type"] == "image/jpeg"


def test_image_block_leaves_small_photos_untouched(tmp_path):
    import base64
    from PIL import Image
    from postroll.ai.claude_client import _image_block

    src = tmp_path / "small.jpg"
    Image.new("RGB", (800, 600), (90, 70, 60)).save(src)

    block = _image_block(src)
    assert base64.standard_b64decode(block["source"]["data"]) == src.read_bytes()


# === Truncation detection (SDK path) ===


def test_sdk_truncated_response_raises_clear_error(monkeypatch):
    """A response cut off at max_tokens must raise a clear error instead of
    surfacing as a confusing JSON parse failure downstream."""
    from types import SimpleNamespace
    from postroll.ai import claude_client as cc

    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")

    fake_message = SimpleNamespace(
        stop_reason="max_tokens",
        content=[SimpleNamespace(text='{"caption": "cut off mid')],
    )

    class FakeMessages:
        def create(self, **kwargs):
            return fake_message

    class FakeClient:
        def __init__(self, **kwargs):
            self.messages = FakeMessages()

    with patch.object(cc.anthropic, "Anthropic", FakeClient):
        with pytest.raises(ClaudeError, match="truncated"):
            run_prompt("write a very long thing")


def test_sdk_normal_response_passes_through(monkeypatch):
    from types import SimpleNamespace
    from postroll.ai import claude_client as cc

    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")

    fake_message = SimpleNamespace(
        stop_reason="end_turn",
        content=[SimpleNamespace(text='{"caption": "complete"}')],
    )

    class FakeMessages:
        def create(self, **kwargs):
            return fake_message

    class FakeClient:
        def __init__(self, **kwargs):
            self.messages = FakeMessages()

    with patch.object(cc.anthropic, "Anthropic", FakeClient):
        assert run_prompt("hi") == '{"caption": "complete"}'


# === Content-block selection (SDK path) ===
#
# Real SDK blocks always declare a `type`. Current models emit a thinking
# block before the text block, so "the first block" is not the answer.


class _ThinkingBlock:
    """Shape of anthropic.types.ThinkingBlock: no `.text` at all."""

    type = "thinking"

    def __init__(self, thinking: str) -> None:
        self.thinking = thinking
        self.signature = "sig"


class _TextBlock:
    type = "text"

    def __init__(self, text: str) -> None:
        self.text = text


def _sdk_reply(monkeypatch, blocks, stop_reason="end_turn"):
    """Run run_prompt against a hand-built message with these content blocks."""
    from types import SimpleNamespace
    from postroll.ai import claude_client as cc

    monkeypatch.setenv("ANTHROPIC_API_KEY", "test-key")
    fake_message = SimpleNamespace(stop_reason=stop_reason, content=blocks)

    class FakeMessages:
        def create(self, **kwargs):
            return fake_message

    class FakeClient:
        def __init__(self, **kwargs):
            self.messages = FakeMessages()

    with patch.object(cc.anthropic, "Anthropic", FakeClient):
        return run_prompt("hi")


def test_sdk_skips_a_leading_thinking_block(monkeypatch):
    """The failure that blocks every newer model: a thinking block first."""
    blocks = [_ThinkingBlock("let me consider"), _TextBlock("the answer")]
    assert _sdk_reply(monkeypatch, blocks) == "the answer"


def test_sdk_no_text_block_names_what_came_back(monkeypatch):
    """No text at all is a ClaudeError naming the block types, never an
    AttributeError from reaching for `.text` on something that lacks it."""
    with pytest.raises(ClaudeError, match="thinking"):
        _sdk_reply(monkeypatch, [_ThinkingBlock("only thought about it")])


def test_sdk_refusal_stop_reason_is_its_own_error(monkeypatch):
    """A refusal is a distinct cause and gets a distinct message, rather than
    surfacing as an empty response."""
    with pytest.raises(ClaudeError, match="declined"):
        _sdk_reply(monkeypatch, [], stop_reason="refusal")


def test_run_review_pass_validator_keeps_prior_on_broken_invariant():
    """A review pass that drops a hard invariant (e.g. a PHOTO marker)
    must be discarded in favor of the prior draft."""
    from postroll.ai.claude_client import run_review_pass

    prior = {"body": "[PHOTO: a.jpg | x]\n\ntext"}
    revised = {"body": "rewritten without the marker"}

    result = run_review_pass(
        "review", prior, label="humanizer",
        runner=lambda p, timeout=300, **kw: revised,
        validate=lambda pr, rv: "dropped markers" if "[PHOTO:" not in rv["body"] else None,
    )
    assert result == prior


# === Image budget and resize failure (#218, #215) ===


def test_the_image_cap_follows_the_resolved_model(tmp_path):
    """#218: two places decided how large an image may be, the module constant
    here and image_budget_for in the splitter. They agreed for the pinned model
    and would drift silently on the next model change."""
    from postroll.ai.claude_client import _image_block
    from postroll.media.page_regions import image_budget_for
    from PIL import Image
    import base64, io

    src = tmp_path / "wide.jpg"
    Image.new("RGB", (4000, 2000), (10, 20, 30)).save(src)

    for model in ("sonnet", "claude-sonnet-4-6"):
        block = _image_block(src, model=model)
        decoded = base64.standard_b64decode(block["source"]["data"])
        with Image.open(io.BytesIO(decoded)) as out:
            assert max(out.size) == image_budget_for(model), model


def test_a_bigger_budget_sends_a_bigger_image(tmp_path, monkeypatch):
    """The cap must MOVE with the model, which a constant cannot do."""
    from postroll.ai import claude_client as cc
    from PIL import Image
    import base64, io

    src = tmp_path / "wide.jpg"
    Image.new("RGB", (4000, 2000), (10, 20, 30)).save(src)

    monkeypatch.setattr("postroll.media.page_regions.image_budget_for",
                        lambda model: 800)
    block = cc._image_block(src, model="anything")
    decoded = base64.standard_b64decode(block["source"]["data"])
    with Image.open(io.BytesIO(decoded)) as out:
        assert max(out.size) == 800


def test_a_failed_resize_refuses_rather_than_sending_the_original(tmp_path, monkeypatch):
    """#215: the resize was wrapped in a bare except that printed a warning and
    carried on with the full-size original.

    That was justified by 'the API downscales server side; we just upload
    more', and #200 established the server-side downscale is exactly what
    destroys character accuracy in program text. So a resize failure silently
    produced the WORST case for OCR, and the only trace was a log line."""
    from postroll.ai import claude_client as cc

    src = tmp_path / "page.png"
    src.write_bytes(b"not a real png")

    with pytest.raises(ClaudeError) as excinfo:
        cc._image_block(src)

    assert "page.png" in str(excinfo.value), "the message must name the file"


def test_the_refusal_explains_why_sending_it_would_be_worse(tmp_path):
    from postroll.ai import claude_client as cc

    src = tmp_path / "broken.jpg"
    src.write_bytes(b"\xff\xd8 not really a jpeg")

    with pytest.raises(ClaudeError, match="reduce"):
        cc._image_block(src)


def test_a_small_valid_image_still_goes_through_untouched(tmp_path):
    """The refusal must not fire on the ordinary case."""
    from postroll.ai.claude_client import _image_block
    from PIL import Image
    import base64

    src = tmp_path / "small.jpg"
    Image.new("RGB", (800, 600), (90, 70, 60)).save(src)

    block = _image_block(src)
    assert base64.standard_b64decode(block["source"]["data"]) == src.read_bytes()


# === A review pass must not drop fields it was never asked about (#202) ===


def test_a_review_pass_keeps_fields_the_reviewer_did_not_return():
    """#202: writing a caption is three model calls. The draft produces
    `famous_people`; the two review passes are asked only for the caption
    shape, so they do not echo it back, and returning the reviewer's object
    wholesale deleted it. The fame gate then read an always-empty field, so a
    genuinely famous performer's hashtag was stripped like everyone else's."""
    from postroll.ai.claude_client import run_review_pass

    prior = {"caption": "draft", "hashtags": ["#a"], "famous_people": ["Yo-Yo Ma"]}
    revised = {"caption": "polished", "hashtags": ["#a"]}

    result = run_review_pass("review", prior, label="voice",
                             runner=lambda p, timeout=300, **kw: revised)

    assert result["caption"] == "polished", "the review must still apply"
    assert result["famous_people"] == ["Yo-Yo Ma"], "the marker must survive the pass"


def test_a_reviewer_may_still_change_a_field_it_does_return():
    from postroll.ai.claude_client import run_review_pass

    prior = {"caption": "draft", "hashtags": ["#old"], "famous_people": ["X"]}
    revised = {"caption": "new", "hashtags": ["#new"]}

    result = run_review_pass("review", prior, label="voice",
                             runner=lambda p, timeout=300, **kw: revised)

    assert result["hashtags"] == ["#new"]


def test_a_reviewer_may_deliberately_empty_a_field_it_returns():
    """Merging must not resurrect a value the reviewer explicitly cleared."""
    from postroll.ai.claude_client import run_review_pass

    prior = {"caption": "d", "famous_people": ["X"]}
    revised = {"caption": "d", "famous_people": []}

    result = run_review_pass("review", prior, label="voice",
                             runner=lambda p, timeout=300, **kw: revised)

    assert result["famous_people"] == []


def test_two_review_passes_in_a_row_still_carry_the_marker():
    """The real shape: voice then humanizer. One pass surviving is not enough."""
    from postroll.ai.claude_client import run_review_pass

    prior = {"caption": "draft", "famous_people": ["Yo-Yo Ma"]}
    after_voice = run_review_pass("v", prior, label="voice",
                                  runner=lambda p, timeout=300, **kw: {"caption": "v"})
    after_human = run_review_pass("h", after_voice, label="humanizer",
                                  runner=lambda p, timeout=300, **kw: {"caption": "h"})

    assert after_human["caption"] == "h"
    assert after_human["famous_people"] == ["Yo-Yo Ma"]
