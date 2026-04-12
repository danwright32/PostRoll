"""
PostRoll — Claude Code CLI client

Thin wrapper around the `claude` CLI for non-interactive prompts. All AI
generators (OCR, captions, blog) call into this module so the subprocess
plumbing lives in one place.

The CLI is invoked with `claude -p PROMPT` which runs Claude Code in
print mode: it executes the prompt with full tool access (Read, etc.)
and prints the final assistant response to stdout. We capture that and
optionally parse JSON out of it.

Env override:
    POSTROLL_CLAUDE_BIN — path to the `claude` binary if not on PATH
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from pathlib import Path
from typing import Any


ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"
BRAND_VOICE_PATH = ASSETS_DIR / "brand-voice.md"


class ClaudeError(RuntimeError):
    """Raised when the Claude CLI fails or returns unparseable output."""


def _binary() -> str:
    return os.environ.get("POSTROLL_CLAUDE_BIN", "claude")


def load_brand_voice() -> str:
    """Read the brand voice system prompt from disk."""
    return BRAND_VOICE_PATH.read_text(encoding="utf-8")


def run_prompt(
    prompt: str,
    *,
    timeout: int = 300,
    allowed_dirs: list[str | Path] | None = None,
    allowed_tools: list[str] | None = None,
) -> str:
    """Send a prompt to Claude Code and return the raw text response.

    Args:
        prompt: The prompt text.
        timeout: Subprocess timeout in seconds.
        allowed_dirs: Directories Claude's tools may access (passed via
            --add-dir). Use this to grant Read access to image paths.
        allowed_tools: Restrict the available toolset (passed via
            --allowedTools). E.g. ["Read"] for read-only operations.

    Raises ClaudeError on non-zero exit or empty response.
    """
    # Pass the prompt via stdin so variadic flags like --add-dir and
    # --allowedTools can't accidentally consume it as one of their values.
    cmd: list[str] = [_binary(), "-p"]
    if allowed_dirs:
        cmd.append("--add-dir")
        cmd.extend(str(Path(d).resolve()) for d in allowed_dirs)
    if allowed_tools:
        cmd.append("--allowedTools")
        cmd.extend(allowed_tools)

    try:
        result = subprocess.run(
            cmd,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as e:
        raise ClaudeError(
            f"`claude` binary not found. Set POSTROLL_CLAUDE_BIN or install Claude Code."
        ) from e
    except subprocess.TimeoutExpired as e:
        raise ClaudeError(f"Claude CLI timed out after {timeout}s") from e

    if result.returncode != 0:
        raise ClaudeError(
            f"Claude CLI exited {result.returncode}: {result.stderr.strip()}"
        )

    text = result.stdout.strip()
    if not text:
        raise ClaudeError("Claude CLI returned empty output")
    return text


def run_json_prompt(
    prompt: str,
    *,
    timeout: int = 300,
    allowed_dirs: list[str | Path] | None = None,
    allowed_tools: list[str] | None = None,
) -> Any:
    """Send a prompt that should return JSON and parse the response.

    The prompt should ask Claude to return JSON only. This function
    extracts the first JSON object/array it finds in the response (so
    incidental wrapping like ```json fences is tolerated).
    """
    raw = run_prompt(
        prompt,
        timeout=timeout,
        allowed_dirs=allowed_dirs,
        allowed_tools=allowed_tools,
    )
    return _extract_json(raw)


def _extract_json(text: str) -> Any:
    """Pull the first JSON object or array out of a response string."""
    # Strip ``` fences if present
    fenced = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL)
    if fenced:
        text = fenced.group(1).strip()

    # Try the whole thing first
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # Find the first balanced { ... } or [ ... ] block
    for opener, closer in (("{", "}"), ("[", "]")):
        start = text.find(opener)
        if start == -1:
            continue
        depth = 0
        for i in range(start, len(text)):
            if text[i] == opener:
                depth += 1
            elif text[i] == closer:
                depth -= 1
                if depth == 0:
                    candidate = text[start : i + 1]
                    try:
                        return json.loads(candidate)
                    except json.JSONDecodeError:
                        break

    raise ClaudeError(f"Could not parse JSON from Claude response:\n{text[:500]}")
