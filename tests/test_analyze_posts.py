"""Tests for postroll.ai.analyze_posts (mocked Claude call)."""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

import pytest

from postroll.ai.analyze_posts import (
    _assign_ids,
    _compact_post,
    _engagement_rate,
    _finalize,
    _prep,
)

FIXTURES = Path(__file__).parent / "fixtures"


# ---------------------------------------------------------------------------
# Unit tests — deterministic prep
# ---------------------------------------------------------------------------

class TestEngagementRate:
    def test_feed_uses_likes_comments_saves(self):
        post = {"reach": 100, "likes": 10, "comments": 5, "saves": 2}
        assert _engagement_rate(post, is_story=False) == 0.17

    def test_story_uses_likes_replies_shares(self):
        post = {"reach": 100, "likes": 5, "replies": 2, "shares": 1}
        assert _engagement_rate(post, is_story=True) == 0.08

    def test_none_when_no_reach(self):
        post = {"likes": 10, "comments": 5}
        assert _engagement_rate(post, is_story=False) is None

    def test_none_when_reach_zero(self):
        post = {"reach": 0, "likes": 10}
        assert _engagement_rate(post, is_story=False) is None


class TestCompactPost:
    def _sample_post(self) -> dict:
        return {
            "ig_post_id":  "P001",
            "media_type":  "image",
            "published_at": "2026-04-09T11:00:00",
            "caption":     "From @dciny at Carnegie Hall. #CarnegieHall #classicalmusic #dwphotony",
            "hashtags":    ["#carnegiehall", "#classicalmusic", "#dwphotony"],
            "org":         "dciny",
            "reach":       200,
            "likes":       20,
            "comments":    3,
            "saves":       5,
        }

    def test_basic_fields(self):
        post = self._sample_post()
        result = _compact_post(post, {"dciny": "k10to50"}, {"#dwphotony"})
        assert result["media_type"] == "image"
        assert result["org_band"] == "k10to50"
        assert result["reach"] == 200
        assert result["eng_rate"] == pytest.approx(0.14)

    def test_global_tags_excluded_from_hashtag_list(self):
        post = self._sample_post()
        result = _compact_post(post, {}, {"#dwphotony"})
        assert "#dwphotony" not in result["hashtags"]
        assert "#carnegiehall" in result["hashtags"]

    def test_caption_truncated_at_300_chars(self):
        post = self._sample_post()
        post["caption"] = "x" * 500
        result = _compact_post(post, {}, set())
        assert len(result["caption"]) == 300

    def test_no_none_values_in_output(self):
        post = {"ig_post_id": "P001", "media_type": "reel", "caption": "", "hashtags": []}
        result = _compact_post(post, {}, set())
        assert None not in result.values()

    def test_story_navigation_metrics_reach_the_prompt(self):
        """The prompt asks for story navigation analysis; the summary must
        actually carry the story metrics or those findings are fabricated."""
        post = {
            "ig_post_id":   "S001",
            "media_type":   "story",
            "published_at": "2026-04-09T11:00:00",
            "caption":      "",
            "hashtags":     [],
            "reach":        150,
            "replies":      2,
            "shares":       1,
            "navigation":   40,
            "profile_visits": 3,
            "sticker_taps": 5,
        }
        result = _compact_post(post, {}, set())
        assert result["navigation"] == 40
        assert result["profile_visits"] == 3
        assert result["sticker_taps"] == 5
        assert result["replies"] == 2
        assert result["shares"] == 1

    def test_feed_posts_do_not_carry_story_metrics(self):
        post = self._sample_post()
        post["navigation"] = 40
        result = _compact_post(post, {}, set())
        assert "navigation" not in result

    def test_is_personal_flag_reaches_the_prompt(self):
        """The prompt excludes personal posts from craft analysis; the flag
        must be present in the summary when set."""
        post = self._sample_post()
        post["is_personal"] = True
        result = _compact_post(post, {}, set())
        assert result["is_personal"] is True
        # And omitted entirely when false, to save tokens
        post["is_personal"] = False
        result = _compact_post(post, {}, set())
        assert "is_personal" not in result


