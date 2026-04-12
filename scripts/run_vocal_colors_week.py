"""One-shot runner: generate all 5 Vocal Colors captions in a single batch call.

Used to validate the batch entry point and compare against the single-caption
approach. Not a reusable script — hardcoded paths for the Vocal Colors test.
"""

from __future__ import annotations

import json
from pathlib import Path

from postroll.ai.generate_captions import generate_week_captions


EVENT_ROOT = Path("/Users/danielhankins-wright/Downloads/socials/vocal colors")
PROGRAM_PATH = Path("/Users/danielhankins-wright/Documents/PostRoll/output/test-vocal-colors/program_enriched.json")
OUT_PATH = Path("/Users/danielhankins-wright/Documents/PostRoll/output/test-vocal-colors/week_batch.json")


def photos_from(day_num: int) -> list[Path]:
    return sorted((EVENT_ROOT / f"day {day_num}").glob("*.jpg"))


def sample_representative(paths: list[Path], k: int) -> list[Path]:
    """Even-spacing sample until we have proper representative picking."""
    if len(paths) <= k:
        return paths
    step = len(paths) // k
    return [paths[i * step] for i in range(k)]


ALWAYS_TAGS = [
    "@dciny",
    "@lincolncenter",
    "@kylepedersonmusic",
    "@jennayarobison",
    "@stephenmartintenor",
]
PERFORMER_TAGS = [
    "@mdumc",
    "@cchs_official",
    "@germantown_legacy",
    "@squoir_mhs",
    "@ocsa_cv",
    "@lrhschorus",
]
NAME_MENTIONS = ["Jordan Langworthy"]


def main() -> None:
    program = json.loads(PROGRAM_PATH.read_text())

    posts = [
        {
            "day": "sunday",
            "post_type": "feed_photo",
            "photo_paths": photos_from(1),
            "tag_handles": ALWAYS_TAGS,
            "name_mentions": NAME_MENTIONS,
        },
        {
            "day": "monday",
            "post_type": "feed_photo",
            "photo_paths": photos_from(2),
            "tag_handles": ALWAYS_TAGS,
            "name_mentions": NAME_MENTIONS,
        },
        {
            "day": "tuesday",
            "post_type": "slider_reel",
            "photo_paths": photos_from(3),
            "tag_handles": ALWAYS_TAGS,
            "name_mentions": NAME_MENTIONS,
        },
        {
            "day": "wednesday",
            "post_type": "carousel",
            "photo_paths": photos_from(4),
            "tag_handles": ALWAYS_TAGS,
            "name_mentions": NAME_MENTIONS,
        },
        {
            "day": "thursday",
            "post_type": "scroll_reel",
            "photo_paths": sample_representative(photos_from(5), 10),
            "tag_handles": ALWAYS_TAGS + PERFORMER_TAGS,
            "name_mentions": NAME_MENTIONS,
        },
    ]

    results = generate_week_captions(
        event="Vocal Colors",
        org="DCINY",
        venue="David Geffen Hall",
        date="2026-03-30",
        program=program,
        posts=posts,
        shoot_type="performance",
    )

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(results, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {OUT_PATH}")
    for r in results:
        print(f"\n--- {r['day'].upper()} ({r['post_type']}) ---")
        print(r["caption"])


if __name__ == "__main__":
    main()
