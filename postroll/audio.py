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
import time
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

JAMENDO_TRACKS_URL = "https://api.jamendo.com/v3.0/tracks"
DEFAULT_CACHE_DIR = Path.home() / ".postroll" / "audio_cache"
_SEARCH_LIMIT = 20  # tracks fetched per search; picks randomly from top 10
# Jamendo's search is flaky: it returns zero downloadable tracks for tags that work
# on the next call. Retry before treating an empty result as the real answer.
#: Retries for a single transient GET against Jamendo (DNS blip, 5xx, timeout).
#: Separate from _SEARCH_ATTEMPTS, which retries a search that SUCCEEDED and
#: came back empty. The two are different failures and are counted separately.
_HTTP_ATTEMPTS = 3
_HTTP_RETRY_DELAY = 1.0

_SEARCH_ATTEMPTS = 3
_SEARCH_RETRY_DELAY = 1.0  # seconds between attempts


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

    # Jamendo intermittently answers with zero downloadable tracks for tags that
    # work on the very next call, so a single empty search is not a real answer.
    # This flake is what left a Tuesday reel with no music at all.
    tracks: list[dict[str, Any]] = []
    for attempt in range(_SEARCH_ATTEMPTS):
        tracks = _search_tracks(tags, client_id)
        if tracks:
            break
        if attempt < _SEARCH_ATTEMPTS - 1:
            time.sleep(_SEARCH_RETRY_DELAY)

    if not tracks:
        raise RuntimeError(
            f"No downloadable Jamendo tracks found for tags={tags!r} after "
            f"{_SEARCH_ATTEMPTS} attempts. "
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


class JamendoUnavailable(RuntimeError):
    """Jamendo could not be reached or answered with an error.

    A RuntimeError so every caller already handling the documented
    "no tracks found" contract keeps working, but a distinct type because the
    two are different problems: one is retryable and says nothing about the
    tags, the other means the search genuinely matched nothing (#93).
    """


def _jamendo_json(url: str, *, what: str) -> dict[str, Any]:
    """GET a Jamendo endpoint and parse the JSON, retrying a transient blip.

    One implementation for both search paths. They previously carried the
    identical call with different error handling, so a DNS failure on the tag
    path escaped as a bare URLError and killed a whole reel render with a
    traceback, while the same failure on the namesearch path was swallowed.
    """
    last: Exception | None = None
    for attempt in range(_HTTP_ATTEMPTS):
        try:
            with urllib.request.urlopen(url, timeout=15) as resp:
                data: dict[str, Any] = json.loads(resp.read().decode())
            return data
        except (urllib.error.URLError, TimeoutError, OSError,
                json.JSONDecodeError) as e:
            last = e
            if attempt < _HTTP_ATTEMPTS - 1:
                time.sleep(_HTTP_RETRY_DELAY)
    raise JamendoUnavailable(
        f"Could not reach the music service to {what} "
        f"({_HTTP_ATTEMPTS} attempts, last error: {last}). "
        "This is a network or Jamendo problem, not a problem with the tags. "
        "Check the connection and retry."
    ) from last


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
    data = _jamendo_json(url, what=f"search for {tags!r}")
    return [
        t
        for t in data.get("results", [])
        if t.get("audiodownload_allowed") and t.get("audiodownload")
    ]


# ─── Program-piece matching ────────────────────────────────────────────────

# Words that are too generic to count as title evidence on their own.
# E.g. "Sonata", "Symphony No. 5" — every classical piece has these.
# Also: header/admin lines that occasionally show up as "pieces" after OCR
# ("Welcome", "Introduction", etc.). Those have no composer and shouldn't
# drive Jamendo searches.
_TITLE_STOPWORDS = frozenset({
    "the", "a", "an", "and", "or", "of", "in", "on", "for", "to",
    "no", "op", "opus", "k", "bwv", "kv",
    "sonata", "symphony", "concerto", "suite", "quartet", "quintet",
    "sextet", "trio", "duet", "nocturne", "etude", "prelude", "fugue",
    "fantasy", "variations", "rhapsody", "overture", "elegy", "ballade",
    "movement", "movements", "act", "scene", "song", "songs", "aria",
    "minor", "major", "sharp", "flat", "natural",
    "welcome", "introduction", "intro", "opening", "openings",
    "greeting", "greetings", "remarks", "announcement", "announcements",
    "interlude", "intermission", "encore", "closing", "finale",
    "preamble", "prologue", "epilogue", "presentation",
})

# Composer "names" that are really placeholders for unknown/missing data.
# Treat these as if the composer field were empty — never use them as a
# Jamendo search term or as a scoring signal, otherwise we match every
# track with the literal word "unknown" in its name.
_PLACEHOLDER_COMPOSERS = frozenset({
    "unknown", "anon", "anonymous", "n/a", "na", "none", "various",
    "traditional", "trad", "tbd", "tba",
})

# Anything below this score is "probably unrelated, skip it".
# Lower numbers = more matches but more false-positives. 2 means at minimum
# a composer-name-in-track-name OR composer-in-artist match — the user
# asked us to skew false-positive over false-negative, so 2 is on purpose.
_PROGRAM_MATCH_THRESHOLD = 2


def _last_name(name: str) -> str:
    """Best-effort last-name extraction. Empty string if the name's empty."""
    parts = name.strip().split()
    return parts[-1] if parts else ""


def _meaningful_title_words(title: str) -> list[str]:
    """Return lowercased title words worth using as relevance signals.
    Drops generic genre vocabulary and anything ≤3 chars."""
    cleaned = "".join(c if c.isalnum() or c.isspace() else " " for c in title.lower())
    return [
        w for w in cleaned.split()
        if len(w) >= 4 and w not in _TITLE_STOPWORDS
    ]


def _score_match(track: dict[str, Any], composer: str, title: str) -> int:
    """Score how well `track` matches a program piece. Higher = better."""
    name = (track.get("name") or "").lower()
    artist = (track.get("artist_name") or "").lower()
    composer_last = _last_name(composer).lower()
    if composer_last in _PLACEHOLDER_COMPOSERS:
        composer_last = ""

    score = 0
    # Composer's last name in the artist credit is the strongest signal:
    # tracks credited to "John Doe plays Shostakovich" or composer-named
    # ensembles are almost always relevant.
    if composer_last and len(composer_last) >= 4 and composer_last in artist:
        score += 3
    # Composer surname in the track title — also strong; many CC recordings
    # name pieces like "Beethoven Sonata No. 14".
    if composer_last and len(composer_last) >= 4 and composer_last in name:
        score += 2
    # Meaningful title-word overlap (capped — five "etude" matches don't
    # mean five times the relevance).
    title_matches = sum(1 for w in _meaningful_title_words(title) if w in name)
    score += min(title_matches, 3)
    return score


def _search_tracks_namesearch(query: str, client_id: str) -> list[dict[str, Any]]:
    """Full-text search across track + artist names. Different endpoint usage
    than `_search_tracks` (which filters by tag).

    Best effort: this runs once per candidate query across every program piece,
    so one unreachable query degrades to no match rather than failing the whole
    program search. It still REPORTS, because a total outage would otherwise be
    indistinguishable from "nothing in the program matched" (#93).
    """
    params = urllib.parse.urlencode(
        {
            "client_id": client_id,
            "namesearch": query,
            "audioformat": "mp31",
            "audiodownload_allowed": "true",
            "limit": str(_SEARCH_LIMIT),
            "format": "json",
        }
    )
    url = f"{JAMENDO_TRACKS_URL}?{params}"
    try:
        data = _jamendo_json(url, what=f"look up {query!r}")
    except JamendoUnavailable as e:
        print(f"warning: {e}", file=sys.stderr, flush=True)
        return []
    return [
        t for t in data.get("results", [])
        if t.get("audiodownload_allowed") and t.get("audiodownload")
    ]


def search_program_pieces(
    pieces: list[dict[str, Any]],
    client_id: str,
    *,
    exclude_ids: tuple[str, ...] = (),
    max_results: int = 10,
) -> list[tuple[dict[str, Any], int, str]]:
    """Search Jamendo for tracks that look like recordings of any program piece.

    Strategy: for each piece, try queries built from composer last name and
    title (most-specific to least). Score every result, keep candidates that
    clear the relevance threshold, dedupe by track id, and return them
    sorted by score descending.

    Returns a list of (track, score, source_label) tuples. The source_label
    is "<title> — <composer>" so callers can show "from program: …" badges.
    """
    if not pieces:
        return []

    seen_ids: set[str] = set(exclude_ids)
    scored: list[tuple[int, dict[str, Any], str]] = []

    for piece in pieces:
        composer = (piece.get("composer") or "").strip()
        title    = (piece.get("title")    or "").strip()
        if not composer and not title:
            continue

        last = _last_name(composer)
        if last.lower() in _PLACEHOLDER_COMPOSERS:
            last = ""
        title_words = _meaningful_title_words(title)
        first_title_word = title_words[0] if title_words else ""

        # If this "piece" has no real composer surname AND no meaningful
        # title words left after stopword filtering, there's nothing to
        # search on — skip it. Otherwise we'd send queries like "unknown"
        # or "welcome" to Jamendo and pull in unrelated junk that scores
        # only because the placeholder word literally appears in a track.
        if not last and not first_title_word:
            continue

        # Try the most-specific query first; stop early if we already have
        # plenty of candidates from this piece.
        queries: list[str] = []
        if last and first_title_word:
            queries.append(f"{last} {first_title_word}")
        if last:
            queries.append(last)
        if first_title_word and not last:
            queries.append(first_title_word)

        piece_label = " — ".join(p for p in [title, composer] if p)
        piece_results = 0

        for query in queries:
            for track in _search_tracks_namesearch(query, client_id):
                tid = str(track.get("id", ""))
                if not tid or tid in seen_ids:
                    continue
                score = _score_match(track, composer, title)
                if score < _PROGRAM_MATCH_THRESHOLD:
                    continue
                seen_ids.add(tid)
                scored.append((score, track, piece_label))
                piece_results += 1
                if piece_results >= 3:
                    break
            if piece_results >= 3:
                break

        if len(scored) >= max_results * 2:
            # Plenty to choose from — stop scanning more pieces
            break

    scored.sort(key=lambda x: -x[0])
    return [(t, s, label) for s, t, label in scored[:max_results]]


def fetch_program_audio_candidates(
    pieces: list[dict[str, Any]],
    *,
    count: int = 5,
    exclude_ids: tuple[str, ...] = (),
    cache_dir: Path | None = None,
    seed: int | None = None,
) -> list[dict[str, Any]]:
    """Like `fetch_audio_candidates` but searches by program content instead
    of tags. Returns at most `count` candidates, downloaded to the cache.
    Empty list if the program has no pieces or nothing scored above threshold.

    Each result dict carries a `source` key set to "program" plus a `match_label`
    so the UI can show "from program: <piece title>".
    """
    client_id = os.environ.get("JAMENDO_CLIENT_ID", "").strip()
    if not client_id:
        raise EnvironmentError(
            "JAMENDO_CLIENT_ID environment variable is not set. "
            "Get a free key at https://devportal.jamendo.com"
        )

    cache = Path(cache_dir) if cache_dir else DEFAULT_CACHE_DIR
    cache.mkdir(parents=True, exist_ok=True)

    matched = search_program_pieces(
        pieces, client_id, exclude_ids=exclude_ids, max_results=count * 2
    )
    if not matched:
        return []

    if seed is not None:
        # Light shuffle within the matched pool so re-rolling produces variety.
        rng = random.Random(seed)
        rng.shuffle(matched)

    results: list[dict[str, Any]] = []
    for track, score, label in matched:
        if len(results) >= count:
            break
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
            "tags": "program",
            "local_path": str(cached),
            "source": "program",
            "match_label": label,
            "match_score": score,
        })
    return results


def fetch_audio_by_program(
    pieces: list[dict[str, Any]],
    *,
    cache_dir: Path | None = None,
    seed: int | None = None,
) -> str | None:
    """Single-track convenience wrapper for the auto-fetch path. Returns the
    cached path of the highest-scoring match, or None if no match cleared the
    threshold (caller falls back to tag-based fetch)."""
    candidates = fetch_program_audio_candidates(
        pieces, count=1, cache_dir=cache_dir, seed=seed
    )
    return candidates[0]["local_path"] if candidates else None


def _download(url: str, dest: Path) -> None:
    # Stream to a temp name and rename into place atomically: a dropped
    # connection must never leave a truncated file at the cache path, where
    # every later run would treat it as a valid cached track and mux it into
    # reels. The pid suffix keeps parallel generations from colliding.
    tmp = dest.with_suffix(f".{os.getpid()}.part")
    try:
        with urllib.request.urlopen(url, timeout=60) as src, open(tmp, "wb") as dst:
            while chunk := src.read(65536):
                dst.write(chunk)
        os.replace(tmp, dest)
    finally:
        tmp.unlink(missing_ok=True)


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