class TestPrep:
    def _make_posts(self):
        return [
            {
                "ig_post_id": "F1", "media_type": "reel",
                "published_at": "2026-02-01T10:00:00",
                "caption": "Feed post", "hashtags": ["#foo"], "org": "dciny",
                "reach": 100, "likes": 10, "comments": 2, "saves": 1,
            },
            {
                "ig_post_id": "S1", "media_type": "story",
                "published_at": "2026-03-01T10:00:00",
                "caption": "Story post", "hashtags": [], "org": None,
                "reach": 30, "likes": 1, "replies": 0,
            },
        ]

    def test_splits_feed_and_stories(self):
        posts = self._make_posts()
        feed, stories, _, _ = _prep(posts, {}, set())
        assert len(feed) == 1
        assert len(stories) == 1

    def test_date_range(self):
        posts = self._make_posts()
        _, _, start, end = _prep(posts, {}, set())
        assert start == "2026-02-01"
        assert end == "2026-03-01"


# ---------------------------------------------------------------------------
# ID assignment
# ---------------------------------------------------------------------------

class TestAssignIds:
    def test_assigns_uuid_to_dict(self):
        obj = {"headline": "Test"}
        _assign_ids(obj)
        assert "id" in obj
        uuid.UUID(obj["id"])  # should not raise

    def test_does_not_overwrite_existing_id(self):
        existing_id = str(uuid.uuid4())
        obj = {"id": existing_id, "headline": "Test"}
        _assign_ids(obj)
        assert obj["id"] == existing_id

    def test_recurses_into_lists(self):
        obj = {"findings": [{"headline": "A"}, {"headline": "B"}]}
        _assign_ids(obj)
        assert "id" in obj["findings"][0]
        assert "id" in obj["findings"][1]


# ---------------------------------------------------------------------------
# Finalize
# ---------------------------------------------------------------------------

class TestFinalize:
    def _minimal_claude_output(self) -> dict:
        return {
            "summary": "Test summary.",
            "post_count": 15,
            "story_count": 5,
            "feed_count": 10,
            "feed_findings": {
                "caption_patterns":      [{"headline": "h1", "evidence": "e1", "confidence": "medium"}],
                "hashtag_patterns":      [],
                "content_type_patterns": [],
                "timing_patterns":       [],
            },
            "story_findings": {
                "caption_patterns": [], "hashtag_patterns": [],
                "content_type_patterns": [], "timing_patterns": [],
            },
            "brand_voice_suggestions": ["Use opening questions for mid-tier orgs."],
            "caveats": ["Small dataset — low confidence on hashtag patterns."],
        }

    def test_adds_report_metadata(self):
        result = _finalize(self._minimal_claude_output(), "2026-01-01", "2026-04-09")
        assert "id" in result
        uuid.UUID(result["id"])
        assert "generated_at" in result
        assert result["date_range_start"] == "2026-01-01"
        assert result["date_range_end"] == "2026-04-09"

    def test_findings_get_ids(self):
        result = _finalize(self._minimal_claude_output(), "", "")
        finding = result["feed_findings"]["caption_patterns"][0]
        assert "id" in finding
        uuid.UUID(finding["id"])

    def test_missing_findings_get_defaults(self):
        minimal = {"summary": "ok", "post_count": 5, "story_count": 0, "feed_count": 5,
                   "brand_voice_suggestions": [], "caveats": []}
        result = _finalize(minimal, "", "")
        assert result["feed_findings"]["caption_patterns"] == []
        assert result["story_findings"]["timing_patterns"] == []


# ---------------------------------------------------------------------------
# Integration smoke test — mocked Claude call
# ---------------------------------------------------------------------------

