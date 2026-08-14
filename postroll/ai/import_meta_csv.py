"""
PostRoll — Meta Business Suite CSV importer.

Parses one or more Meta Business Suite CSV exports (stories and/or feed posts)
into the IGPost JSON shape expected by AnalyticsStore. Pure Python — no Claude.

Usage:
    python -m postroll.ai.import_meta_csv \
        --csv /path/to/feed_export.csv \
        --csv /path/to/stories_export.csv \
        --output /path/to/result.json

Output JSON:
    {"posts": [...], "warnings": [...]}
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any
from zoneinfo import ZoneInfo


# ---------------------------------------------------------------------------
# Column mapping  (Meta renames columns across versions — aliases are checked
# in order; first match wins)
# ---------------------------------------------------------------------------

FIELD_ALIASES: dict[str, list[str]] = {
    "ig_post_id":       ["Post ID"],
    "ig_permalink":     ["Permalink"],
    "published_at":     ["Publish time", "Publish Time", "Post publish time", "Created time"],
    "raw_post_type":    ["Post type", "Type"],
    "caption":          ["Description", "Post caption", "Caption", "Post text"],
    "duration_sec":     ["Duration (sec)", "Duration"],
    "views":            ["Views"],
    "reach":            ["Reach", "Accounts reached"],
    "likes":            ["Likes", "Likes & Reactions", "Reactions"],
    "shares":           ["Shares"],
    "follows":          ["Follows"],
    "comments":         ["Comments"],
    "saves":            ["Saves", "Bookmarks"],
    "replies":          ["Replies"],
    "navigation":       ["Navigation"],
    "profile_visits":   ["Profile visits", "Profile Visits"],
    "sticker_taps":     ["Sticker taps", "Sticker Taps"],
}

#: The metric columns that may or may not appear on a post, named here rather
#: than inline so the payload contract can expand them from the real symbol
#: instead of a hand-copied list that stops matching (#274, L41).
OPTIONAL_METRIC_FIELDS = (
    "views", "reach", "likes", "shares", "follows",
    "comments", "saves", "replies", "navigation",
    "profile_visits", "sticker_taps",
)

#: The timezone Meta writes the "Publish time" column in, MEASURED rather than
#: assumed (#487). A scheduled carousel Dan set for 4:08pm New York on
#: 2026-08-12 is written into the export as 13:08, three hours behind, which is
#: neither the account's own local time (what this file used to assume) nor UTC
#: (what its docstring used to claim). Pacific is Meta's own home timezone.
#:
#: The sample behind that, and instructions for adding another, live in
#: tests/fixtures/meta_publish_time_measurement.json, which the suite holds this
#: constant to. Change it only against a new measurement, never against a guess:
#: three hours of error here moves every "best hour to post" number the app
#: produces without anything looking wrong (L34).
META_EXPORT_TIMEZONE = ZoneInfo("America/Los_Angeles")

#: The zone Dan actually posts in, and therefore the one an hour or a
#: day-of-week has to be expressed in for the analysis to mean anything.
ACCOUNT_TIMEZONE = ZoneInfo("America/New_York")

# Meta post type → normalized IGMediaType value
MEDIA_TYPE_MAP: dict[str, str] = {
    "ig story":   "story",
    "ig reel":    "reel",
    "ig image":   "image",
    "ig photo":   "image",
    "ig carousel": "carousel",
    "ig album":   "carousel",
    "ig video":   "video",
}

# Dan's own account handle — exclude from org extraction
OWN_HANDLE = "dwphotony"

# Publish time format from Meta
PUBLISH_TIME_FMT = "%m/%d/%Y %H:%M"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _build_field_index(headers: list[str]) -> dict[str, str]:
    """Map internal field names to actual CSV column names."""
    # Lowercase + strip for case-insensitive comparison
    header_lower = {h.strip().lower(): h for h in headers}
    mapping: dict[str, str] = {}
    for field, aliases in FIELD_ALIASES.items():
        for alias in aliases:
            if alias.strip().lower() in header_lower:
                mapping[field] = header_lower[alias.strip().lower()]
                break
    return mapping


def _parse_int(raw: str | None) -> int | None:
    if not raw or not raw.strip():
        return None
    try:
        return int(raw.strip().replace(",", ""))
    except ValueError:
        return None


def _parse_float(raw: str | None) -> float | None:
    if not raw or not raw.strip():
        return None
    try:
        return float(raw.strip())
    except ValueError:
        return None


def _parse_date(raw: str) -> str | None:
    """Parse a Meta publish time into an ISO 8601 string in Dan's own timezone.

    The column is Pacific (see META_EXPORT_TIMEZONE), so it is read in that zone
    and converted to the account's, which is the frame every hour and
    day-of-week in the posting-time analysis is then read in.

    The returned string carries its UTC offset. It used to be naive, which is
    exactly what let three hours of error sit unnoticed: a naive string reads as
    correct to every consumer no matter which zone produced it, so there was
    nothing to disagree with. A date with no time in it stays a bare date, since
    inventing midnight in a zone would be asserting an hour nobody measured.
    """
    raw = raw.strip()
    if not raw:
        return None

    for fmt in (PUBLISH_TIME_FMT, "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            source = datetime.strptime(raw, fmt).replace(tzinfo=META_EXPORT_TIMEZONE)
        except ValueError:
            continue
        return source.astimezone(ACCOUNT_TIMEZONE).isoformat()

    try:
        return datetime.strptime(raw, "%Y-%m-%d").date().isoformat()
    except ValueError:
        return None


def _parse_hashtags(caption: str) -> list[str]:
    """Extract all hashtags from caption text, lowercased and deduped."""
    tags = re.findall(r"#[\w\u00C0-\uFFFF]+", caption)
    seen: set[str] = set()
    result: list[str] = []
    for tag in tags:
        t = tag.lower()
        if t not in seen:
            seen.add(t)
            result.append(t)
    return result


def _extract_org(caption: str) -> str | None:
    """Return the first @-mention that isn't Dan's own account handle."""
    mentions = re.findall(r"@([\w.]+)", caption)
    for mention in mentions:
        handle = mention.rstrip(".")      # strip trailing period (sentence punctuation)
        if handle.lower() != OWN_HANDLE.lower():
            return handle.lower()
    return None


def _normalize_media_type(raw_type: str) -> str:
    return MEDIA_TYPE_MAP.get(raw_type.strip().lower(), "unknown")


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

def parse_csv(path: Path) -> tuple[list[dict[str, Any]], list[str]]:
    """Parse one CSV file, return (posts, warnings)."""
    warnings: list[str] = []
    posts: list[dict[str, Any]] = []

    with path.open(newline="", encoding="utf-8-sig") as fh:
        reader = csv.DictReader(fh)
        headers = reader.fieldnames or []
        field_index = _build_field_index(list(headers))

        # Warn about any known fields that could not be mapped
        critical = {"ig_post_id", "published_at", "caption", "raw_post_type"}
        for f in critical:
            if f not in field_index:
                warnings.append(f"File {path.name}: could not find column for '{f}'. "
                                 f"Available columns: {list(headers)[:10]}")

        # Report completely unknown columns that might be new metrics
        known_aliases = {a.strip().lower() for aliases in FIELD_ALIASES.values() for a in aliases}
        # Also ignore the non-metric informational columns
        ignore_cols = {"account id", "account username", "account name", "data comment", "date"}
        for header in headers:
            h = header.strip().lower()
            if h and h not in known_aliases and h not in ignore_cols:
                warnings.append(f"File {path.name}: unmapped column '{header}' — may be a new metric.")

        def get(row: dict, field: str) -> str | None:
            col = field_index.get(field)
            return row.get(col, "").strip() if col else None  # type: ignore[return-value]

        for row_num, row in enumerate(reader, start=2):
            post_id = get(row, "ig_post_id") or ""
            if not post_id:
                warnings.append(f"File {path.name} row {row_num}: missing Post ID, skipping.")
                continue

            raw_date = get(row, "published_at") or ""
            published_at = _parse_date(raw_date)
            if not published_at:
                # Swift requires a real date on every post; a dateless post is
                # useless for timing analysis anyway, so skip it loudly.
                warnings.append(f"File {path.name} row {row_num} ({post_id}): "
                                 f"could not parse date '{raw_date}', skipping post.")
                continue

            raw_type = get(row, "raw_post_type") or ""
            media_type = _normalize_media_type(raw_type)
            if media_type == "unknown" and raw_type:
                warnings.append(f"File {path.name} row {row_num}: unknown post type '{raw_type}'.")

            caption = get(row, "caption") or ""
            hashtags = _parse_hashtags(caption)
            org = _extract_org(caption)

            post: dict[str, Any] = {
                "ig_post_id":    post_id,
                "ig_permalink":  get(row, "ig_permalink") or "",
                "published_at":  published_at,
                "media_type":    media_type,
                "caption":       caption,
                "hashtags":      hashtags,
                "org":           org,
                "is_personal":   False,  # manual flag; nothing sets it automatically yet
            }

            # Metrics (all optional)
            for field in OPTIONAL_METRIC_FIELDS:
                v = _parse_int(get(row, field))
                if v is not None:
                    post[field] = v

            dur = _parse_float(get(row, "duration_sec"))
            if dur is not None:
                post["duration_sec"] = dur

            posts.append(post)

    return posts, warnings


def dedupe(posts: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Deduplicate by ig_post_id, keeping the last-seen entry."""
    seen: dict[str, dict[str, Any]] = {}
    for p in posts:
        seen[p["ig_post_id"]] = p
    # Sort by published_at descending (newest first)
    result = list(seen.values())
    result.sort(key=lambda p: p.get("published_at") or "", reverse=True)
    return result


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Import Meta Business Suite CSV exports.")
    parser.add_argument("--csv", action="append", required=True,
                        help="Path to a Meta CSV export. Repeat to add multiple files.")
    parser.add_argument("--output", required=True,
                        help="Path to write the output JSON.")
    args = parser.parse_args()

    all_posts: list[dict[str, Any]] = []
    all_warnings: list[str] = []

    for csv_path_str in args.csv:
        csv_path = Path(csv_path_str)
        if not csv_path.exists():
            all_warnings.append(f"File not found: {csv_path_str}")
            continue
        try:
            posts, warnings = parse_csv(csv_path)
            all_posts.extend(posts)
            all_warnings.extend(warnings)
        except Exception as exc:  # noqa: BLE001
            all_warnings.append(f"Failed to parse {csv_path.name}: {exc}")

    deduped = dedupe(all_posts)

    output = {
        "posts":    deduped,
        "warnings": all_warnings,
    }

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"Imported {len(deduped)} posts ({len(all_warnings)} warnings).", file=sys.stderr)


if __name__ == "__main__":
    main()
