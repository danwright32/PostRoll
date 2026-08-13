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
from collections import OrderedDict
import json
import mimetypes
import os
import re
import subprocess
import tempfile
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import anthropic

from . import transport, usage_log


ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"
BRAND_VOICE_PATH = ASSETS_DIR / "brand-voice.md"

# Tools that require the Claude Code CLI (not available in SDK). Defined once,
# in transport, so the resolver and the error message below cannot disagree.
_CLI_ONLY_TOOLS = transport.CLI_ONLY_TOOLS

# The floating names are the KEYS, and resolving them is the pinning (#472).
#
# Do not append a date to the values. It is tempting, because haiku's value
# carries one and the other two do not, and that reads as an oversight. It is
# not: Anthropic publishes no dated snapshot for `claude-sonnet-4-6` or
# `claude-opus-4-6`, states those ids are complete as written, and a date
# appended to one 404s the request. A new snapshot arrives as a new version
# number (`claude-opus-4-7`), which is a different id rather than a silent
# re-point of this one, so these values are already pinned as tightly as the
# vendor allows.
#
# Every consumer resolves through `_resolve_model` before the model reaches a
# request, on BOTH transports. One of them did not, and the CLI decided the
# model for the entire subscription path; `tests/test_model_pinning.py` holds
# the two sides together now.
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
# per-image budget instead of a share of the page's (#208).
#
# The number itself is no longer kept here. It belongs to the RESOLVED MODEL,
# and sonnet-4-6 and the Opus 4.7+ tier do not share a limit, so `_image_block`
# reads it from `image_budget_for` (#218). This alias exists only for the
# comparison tool under tools/, which reports the cap it used.


from ..media.page_regions import DEFAULT_IMAGE_BUDGET as MAX_IMAGE_EDGE  # noqa: E402,F401  (re-exported for tools/ and the tests that pin the cap)


def _build_image_block(path: Path, *, model: str = "") -> dict:
    """Build an Anthropic base64 image content block from a local file.

    Full resolution concert JPEGs are commonly 5 to 15 MB; anything whose long
    edge exceeds the model's budget is downscaled in memory first.

    The cap comes from `image_budget_for` on the RESOLVED model, not from a
    constant here (#218). Two places used to answer this question from
    different sources, agreeing only for the pinned model, so the next model
    change had to be made in both files or they drifted with no signal.

    A resize that FAILS refuses the call instead of sending the original
    (#215). That path used to print a warning and carry on, justified by "the
    API downscales server side; we just upload more". #200 disproved that: the
    service-side downscale is exactly what destroys character accuracy in
    program text, so carrying on silently produced the worst possible input for
    OCR, with a plausible-looking wrong answer and nothing to distinguish it
    from a good run.
    """
    from ..media.page_regions import image_budget_for

    cap = image_budget_for(model)
    mime, _ = mimetypes.guess_type(str(path))
    if mime not in ("image/jpeg", "image/png", "image/gif", "image/webp"):
        mime = "image/jpeg"
    raw = path.read_bytes()

    try:
        from PIL import Image

        with Image.open(io.BytesIO(raw)) as img:
            if max(img.size) > cap:
                img.thumbnail((cap, cap), Image.LANCZOS)
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
        raise ClaudeError(
            f"Could not prepare {path.name} for upload: {e}. Sending it as-is "
            "would leave the service to reduce it instead, and that reduction "
            "is what corrupts characters in program text, so the call is "
            "refused rather than quietly degraded. Check the file opens."
        ) from e

    data = base64.standard_b64encode(raw).decode()
    return {
        "type": "image",
        "source": {"type": "base64", "media_type": mime, "data": data},
    }


#: How many encoded images to keep. A base64 page is a megabyte or two, so an
#: unbounded cache would hold a whole programme in memory for the life of the
#: process to save work that may never be repeated. Sized to cover the largest
#: single call: a ten photo carousel, preflighted and then sent, plus headroom.
IMAGE_BLOCK_CACHE_LIMIT = 16

#: (path, size, mtime, model) -> content block. Insertion ordered, so the
#: oldest entry is the one evicted.
_BLOCK_CACHE: "OrderedDict[tuple, dict]" = OrderedDict()


