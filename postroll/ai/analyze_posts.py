"""
PostRoll — Instagram analytics (Claude-as-analyst).

Reads a manifest of IGPost data + org follower bands, runs a confounder-aware
analysis via Claude, and returns an InsightReport JSON.

Usage:
    python -m postroll.ai.analyze_posts \
        --manifest /path/to/manifest.json \
        --output /path/to/report.json

Manifest shape:
    {
      "posts": [ /* array of IGPost in snake_case */ ],
      "org_bands": {"kyhs_music": "k1to10", ...},
      "global_hashtags_to_exclude": ["#dwphotony"],
    }

Output: InsightReport JSON (snake_case, all fields required by Swift Codable).
"""

from __future__ import annotations

import argparse
import json
import sys
import uuid
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from postroll.ai.claude_client import load_brand_voice, run_json_prompt


ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"

_EMPTY_FINDINGS = {
    "caption_patterns":      [],
    "hashtag_patterns":      [],
    "content_type_patterns": [],
    "timing_patterns":       [],
}

_EMPTY_REPORT_SHELL: dict[str, Any] = {
    "summary":               "",
    "post_count":            0,
    "story_count":           0,
    "feed_count":            0,
    "feed_findings":         _EMPTY_FINDINGS.copy(),
    "story_findings":        _EMPTY_FINDINGS.copy(),
    "brand_voice_suggestions": [],
    "caveats":               [],
}


# ---------------------------------------------------------------------------
# Deterministic prep
# ---------------------------------------------------------------------------

def _engagement_rate(post: dict[str, Any], is_story: bool) -> float | None:
    """Compute (interactions) / reach. Returns None if reach is absent."""
    reach = post.get("reach")
    if not reach or reach <= 0:
        return None
    if is_story:
        interactions = (post.get("likes") or 0) + (post.get("replies") or 0) + (post.get("shares") or 0)
    else:
        interactions = (post.get("likes") or 0) + (post.get("comments") or 0) + (post.get("saves") or 0)
    return round(interactions / reach, 4)


def _date_parts(iso: str) -> dict[str, Any]:
    """Parse ISO date string into day-of-week and hour (best effort)."""
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
        return {"day_of_week": dt.strftime("%A"), "hour": dt.hour}
    except ValueError:
        return {}


def _compact_post(post: dict[str, Any], org_bands: dict[str, str],
                  exclude_tags: set[str]) -> dict[str, Any]:
    """Build a compact per-post summary for the Claude prompt."""
    is_story = post.get("media_type") == "story"
    eng_rate = _engagement_rate(post, is_story)
    date_parts = _date_parts(post.get("published_at", ""))
    caption = post.get("caption", "")
    tags = [t for t in (post.get("hashtags") or []) if t not in exclude_tags]
    org = post.get("org")
    band = org_bands.get(org, "unknown") if org else "unknown"

    summary: dict[str, Any] = {
        "date":           (post.get("published_at") or "")[:10],
        "day_of_week":    date_parts.get("day_of_week"),
        "hour":           date_parts.get("hour"),
        "media_type":     post.get("media_type"),
        "org":            org,
        "org_band":       band,
        "caption_chars":  len(caption),
        "hashtag_count":  len(tags),
        "hashtags":       tags[:10],           # cap to top 10 for token budget
        "caption":        caption[:300],       # first 300 chars only
        "eng_rate":       eng_rate,
        "reach":          post.get("reach"),
        "likes":          post.get("likes"),
        "comments":       post.get("comments"),
        "saves":          post.get("saves"),
        "views":          post.get("views"),
    }
    # The prompt's confounder rule and the story navigation analysis only
    # work if these fields actually reach Claude; omitting them makes those
    # findings fabricated by construction.
    if is_story:
        summary["replies"]        = post.get("replies")
        summary["shares"]         = post.get("shares")
        summary["navigation"]     = post.get("navigation")
        summary["profile_visits"] = post.get("profile_visits")
        summary["sticker_taps"]   = post.get("sticker_taps")
    if post.get("is_personal"):
        summary["is_personal"] = True
    # Drop None values to reduce token count
    return {k: v for k, v in summary.items() if v is not None}


