"""#228: one unreadable concert photo must not cost the whole day.

#215 made a failed image resize refuse the call rather than upload the
full-size original, because the service-side downscale is what corrupts
performer names in program text (#200). That reasoning is right for program
pages, where character fidelity is the entire point of the call.

It reached ordinary concert photos as a side effect, and there the trade runs
the other way: one file that cannot be opened fails that day's caption and alt
text completely, where before it produced very slightly worse output from the
photos that were fine.

The decision is made BEFORE the prompt is written, not inside the transport.
The prompt states how many photos this post has and lists them by filename, so
a photo dropped later would leave the model reading about a photograph that
never arrived, which is the exact setup for invented alt text. Preflighting
means the prompt, the attached images and the returned alt text all describe
the same set.

The refusal itself is unchanged for everyone who does not preflight, which is
what keeps OCR and program pages strict.
"""

from __future__ import annotations

import pytest

from postroll.ai.claude_client import ClaudeError, partition_uploadable


@pytest.fixture
def photos(tmp_path):
    """Two real JPEGs and one file that is not a decodable image."""
    from PIL import Image

    good = []
    for n in ("a", "b"):
        p = tmp_path / f"{n}.jpg"
        # Over the long-edge budget, so the resize path actually runs and the
        # readable ones are proved readable by the same operation that will
        # run at send time, not by a cheaper stand-in for it.
        Image.new("RGB", (4200, 3000), (40, 60, 80)).save(p)
        good.append(p)

    bad = tmp_path / "truncated.jpg"
    bad.write_bytes(b"\xff\xd8\xff\xe0 this is not a decodable jpeg")
    return good, bad


# ── what survives ─────────────────────────────────────────────────────────────

def test_the_readable_photos_are_kept_in_order(photos):
    good, bad = photos

    kept, skipped = partition_uploadable([good[0], bad, good[1]], model="sonnet")

    assert kept == [0, 2], "kept photos are reported by position, in order"


def test_the_unreadable_photo_is_named_so_dan_learns_which_one(photos):
    # "A photo was skipped" is not actionable. The point of carrying on is that
    # he can go and look at the file that failed.
    good, bad = photos

    _, skipped = partition_uploadable([good[0], bad], model="sonnet")

    assert len(skipped) == 1
    assert skipped[0].index == 1
    assert skipped[0].name == "truncated.jpg"
    assert skipped[0].reason, "a skip with no reason cannot be diagnosed"


def test_nothing_is_reported_when_every_photo_is_readable(photos):
    # Guards against a preflight that reports on the happy path, which would
    # put a warning on every ordinary day and train Dan to ignore it.
    good, _ = photos

    kept, skipped = partition_uploadable(list(good), model="sonnet")

    assert kept == [0, 1]
    assert skipped == []


def test_every_photo_unreadable_refuses_rather_than_generating_from_none(photos):
    # A day whose photos all failed has nothing to write a caption from, and a
    # caption generated from zero photographs is pure fabrication. Carrying on
    # only makes sense while something survived.
    _, bad = photos

    with pytest.raises(ClaudeError) as e:
        partition_uploadable([bad], model="sonnet")

    assert "truncated.jpg" in str(e.value)


def test_an_empty_list_is_left_alone(photos):
    # Callers with no photos at all are a different case, handled by their own
    # guard; the preflight must not turn "nothing to do" into a failure.
    kept, skipped = partition_uploadable([], model="sonnet")

    assert kept == []
    assert skipped == []


# ── the strict path is untouched ──────────────────────────────────────────────

def test_the_transport_still_refuses_an_unreadable_image_outright(photos):
    # OCR and program pages do not preflight. They must keep failing loudly: a
    # page silently dropped is a cast list read from fewer pages than the
    # programme has.
    from postroll.ai import transport as tp

    good, bad = photos
    req = tp.Request(prompt="hi", model="sonnet", step="test",
                     image_paths=(good[0], bad))

    with pytest.raises(ClaudeError) as e:
        tp.build_content(req)

    assert "truncated.jpg" in str(e.value)


