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
import io
import json
import mimetypes
import os
import re
import subprocess
import sys
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
    """Read the brand voice system prompt from disk.

    The writable copy lives at $POSTROLL_BRAND_VOICE (the app's data root, outside
    the TCC-protected Documents checkout) when the app sets it. On first use that
    copy won't exist yet, so we seed it from the bundled default. Without the env
    var (CLI / dev), fall back to the in-repo default.
    """
    override = os.environ.get("POSTROLL_BRAND_VOICE")
    if not override:
        return BRAND_VOICE_PATH.read_text(encoding="utf-8")

    target = Path(override)
    if not target.exists():
        default = BRAND_VOICE_PATH.read_text(encoding="utf-8")
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(default, encoding="utf-8")
        except OSError:
            return default
    return target.read_text(encoding="utf-8")


# The API downscales images to this long edge server side before
# tokenising, so sending anything larger only inflates the request
# (413 request_too_large on big batches) and upload time.
MAX_IMAGE_EDGE = 1568


def _image_block(path: Path) -> dict:
    """Build an Anthropic base64 image content block from a local file.

    Full resolution concert JPEGs are commonly 5 to 15 MB; anything whose
    long edge exceeds MAX_IMAGE_EDGE is downscaled in memory first. The
    model sees identical pixels either way (see MAX_IMAGE_EDGE).
    """
    mime, _ = mimetypes.guess_type(str(path))
    if mime not in ("image/jpeg", "image/png", "image/gif", "image/webp"):
        mime = "image/jpeg"
    raw = path.read_bytes()

    try:
        from PIL import Image

        with Image.open(io.BytesIO(raw)) as img:
            if max(img.size) > MAX_IMAGE_EDGE:
                img.thumbnail((MAX_IMAGE_EDGE, MAX_IMAGE_EDGE), Image.LANCZOS)
                buf = io.BytesIO()
                if mime == "image/png":
                    # Program pages: keep PNG so small text stays crisp
                    img.save(buf, format="PNG")
                else:
                    if img.mode not in ("RGB", "L"):
                        img = img.convert("RGB")
                    img.save(buf, format="JPEG", quality=88)
                    mime = "image/jpeg"
                raw = buf.getvalue()
    except Exception as e:
        # Not fatal: the API downscales server side; we just upload more.
        print(f"warning: could not downscale {path.name}: {e}",
              file=sys.stderr, flush=True)

    data = base64.standard_b64encode(raw).decode()
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
    image_labels: list[str] | None,
    model: str,
) -> str:
    client = anthropic.Anthropic(
        api_key=os.environ.get("ANTHROPIC_API_KEY"),
        timeout=float(timeout),
        # SDK-level retry with backoff for 429/overloaded/5xx, so a single
        # transient blip doesn't fail a multi-pass generation chain.
        max_retries=4,
    )
    content: list[dict] = []
    paths = list(image_paths or [])
    labels = list(image_labels) if image_labels is not None else None
    if labels is not None and len(labels) != len(paths):
        raise ValueError(
            f"image_labels has {len(labels)} entries but image_paths has {len(paths)}"
        )
    for i, p in enumerate(paths):
        if labels is not None:
            content.append({"type": "text", "text": f"Photo {i + 1}: {labels[i]}"})
        content.append(_image_block(Path(p)))
    content.append({"type": "text", "text": prompt})

    try:
        message = client.messages.create(
            model=_resolve_model(model),
            # Generous cap (within every aliased model's output limit): a
            # week batch or long blog through three review passes can run
            # well past 8k tokens. Cost scales with tokens used, not the cap.
            max_tokens=16384,
            messages=[{"role": "user", "content": content}],
        )
    except anthropic.APIError as e:
        raise ClaudeError(f"Anthropic API error: {e}") from e

    if message.stop_reason == "max_tokens":
        # A truncated response would otherwise surface as a confusing JSON
        # parse failure (or silently clipped text for plain prompts).
        raise ClaudeError(
            "Response was truncated at the max_tokens cap. The prompt or "
            "requested output is too large; try fewer photos or a shorter "
            "input, then retry."
        )

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
    image_labels: list[str] | None = None,
    allowed_dirs: list[str | Path] | None = None,
    allowed_tools: list[str] | None = None,
    model: str = "sonnet",
) -> str:
    """Send a prompt to Claude and return the raw text response.

    Uses the Anthropic SDK directly unless allowed_tools contains CLI-only
    tools (WebSearch, WebFetch), in which case falls back to the claude CLI.

    image_paths: local files embedded as base64 vision blocks (SDK path).
    image_labels: parallel list to image_paths. When provided, each image
        is preceded in the message by a tiny `Photo N: <label>` text block,
        giving the model an unambiguous local anchor between each image
        and its filename. Length must match image_paths.
    allowed_dirs/allowed_tools: passed through to CLI when falling back.
    """
    if _needs_cli(allowed_tools):
        # The CLI path cannot attach images. Falling back with images would
        # silently drop them all and Claude would fabricate plausible looking
        # OCR data, alt text, and captions from nothing. Fail loudly instead.
        if image_paths:
            if not os.environ.get("ANTHROPIC_API_KEY"):
                raise ClaudeError(
                    "ANTHROPIC_API_KEY is not set, and this call attaches "
                    f"{len(image_paths)} image(s). The Claude CLI fallback "
                    "cannot attach images, so continuing would generate "
                    "output from nothing. Set the API key and retry."
                )
            cli_tools = sorted(set(allowed_tools or []) & _CLI_ONLY_TOOLS)
            raise ClaudeError(
                f"This call attaches {len(image_paths)} image(s) but requests "
                f"CLI-only tools {cli_tools}; the CLI path cannot attach "
                "images. Split the call or drop the web tools."
            )
        return _run_cli(
            prompt,
            timeout=timeout,
            allowed_dirs=allowed_dirs,
            allowed_tools=allowed_tools,
            model=model,
        )
    return _run_sdk(
        prompt,
        timeout=timeout,
        image_paths=image_paths,
        image_labels=image_labels,
        model=model,
    )


