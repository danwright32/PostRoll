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


# ── and the reel SAYS when the track had to be stretched (#1076) ─────────────
#
# Looping covers the reel, which is the right thing to do, but it was done in
# silence: a reel whose music repeats read exactly like one whose track fits.
# Dan noticed only because he happened to know a track's length, and his
# response was to accept a reel he had just called too fast rather than loop the
# music further, which is a decision he would have made earlier with the fact in
# front of him.
#
# Only the scroll reel carries the fact out. It is the one with an `on_warning`
# channel, because it is the one whose length Dan chooses in the editor; the
# Tuesday reels are a fixed length with nothing to decide and nowhere to put a
# warning, so they pass no hook rather than being left out by oversight.

def _tone(path, seconds: float):
    import subprocess
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi",
         "-i", f"sine=frequency=440:duration={seconds}", "-c:a", "aac", str(path)],
        check=True)
    return str(path)


def test_the_scroll_reel_says_when_its_music_had_to_repeat(tmp_path, monkeypatch):
    from PIL import Image

    from postroll.media import generate_reel_scroll as scroll_mod

    photos = []
    for i in range(6):
        p = tmp_path / f"p{i}.jpg"
        Image.new("RGB", (1200, 800), (i * 30, 80, 160)).save(p)
        photos.append(str(p))

    # Deliberately shorter than the reel, which is what a real short upload is.
    audio = _tone(tmp_path / "short.m4a", 2.0)

    monkeypatch.setattr(scroll_mod, "FPS", 4)
    said: list[str] = []
    out = tmp_path / "reel.mp4"
    scroll_mod.generate_reel_scroll(
        photos, audio, str(out), event_name="Reference Event", org="Org",
        venue="Hall", seed=163, scroll_duration=1.0, on_warning=said.append)

    # The positive half: a render that failed before the audio step warns about
    # nothing either, and would satisfy the assertion below (L98, L159).
    assert out.exists() and out.stat().st_size > 0, "the render produced no reel"

    looped = [m for m in said if "repeat" in m.lower()]
    assert looped, f"the music was stretched and the run said {said}"


def test_the_scroll_reel_says_nothing_when_the_track_covers_it(tmp_path, monkeypatch):
    """The other half. A warning on the ordinary outcome is one nobody
    reads, and this is the ordinary outcome: most tracks are minutes long."""
    from PIL import Image

    from postroll.media import generate_reel_scroll as scroll_mod

    photos = []
    for i in range(6):
        p = tmp_path / f"p{i}.jpg"
        Image.new("RGB", (1200, 800), (i * 30, 80, 160)).save(p)
        photos.append(str(p))

    audio = _tone(tmp_path / "long.m4a", 60.0)

    monkeypatch.setattr(scroll_mod, "FPS", 4)
    said: list[str] = []
    out = tmp_path / "reel.mp4"
    scroll_mod.generate_reel_scroll(
        photos, audio, str(out), event_name="Reference Event", org="Org",
        venue="Hall", seed=163, scroll_duration=1.0, on_warning=said.append)

    assert out.exists() and out.stat().st_size > 0, "the render produced no reel"
    assert [m for m in said if "repeat" in m.lower()] == [], said