def test_a_preflighted_set_passes_the_intact_guard(photos):
    # The guard counts blocks against paths on every call. Handing it the
    # survivors must satisfy it, or the whole opt-in path would refuse anyway
    # and the feature would be unreachable.
    from postroll.ai import transport as tp

    good, bad = photos
    kept, _ = partition_uploadable([good[0], bad, good[1]], model="sonnet")
    survivors = [[good[0], bad, good[1]][i] for i in kept]

    content = tp.build_content(tp.Request(
        prompt="hi", model="sonnet", step="test", image_paths=tuple(survivors)))

    tp.assert_images_intact(content, expected=len(survivors), transport="sdk")


# ── the caption pipeline actually uses it ─────────────────────────────────────

def test_the_caption_run_drops_the_bad_photo_and_says_so(photos, monkeypatch):
    # Built is not wired: the preflight above is worth nothing unless the
    # caption path calls it and reports what it dropped.
    from unittest.mock import patch

    from postroll.ai import generate_captions

    good, bad = photos
    captured: dict = {}

    def fake_run_json(prompt, **kw):
        captured["prompt"] = prompt
        captured["image_paths"] = kw.get("image_paths")
        return {
            "caption": "A caption.",
            "hashtags": ["#dwphotony"],
            "alt_texts": ["first photo alt", "third photo alt"],
            "scene_labels": ["Scene A", "Scene C"],
        }

    with patch("postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json):
        result = generate_captions.generate_caption(
            event="E", org="O", venue="V", date="2026-04-05", day="wednesday",
            photo_paths=[good[0], bad, good[1]],
            program={"performers": [], "pieces": []},
            post_type="carousel",
            skip_humanizer=True, skip_voice_pass=True,
        )

    assert len(captured["image_paths"]) == 2, "only the readable photos are sent"
    assert result["skipped_photos"] == [
        {"file": "truncated.jpg", "reason": result["skipped_photos"][0]["reason"]}
    ]
    assert "truncated.jpg" in result["skipped_photos"][0]["reason"]


def test_alt_text_stays_with_its_own_photo_after_a_skip(photos):
    # The failure this guards against: photo 3's alt text sliding onto photo 2
    # because the model returned two entries for three photos. That reads as a
    # correct caption set and describes the wrong photograph.
    from unittest.mock import patch

    from postroll.ai import generate_captions

    good, bad = photos

    def fake_run_json(prompt, **kw):
        return {
            "caption": "A caption.",
            "hashtags": [],
            "alt_texts": ["first photo alt", "third photo alt"],
            "scene_labels": ["Scene A", "Scene C"],
        }

    with patch("postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json):
        result = generate_captions.generate_caption(
            event="E", org="O", venue="V", date="2026-04-05", day="wednesday",
            photo_paths=[good[0], bad, good[1]],
            program={"performers": [], "pieces": []},
            post_type="carousel",
            skip_humanizer=True, skip_voice_pass=True,
        )

    assert result["alt_texts"] == ["first photo alt", "", "third photo alt"]
    assert result["scene_labels"] == ["Scene A", "", "Scene C"]


def test_an_ordinary_day_reports_no_skips(photos):
    from unittest.mock import patch

    from postroll.ai import generate_captions

    good, _ = photos

    def fake_run_json(prompt, **kw):
        return {
            "caption": "A caption.",
            "hashtags": [],
            "alt_texts": ["one", "two"],
            "scene_labels": ["A", "B"],
        }

    with patch("postroll.ai.generate_captions.run_json_prompt", side_effect=fake_run_json):
        result = generate_captions.generate_caption(
            event="E", org="O", venue="V", date="2026-04-05", day="wednesday",
            photo_paths=list(good),
            program={"performers": [], "pieces": []},
            post_type="carousel",
            skip_humanizer=True, skip_voice_pass=True,
        )

    assert result["skipped_photos"] == []
    assert result["alt_texts"] == ["one", "two"]