def clear_image_block_cache() -> None:
    _BLOCK_CACHE.clear()


def image_block_cache_size() -> int:
    return len(_BLOCK_CACHE)


def _image_block(path: Path, *, model: str = "") -> dict:
    """An image content block, encoded once per file per model (#220).

    The same image was opened, downscaled and base64-encoded at least twice on
    every OCR run: once by `ocr_batching.encoded_size` to measure what the
    request would weigh, and again by `build_content` to send it. The caption
    preflight added in #228 made it three times. On a thirty page programme
    that is sixty full-resolution resizes on a step that already takes minutes,
    and the repeat work cannot produce a different answer from the first.

    Keyed on what the file IS right now (size and mtime) as well as its path,
    so an image Dan has replaced since is re-encoded rather than served from
    the previous contents. Keyed on the model too, because the long-edge budget
    follows the resolved model and a bigger-budget model must not be handed
    pixels shrunk to a smaller one's limit (#218).

    A file that cannot be stat'ed is not cached at all, so a missing photo
    still raises rather than being answered from a stale entry.
    """
    try:
        stat = Path(path).stat()
        key = (str(path), stat.st_size, stat.st_mtime, model)
    except OSError:
        # Cannot identify the file, so cannot safely reuse anything for it.
        return _build_image_block(Path(path), model=model)

    if (hit := _BLOCK_CACHE.get(key)) is not None:
        return hit

    block = _build_image_block(Path(path), model=model)
    _BLOCK_CACHE[key] = block
    while len(_BLOCK_CACHE) > IMAGE_BLOCK_CACHE_LIMIT:
        _BLOCK_CACHE.popitem(last=False)
    return block


@dataclass(frozen=True)
class SkippedPhoto:
    """A photo left out of a call because it could not be prepared for upload."""

    index: int   # position in the list the caller passed
    name: str    # filename, so Dan can go and look at it
    reason: str


def partition_uploadable(
    paths: list[str | Path], *, model: str = "",
) -> tuple[list[int], list[SkippedPhoto]]:
    """Split photos into the ones that can be sent and the ones that cannot.

    For ORDINARY CONCERT PHOTOS only (#228). A file that will not open fails
    the whole call otherwise, which costs that day's caption and alt text
    entirely, where the honest alternative is slightly less context and a named
    warning. Program pages and OCR must not use this: character fidelity is the
    point of those calls, and a page quietly missing is a cast list read from
    fewer pages than the programme has (#200, #215).

    Callers must preflight BEFORE building their prompt. The caption prompt
    states the photo count and lists the filenames, so a photo dropped after
    the prompt was written would leave the model reading about a photograph it
    never received, which is exactly how invented alt text gets in.

    Readability is decided by running the real `_image_block`, not a cheaper
    stand-in: the question is whether the operation that runs at send time
    succeeds, and anything else can disagree with it. The encode is cached
    (#220), so proving a photo readable here and then sending it costs one
    encode rather than two.

    Raises ClaudeError when nothing survives: a caption written from zero
    photographs is invented rather than degraded.
    """
    kept: list[int] = []
    skipped: list[SkippedPhoto] = []

    for i, p in enumerate(paths):
        try:
            _image_block(Path(p), model=model)
        except Exception as e:
            skipped.append(SkippedPhoto(index=i, name=Path(p).name, reason=str(e)))
            continue
        kept.append(i)

    if paths and not kept:
        names = ", ".join(s.name for s in skipped)
        raise ClaudeError(
            f"None of the {len(paths)} photo(s) for this post could be read "
            f"({names}). There is nothing left to write from, and a caption or "
            "alt text produced from zero photographs is invented rather than "
            "degraded, so this is refused rather than guessed."
        )

    return kept, skipped


def _needs_cli(allowed_tools: list[str] | None) -> bool:
    """Return True if any requested tool requires the Claude Code CLI,
    or if no ANTHROPIC_API_KEY is set (fall back to CLI auth).

    Says so, once, when the CLI is where this ended up rather than where it was
    sent (#352). The routing already knew; nothing read it, so a fall back to a
    path that is five times slower and cannot carry photographs happened in
    silence for two days.
    """
    choice = transport.choose_transport(
        transport.Request(prompt="", allowed_tools=tuple(allowed_tools or ()))
    )
    transport.announce_fallback(choice)
    return choice.transport == "cli"


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


