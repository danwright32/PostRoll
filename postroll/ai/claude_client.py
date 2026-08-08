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

from . import transport, usage_log


ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"
BRAND_VOICE_PATH = ASSETS_DIR / "brand-voice.md"

# Tools that require the Claude Code CLI (not available in SDK). Defined once,
# in transport, so the resolver and the error message below cannot disagree.
_CLI_ONLY_TOOLS = transport.CLI_ONLY_TOOLS

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


# Long-edge cap applied before upload. Sending anything larger mostly inflates
# the request (413 request_too_large on big batches) and upload time.
#
# Capping a whole program page here puts its small print exactly ON the
# boundary of legibility. Measured on the real BLUDLINE page (#207), five runs
# per build: a 3024x4032 page capped to 1176x1568 reads the performer "Safa"
# as "5afa" 0 times out of 5 correct, under three different resamplers, and
# still fails when everything except that band is painted white. The same band
# cropped and sent as its own image reads "Safa" 5 out of 5.
#
# Total area, resampling and surrounding content were each tested and each
# ruled out: builds at the same 1.84MP area and the same 0.389 scale both pass
# and fail. What decides it is sub-pixel sampling phase, which nothing here
# controls. So this constant cannot be tuned into correctness.
#
# The fix is to give each region of interest its own image, so it gets the full
# per-image budget instead of a share of the page's (#208). Left as-is until
# that lands. Note the budget belongs to the RESOLVED MODEL, not to this
# module: sonnet-4-6 and the Opus 4.7+ tier do not share a limit.
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
    return transport.choose_transport(
        transport.Request(prompt="", allowed_tools=tuple(allowed_tools or ()))
    ).transport == "cli"


# ── SDK path ──────────────────────────────────────────────────────────────────

def _record_usage(message: Any, model: str, step: str) -> None:
    """Log what this call cost. Never raises: the answer is already paid for.

    A response with no usable token counts is NOT recorded as a zero-token
    call. Zero would total as a free call rather than an unmeasured one, so it
    is reported on stderr and left out, which is what `Summary.complete` and
    the operator both need to see.
    """
    raw = getattr(message, "usage", None)
    counts = {
        key: getattr(raw, key, None)
        for key in ("input_tokens", "output_tokens")
    }
    if not all(isinstance(v, int) for v in counts.values()):
        print(
            f"warning: no usage counts on the {step} response, so this call is "
            "missing from the AI spend total.",
            file=sys.stderr, flush=True,
        )
        return
    try:
        usage_log.record(
            usage_log.Usage(
                model=model,
                input_tokens=counts["input_tokens"],
                output_tokens=counts["output_tokens"],
                cache_read_tokens=getattr(raw, "cache_read_input_tokens", 0) or 0,
                cache_write_tokens=getattr(raw, "cache_creation_input_tokens", 0) or 0,
            ),
            step=step,
        )
    except Exception as e:  # noqa: BLE001 - bookkeeping must not fail a paid run
        print(f"warning: could not record {step} usage: {e}",
              file=sys.stderr, flush=True)


def _run_sdk(
    prompt: str,
    *,
    timeout: int,
    image_paths: list[str | Path] | None,
    image_labels: list[str] | None,
    model: str,
    step: str = "unknown",
) -> str:
    client = anthropic.Anthropic(
        api_key=os.environ.get("ANTHROPIC_API_KEY"),
        timeout=float(timeout),
        # SDK-level retry with backoff for 429/overloaded/5xx, so a single
        # transient blip doesn't fail a multi-pass generation chain.
        max_retries=4,
    )
    paths = list(image_paths or [])
    content = transport.build_content(transport.Request(
        prompt=prompt,
        model=model,
        step=step,
        image_paths=tuple(Path(p) for p in paths),
        image_labels=tuple(image_labels) if image_labels is not None else None,
    ))
    # Counted on every call, not just when a transport is known to be unable to
    # carry images: a block that goes missing here would otherwise be answered
    # from the photos that did arrive, confidently (#210).
    transport.assert_images_intact(content, expected=len(paths), transport="sdk")

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

    # Before the truncation check below: a response cut off at the cap still
    # burned every one of those tokens and still appears on the bill.
    _record_usage(message, _resolve_model(model), step)

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
    step: str = "unknown",
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
        step=step,
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
    step: str = "unknown",
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
        step=step,
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
        # Each caption and blog runs two of these on top of the draft, so they
        # are attributed separately: lumped into the draft's step they would
        # hide the largest multiplier on a week's bill.
        data = run(prompt, timeout=timeout, step=f"review:{label}")
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