def run_json_prompt(
    prompt: str,
    *,
    timeout: int = 300,
    image_paths: list[str | Path] | None = None,
    image_labels: list[str] | None = None,
    allowed_dirs: list[str | Path] | None = None,
    allowed_tools: list[str] | None = None,
    model: str = "sonnet",
) -> Any:
    """Send a prompt that should return JSON and parse the response."""
    raw = run_prompt(
        prompt,
        timeout=timeout,
        image_paths=image_paths,
        image_labels=image_labels,
        allowed_dirs=allowed_dirs,
        allowed_tools=allowed_tools,
        model=model,
    )
    return _extract_json(raw)


def run_review_pass(
    prompt: str,
    prior: dict,
    *,
    label: str,
    timeout: int = 300,
    runner=None,
    validate=None,
) -> dict:
    """Run a quality review pass (voice, humanizer) over an existing draft.

    Review passes improve a draft; they do not define correctness. A rate
    limit or network blip here must not discard the already paid-for draft,
    so any failure (or a non-dict response) keeps the prior draft and warns
    on stderr instead of raising.

    runner: callers pass their own module-level run_json_prompt binding so
    tests that patch that name still intercept review pass calls.

    validate: optional callable (prior, revised) -> problem string or None.
    When the revision breaks a hard invariant (e.g. dropped a [PHOTO:]
    marker), the prior draft is kept instead.
    """
    run = runner or run_json_prompt
    try:
        data = run(prompt, timeout=timeout)
    except ClaudeError as e:
        print(
            f"warning: {label} pass failed, keeping previous draft: {e}",
            file=sys.stderr, flush=True,
        )
        return prior
    if not isinstance(data, dict):
        print(
            f"warning: {label} pass returned {type(data).__name__}, "
            "keeping previous draft",
            file=sys.stderr, flush=True,
        )
        return prior
    if validate is not None:
        problem = validate(prior, data)
        if problem:
            print(
                f"warning: {label} pass {problem}, keeping previous draft",
                file=sys.stderr, flush=True,
            )
            return prior
    return data


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
