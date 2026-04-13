"""Tests for postroll.ai.import_meta_csv."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from postroll.ai.import_meta_csv import (
    _build_field_index,
    _extract_org,
    _normalize_media_type,
    _parse_date,
    _parse_hashtags,
    dedupe,
    parse_csv,
)

FIXTURES = Path(__file__).parent / "fixtures"


# ---------------------------------------------------------------------------
# Unit tests
# ---------------------------------------------------------------------------

class TestFieldIndex:
    def test_exact_match(self):
        idx = _build_field_index(["Post ID", "Permalink", "Publish time", "Description"])
        assert idx["ig_post_id"] == "Post ID"
        assert idx["ig_permalink"] == "Permalink"
        assert idx["published_at"] == "Publish time"
        assert idx["caption"] == "Description"

    def test_case_insensitive(self):
        idx = _build_field_index(["post id", "PERMALINK", "publish time"])
        assert idx["ig_post_id"] == "post id"

    def test_alias_fallback(self):
        # "Post text" is an alias for caption
        idx = _build_field_index(["Post ID", "Post text"])
        assert idx["caption"] == "Post text"

    def test_missing_field_absent(self):
        idx = _build_field_index(["Post ID"])
        assert "ig_permalink" not in idx


class TestParsers:
    def test_parse_date_standard(self):
        result = _parse_date("04/09/2026 11:02")
        assert result == "2026-04-09T11:02:00"

    def test_parse_date_empty(self):
        assert _parse_date("") is None

    def test_parse_hashtags(self):
        caption = "Photo from @kyhs_music at Carnegie Hall.\n\n#CarnegieHall #classicalmusic #dwphotony"
        tags = _parse_hashtags(caption)
        assert "#carngiehall" not in tags          # shouldn't be there
        assert "#carngiehall" not in tags
        assert "#carnegiehall" in tags
        assert "#classicalmusic" in tags
        assert "#dwphotony" in tags
        assert len(tags) == len(set(tags))         # no duplicates

    def test_parse_hashtags_emoji_unicode(self):
        caption = "Concert 🎹 #classiqué #música"
        tags = _parse_hashtags(caption)
        assert "#classiqu\u00e9" in tags
        assert "#m\u00fasica" in tags

    def test_extract_org_skips_own_handle(self):
        caption = "@dwphotony covering @kyhs_music at Carnegie Hall."
        org = _extract_org(caption)
        assert org == "kyhs_music"

    def test_extract_org_none_when_only_own(self):
        caption = "A personal post by @dwphotony."
        assert _extract_org(caption) is None

    def test_normalize_media_type(self):
        assert _normalize_media_type("IG reel") == "reel"
        assert _normalize_media_type("IG story") == "story"
        assert _normalize_media_type("IG image") == "image"
        assert _normalize_media_type("IG carousel") == "carousel"
        assert _normalize_media_type("IG photo") == "image"
        assert _normalize_media_type("Something weird") == "unknown"

    def test_normalize_media_type_case_insensitive(self):
        assert _normalize_media_type("ig REEL") == "reel"


class TestDedupe:
    def test_dedupes_by_post_id(self):
        posts = [
            {"ig_post_id": "A", "published_at": "2026-01-01T00:00:00", "likes": 5},
            {"ig_post_id": "A", "published_at": "2026-01-01T00:00:00", "likes": 10},  # duplicate
            {"ig_post_id": "B", "published_at": "2026-01-02T00:00:00", "likes": 3},
        ]
        result = dedupe(posts)
        assert len(result) == 2

    def test_sorts_newest_first(self):
        posts = [
            {"ig_post_id": "A", "published_at": "2026-01-01T00:00:00"},
            {"ig_post_id": "B", "published_at": "2026-03-01T00:00:00"},
            {"ig_post_id": "C", "published_at": "2026-02-01T00:00:00"},
        ]
        result = dedupe(posts)
        assert [p["ig_post_id"] for p in result] == ["B", "C", "A"]


# ---------------------------------------------------------------------------
# Integration tests (against fixture CSVs)
# ---------------------------------------------------------------------------

class TestParseFeedCSV:
    def test_loads_all_rows(self):
        posts, warnings = parse_csv(FIXTURES / "meta_feed_fixture.csv")
        assert len(posts) == 10

    def test_post_fields_populated(self):
        posts, _ = parse_csv(FIXTURES / "meta_feed_fixture.csv")
        p = posts[0]  # first row
        assert p["ig_post_id"] == "POST_FEED_001"
        assert "ig_permalink" in p
        assert p["media_type"] == "reel"
        assert "#carnegiehall" in p["hashtags"]
        assert "#dwphotony" in p["hashtags"]
        assert p["org"] == "kyhs_music"
        assert p["reach"] == 120
        assert p["likes"] == 12
        assert "comments" in p

    def test_multiline_caption_preserved(self):
        """Captions with embedded newlines must parse as a single row."""
        posts, _ = parse_csv(FIXTURES / "meta_feed_fixture.csv")
        # First post caption has a blank line before hashtags
        assert "\n" in posts[0]["caption"]

    def test_no_spurious_warnings_for_known_columns(self):
        _, warnings = parse_csv(FIXTURES / "meta_feed_fixture.csv")
        # There should be no warnings about missing critical columns
        critical_warnings = [w for w in warnings if "could not find column" in w]
        assert critical_warnings == []

    def test_personal_post_parsed(self):
        """Non-concert post should parse; is_personal starts as False (Claude classifies later)."""
        posts, _ = parse_csv(FIXTURES / "meta_feed_fixture.csv")
        dog_post = next(p for p in posts if "dog" in p["caption"].lower())
        assert dog_post["ig_post_id"] == "POST_FEED_007"
        assert dog_post["is_personal"] is False   # Claude classifies during analysis

    def test_org_not_own_handle(self):
        posts, _ = parse_csv(FIXTURES / "meta_feed_fixture.csv")
        for p in posts:
            assert p.get("org") != "dwphotony"


class TestParseStoryCSV:
    def test_loads_all_rows(self):
        posts, _ = parse_csv(FIXTURES / "meta_story_fixture.csv")
        assert len(posts) == 5

    def test_story_media_type(self):
        posts, _ = parse_csv(FIXTURES / "meta_story_fixture.csv")
        assert all(p["media_type"] == "story" for p in posts)

    def test_story_metrics(self):
        posts, _ = parse_csv(FIXTURES / "meta_story_fixture.csv")
        p = posts[0]
        assert p["reach"] == 22
        assert p["replies"] == 0
        assert p["navigation"] == 30
        # Feed-only metrics should be absent
        assert "comments" not in p
        assert "saves" not in p

    def test_empty_caption_story(self):
        posts, _ = parse_csv(FIXTURES / "meta_story_fixture.csv")
        empty = next(p for p in posts if p["ig_post_id"] == "STORY_003")
        assert empty["caption"] == ""
        assert empty["hashtags"] == []


# ---------------------------------------------------------------------------
# CLI smoke test
# ---------------------------------------------------------------------------

class TestCLI:
    def test_full_import_produces_valid_json(self, tmp_path):
        """Full CLI-style run through parse + dedupe + write."""
        import sys
        from unittest.mock import patch

        out_file = tmp_path / "result.json"
        test_args = [
            "import_meta_csv",
            "--csv", str(FIXTURES / "meta_feed_fixture.csv"),
            "--csv", str(FIXTURES / "meta_story_fixture.csv"),
            "--output", str(out_file),
        ]
        with patch.object(sys, "argv", test_args):
            from postroll.ai.import_meta_csv import main
            main()

        assert out_file.exists()
        data = json.loads(out_file.read_text())
        assert "posts" in data
        assert "warnings" in data
        assert len(data["posts"]) == 15  # 10 feed + 5 story, no dupes

    def test_mixed_media_types_in_output(self, tmp_path):
        out_file = tmp_path / "result.json"
        import sys
        from unittest.mock import patch

        with patch.object(sys, "argv", [
            "import_meta_csv",
            "--csv", str(FIXTURES / "meta_feed_fixture.csv"),
            "--output", str(out_file),
        ]):
            from postroll.ai.import_meta_csv import main
            main()

        data = json.loads(out_file.read_text())
        types = {p["media_type"] for p in data["posts"]}
        assert "reel" in types
        assert "image" in types
        assert "carousel" in types
