"""One request shape, two transports, one resolver deciding between them (#210).

This is the seam the subscription transport plugs into (#212). It lands with
behaviour unchanged on purpose: a restructure that also changes routing cannot
be shown to be neutral, and this one has to be, because everything after it is
judged against the paid path's output.

The images guard is the part that gets STRONGER rather than merely moved.
`claude_client` today refuses any CLI call carrying images, because the CLI
cannot attach them and Claude will invent OCR, alt text and captions out of
nothing rather than say it saw no photograph. That refusal is right, but it can
only catch the case it already knows about: a whole transport that cannot carry
images. It cannot catch one block going missing on a transport that can. So the
guard here counts blocks against paths on every call, on both transports.

`enrich_program` is the one genuine CLI case, and the resolver names it. It
passes WebSearch in allowed_tools and the SDK path has no tools parameter at
all, so WebSearch has never worked there.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

#: Tools only the Claude Code CLI provides. The SDK path takes no tools
#: parameter, so a call asking for one of these over the SDK would silently
#: run without it and answer from the model's memory instead of the web.
CLI_ONLY_TOOLS = frozenset({"WebSearch", "WebFetch", "Bash"})


@dataclass(frozen=True)
class Request:
    """Everything a transport needs, independent of which one runs it."""

    prompt: str
    model: str = "sonnet"
    step: str = "unknown"
    timeout: int = 300
    image_paths: tuple[Path, ...] = ()
    image_labels: tuple[str, ...] | None = None
    allowed_dirs: tuple[Path, ...] = ()
    allowed_tools: tuple[str, ...] = ()


@dataclass(frozen=True)
class Choice:
    """Which transport, and why. The reason is not decoration: routing that
    cannot explain itself cannot be debugged when a call goes to the wrong
    place, which is exactly the failure mode #212 introduces."""

    transport: str
    reason: str
    #: Whether the chosen transport can actually carry this request's images.
    #: False plus a non-empty image_paths is a refusal, never a silent drop.
    carries_images: bool = True


def build_content(req: Request) -> list[dict]:
    """The message content blocks, shared verbatim by both transports.

    Images travel as ordinary base64 image blocks. Nothing here reads a file on
    the model's behalf, so the CLI transport gains no agentic file access by
    reusing this.
    """
    from .claude_client import _image_block

    paths = list(req.image_paths)
    labels = list(req.image_labels) if req.image_labels is not None else None
    if labels is not None and len(labels) != len(paths):
        raise ValueError(
            f"image_labels has {len(labels)} entries but image_paths has {len(paths)}"
        )

    content: list[dict] = []
    for i, p in enumerate(paths):
        if labels is not None:
            # Immediately before its own image: a filename listed once at the
            # top leaves the model correlating by guess, which is how invented
            # alt text gets in.
            content.append({"type": "text", "text": f"Photo {i + 1}: {labels[i]}"})
        # The cap follows the request's model (#218): a bigger-budget model
        # must not be sent images shrunk to a smaller one's limit.
        content.append(_image_block(Path(p), model=req.model))
    content.append({"type": "text", "text": req.prompt})
    return content


def assert_images_intact(content: list[dict], *, expected: int, transport: str) -> None:
    """Every image the caller asked for is still in the payload being sent.

    Runs on both transports, on every call. An answer produced from fewer
    photographs than were handed over is not a degraded answer, it is a
    confident description of something the model never saw.
    """
    from .claude_client import ClaudeError

    present = sum(1 for b in content if b.get("type") == "image")
    if present != expected:
        raise ClaudeError(
            f"{expected} image(s) were attached but {present} reached the "
            f"{transport} transport. Refusing to send: the answer would be "
            "invented from the images that went missing."
        )


def choose_transport(req: Request) -> Choice:
    """Which transport runs this request, and why.

    Deliberately identical to the routing `claude_client._needs_cli` has always
    done. Phase 3 changes structure, not behaviour (#210).
    """
    cli_tools = sorted(set(req.allowed_tools) & CLI_ONLY_TOOLS)
    if cli_tools:
        return Choice(
            "cli",
            f"{', '.join(cli_tools)} is only available through the Claude Code "
            "CLI; the SDK path takes no tools parameter, so it would answer "
            "from memory instead of the web.",
            carries_images=False,
        )

    if subscription_enabled():
        return Choice(
            "cli",
            "the subscription transport is switched on, so every request runs "
            f"on Dan's Claude Code allowance rather than the metered API. "
            f"Unset {SUBSCRIPTION_ENV} to go straight back to the paid path.",
            carries_images=False,
        )

    if not os.environ.get("ANTHROPIC_API_KEY"):
        return Choice(
            "cli",
            "no ANTHROPIC_API_KEY is set, so there is no paid path to use.",
            carries_images=False,
        )

    return Choice("sdk", "the metered Anthropic API is the default path.")


# ── the subscription transport (#212) ─────────────────────────────────────────

#: The one switch. OFF is the stored default, so forgetting to set it produces
#: the paid path rather than quietly spending Dan's own Claude Code allowance,
#: and setting it back to anything else takes it straight off again. The app
#: draws on the same allowance he uses for his own work, so this has to revert
#: instantly rather than through a rebuild.
SUBSCRIPTION_ENV = "POSTROLL_USE_SUBSCRIPTION"


def subscription_enabled() -> bool:
    """Whether the app should run on Dan's Claude Code subscription."""
    return os.environ.get(SUBSCRIPTION_ENV, "").strip().lower() in {"1", "true", "yes", "on"}


def isolated_settings_json() -> str:
    """The settings a subscription call runs under, as JSON for `--settings`.

    `claude -p` inherits the user's own Claude Code configuration. Dan's
    personal hooks wrote an issue-review banner into the middle of the JSON this
    app parses, and the first spike failed outright on it.

    Hooks are therefore disabled for the app's own calls. The config DIRECTORY
    is deliberately left alone: auth and config share it, so pointing at a clean
    one loses the subscription login and the whole point with it.

    This breaks only on a machine that has hooks, so it works perfectly in
    ordinary testing and fails on Dan's. `tests/test_subscription_transport.py`
    asserts the isolation is requested rather than waiting for a live run to
    show its absence.
    """
    return json.dumps({"hooks": {}})


def cli_command(
    *,
    binary: str,
    model: str,
    settings_path: str | Path,
    allowed_dirs: list[str | Path] | None = None,
    allowed_tools: list[str] | None = None,
) -> list[str]:
    """The argv for one non-interactive CLI call, isolated from user config."""
    # -p first: it is what makes the call non-interactive, and an interactive
    # call inside the app would hang with nobody to answer it.
    cmd: list[str] = [binary, "-p", "--model", model,
                      "--settings", str(settings_path)]
    if allowed_dirs:
        cmd.append("--add-dir")
        cmd.extend(str(Path(d).resolve()) for d in allowed_dirs)
    if allowed_tools:
        cmd.append("--allowedTools")
        cmd.extend(allowed_tools)
    return cmd
