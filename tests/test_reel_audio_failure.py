"""The Tuesday reel shipped with no audio track at all (2026-07-14).

Jamendo's search intermittently returns zero downloadable tracks for tags that
work fine on the next call. generate_reel_morph / generate_reel_slider caught that
and set audio_path = None, so the reel rendered silently and nothing said a word.
The Thursday and screen reels let the same failure raise, which is why only Tuesday
was ever silent.

Two rules pinned here:
  1. A transient empty search is retried before giving up.
  2. If audio genuinely cannot be resolved, the reel FAILS instead of quietly
     producing a video with no music.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from PIL import Image

from postroll import audio as audio_mod
from postroll.media import generate_reel_morph as morph_mod
from postroll.media import generate_reel_slider as slider_mod


TRACK = {"id": 1, "name": "Test Track", "audiodownload": "http://x/t.mp3"}


def test_fetch_audio_retries_a_transient_empty_search(tmp_path):
    # First search comes back empty (the real, observed flake); the retry finds it.
    with patch.object(audio_mod, "_search_tracks", side_effect=[[], [TRACK]]) as search, \
         patch.object(audio_mod, "_download") as download, \
         patch.dict("os.environ", {"JAMENDO_CLIENT_ID": "x"}):
        path = audio_mod.fetch_audio("electronic,upbeat", cache_dir=tmp_path, seed=0)

    assert search.call_count == 2, "an empty search must be retried, not taken as final"
    assert path.endswith(".mp3")
    download.assert_called_once()


def test_fetch_audio_still_raises_when_every_attempt_is_empty(tmp_path):
    with patch.object(audio_mod, "_search_tracks", return_value=[]) as search, \
         patch.dict("os.environ", {"JAMENDO_CLIENT_ID": "x"}):
        with pytest.raises(RuntimeError):
            audio_mod.fetch_audio("nonsense,tags", cache_dir=tmp_path)

    assert search.call_count > 1, "it should have retried before giving up"


def _photo(tmp_path, name):
    p = tmp_path / name
    Image.new("RGB", (1500, 1000), (40, 90, 150)).save(str(p), "JPEG")
    return str(p)


@pytest.mark.parametrize("generate", [
    morph_mod.generate_reel_morph,
    slider_mod.generate_reel_slider,
])
def test_tuesday_reel_fails_loudly_rather_than_rendering_silent(tmp_path, generate):
    raw = _photo(tmp_path, "raw.jpg")
    edit = _photo(tmp_path, "edit.jpg")

    with patch("postroll.audio.fetch_audio", side_effect=RuntimeError("Jamendo down")):
        with pytest.raises(Exception) as err:
            generate(
                raw_path=raw, edit_path=edit, audio_path=None,
                output_path=str(tmp_path / "out.mp4"),
                event_name="E", org="O", venue="V",
            )

    # And it must not have quietly produced a reel.
    assert not (tmp_path / "out.mp4").exists(), "a silent reel was rendered anyway"
    assert "audio" in str(err.value).lower() or "jamendo" in str(err.value).lower()
