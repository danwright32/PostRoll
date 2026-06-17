"""Tests for the relocatable brand voice doc.

The app stores the writable brand-voice.md in its data root (outside the
TCC-protected Documents checkout) and points Python at it via
$POSTROLL_BRAND_VOICE. Without the env var (CLI/dev) the in-repo default is used.
"""

from __future__ import annotations

from postroll.ai.claude_client import load_brand_voice, BRAND_VOICE_PATH


def test_no_override_reads_repo_default(monkeypatch):
    monkeypatch.delenv("POSTROLL_BRAND_VOICE", raising=False)
    assert load_brand_voice() == BRAND_VOICE_PATH.read_text(encoding="utf-8")


def test_override_missing_seeds_from_default(tmp_path, monkeypatch):
    target = tmp_path / "data" / "brand-voice.md"  # parent doesn't exist yet
    monkeypatch.setenv("POSTROLL_BRAND_VOICE", str(target))
    assert not target.exists()

    text = load_brand_voice()

    # First use seeds the writable copy from the repo default, then reads it.
    assert target.exists()
    default = BRAND_VOICE_PATH.read_text(encoding="utf-8")
    assert text == default
    assert target.read_text(encoding="utf-8") == default


def test_override_existing_is_read_verbatim(tmp_path, monkeypatch):
    target = tmp_path / "brand-voice.md"
    target.write_text("CUSTOM ACCUMULATED VOICE DOC", encoding="utf-8")
    monkeypatch.setenv("POSTROLL_BRAND_VOICE", str(target))

    # An existing writable copy (with the user's appended notes) wins over the
    # repo default and is never overwritten.
    assert load_brand_voice() == "CUSTOM ACCUMULATED VOICE DOC"
