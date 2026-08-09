"""One request shape, two transports, one resolver deciding (#210).

Phase 3 of the plan, and it must land with behaviour unchanged: the point is to
have a seam the subscription transport can plug into (#212), proved neutral
before anything is flipped.

The part worth being careful about is the images guard. Today the CLI path
REFUSES any call carrying images, on the grounds that it cannot attach them and
would otherwise let Claude invent OCR and alt text out of nothing. That refusal
is correct but blunt, and it is structurally unable to catch the failure it
actually fears: a block silently going missing on a path that does accept
images. The replacement counts blocks against paths on every call, on both
transports, so a dropped image fails loudly wherever it happens.

`enrich_program` is the one genuine CLI case. It passes WebSearch in
allowed_tools, and the SDK path has no tools parameter at all, so WebSearch has
never worked there. The resolver has to name that rather than leave it implicit.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from postroll.ai import transport as tp
from postroll.ai.claude_client import ClaudeError


@pytest.fixture
def images(tmp_path):
    """Real JPEGs, not a few bytes with a JPEG magic number.

    A stand-in that cannot actually be opened is not a photo, and since #215
    an unopenable file is refused outright rather than uploaded as-is. Pinning
    the seam against fake bytes would have been testing the refusal path while
    claiming to test the image-carrying one.
    """
    from PIL import Image

    out = []
    for n in ("a", "b", "c"):
        p = tmp_path / f"{n}.jpg"
        Image.new("RGB", (120, 90), (40, 60, 80)).save(p)
        out.append(p)
    return out


def _req(**kw):
    return tp.Request(**{"prompt": "hi", "model": "sonnet", "step": "test", **kw})


# ── one content shape, shared by both transports ──────────────────────────────

def test_every_image_path_becomes_an_image_block(images):
    content = tp.build_content(_req(image_paths=tuple(images)))

    assert sum(1 for b in content if b["type"] == "image") == len(images)


def test_the_prompt_is_the_last_block(images):
    content = tp.build_content(_req(image_paths=tuple(images)))

    assert content[-1]["type"] == "text"
    assert content[-1]["text"] == "hi"


def test_labels_are_interleaved_with_their_own_image(images):
    """The label has to sit immediately before its image or the model
    correlates filenames by guess, which is how invented alt text happens."""
    content = tp.build_content(_req(image_paths=tuple(images),
                                    image_labels=("one", "two", "three")))

    for i, block in enumerate(content):
        if block["type"] == "image":
            assert content[i - 1]["text"].endswith(("one", "two", "three"))


def test_mismatched_labels_are_refused(images):
    with pytest.raises(ValueError, match="image_labels"):
        tp.build_content(_req(image_paths=tuple(images), image_labels=("only one",)))


# ── the images guard, on every call, on both transports ───────────────────────

def test_the_guard_passes_when_every_image_is_present(images):
    content = tp.build_content(_req(image_paths=tuple(images)))

    tp.assert_images_intact(content, expected=len(images), transport="sdk")


def test_a_silently_dropped_image_block_is_caught(images):
    """The failure the current blanket refusal fears but cannot detect."""
    content = tp.build_content(_req(image_paths=tuple(images)))
    content = [b for b in content if b["type"] != "image"][:1] + content[2:]
    present = sum(1 for b in content if b["type"] == "image")

    with pytest.raises(ClaudeError, match="image"):
        tp.assert_images_intact(content, expected=len(images), transport="sdk")

    assert present < len(images), "the test did not actually drop a block"


def test_the_guard_names_the_transport_so_the_report_is_actionable(images):
    content = [b for b in tp.build_content(_req(image_paths=tuple(images)))
               if b["type"] != "image"]

    with pytest.raises(ClaudeError, match="cli"):
        tp.assert_images_intact(content, expected=len(images), transport="cli")


# ── one resolver, with reasons ────────────────────────────────────────────────

def test_a_plain_call_with_a_key_goes_to_the_paid_sdk(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")

    choice = tp.choose_transport(_req())

    assert choice.transport == "sdk"


def test_a_websearch_call_is_named_as_the_cli_case(monkeypatch):
    """enrich_program is the one genuine one: the SDK path has no tools
    parameter, so WebSearch has never worked there."""
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")

    choice = tp.choose_transport(_req(allowed_tools=("WebSearch",)))

    assert choice.transport == "cli"
    assert "WebSearch" in choice.reason


def test_no_api_key_falls_back_to_the_cli(monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

    choice = tp.choose_transport(_req())

    assert choice.transport == "cli"
    assert "key" in choice.reason.lower()


def test_the_resolver_always_gives_a_reason(monkeypatch):
    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")

    for req in (_req(), _req(allowed_tools=("WebSearch",))):
        assert tp.choose_transport(req).reason.strip(), \
            "a routing decision with no stated reason cannot be debugged"


def test_images_with_no_key_still_refuse_rather_than_generate_from_nothing(
        monkeypatch, images):
    """Until the CLI can genuinely carry images (#212), a call that would drop
    them has to fail loudly: Claude will happily invent OCR from nothing."""
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

    choice = tp.choose_transport(_req(image_paths=tuple(images)))

    assert choice.transport == "cli"
    assert choice.carries_images is False, \
        "the CLI transport would silently drop the images"


# ── the restructure is neutral ────────────────────────────────────────────────

def test_the_public_entry_point_still_routes_the_same_way(monkeypatch, images):
    """Phase 3 lands with behaviour unchanged; this pins that."""
    from postroll.ai import claude_client as cc

    monkeypatch.setenv("ANTHROPIC_API_KEY", "sk-ant-test")
    assert cc._needs_cli(None) is False
    assert cc._needs_cli(["WebSearch"]) is True

    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    assert cc._needs_cli(None) is True


def test_an_image_call_that_would_lose_its_images_still_raises(monkeypatch, images):
    from postroll.ai.claude_client import run_prompt

    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)

    with pytest.raises(ClaudeError, match="image"):
        run_prompt("describe", image_paths=[str(p) for p in images])
