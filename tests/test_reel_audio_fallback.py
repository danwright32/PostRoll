"""#117: a short music track must not shorten the reel.

Every reel routes its audio through `fit_audio_to_duration`, which loops a
short track with crossfaded seams so it covers the whole video. When that fails
the code falls back to the raw track, and the fallback passed `-shortest`.

`-shortest` ends the OUTPUT when the shortest INPUT ends. On the fallback path
the raw track is routinely shorter than the reel, so the video was cut to the
length of the music: a 36 second reel with a 20 second track became a 20 second
reel, silently, with the last third of the photographs simply absent.

Truncating the video is the worst of the three options available here. Silence
at the tail is visible in the preview and fixable by picking another track; a
reel that is missing its ending looks finished.

Three generators had their own copy of this fallback, so it is one helper now.
"""

from __future__ import annotations

import pytest

from postroll.media.audio_fit import fallback_audio_opts


DURATION = 36.0


def _opts(**kw):
    return fallback_audio_opts(duration=DURATION, **kw)


# ── the defect ────────────────────────────────────────────────────────────────

def test_the_fallback_never_uses_shortest():
    # The whole point: -shortest is what cut the video to the music.
    assert "-shortest" not in _opts()


def test_the_output_is_capped_at_the_video_length():
    # Without a cap a track LONGER than the reel would run past the last frame.
    opts = _opts()

    assert "-t" in opts
    assert opts[opts.index("-t") + 1] == str(DURATION)


def test_short_audio_is_padded_rather_than_left_to_end_the_video():
    # apad extends the track with silence, so the video plays to its own end.
    assert any("apad" in o for o in _opts())


def test_the_fade_is_kept():
    # The music still has to fade rather than stop dead at the cut.
    assert any("afade" in o for o in _opts())


def test_the_fade_lands_before_the_end():
    # A fade starting after the reel ends is a fade nobody hears.
    opts = _opts()
    filters = next(o for o in opts if "afade" in o)
    start = float(filters.split("st=")[1].split(":")[0])

    assert 0 < start < DURATION


def test_a_very_short_reel_still_gets_a_sane_fade():
    # A fade longer than the reel would give a negative start time, which
    # ffmpeg rejects outright and would fail the render.
    opts = fallback_audio_opts(duration=1.5)
    filters = next(o for o in opts if "afade" in o)
    start = float(filters.split("st=")[1].split(":")[0])

    assert start >= 0


# ── the generators use it ─────────────────────────────────────────────────────

@pytest.mark.parametrize("module", [
    "postroll.media.generate_reel_slider",
    "postroll.media.generate_reel_morph",
    "postroll.media.generate_reel_screen",
])
def test_no_generator_keeps_its_own_shortest_fallback(module):
    # Built is not wired: the helper is worth nothing while a generator still
    # has its own copy of the line that caused this.
    import importlib
    import inspect

    source = inspect.getsource(importlib.import_module(module))

    assert '"-shortest"' not in source, (
        f"{module} still passes -shortest, so a short track can still cut its reel")
