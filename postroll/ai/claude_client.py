"""
PostRoll — Anthropic API client

Uses the Anthropic Python SDK directly for all calls that don't require
Claude Code CLI tools (WebSearch, WebFetch). Falls back to the Claude
Code CLI only when those tools are explicitly requested.

Images are embedded as base64 content blocks when image_paths is provided.

Env:
    ANTHROPIC_API_KEY — required for SDK path
    POSTROLL_CLAUDE_BIN — path to `claude` binary (CLI fallback only)
"""

from __future__ import annotations

import base64
import json
import mimetypes
import os
import re
import subprocess
from pathlib import Path
from typing import Any

import anthropic


ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"
BRAND_VOICE_PATH = ASSETS_DIR / "brand-voice.md"

# Tools that require the Claude Code CLI (not available in SDK)
_CLI_ONLY_TOOLS = {"WebSearch", "WebFetch", "Bash"}

_MODEL_ALIASES: dict[str, str] = {
    "sonnet": "claude-sonnet-4-6",
    "opus":   "claude-opus-4-6",
    "haiku":  "claude-haiku-4-5-20251001",
}


class ClaudeError(RuntimeError):
    """Raised when the API fails or returns unparseable output."""


def _resolve_model(model: str) -> str:
    return _MODEL_ALIASES.get(model, model)


def load_brand_voice() -> str:
    """Read the brand voice system prompt from disk."""
    return BRAND_VOICE_PATH.read_text(encoding="utf-8")


def _image_block(path: Path) -> dict:
    """Build an Anthropic base64 image content block from a local file."""
    mime, _ = mimetypes.guess_type(str(path))
    if mime not in ("image/jpeg", "image/png", "image/gif", "image/webp"):
        mime = "image/jpeg"
    data = base64.standard_b64encode(path.read_bytes()).decode()
    return {
        "type": "image",
        "source": {"type": "base64", "media_type": mime, "data": data},
    }


def _needs_cli(allowed_tools: list[str] | None) -> bool:
    """Return True if any requested tool requires the Claude Code CLI,
    or if no ANTHROPIC_API_KEY is set (fall back to CLI auth)."""
    if not os.environ.get("ANTHROPIC_API_KEY"):
        return True
    if not allowed_tools:
        return False
    return bool(set(allowed_tools) & _CLI_ONLY_TOOLS)


# ── SDK path ──────────────────────────────────────────────────────────────────

def _run_sdk(
    prompt: str,
    *,
    timeout: int,
    image_paths: list[str | Path] | None,
    model: str,
) -> str:
    client = anthropic.Anthropic(
        api_key=os.environ.get("ANTHROPIC_API_KEY"),
        timeout=float(timeout),
    )
    content: list[dict] = []
    for p in (image_paths or []):
        content.append(_image_block(Path(p)))
    content.append({"type": "text", "text": prompt})

    try:
        message = client.messages.create(
            model=_resolve_model(model),
            max_tokens=8096,
            messages=[{"role": "user", "content": content}],
        )
    except anthropic.APIError as e:
        raise ClaudeError(f"Anthropic API error: {e}") from e

    text = message.content[0].text.strip() if message.content else ""
    if not text:
        raise ClaudeError("Anthropic API returned empty response")
    return text


# ── CLI fallback (web tools only) ─────────────────────────────────────────────

def _cli_binary() -> str:
    return os.environ.get("POSTROLL_CLAUDE_BIN", "claude")


def _run_cli(
    prompt: str,
    *,
    timeout: int,
    allowed_dirs: list[str | Path] | None,
    allowed_tools: list[str] | None,
    model: str,
) -> str:
    cmd: list[str] = [_cli_binary(), "-p", "--model", model]
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
            "`claude` binary not found. Set POSTROLL_CLAUDE_BIN or install Claude Code."
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


# ── Public interface ───────────────────────────────────────────────────────────

def run_prompt(
    prompt: str,
    *,
    timeout: int = 300,
    image_paths: list[str | Path] | None = None,
    allowed_dirs: list[str | Path] | None = None,
    allowed_tools: list[str] | None = None,
    model: str = "sonnet",
) -> str:
    """Send a prompt to Claude and return the raw text response.

    Uses the Anthropic SDK directly unless allowed_tools contains CLI-only
    tools (WebSearch, WebFetch), in which case falls back to the claude CLI.

    image_paths: local files embedded as base64 vision blocks (SDK path).
    allowed_dirs/allowed_tools: passed through to CLI when falling back.
    """
    if _needs_cli(allowed_tools):
        return _run_cli(
            prompt,
            timeout=timeout,
            allowed_dirs=allowed_dirs,
            allowed_tools=allowed_tools,
            model=model,
        )
    return _run_sdk(prompt, timeout=timeout, image_paths=image_paths, model=model)


def run_json_prompt(
    prompt: str,
    *,
    timeout: int = 300,
    image_paths: list[str | Path] | None = None,
    allowed_dirs: list[str | Path] | None = None,
    allowed_tools: list[str] | None = None,
    model: str = "sonnet",
) -> Any:
    """Send a prompt that should return JSON and parse the response."""
    raw = run_prompt(
        prompt,
        timeout=timeout,
        image_paths=image_paths,
        allowed_dirs=allowed_dirs,
        allowed_tools=allowed_tools,
        model=model,
    )
    return _extract_json(raw)


def _extract_json(text: str) -> Any:
    """Pull the first JSON object or array out of a response string."""
    fenced = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL)
    if fenced:
        text = fenced.group(1).strip()

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

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
