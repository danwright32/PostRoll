"""
PostRoll — Royalty-free audio fetcher (Jamendo)

Searches Jamendo for a downloadable instrumental track matching the
given comma-separated tags (e.g. "ambient,atmospheric"), caches it
locally by track ID, and returns the local path. Re-running with the
same result track skips the download.

Requires JAMENDO_CLIENT_ID environment variable.
Get a free key at https://devportal.jamendo.com

Cache location: ~/.postroll/audio_cache/<track_id>.mp3

Usage:
    python -m postroll.audio --tags ambient,atmospheric --output /tmp/track.mp3
"""

from __future__ import annotations

import json
import os
import random
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

JAMENDO_TRACKS_URL = "https://api.jamendo.com/v3.0/tracks"
DEFAULT_CACHE_DIR = Path.home() / ".postroll" / "audio_cache"
_SEARCH_LIMIT = 20  # tracks fetched per search; picks randomly from top 10


def fetch_audio_candidates(
    tags: str,
    *,
    count: int = 5,
    exclude_ids: tuple[str, ...] = (),
    cache_dir: Path | None = None,
    seed: int | None = None,
    exclude_keywords: tuple[str, ...] = ("rock", "heroic", "loop", " logo", "adventure"),
) -> list[dict[str, Any]]:
    """Return a list of candidate Jamendo tracks matching `tags`, pre-downloaded
    to the local cache so the UI can preview them immediately.

    Args:
        tags: Comma-separated genre/mood tags.
        count: Target number of candidates to return (<= _SEARCH_LIMIT).
        exclude_ids: Track IDs to skip (used for "get new tracks" pagination).
        cache_dir: Override the default cache directory.
        seed: Seeds the deterministic ordering inside the filtered pool so
              repeated calls with the same seed return the same set.
        exclude_keywords: Name substrings to filter out (same defaults as
                          `fetch_audio`).

    Returns:
        List of dicts: {id, name, artist_name, duration, tags, local_path}.
    """
    client_id = os.environ.get("JAMENDO_CLIENT_ID", "").strip()
    if not client_id:
        raise EnvironmentError(
            "JAMENDO_CLIENT_ID environment variable is not set. "
            "Get a free key at https://devportal.jamendo.com"
        )

    cache = Path(cache_dir) if cache_dir else DEFAULT_CACHE_DIR
    cache.mkdir(parents=True, exist_ok=True)

    tracks = _search_tracks(tags, client_id)
    excluded = set(exclude_ids)
    filtered = [
        t for t in tracks
        if str(t["id"]) not in excluded
        and not any(kw.lower() in t["name"].lower() for kw in exclude_keywords)
    ]
    if not filtered:
        return []

    rng = random.Random(seed)
    rng.shuffle(filtered)
    picks = filtered[:count]

    results: list[dict[str, Any]] = []
    for track in picks:
        track_id = str(track["id"])
        cached = cache / f"{track_id}.mp3"
        if not cached.exists():
            try:
                _download(track["audiodownload"], cached)
            except Exception:
                continue
        results.append({
            "id": track_id,
            "name": track["name"],
            "artist_name": track.get("artist_name", ""),
            "duration": float(track.get("duration", 0) or 0),
            "tags": tags,
            "local_path": str(cached),
        })
    return results


def fetch_audio(
    tags: str,
    cache_dir: Path | None = None,
    *,
    seed: int | None = None,
    exclude: tuple[str, ...] = ("rock", "heroic", "loop", " logo", "adventure"),
) -> str:
    """Return path to a cached Jamendo track matching the given tags.

    Downloads on first use; returns the cached path on subsequent calls
    for the same track.

    Args:
        tags: Comma-separated genre/mood tags, e.g. "ambient,instrumental".
        cache_dir: Override the default ~/.postroll/audio_cache directory.
        seed: Fix the random track selection (useful for tests).
        exclude: Case-insensitive substrings to filter out of track names.
                 Removes low-quality picks like "Epic Rock", "logo sting", loops, etc.

    Returns:
        Absolute path to the downloaded .mp3 file.

    Raises:
        EnvironmentError: JAMENDO_CLIENT_ID is not set.
        RuntimeError: No downloadable tracks found for the given tags.
    """
    client_id = os.environ.get("JAMENDO_CLIENT_ID", "").strip()
    if not client_id:
        raise EnvironmentError(
            "JAMENDO_CLIENT_ID environment variable is not set. "
            "Get a free key at https://devportal.jamendo.com"
        )

    cache = Path(cache_dir) if cache_dir else DEFAULT_CACHE_DIR
    cache.mkdir(parents=True, exist_ok=True)

    tracks = _search_tracks(tags, client_id)
    if not tracks:
        raise RuntimeError(
            f"No downloadable Jamendo tracks found for tags={tags!r}. "
            "Try different tags or verify your JAMENDO_CLIENT_ID."
        )

    # Filter out tracks whose names contain unwanted keywords
    filtered = [
        t for t in tracks
        if not any(kw.lower() in t["name"].lower() for kw in exclude)
    ]
    pool = filtered if filtered else tracks  # fall back to unfiltered if everything matched

    rng = random.Random(seed)
    track = rng.choice(pool[: min(10, len(pool))])
    track_id = str(track["id"])
    cached = cache / f"{track_id}.mp3"

    if not cached.exists():
        print(f"Downloading audio: {track['name']!r} (Jamendo id={track_id})")
        _download(track["audiodownload"], cached)

    return str(cached)


def _search_tracks(tags: str, client_id: str) -> list[dict[str, Any]]:
    params = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "tags": tags,
            "audioformat": "mp31",
            "audiodownload_allowed": "true",
            "limit": str(_SEARCH_LIMIT),
            "format": "json",
        }
    )
    url = f"{JAMENDO_TRACKS_URL}?{params}"
    with urllib.request.urlopen(url, timeout=15) as resp:
        data: dict[str, Any] = json.loads(resp.read().decode())
    return [
        t
        for t in data.get("results", [])
        if t.get("audiodownload_allowed") and t.get("audiodownload")
    ]


def _download(url: str, dest: Path) -> None:
    with urllib.request.urlopen(url, timeout=60) as src, open(dest, "wb") as dst:
        while chunk := src.read(65536):
            dst.write(chunk)


if __name__ == "__main__":
    import argparse
    import shutil

    parser = argparse.ArgumentParser(description="Fetch royalty-free audio from Jamendo")
    parser.add_argument(
        "--tags", required=True, help="Comma-separated tags e.g. ambient,atmospheric"
    )
    parser.add_argument("--output", required=True, help="Destination path for the audio file")
    parser.add_argument("--seed", type=int, default=None, help="Random seed for reproducible selection")
    args = parser.parse_args()

    src = fetch_audio(tags=args.tags, seed=args.seed)
    shutil.copy2(src, args.output)
    print(f"Audio saved to: {args.output}")
