"""
PostRoll: Render the Friday clip reel from a user's manual override
(reorder/include-exclude/swap), skipping Stage 1/2 entirely.

A thin CLI wrapper around render_clip_reel.py's core primitive, mirroring
swap_reel_audio.py's focused-script pattern. Invoked directly by
PythonBridge.swift when the user edits the AI's cut without asking Claude
to re-cut it (feedback_collage_edits_no_python_regen: manual edits never
re-invoke Claude).

Usage:
    python -m postroll.ai.render_friday_override \\
        --manifest /path/to/manifest.json \\
        --output   /path/to/reel.mp4

Manifest:
{
  "selections": [
    {"clip_path": "...", "trim_in": 1.2, "trim_out": 4.5, "transition": "cut"},
    ...
  ],
  "audio": "/path/to/user/audio.mp3",   # optional; omit to auto-fetch
  "shoot_type": "performance",          # optional; used only for auto-fetch
  "pieces": [...],                      # optional; used only for auto-fetch
  "duck_gain_db": -15.0,                # optional
  "mute_clip_audio": false              # optional
}
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from ..media.render_clip_reel import render_clip_reel, DEFAULT_DUCK_GAIN_DB
from ..media.generate_title_card import apply_title_card_in_place
from .audio_tags import resolve_reel_audio


def render_friday_override(manifest: dict[str, Any], output_path: str | Path) -> dict[str, str]:
    """Render `manifest`'s selections (already reordered/filtered by the
    user's fridayClipOverride, transition carried over from the original
    AI plan by the caller) into the reel MP4 at `output_path`.

    Returns:
        {"reel": <path actually written>,
         "title_card_skipped": <why the reel carries no title, "" when it does>}

        `title_card_skipped` is empty for a reel that HAS its title and for one
        Dan muted the title on, which are the two cases needing nothing said: he
        made the second choice himself, in the app, which already knows it. It
        carries a reason only when the card was meant to be there and is not
        (#824), so that the app can say so rather than the process printing it
        to a console nobody keeps.

    Raises ValueError if `selections` is empty.
    """
    selections = manifest.get("selections") or []
    if not selections:
        raise ValueError("no selections in override manifest")

    render_selections = [
        {
            "clip_path": sel["clip_path"],
            "trim_in": sel["trim_in"],
            "trim_out": sel["trim_out"],
            "transition_after": sel.get("transition", "cut"),
            # Carried through so a manual reorder/trim edit doesn't silently
            # drop the AI's crop choice (plan #148, Phase 2): this path
            # used to only know clip path, trim, and transition.
            "crop_x": sel.get("crop_x", 0.0),
            "crop_y": sel.get("crop_y", 0.0),
        }
        for sel in selections
    ]

    music_path = resolve_reel_audio(
        manifest.get("audio"),
        shoot_type=manifest.get("shoot_type", "performance"),
        pieces=manifest.get("pieces", []),
    )

    reel_path = render_clip_reel(
        render_selections,
        output_path,
        audio_path=music_path,
        duck_gain_db=float(manifest.get("duck_gain_db", DEFAULT_DUCK_GAIN_DB)),
        mute_clip_audio=bool(manifest.get("mute_clip_audio", False)),
    )

    # Title card overlay (plan #148, Phase 3): same on-by-default policy as
    # generate_media.py's initial render, so a manual reorder/trim edit
    # doesn't silently drop or restore it. A finishing touch, not the
    # product itself, so a failure here must never cost the reel already
    # rendered above.
    title_card_skipped = ""
    if not bool(manifest.get("title_card_muted", False)):
        title_card_skipped = apply_title_card_in_place(
            reel_path, manifest.get("event_name", ""),
            staging_path=f"{reel_path}.titled.tmp",
        ) or ""
        if title_card_skipped:
            print(f"[render_friday_override] WARNING: {title_card_skipped}",
                  flush=True, file=sys.stderr)

    return {"reel": str(reel_path), "title_card_skipped": title_card_skipped}


def _main() -> int:
    parser = argparse.ArgumentParser(description="Render the Friday reel from a manual override")
    parser.add_argument("--manifest", required=True, help="JSON file (see module docstring)")
    parser.add_argument("--output", required=True, help="Where to write the rendered MP4")
    # Optional, unlike swap_reel_audio.py's: the Swift half is frozen into the
    # installed app while this half runs live from the checkout, so an app build
    # predating this flag must keep working rather than failing on an argument
    # it has never heard of. What such a build loses is only the title card
    # report, and it gets that back on its next rebuild.
    parser.add_argument("--result", default=None,
                        help="Where to write the JSON result (reel + title_card_skipped)")
    args = parser.parse_args()

    try:
        manifest = json.loads(Path(args.manifest).read_text())
        result = render_friday_override(manifest, args.output)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    if args.result:
        Path(args.result).write_text(json.dumps(result, indent=2))

    print(f"[render_friday_override] wrote {args.output}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(_main())
