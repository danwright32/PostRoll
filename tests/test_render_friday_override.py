"""Tests for re-rendering the Friday clip reel from a user's manual override
(reorder/include-exclude/swap), skipping Stage 1/2 entirely (Phase 4, #135).
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path
from unittest.mock import patch

import pytest

from postroll.ai.render_friday_override import render_friday_override

HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg/ffprobe not installed")


def _make_clip(path, seconds=4.0):
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"testsrc=s=320x240:d={seconds}:r=10", str(path)],
        check=True,
    )


def test_empty_selections_raises(tmp_path):
    manifest = {"selections": []}
    with pytest.raises(ValueError):
        render_friday_override(manifest, tmp_path / "out.mp4")


@needs_ffmpeg
def test_renders_reel_from_override_selections_without_claude(tmp_path):
    clip_a = tmp_path / "a.mp4"
    clip_b = tmp_path / "b.mp4"
    _make_clip(clip_a)
    _make_clip(clip_b)

    manifest = {
        "selections": [
            {"clip_path": str(clip_a), "trim_in": 0.0, "trim_out": 3.0, "transition": "cut"},
            {"clip_path": str(clip_b), "trim_in": 0.0, "trim_out": 3.0, "transition": "crossfade"},
        ],
        "shoot_type": "performance",
        "pieces": [],
    }
    out = tmp_path / "reel.mp4"

    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None) as mock_resolve:
        render_friday_override(manifest, out)

    assert out.exists()
    mock_resolve.assert_called_once()


# ===================================================================
# Crop fields threading (issue #151): a manual override must not silently
# drop the AI's crop choice just because it only carries clip path, trim,
# and transition through the rest of this manifest.
# ===================================================================

def test_crop_fields_from_manifest_pass_through_to_render(tmp_path):
    # title_card_muted=True: this test is about crop-field passthrough,
    # not the title card, and render_clip_reel is mocked (returns a
    # MagicMock, not a real file), so an unmocked apply_title_card would
    # try to ffprobe a fake path. Skip it here to keep the test focused.
    manifest = {
        "selections": [
            {"clip_path": "/clips/a.mov", "trim_in": 0.0, "trim_out": 3.0,
             "transition": "cut", "crop_x": 0.4, "crop_y": -0.2},
        ],
        "title_card_muted": True,
    }

    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None), \
         patch("postroll.ai.render_friday_override.render_clip_reel") as mock_render:
        render_friday_override(manifest, tmp_path / "out.mp4")

    rendered_selections = mock_render.call_args[0][0]
    assert rendered_selections[0]["crop_x"] == 0.4
    assert rendered_selections[0]["crop_y"] == -0.2


def test_missing_crop_fields_default_to_centered(tmp_path):
    manifest = {
        "selections": [
            {"clip_path": "/clips/a.mov", "trim_in": 0.0, "trim_out": 3.0, "transition": "cut"},
        ],
        "title_card_muted": True,
    }

    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None), \
         patch("postroll.ai.render_friday_override.render_clip_reel") as mock_render:
        render_friday_override(manifest, tmp_path / "out.mp4")

    rendered_selections = mock_render.call_args[0][0]
    assert rendered_selections[0]["crop_x"] == 0.0
    assert rendered_selections[0]["crop_y"] == 0.0


# ===================================================================
# Title card overlay (plan #148, Phase 3): applied by default after the
# override reel renders, skippable per event via title_card_muted, same
# policy as generate_media.py's initial render path.
# ===================================================================

def test_title_card_applied_by_default(tmp_path):
    # render_clip_reel and apply_title_card are both mocked, so this test
    # is pure orchestration: it needs no real video file and no ffmpeg.
    manifest = {
        "selections": [{"clip_path": str(tmp_path / "a.mov"), "trim_in": 0.0, "trim_out": 3.0, "transition": "cut"}],
        "event_name": "Sing Play",
    }
    out = tmp_path / "reel.mp4"

    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None), \
         patch("postroll.ai.render_friday_override.render_clip_reel", return_value=str(out)), \
         patch("postroll.media.generate_title_card.apply_title_card") as mock_title:
        mock_title.side_effect = lambda video_path, event_name, output_path, **kwargs: Path(output_path).write_bytes(b"x") or str(output_path)
        render_friday_override(manifest, out)

    mock_title.assert_called_once()
    assert mock_title.call_args[0][1] == "Sing Play"


def test_title_card_skipped_when_muted(tmp_path):
    manifest = {
        "selections": [{"clip_path": str(tmp_path / "a.mov"), "trim_in": 0.0, "trim_out": 3.0, "transition": "cut"}],
        "event_name": "Sing Play",
        "title_card_muted": True,
    }
    out = tmp_path / "reel.mp4"

    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None), \
         patch("postroll.ai.render_friday_override.render_clip_reel", return_value=str(out)), \
         patch("postroll.media.generate_title_card.apply_title_card") as mock_title:
        render_friday_override(manifest, out)

    mock_title.assert_not_called()


@needs_ffmpeg
def test_user_provided_audio_file_passed_through(tmp_path):
    clip_a = tmp_path / "a.mp4"
    _make_clip(clip_a)
    audio = tmp_path / "music.wav"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", "sine=frequency=220:duration=10", str(audio)],
        check=True,
    )

    manifest = {
        "selections": [{"clip_path": str(clip_a), "trim_in": 0.0, "trim_out": 3.0, "transition": "cut"}],
        "audio": str(audio),
    }
    out = tmp_path / "reel.mp4"

    render_friday_override(manifest, out)

    assert out.exists()


# ===================================================================
# What the override run reports about the title card (#824).
#
# This path renders the reel Dan is looking at when he reorders a cut, and
# it applied the title card by printing a line on failure and carrying on.
# The app reads none of the process's output, so a reel that came back
# untitled was indistinguishable from one that came back titled.
# ===================================================================

def test_result_carries_the_reel_and_nothing_to_report_when_the_card_lands(tmp_path):
    manifest = {
        "selections": [{"clip_path": str(tmp_path / "a.mov"), "trim_in": 0.0,
                        "trim_out": 3.0, "transition": "cut"}],
        "event_name": "Sing Play",
    }
    out = tmp_path / "reel.mp4"

    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None), \
         patch("postroll.ai.render_friday_override.render_clip_reel", return_value=str(out)), \
         patch("postroll.media.generate_title_card.apply_title_card") as mock_title:
        mock_title.side_effect = (
            lambda video_path, event_name, output_path, **kwargs:
            Path(output_path).write_bytes(b"titled") or str(output_path)
        )
        result = render_friday_override(manifest, out)

    assert result["reel"] == str(out)
    # Empty rather than absent: a key that disappears when nothing went wrong
    # cannot tell a reader "the card is on the reel" from "this build did not
    # look" (L505).
    assert result["title_card_skipped"] == ""


def test_result_names_the_reason_when_the_card_fails_and_keeps_the_reel(tmp_path):
    import postroll.media.generate_title_card as card_mod

    out = tmp_path / "reel.mp4"
    out.write_bytes(b"the rendered reel")
    manifest = {
        "selections": [{"clip_path": str(tmp_path / "a.mov"), "trim_in": 0.0,
                        "trim_out": 3.0, "transition": "cut"}],
        "event_name": "Sing Play",
    }

    def failing(video_path, event_name, output_path, **kwargs):
        raise card_mod.TitleCardError("ffmpeg title card overlay failed: no such filter")

    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None), \
         patch("postroll.ai.render_friday_override.render_clip_reel", return_value=str(out)), \
         patch("postroll.media.generate_title_card.apply_title_card", failing):
        result = render_friday_override(manifest, out)

    assert "no such filter" in result["title_card_skipped"]
    assert result["reel"] == str(out)
    assert out.read_bytes() == b"the rendered reel", "the reel must survive its missing title"


def test_a_muted_card_is_not_reported_as_a_skip(tmp_path):
    # Muting is Dan's own choice, made in the app, which already knows it. A
    # reason filed on every deliberately untitled reel is a notice that fires
    # on the normal case, and those stop being read (L36).
    out = tmp_path / "reel.mp4"
    manifest = {
        "selections": [{"clip_path": str(tmp_path / "a.mov"), "trim_in": 0.0,
                        "trim_out": 3.0, "transition": "cut"}],
        "event_name": "Sing Play",
        "title_card_muted": True,
    }

    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None), \
         patch("postroll.ai.render_friday_override.render_clip_reel", return_value=str(out)):
        result = render_friday_override(manifest, out)

    assert result["title_card_skipped"] == ""


def test_the_cli_writes_the_result_where_it_is_asked_to(tmp_path):
    import json
    import postroll.ai.render_friday_override as mod
    import postroll.media.generate_title_card as card_mod

    manifest_file = tmp_path / "manifest.json"
    manifest_file.write_text(json.dumps({
        "selections": [{"clip_path": str(tmp_path / "a.mov"), "trim_in": 0.0,
                        "trim_out": 3.0, "transition": "cut"}],
        "event_name": "Sing Play",
    }))
    out = tmp_path / "reel.mp4"
    result_file = tmp_path / "result.json"

    def failing(video_path, event_name, output_path, **kwargs):
        raise card_mod.TitleCardError("ffmpeg title card overlay failed: no such filter")

    argv = ["render_friday_override", "--manifest", str(manifest_file),
            "--output", str(out), "--result", str(result_file)]
    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None), \
         patch("postroll.ai.render_friday_override.render_clip_reel", return_value=str(out)), \
         patch("postroll.media.generate_title_card.apply_title_card", failing), \
         patch("sys.argv", argv):
        assert mod._main() == 0

    written = json.loads(result_file.read_text())
    assert written["reel"] == str(out)
    assert "no such filter" in written["title_card_skipped"]


def test_the_cli_still_runs_for_an_app_build_that_does_not_ask_for_a_result(tmp_path):
    # The Swift half is frozen into the installed app and the Python half runs
    # live from the checkout, so an installed build predating --result must not
    # be broken by this file gaining one.
    import json
    import postroll.ai.render_friday_override as mod

    manifest_file = tmp_path / "manifest.json"
    manifest_file.write_text(json.dumps({
        "selections": [{"clip_path": str(tmp_path / "a.mov"), "trim_in": 0.0,
                        "trim_out": 3.0, "transition": "cut"}],
        "event_name": "Sing Play",
        "title_card_muted": True,
    }))
    out = tmp_path / "reel.mp4"

    argv = ["render_friday_override", "--manifest", str(manifest_file), "--output", str(out)]
    with patch("postroll.ai.render_friday_override.resolve_reel_audio", return_value=None), \
         patch("postroll.ai.render_friday_override.render_clip_reel", return_value=str(out)), \
         patch("sys.argv", argv):
        assert mod._main() == 0
