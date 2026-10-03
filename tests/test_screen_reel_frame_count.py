"""#1479 (L743): counting a long screen recording's frames cannot fail the reel.

`ffprobe -count_frames` decodes the whole recording, so its time grows with the
recording's length, under a fixed 120 second limit. A recording long enough to
reach it raised TimeoutExpired out of the render and Tuesday's reel failed,
though the recording was fine. The recording has just been converted to a fixed
30 frames a second, so its length times 30 is the count, and that is the
answer when counting takes too long, as it already was when the count could
not be read.
"""

from __future__ import annotations

import subprocess

from postroll.media.generate_reel_screen import cfr_frame_count


def _ran(stdout: str):
    def run(args, **kwargs):
        return subprocess.CompletedProcess(args, 0, stdout, "")
    return run


def test_the_counted_frames_are_used_when_counting_finishes():
    assert cfr_frame_count("x.mp4", 10.0, run=_ran("297\n")) == 297


def test_an_unreadable_count_falls_back_to_length_times_thirty():
    assert cfr_frame_count("x.mp4", 10.0, run=_ran("N/A")) == 300


def test_a_count_that_takes_too_long_falls_back_rather_than_failing(capsys):
    def slow(args, **kwargs):
        raise subprocess.TimeoutExpired(args, kwargs.get("timeout"))
    assert cfr_frame_count("x.mp4", 600.0, run=slow) == 18000
    assert "counting" in capsys.readouterr().err
