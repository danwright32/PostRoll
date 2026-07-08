"""
PostRoll: Friday clip reel Stage 3, render Stage 2's selection plan into the
final MP4.

Trims each selected clip to its (already-clamped) window, joins consecutive
clips with either a hard cut or a short crossfade per Stage 2's
`transition_after` choice, and mixes a music bed under each clip's own
audio, ducked to a fixed gain (or muted entirely) rather than played silent.

Video and audio joins are both expressed as `xfade`/`acrossfade` chains:
a "cut" is just a crossfade with a near-zero duration, so one filter-graph
path handles both transition styles instead of maintaining a separate
concat-demuxer path for cuts. Mirrors audio_fit.py's acrossfade precedent
and swap_reel_audio.py's atomic tmp.replace(...) write.

Usage:
    from postroll.media.render_clip_reel import render_clip_reel

    render_clip_reel(
        plan["selections"],  # Stage 2's clamped, ordered selection
        out_path,
        audio_path=music_track,       # None = silent music bed (rare)
        duck_gain_db=-15.0,
        mute_clip_audio=False,
    )
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from .audio_fit import fit_audio_to_duration

CANVAS_W = 1080
CANVAS_H = 1920

# Applied to both "cut" and "crossfade" joins via xfade/acrossfade. A cut
# uses a near-zero duration (short enough to read as instantaneous) so both
# transition styles share one filter-graph construction path.
CUT_DURATION = 0.04
CROSSFADE_DURATION = 0.4
TRANSITION_DURATION = CROSSFADE_DURATION

# Dan's explicit call: clip audio present but subordinate to the music bed,
# not silent underneath it. Overridable per event (mute_clip_audio) since
# he sometimes wants clips fully silent under the music instead.
DEFAULT_DUCK_GAIN_DB = -15.0


class RenderClipReelError(RuntimeError):
    """Raised when the selection plan is invalid or ffmpeg fails."""


def _transition_duration(transition_after: str) -> float:
    return CROSSFADE_DURATION if transition_after == "crossfade" else CUT_DURATION


def _xfade_offsets(durations: list[float], transition_durations: list[float]) -> list[float]:
    """Cumulative xfade `offset` for each join: the timeline position (in
    the running concatenation) where the next segment's crossfade begins.
    len(durations) == len(transition_durations) + 1 (N segments, N-1 joins).
    """
    offsets: list[float] = []
    running = durations[0]
    for seg_duration, join_duration in zip(durations[1:], transition_durations):
        offset = running - join_duration
        offsets.append(offset)
        running = offset + seg_duration
    return offsets


def _scale_pad_filter() -> str:
    return (
        f"scale={CANVAS_W}:{CANVAS_H}:force_original_aspect_ratio=decrease,"
        f"pad={CANVAS_W}:{CANVAS_H}:(ow-iw)/2:(oh-ih)/2,setsar=1"
    )


def _validate_selections(selections: list[dict]) -> None:
    if not selections:
        raise RenderClipReelError("no selections to render")
    for sel in selections:
        trim_in = float(sel.get("trim_in", 0.0))
        trim_out = float(sel.get("trim_out", 0.0))
        if trim_out <= trim_in:
            raise RenderClipReelError(
                f"non-positive trim window for {sel.get('clip_path')!r}: "
                f"trim_in={trim_in}, trim_out={trim_out}"
            )


def _prepare_segment(sel: dict, out_path: Path, *, has_audio: bool) -> float:
    """Trim + normalize one selection to a standalone segment at a
    consistent resolution/fps/audio format so the segments can be joined
    with xfade regardless of the source clips' original formats. Returns
    the segment's duration."""
    trim_in = float(sel["trim_in"])
    trim_out = float(sel["trim_out"])
    duration = trim_out - trim_in

    cmd = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-ss", str(trim_in), "-to", str(trim_out), "-i", str(sel["clip_path"]),
        "-vf", _scale_pad_filter(),
        "-r", "30",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
        "-pix_fmt", "yuv420p",
    ]
    if has_audio:
        cmd += ["-c:a", "aac", "-b:a", "192k", "-ar", "44100", "-ac", "2"]
    else:
        cmd += ["-an"]
    cmd += [str(out_path)]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 or not out_path.exists():
        raise RenderClipReelError(
            f"ffmpeg segment prep failed for {sel.get('clip_path')!r}: {result.stderr.strip()}"
        )
    return duration


def _segment_has_audio(path: str) -> bool:
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
         "stream=index", "-of", "csv=p=0", str(path)],
        capture_output=True, text=True,
    )
    return proc.returncode == 0 and proc.stdout.strip() != ""