def _prep(
    posts: list[dict[str, Any]],
    org_bands: dict[str, str],
    global_exclude: set[str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], str, str]:
    """
    Split into feed/story, compute engagement rates.
    Returns (compact_feed, compact_stories, date_range_start, date_range_end).
    """
    feed, stories = [], []
    dates: list[str] = []

    for post in posts:
        if post.get("published_at"):
            dates.append(post["published_at"][:10])
        if post.get("media_type") == "story":
            stories.append(_compact_post(post, org_bands, global_exclude))
        else:
            feed.append(_compact_post(post, org_bands, global_exclude))

    dates.sort()
    start = dates[0] if dates else ""
    end = dates[-1] if dates else ""
    return feed, stories, start, end


# ---------------------------------------------------------------------------
# Prompt
# ---------------------------------------------------------------------------

_SCHEMA_DOC = """
Output a JSON object with this exact schema (all fields required):

{
  "summary": "<2–3 paragraphs of plain-English findings>",
  "post_count": <int — total posts analyzed>,
  "story_count": <int>,
  "feed_count": <int>,
  "feed_findings": {
    "caption_patterns":      [FindingList],
    "hashtag_patterns":      [FindingList],
    "content_type_patterns": [FindingList],
    "timing_patterns":       [FindingList]
  },
  "story_findings": {
    "caption_patterns":      [FindingList],
    "hashtag_patterns":      [FindingList],
    "content_type_patterns": [FindingList],
    "timing_patterns":       [FindingList]
  },
  "brand_voice_suggestions": ["<actionable sentence for the caption generator>", ...],
  "caveats": ["<data limitation or reliability note>", ...]
}

Where each FindingList item is:
{
  "headline": "<one-line scannable finding>",
  "evidence":   "<which posts, what metric, how you controlled for confounders>",
  "confidence": "low" | "medium" | "high"
}

Produce 2–5 findings per category where you have enough data; output [] where you don't.
Produce 3–6 brand_voice_suggestions.
Output ONLY the JSON — no preamble, no markdown fences.
"""


def _build_prompt(
    brand_voice: str,
    compact_feed: list[dict[str, Any]],
    compact_stories: list[dict[str, Any]],
    org_bands: dict[str, str],
    global_exclude: set[str],
    date_start: str,
    date_end: str,
) -> str:
    feed_json  = json.dumps(compact_feed,    ensure_ascii=False, separators=(",", ":"))
    story_json = json.dumps(compact_stories, ensure_ascii=False, separators=(",", ":"))
    bands_json = json.dumps(org_bands,       ensure_ascii=False)
    excluded   = ", ".join(sorted(global_exclude)) if global_exclude else "(none)"

    return f"""You are analyzing the Instagram post history of Dan Wright (@dwphotony), a classical concert photographer based in New York.

## Your mission
Find patterns in Dan's CRAFT that he can replicate — captions, hashtags, post type, content framing, timing. Your job is NOT to surface top posts by raw likes. That measures who he photographed (famous performer, high-follower org), not what he did as a photographer.

## Confounder-control rules — MUST follow
1. Use `eng_rate` (engagement rate against reach) as your primary metric when present. When absent, use normalized likes within the same `org_band` tier.
2. Group posts by `org_band` when making comparisons. Only report a pattern if it holds WITHIN a band (e.g., "among k1to10 orgs, X outperforms Y"). Never compare across bands.
3. Mark posts with `org_band = "unknown"` as unreliable for confounder-controlled comparisons. Mention them separately as "uncontrolled observations" only.
4. When `is_personal = true`, EXCLUDE the post from craft analysis entirely. Note how many personal posts were excluded.
5. For stories: note that story reach is typically lower than feed reach. Don't compare story metrics to feed metrics.
6. `org_band` values: under1k = < 1k followers, k1to10 = 1–10k, k10to50 = 10–50k, k50plus = 50k+, unknown = not tagged.

## Global hashtags (apply to every post — carry zero signal, exclude from ranking)
{excluded}

## Org follower bands
{bands_json}

## Brand voice reference (for tone — so suggestions match Dan's style)
{brand_voice[:2000]}

## Data
Date range: {date_start} to {date_end}
Feed posts ({len(compact_feed)} total):
{feed_json}

Story posts ({len(compact_stories)} total):
{story_json}

## What to produce
Analyze BOTH tracks (feed and stories) separately. For feed:
- Caption patterns: caption length, opening style (question vs statement vs location), emotional tone
- Hashtag patterns: which non-global tags correlate with higher eng_rate within the same org_band tier
- Content type patterns: classify each post from caption context (solo-portrait / ensemble / action-during-performance / venue / backstage / promo / recap / other) and find which types outperform within org_band tiers
- Timing patterns: day-of-week and hour patterns, controlling for org_band

For stories, analyze reach and navigation patterns separately.

For brand_voice_suggestions: write actionable sentences Dan can add to his brand voice file. Examples: "Close-up captions with an opening question outperform statement captions for mid-tier orgs" or "Limit hashtags to 5–8 for reels — more tags correlate with lower eng_rate in this dataset."

Set confidence honestly:
- high: pattern holds consistently across ≥10 posts in the same org_band tier
- medium: 5–9 posts, pattern visible but not robust
- low: fewer than 5 posts, or pattern is suggestive but confounded

{_SCHEMA_DOC}"""


