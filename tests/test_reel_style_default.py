"""The Tuesday reel defaults to the program-plate morph (2026-07-14).

Previously it picked randomly between slider and morph; now morph is the default
so the approved program-plate look is what actually ships, while 3-photo mode
(a B&W after) keeps the slider reveal.
"""

from __future__ import annotations

from postroll.ai.generate_media import resolve_tuesday_reel_style


def test_default_is_morph():
    assert resolve_tuesday_reel_style(bw=None, requested=None) == "morph"


def test_explicit_request_is_honoured():
    assert resolve_tuesday_reel_style(bw=None, requested="slider") == "slider"
    assert resolve_tuesday_reel_style(bw=None, requested="morph") == "morph"


def test_three_photo_mode_forces_slider():
    # A B&W after present → 3-photo mode → slider, even if morph is requested.
    assert resolve_tuesday_reel_style(bw="bw.jpg", requested="morph") == "slider"
    assert resolve_tuesday_reel_style(bw="bw.jpg", requested=None) == "slider"