def _xfade_chain(
    segment_paths: list[Path],
    durations: list[float],
    transitions: list[str],
    *,
    stream_label: str,
    filter_name: str,
) -> tuple[list[str], str, str]:
    """Build the ffmpeg -i args + filter_complex chain joining `segment_paths`
    with xfade (video) or acrossfade (audio) at each transition. Returns
    (input_args, final_output_label)."""
    input_args: list[str] = []
    for p in segment_paths:
        input_args += ["-i", str(p)]

    join_durations = [_transition_duration(t) for t in transitions]
    offsets = _xfade_offsets(durations, join_durations)

    parts: list[str] = []
    prev = f"0:{stream_label}"
    for i, (join_duration, offset) in enumerate(zip(join_durations, offsets)):
        nxt_input = f"{i + 1}:{stream_label}"
        out_label = f"{stream_label}{i + 1}"
        if filter_name == "xfade":
            parts.append(
                f"[{prev}][{nxt_input}]xfade=transition=fade:"
                f"duration={join_duration:.3f}:offset={offset:.3f}[{out_label}]"
            )
        else:
            parts.append(
                f"[{prev}][{nxt_input}]acrossfade=d={join_duration:.3f}:c1=qsin:c2=qsin[{out_label}]"
            )
        prev = out_label

    return input_args, prev if parts else "0:" + stream_label, ";".join(parts)


def render_clip_reel(
    selections: list[dict],
    out_path: str | Path,
    *,
    audio_path: str | Path | None = None,
    duck_gain_db: float = DEFAULT_DUCK_GAIN_DB,
    mute_clip_audio: bool = False,
) -> str:
    """Render Stage 2's `selections` (clip_path, trim_in, trim_out,
    transition_after) into a single reel MP4 at `out_path`.

    The music bed (`audio_path`, already resolved by the caller: Jamendo
    fetch or a user-provided file) is fit to the reel's exact rendered
    duration and mixed with each clip's own trimmed audio, ducked
    `duck_gain_db` under the music (or dropped entirely if
    `mute_clip_audio`). Raises RenderClipReelError for an empty or invalid
    plan, or if ffmpeg fails at any stage.
    """
    _validate_selections(selections)
    out_path = Path(out_path)

    with tempfile.TemporaryDirectory(prefix="postroll-renderclipreel-") as tmp:
        tmp_path = Path(tmp)

        # Only the audio that actually exists on the source clip is kept.
        # Muting is a mix-time decision (below), not a segment-prep one, so
        # the same prepared segments are reusable regardless of mute_clip_audio.
        has_audio = [not mute_clip_audio and _segment_has_audio(sel["clip_path"]) for sel in selections]

        segment_paths: list[Path] = []
        durations: list[float] = []
        for i, sel in enumerate(selections):
            seg_path = tmp_path / f"segment_{i:02d}.mp4"
            duration = _prepare_segment(sel, seg_path, has_audio=has_audio[i])
            segment_paths.append(seg_path)
            durations.append(duration)

        transitions = [s.get("transition_after", "cut") for s in selections[:-1]]

        video_input_args, video_out_label, video_filter = _xfade_chain(
            segment_paths, durations, transitions, stream_label="v", filter_name="xfade"
        )

        video_track = tmp_path / "video_track.mp4"
        if len(segment_paths) == 1:
            video_cmd = [
                "ffmpeg", "-y", "-loglevel", "error", "-i", str(segment_paths[0]),
                "-an", "-c:v", "copy", str(video_track),
            ]
        else:
            video_cmd = [
                "ffmpeg", "-y", "-loglevel", "error", *video_input_args,
                "-filter_complex", video_filter,
                "-map", f"[{video_out_label}]", "-an",
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
                str(video_track),
            ]
        result = subprocess.run(video_cmd, capture_output=True, text=True)
        if result.returncode != 0 or not video_track.exists():
            raise RenderClipReelError(f"ffmpeg video join failed: {result.stderr.strip()}")

        reel_duration = _probe_duration(video_track)

        clip_audio_track: Path | None = None
        audible_segments = [p for p, a in zip(segment_paths, has_audio) if a]
        if audible_segments and not mute_clip_audio:
            clip_audio_track = tmp_path / "clip_audio.wav"
            audible_durations = [d for d, a in zip(durations, has_audio) if a]
            audible_transitions = [
                t for t, a1, a2 in zip(transitions, has_audio[:-1], has_audio[1:]) if a1 and a2
            ]
            if len(audible_segments) == 1:
                audio_cmd = [
                    "ffmpeg", "-y", "-loglevel", "error", "-i", str(audible_segments[0]),
                    "-vn", "-c:a", "pcm_s16le", str(clip_audio_track),
                ]
            else:
                audio_input_args, audio_out_label, audio_filter = _xfade_chain(
                    audible_segments, audible_durations, audible_transitions,
                    stream_label="a", filter_name="acrossfade",
                )
                audio_cmd = [
                    "ffmpeg", "-y", "-loglevel", "error", *audio_input_args,
                    "-filter_complex", audio_filter,
                    "-map", f"[{audio_out_label}]", "-c:a", "pcm_s16le",
                    str(clip_audio_track),
                ]
            result = subprocess.run(audio_cmd, capture_output=True, text=True)
            if result.returncode != 0 or not clip_audio_track.exists():
                raise RenderClipReelError(f"ffmpeg clip-audio join failed: {result.stderr.strip()}")

        mixed_audio = _build_mixed_audio(
            tmp_path, reel_duration, audio_path, clip_audio_track, duck_gain_db
        )

        # ffmpeg picks its output muxer from the filename extension; ".mp4.tmp"
        # doesn't match anything, so the container format is forced explicitly.
        tmp_out = out_path.with_suffix(out_path.suffix + ".tmp")
        if mixed_audio is not None:
            mux_cmd = [
                "ffmpeg", "-y", "-loglevel", "error",
                "-i", str(video_track), "-i", str(mixed_audio),
                "-map", "0:v:0", "-map", "1:a:0",
                "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                "-shortest", "-f", "mp4", str(tmp_out),
            ]
        else:
            mux_cmd = [
                "ffmpeg", "-y", "-loglevel", "error",
                "-i", str(video_track), "-c:v", "copy", "-an", "-f", "mp4", str(tmp_out),
            ]
        result = subprocess.run(mux_cmd, capture_output=True, text=True)
        if result.returncode != 0 or not tmp_out.exists():
            tmp_out.unlink(missing_ok=True)
            raise RenderClipReelError(f"ffmpeg mux failed: {result.stderr.strip()}")

        tmp_out.replace(out_path)

    return str(out_path)