def _text_from_blocks(message: Any) -> str:
    """Return the text of the first text block in the reply.

    Never `content[0]`: current models put a thinking block before the text
    block, so the first block is not reliably the answer, and reaching for
    `.text` on it raises AttributeError before any output is read (#214).

    A block that declares no type at all is treated as text. The SDK always
    declares one, so that only covers hand-built stand-ins.
    """
    blocks = list(getattr(message, "content", None) or [])
    for block in blocks:
        if getattr(block, "type", "text") != "text":
            continue
        text = getattr(block, "text", None)
        if isinstance(text, str):
            return text
    if not blocks:
        return ""
    kinds = ", ".join(
        str(getattr(block, "type", None) or type(block).__name__)
        for block in blocks
    )
    raise ClaudeError(
        "Anthropic API returned no text block. Blocks received: " + kinds
    )


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

    if message.stop_reason == "refusal":
        # A distinct cause gets a distinct message: this is not an empty
        # response and not a truncated one, and retrying it unchanged will
        # refuse again.
        raise ClaudeError(
            "Anthropic declined to answer this request (stop_reason=refusal). "
            "Retrying the same prompt will refuse again; change the input."
        )

    if message.stop_reason == "max_tokens":
        # A truncated response would otherwise surface as a confusing JSON
        # parse failure (or silently clipped text for plain prompts).
        raise ClaudeError(
            "Response was truncated at the max_tokens cap. The prompt or "
            "requested output is too large; try fewer photos or a shorter "
            "input, then retry."
        )

    text = _text_from_blocks(message).strip()
    if not text:
        raise ClaudeError("Anthropic API returned empty response")
    return text


# ── CLI fallback (web tools only) ─────────────────────────────────────────────

def _failure_message(returncode: int, stdout: str | None, stderr: str | None) -> str:
    """Everything the CLI said about a failure, reason first (#296).

    The CLI splits its failures across both streams, measured against 2.1.227 on
    2026-08-10:

    * A runtime failure reports on STDOUT. `--model definitely-not-a-real-model`
      exits 1 with "There's an issue with the selected model" on stdout, while
      stderr carried an unrelated context-window warning.
    * A startup or config failure reports on STDERR. `--settings /nonexistent`
      exits 1 with "Error: Settings file not found" there.

    Keeping stderr alone therefore threw the reason away for the whole runtime
    category, and a usage cap is a runtime condition. `cap_signals` was handed
    a line unrelated to the failure, so the halt could not fire and the
    unrecognised-failures log would have recorded the wrong text, wasting the
    one sample #258 needs to calibrate against.

    Both streams are kept, labelled, with stdout FIRST. `cap_signals` matches
    substrings over this text and stderr is known to carry warnings that have
    nothing to do with the failure, so the stream holding the reason goes ahead
    of the stream holding the noise.

    An exit code with nothing on either stream says so rather than trailing off,
    because a blank tail reads as a message that failed to load.
    """
    out = (stdout or "").strip()
    err = (stderr or "").strip()
    parts = [f"Claude CLI exited {returncode}"]
    if out:
        parts.append(f"stdout: {out}")
    if err:
        parts.append(f"stderr: {err}")
    if not out and not err:
        parts.append("no output on either stream")
    return "; ".join(parts)


def _cli_binary() -> str:
    return os.environ.get("POSTROLL_CLAUDE_BIN", "claude")


