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

Each selection may also carry crop_x/crop_y (plan #148, Phase 2): a
per-clip crop offset in [-1, 1], already server-side clamped and gated in
select_reel_clips.apply_selection. Missing or (0, 0) reproduces today's
centered crop exactly.
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


def _scale_pad_filter(crop_x: float = 0.0, crop_y: float = 0.0) -> str:
    """Fill the portrait canvas and crop the excess rather than fitting
    inside it with black bars: a landscape source should read as
    cropped-to-fill, matching every other template in this app (Dan's
    explicit feedback, 2026-07-08).

    crop_x/crop_y (plan #148, Phase 2) shift where that crop is taken from,
    same [-1, 1] convention as the app's CropOffset (0 = centered, already
    server-side clamped and gated in select_reel_clips.apply_selection
    before ever reaching here). At (0, 0) this must produce the exact
    "crop=W:H" string every reel rendered before this feature existed.
    """
    if crop_x == 0.0 and crop_y == 0.0:
        crop = f"crop={CANVAS_W}:{CANVAS_H}"
    else:
        # ffmpeg crop's own default position is centered: (in_w-out_w)/2,
        # (in_h-out_h)/2. An offset scales that same centered position by
        # (1 + offset), so -1/+1 lands exactly on the left/right (or
        # top/bottom) edge of the available slack and 0 reproduces center.
        x_expr = f"(in_w-out_w)/2*(1+({crop_x:.4f}))"
        y_expr = f"(in_h-out_h)/2*(1+({crop_y:.4f}))"
        crop = f"crop={CANVAS_W}:{CANVAS_H}:{x_expr}:{y_expr}"
    return f"scale={CANVAS_W}:{CANVAS_H}:force_original_aspect_ratio=increase,{crop},setsar=1"


#: What the intermediate segment encodes ask x264 for.
#:
#: Named rather than written into the command, so the tool that measures what
#: they cost moves the setting the encode really uses rather than a copy of it
#: (`tools/measure_clip_reel_encodes.py`, #826). The readings recorded beside
#: `_prepare_segment` were taken by moving these.
#:
#: The preset applies only when something downstream re-encodes these pixels;
#: see `_prepare_segment` for why, and #819 for what it costs.
SEGMENT_PRESET = "veryfast"
SEGMENT_CRF = "20"


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


def _prepare_segment(sel: dict, out_path: Path, *, has_audio: bool,
                     reencoded_downstream: bool = True) -> float:
    """Trim + normalize one selection to a standalone segment at a
    consistent resolution/fps/audio format so the segments can be joined
    with xfade regardless of the source clips' original formats. Returns
    the segment's duration.

    `reencoded_downstream` says whether anything encodes these pixels again.
    With more than one selection the join below does, and this pass takes
    `-preset veryfast`; with exactly ONE the join is a stream copy, so this is
    the encode that decides what ships and it takes no preset (#819).
    """
    trim_in = float(sel["trim_in"])
    trim_out = float(sel["trim_out"])
    duration = trim_out - trim_in

    crop_x = float(sel.get("crop_x") or 0.0)
    crop_y = float(sel.get("crop_y") or 0.0)
    cmd = [
        "ffmpeg", "-y", "-loglevel", "error",
        "-ss", str(trim_in), "-to", str(trim_out), "-i", str(sel["clip_path"]),
        "-vf", _scale_pad_filter(crop_x, crop_y),
        "-r", "30",
        # Fast when the join re-encodes these pixels, and what that costs was
        # measured rather than assumed (#819). On 30s of panned photography
        # with grain, the whole reel takes 16.6s with every pass fast, 21.3s
        # with only the delivering pass at medium, and 37.8s with these at
        # medium too. Against intermediates encoded LOSSLESSLY, which is the
        # best material the last pass could have, dropping the preset here
        # buys 1.0 dB of PSNR and 0.06 of SSIM on footage of pure noise, the
        # hardest case there is. So it more than doubles a Friday render for a
        # difference nothing has shown to be visible, and it stays.
        #
        # The OTHER lever was measured afterwards (#826), by
        # `tools/measure_clip_reel_encodes.py`, which is the same comparison
        # written down rather than done by hand. Keeping `veryfast` and lowering
        # the intermediate's `-crf` was supposed to cost bitrate and disk rather
        # than CPU. On this Mac on 2026-08-22, a 30s reel of panned footage with
        # heavy grain, every row against lossless intermediates:
        #
        #     veryfast crf 20 (ships)    72.7s   36.86 dB   SSIM 0.9056
        #     veryfast crf 16            81.7s   37.12 dB   SSIM 0.9150
        #     medium   crf 20           122.1s   38.48 dB   SSIM 0.9410
        #
        # `crf 16` buys a sixth of what the preset buys, and it is not free: 12%
        # more wall clock, because more bits take longer to write. The premise
        # that it would cost no CPU is what the measurement disproved.
        #
        # The same table on ordinary footage (grain 8) separates no variant from
        # another by more than 0.3 dB, with every render inside 8s of the
        # others, so the question only has teeth on footage that barely
        # compresses at all. The intermediates stay at veryfast crf 20.
        #
        # Both readings are synthetic: there were no real Friday clips on this
        # machine to measure. The tool takes them with `--clips`, and re-takes
        # the whole table.
        "-c:v", "libx264",
        *(("-preset", SEGMENT_PRESET) if reencoded_downstream else ()),
        "-crf", SEGMENT_CRF,
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


from .probe import probe_duration  # noqa: E402


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
        # A single selection is copied rather than joined below, so its
        # prepared segment IS the reel and the pass that makes it is the one
        # deciding shipped pixels (#819).
        joined_afterwards = len(selections) > 1
        for i, sel in enumerate(selections):
            seg_path = tmp_path / f"segment_{i:02d}.mp4"
            duration = _prepare_segment(sel, seg_path, has_audio=has_audio[i],
                                        reencoded_downstream=joined_afterwards)
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
                # No preset, which is ffmpeg's medium (#819). The mux below
                # copies this stream and the title card is optional, so these
                # are the pixels that ship whenever it is muted or fails, and
                # #811 settled what a fast preset does to a delivered file.
                # Measured on 2026-08-22, on 30s of panned photography with
                # grain: 16.6s for the whole reel with every pass fast, 21.3s
                # with this one at medium, 37.8s with every pass at medium.
                "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p",
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
    """Length of a clip, refusing rather than returning an unusable number.

    Through the shared probe (#123), so a failed exit, empty output and "N/A"
    all arrive here as None instead of three different crashes.
    """
    seconds = probe_duration(path)
    if seconds is None:
        raise RenderClipReelError(f"could not probe duration of {path}")
    return seconds


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