def _probe_duration(path: Path) -> float:
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", str(path)],
        capture_output=True, text=True,
    )
    try:
        return float(proc.stdout.strip())
    except ValueError:
        raise RenderClipReelError(f"could not probe duration of {path}")


def _build_mixed_audio(
    tmp_path: Path,
    reel_duration: float,
    audio_path: str | Path | None,
    clip_audio_track: Path | None,
    duck_gain_db: float,
) -> Path | None:
    """Fit the music bed to `reel_duration` and mix it with the (already
    ducked-at-mix-time) clip audio track, if any. Returns None when there is
    neither a music bed nor clip audio to mux (silent reel)."""
    if audio_path is None and clip_audio_track is None:
        return None

    fitted_music: Path | None = None
    if audio_path is not None:
        fitted_music = tmp_path / "fitted_music.wav"
        fit_audio_to_duration(audio_path, fitted_music, duration=reel_duration)

    if fitted_music is not None and clip_audio_track is not None:
        mixed = tmp_path / "mixed_audio.wav"
        cmd = [
            "ffmpeg", "-y", "-loglevel", "error",
            "-i", str(fitted_music), "-i", str(clip_audio_track),
            "-filter_complex",
            f"[1:a]volume={duck_gain_db:.1f}dB[ducked];"
            f"[0:a][ducked]amix=inputs=2:duration=first:dropout_transition=0,"
            f"volume=2[aout]",
            "-map", "[aout]", "-t", f"{reel_duration:.3f}",
            "-c:a", "pcm_s16le", str(mixed),
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0 or not mixed.exists():
            raise RenderClipReelError(f"ffmpeg audio mix failed: {result.stderr.strip()}")
        return mixed

    return fitted_music if fitted_music is not None else clip_audio_track


def _main() -> int:
    import argparse
    import json

    parser = argparse.ArgumentParser(description="Render Stage 2's clip selection plan into a reel MP4")
    parser.add_argument("--plan", required=True, help="JSON file with {selections: [...]}")
    parser.add_argument("--output", required=True, help="Where to write the rendered MP4")
    parser.add_argument("--audio", default=None, help="Music bed file (already resolved by the caller)")
    parser.add_argument("--duck-gain-db", type=float, default=DEFAULT_DUCK_GAIN_DB)
    parser.add_argument("--mute-clip-audio", action="store_true")
    args = parser.parse_args()

    try:
        plan = json.loads(Path(args.plan).read_text())
        render_clip_reel(
            plan["selections"],
            args.output,
            audio_path=args.audio,
            duck_gain_db=args.duck_gain_db,
            mute_clip_audio=args.mute_clip_audio,
        )
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    print(f"[render_clip_reel] wrote {args.output}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(_main())