class TestAnalyzePostsCLI:
    def _make_manifest(self, tmp_path: Path) -> Path:
        from postroll.ai.import_meta_csv import parse_csv, dedupe
        feed_posts, _ = parse_csv(FIXTURES / "meta_feed_fixture.csv")
        story_posts, _ = parse_csv(FIXTURES / "meta_story_fixture.csv")
        all_posts = dedupe(feed_posts + story_posts)

        manifest = {
            "posts": all_posts,
            "org_bands": {"dciny": "k10to50", "kyhs_music": "k1to10"},
            "global_hashtags_to_exclude": ["#dwphotony"],
        }
        path = tmp_path / "manifest.json"
        path.write_text(json.dumps(manifest), encoding="utf-8")
        return path

    def _mock_claude_response(self) -> dict:
        """A minimal valid InsightReport shape (no UUIDs — Python assigns them)."""
        return {
            "summary": "Based on the 15 posts analyzed...",
            "post_count": 15,
            "story_count": 5,
            "feed_count": 10,
            "feed_findings": {
                "caption_patterns": [
                    {"headline": "Opening questions outperform statements",
                     "evidence": "5 posts with question openers averaged 0.14 eng_rate vs 0.08 for statements within k10to50 band.",
                     "confidence": "medium"},
                ],
                "hashtag_patterns": [],
                "content_type_patterns": [
                    {"headline": "Solo portraits outperform ensemble shots in k1to10 orgs",
                     "evidence": "3 solo vs 2 ensemble — small sample, confidence low.",
                     "confidence": "low"},
                ],
                "timing_patterns": [],
            },
            "story_findings": {
                "caption_patterns": [], "hashtag_patterns": [],
                "content_type_patterns": [], "timing_patterns": [],
            },
            "brand_voice_suggestions": [
                "For mid-tier orgs (10–50k), open with a question to drive engagement.",
                "Keep hashtags under 8 — more tags did not improve reach in this dataset.",
            ],
            "caveats": [
                "Dataset is small (10 feed posts). Treat all patterns as directional, not definitive.",
                "5 posts lack reach data — engagement rate unavailable for those.",
            ],
        }

    def test_cli_produces_valid_output(self, tmp_path):
        import sys
        from unittest.mock import patch as mock_patch

        manifest_path = self._make_manifest(tmp_path)
        out_file = tmp_path / "report.json"

        with mock_patch("postroll.ai.analyze_posts.run_json_prompt",
                        return_value=self._mock_claude_response()), \
             mock_patch("postroll.ai.analyze_posts.load_brand_voice",
                        return_value="# Brand voice\nBe concise and direct."), \
             mock_patch.object(sys, "argv", [
                 "analyze_posts",
                 "--manifest", str(manifest_path),
                 "--output",   str(out_file),
             ]):
            from postroll.ai.analyze_posts import main
            main()

        assert out_file.exists()
        report = json.loads(out_file.read_text())

        # Required fields
        assert "id" in report
        assert "generated_at" in report
        assert "date_range_start" in report
        assert "date_range_end" in report
        assert report["post_count"] == 15
        assert isinstance(report["brand_voice_suggestions"], list)
        assert len(report["brand_voice_suggestions"]) >= 1

        # All findings have IDs
        for finding in report["feed_findings"]["caption_patterns"]:
            uuid.UUID(finding["id"])  # should not raise

        # Confidence values are valid
        valid_confidence = {"low", "medium", "high"}
        for finding in report["feed_findings"]["caption_patterns"]:
            assert finding["confidence"] in valid_confidence

    def test_global_tags_excluded_from_analysis(self, tmp_path):
        """#dwphotony should be stripped from hashtag lists passed to Claude."""
        manifest_path = self._make_manifest(tmp_path)
        out_file = tmp_path / "report.json"
        captured_prompt = []

        def capture_prompt(prompt, **kwargs):
            captured_prompt.append(prompt)
            return self._mock_claude_response()

        import sys
        from unittest.mock import patch as mock_patch

        with mock_patch("postroll.ai.analyze_posts.run_json_prompt", side_effect=capture_prompt), \
             mock_patch("postroll.ai.analyze_posts.load_brand_voice", return_value=""), \
             mock_patch.object(sys, "argv", [
                 "analyze_posts",
                 "--manifest", str(manifest_path),
                 "--output",   str(out_file),
             ]):
            from postroll.ai.analyze_posts import main
            main()

        assert len(captured_prompt) == 1
        # The global exclusion tag should appear in the prompt's exclusion section
        assert "#dwphotony" in captured_prompt[0]


# ---------------------------------------------------------------------------
# How much of a report could not be controlled for audience size (#720)
# ---------------------------------------------------------------------------