def _run_cli(
    prompt: str,
    *,
    timeout: int,
    allowed_dirs: list[str | Path] | None,
    allowed_tools: list[str] | None,
    model: str,
    step: str = "unknown",
) -> str:
    """One CLI call. `step` is carried so spend stays attributable (#343).

    It is not read here: `claude -p` returns plain text with no token counts,
    so unlike the SDK path there is nothing to record against it. What the step
    IS for is everything watching this seam. The comparison harness reads it to
    line each call up with its metered twin, and the subscription switch routes
    every call through here, so without it per step attribution disappears at
    exactly the point it is needed to judge that switch.

    Token counts for this path are a separate matter, and would mean asking the
    CLI for JSON output rather than text.
    """
    # Session isolation, not optional (#212). `claude -p` inherits the user's own
    # Claude Code configuration, and Dan's personal hooks wrote a banner into the
    # middle of the JSON this function's callers parse. The settings file
    # disables hooks while leaving the config DIRECTORY alone, because auth lives
    # there too and a clean directory loses the subscription login.
    #
    # Written per call into a temp file rather than kept on disk: nothing then
    # persists to go stale or be edited by hand into something that stops
    # isolating.
    with tempfile.TemporaryDirectory(prefix="postroll-cli-") as tmp:
        settings_path = Path(tmp) / "settings.json"
        settings_path.write_text(transport.isolated_settings_json(), encoding="utf-8")

        cmd = transport.cli_command(
            binary=_cli_binary(),
            # Resolved here, not passed raw (#472). The SDK path has always
            # resolved the alias; this one handed "sonnet" to the installed
            # Claude Code CLI and let IT decide which model that meant. The
            # subscription switch routes every call through here, so flipping
            # it silently changed the model behind the whole pipeline, and the
            # compare-transports harness built to judge that switch was
            # comparing two different models while reporting on one.
            model=_resolve_model(model),
            settings_path=settings_path,
            allowed_dirs=list(allowed_dirs) if allowed_dirs else None,
            allowed_tools=list(allowed_tools) if allowed_tools else None,
        )

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
                "`claude` binary not found. Set POSTROLL_CLAUDE_BIN or install "
                "Claude Code."
            ) from e
        except subprocess.TimeoutExpired as e:
            raise ClaudeError(f"Claude CLI timed out after {timeout}s") from e

    if result.returncode != 0:
        raise ClaudeError(
            _failure_message(result.returncode, result.stdout, result.stderr)
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
            step=step,
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
    # Merge onto the prior draft rather than replacing it (#202). A review
    # prompt asks for the caption shape, so a reviewer never echoes back the
    # fields it was not asked about, and returning its object wholesale deleted
    # them. That is how `famous_people` disappeared between the draft and the
    # fame gate, leaving the gate reading an always-empty field and stripping a
    # genuinely famous performer's hashtag like everyone else's.
    #
    # A field the reviewer DID return wins, including one it deliberately
    # emptied, so this preserves rather than resurrects.
    merged = dict(prior)
    merged.update(data)
    return merged


def _balanced_span(text: str, start: int, opener: str, closer: str) -> str | None:
    """The substring from `start` to its matching close, or None.

    Braces and brackets INSIDE a JSON string are literal text, not structure.
    Counting them (#121) made a caption containing a stray `}` close the object
    early, which is the worst shape of failure available here: the result still
    parses, so nothing raises and the caption simply comes back with fields
    missing. Captions and blog bodies are prose Claude wrote about a programme,
    so a stray bracket is an ordinary thing for them to contain.

    Escapes are tracked as well, because a caption quoting a work title carries
    `\\"`, and treating that as the end of the string drops the walker back
    into counting mode in the middle of prose.
    """
    depth = 0
    in_string = False
    escaped = False

    for i in range(start, len(text)):
        ch = text[i]

        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue

        if ch == '"':
            in_string = True
        elif ch == opener:
            depth += 1
        elif ch == closer:
            depth -= 1
            if depth == 0:
                return text[start : i + 1]

    # Ran out of text with the structure still open: truncated or malformed,
    # and a partial object is not worth guessing at.
    return None


def _extract_json(text: str) -> Any:
    """Pull the first JSON object or array out of a response string."""
    fenced = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL)
    if fenced:
        text = fenced.group(1).strip()

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        pass

    # Whichever structure opens FIRST, rather than always trying objects
    # before arrays: an array of objects starts with "[", and going for "{"
    # first returned its first element and silently dropped the rest.
    candidates = [(text.find(o), o, c) for o, c in (("{", "}"), ("[", "]"))]
    for start, opener, closer in sorted(p for p in candidates if p[0] != -1):
        candidate = _balanced_span(text, start, opener, closer)
        if candidate is None:
            continue
        try:
            return json.loads(candidate)
        except json.JSONDecodeError:
            continue

    raise ClaudeError(f"Could not parse JSON from Claude response:\n{text[:500]}")