# ---------------------------------------------------------------------------
# ID assignment
# ---------------------------------------------------------------------------

def _assign_ids(obj: Any) -> None:
    """Recursively assign UUIDs to dicts missing an 'id' field."""
    if isinstance(obj, dict):
        if "id" not in obj:
            obj["id"] = str(uuid.uuid4())
        for v in obj.values():
            _assign_ids(v)
    elif isinstance(obj, list):
        for item in obj:
            _assign_ids(item)


def _finalize(result: dict[str, Any], date_start: str, date_end: str) -> dict[str, Any]:
    """Add server-generated metadata and ensure all required fields exist."""
    now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    # Ensure required top-level keys are present (Claude may omit some on small data)
    for key, default in _EMPTY_REPORT_SHELL.items():
        if key not in result:
            result[key] = default

    for track in ("feed_findings", "story_findings"):
        if not isinstance(result.get(track), dict):
            result[track] = _EMPTY_FINDINGS.copy()
        else:
            for sub in ("caption_patterns", "hashtag_patterns",
                         "content_type_patterns", "timing_patterns"):
                if sub not in result[track]:
                    result[track][sub] = []

    result["generated_at"]    = now
    result["date_range_start"] = date_start or now[:10]
    result["date_range_end"]   = date_end or now[:10]

    _assign_ids(result)
    return result


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="Analyze Instagram posts via Claude.")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output",   required=True)
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    posts: list[dict[str, Any]] = manifest.get("posts", [])
    org_bands: dict[str, str]   = manifest.get("org_bands", {})
    global_raw: list[str]       = manifest.get("global_hashtags_to_exclude", [])

    # Normalize global tags (make sure they start with #, lowercase)
    global_exclude: set[str] = set()
    for tag in global_raw:
        t = tag.lower()
        global_exclude.add(t if t.startswith("#") else f"#{t}")

    # Auto-detect tags that appear on ≥95% of feed posts and add to exclusion
    feed_posts = [p for p in posts if p.get("media_type") != "story"]
    if len(feed_posts) >= 10:
        tag_counts: dict[str, int] = defaultdict(int)
        for p in feed_posts:
            for tag in (p.get("hashtags") or []):
                tag_counts[tag.lower()] += 1
        threshold = len(feed_posts) * 0.95
        for tag, count in tag_counts.items():
            if count >= threshold:
                global_exclude.add(tag)

    brand_voice = load_brand_voice()

    compact_feed, compact_stories, date_start, date_end = _prep(
        posts, org_bands, global_exclude
    )

    prompt = _build_prompt(
        brand_voice=brand_voice,
        compact_feed=compact_feed,
        compact_stories=compact_stories,
        org_bands=org_bands,
        global_exclude=global_exclude,
        date_start=date_start,
        date_end=date_end,
    )

    print(f"Analyzing {len(compact_feed)} feed posts + {len(compact_stories)} stories…", file=sys.stderr)

    result = run_json_prompt(prompt, timeout=600, step="analyze_posts")

    if not isinstance(result, dict):
        raise ValueError(f"Expected dict from Claude, got {type(result)}")

    report = _finalize(result, date_start, date_end)

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")

    print("Analysis complete.", file=sys.stderr)


if __name__ == "__main__":
    main()