class TestAudienceControl:
    """A report has to say how much of itself rests on comparisons it could not
    make fair.

    Posts whose credited account has no follower band are analysed as
    uncontrolled observations rather than compared within a tier. That is the
    right treatment, and #712 made the stored bands visible and correctable. The
    gap this closes is the output side: a finished report read exactly the same
    whether that applied to two posts or two hundred, so a thin report was
    indistinguishable from one where every comparison was controlled.

    Measured here rather than asked of Claude. A field whose only writer is a
    prompt, and whose absence is itself a legitimate value, cannot tell a model
    that ignored the instruction from one that judged the field inapplicable, so
    it stays dormant forever while every reader reports its honest default
    (L128). This is a count the code already holds.
    """

    def _post(self, **over) -> dict:
        base = {
            "media_type": "image",
            "published_at": "2026-04-09T11:00:00",
            "caption": "a caption",
            "hashtags": [],
            "reach": 100,
            "likes": 10,
        }
        base.update(over)
        return base

    def _measure(self, posts, bands):
        from postroll.ai.analyze_posts import audience_control
        feed, stories, _, _ = _prep(posts, bands, set())
        return audience_control(feed, stories)

    def test_a_post_whose_account_has_a_band_is_controlled(self):
        got = self._measure([self._post(org="dciny")], {"dciny": "k1to10"})
        assert got["uncontrolled_count"] == 0
        assert got["uncontrolled_orgs"] == []
        assert got["analyzed_count"] == 1

    def test_a_post_whose_account_has_no_band_is_counted_and_named(self):
        got = self._measure([self._post(org="newchoir")], {})
        assert got["uncontrolled_count"] == 1
        assert got["uncontrolled_orgs"] == ["newchoir"], (
            "the account is not named, so the count says a report is thin "
            "without saying what would fix it"
        )

    def test_an_account_is_named_once_however_many_posts_it_has(self):
        posts = [self._post(org="newchoir"), self._post(org="newchoir"),
                 self._post(org="newchoir")]
        got = self._measure(posts, {})
        assert got["uncontrolled_count"] == 3
        assert got["uncontrolled_orgs"] == ["newchoir"]

    def test_accounts_are_named_in_a_stable_order(self):
        # Otherwise the same report reads differently on each generation, and a
        # reader cannot tell a changed list from a reshuffled one.
        posts = [self._post(org="zeta"), self._post(org="alpha")]
        got = self._measure(posts, {})
        assert got["uncontrolled_orgs"] == ["alpha", "zeta"]

    def test_a_post_with_no_account_credited_counts_but_names_nobody(self):
        # A different cause with a different remedy: no band can be set for an
        # account that was never credited, so listing it as an account to go and
        # fix would send Dan somewhere that cannot help (L11, L111).
        got = self._measure([self._post()], {})
        assert got["uncontrolled_count"] == 1
        assert got["uncontrolled_orgs"] == []
        assert got["uncredited_count"] == 1

    def test_a_personal_post_is_neither_controlled_nor_uncontrolled(self):
        # Personal posts are excluded from craft analysis entirely, so counting
        # one as an observation the report could not control would inflate the
        # very number this exists to make honest.
        got = self._measure([self._post(is_personal=True)], {})
        assert got["uncontrolled_count"] == 0
        assert got["analyzed_count"] == 0

    def test_stories_are_counted_too(self):
        # The confounder rule applies to both tracks, and a report that counted
        # only feed posts would understate how much of itself is uncontrolled.
        got = self._measure(
            [self._post(media_type="story", org="newchoir")], {})
        assert got["uncontrolled_count"] == 1
        assert got["analyzed_count"] == 1

    def test_an_empty_band_string_is_not_a_band(self):
        # A stored band of "" would otherwise read as tagged, and the post would
        # be counted as controlled while Claude, reading the same value, treats
        # it as unknown.
        got = self._measure([self._post(org="newchoir")], {"newchoir": ""})
        assert got["uncontrolled_count"] == 1
        assert got["uncontrolled_orgs"] == ["newchoir"]

    def test_the_measurement_reaches_the_finished_report(self):
        # Built is not wired (L3). The count existing and no report carrying it
        # is the same as not having it.
        feed, stories, start, end = _prep(
            [self._post(org="newchoir"), self._post(org="dciny")],
            {"dciny": "k1to10"}, set())
        from postroll.ai.analyze_posts import audience_control
        report = _finalize({"summary": "ok"}, start, end,
                           control=audience_control(feed, stories))
        assert report["uncontrolled_count"] == 1
        assert report["uncontrolled_orgs"] == ["newchoir"]
        assert report["analyzed_count"] == 2

    def test_a_report_finalized_without_a_measurement_says_nothing_rather_than_zero(self):
        # Zero and "nobody measured" are different facts, and a zero nothing
        # produced is indistinguishable from a report where every comparison was
        # controlled (L90). The optional argument exists for the tests and the
        # older stored reports that predate this.
        report = _finalize({"summary": "ok"}, "2026-01-01", "2026-01-02")
        assert report["uncontrolled_count"] is None
        assert report["analyzed_count"] is None
