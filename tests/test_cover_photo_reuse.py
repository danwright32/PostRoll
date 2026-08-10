"""#144: a cover does not repeat a photo already showing elsewhere in the week.

Thursday's and Friday's covers were picked with no idea what the rest of the
grid was doing, so a week could put the same frame in two cells of the
Instagram profile grid, or make a cover out of the photo Tuesday's before/after
had already made its hero.

Filtered out of the candidate list rather than asked for in the prompt: a rule
that lives only in a prompt is a hope, and this one is checkable in code (L27).

The fallback matters as much as the rule. If excluding leaves nothing, the day
takes its pick from the full list anyway, because a repeated cover is a much
smaller problem than a day with no cover at all. That is a choice of which
defect to ship, so it says so out loud when it fires rather than happening
quietly (L93).
"""

from __future__ import annotations

from unittest.mock import patch

import pytest

from postroll.ai.select_cover_photo import select_cover_photo


def _candidates(*names: str) -> list[dict]:
    return [{"path": f"/photos/{n}"} for n in names]


def _pick_first(data_prompt=None, **kw):
    return {"index": 0, "rationale": "first"}


def test_a_photo_used_elsewhere_is_not_offered(tmp_path):
    seen: list[list[str]] = []

    def spy(prompt, **kw):
        seen.append([Path(p).name for p in kw["image_labels"]])
        return {"index": 0, "rationale": "r"}

    from pathlib import Path
    for name in ("a.jpg", "b.jpg", "c.jpg"):
        (tmp_path / name).write_bytes(b"x")

    cands = [{"path": str(tmp_path / n)} for n in ("a.jpg", "b.jpg", "c.jpg")]

    with patch("postroll.ai.select_cover_photo.run_json_prompt", side_effect=spy):
        pick = select_cover_photo(cands, exclude_paths=[str(tmp_path / "a.jpg")])

    assert pick["path"] != str(tmp_path / "a.jpg")
    assert seen and all("a.jpg" not in label for label in seen[0]), seen


def test_excluding_nothing_leaves_the_list_alone(tmp_path):
    for name in ("a.jpg", "b.jpg"):
        (tmp_path / name).write_bytes(b"x")
    cands = [{"path": str(tmp_path / n)} for n in ("a.jpg", "b.jpg")]

    with patch("postroll.ai.select_cover_photo.run_json_prompt",
               return_value={"index": 0, "rationale": "r"}):
        pick = select_cover_photo(cands, exclude_paths=[])

    assert pick["path"] == str(tmp_path / "a.jpg")


def test_one_candidate_left_after_excluding_is_taken_without_a_claude_call(tmp_path):
    # The single-candidate shortcut already existed; excluding must reach it
    # rather than paying for a call to choose from a list of one.
    for name in ("a.jpg", "b.jpg"):
        (tmp_path / name).write_bytes(b"x")
    cands = [{"path": str(tmp_path / n)} for n in ("a.jpg", "b.jpg")]

    with patch("postroll.ai.select_cover_photo.run_json_prompt") as call:
        pick = select_cover_photo(cands, exclude_paths=[str(tmp_path / "a.jpg")])

    call.assert_not_called()
    assert pick["path"] == str(tmp_path / "b.jpg")


def test_excluding_everything_falls_back_rather_than_leaving_no_cover(tmp_path, capsys):
    for name in ("a.jpg", "b.jpg"):
        (tmp_path / name).write_bytes(b"x")
    cands = [{"path": str(tmp_path / n)} for n in ("a.jpg", "b.jpg")]

    with patch("postroll.ai.select_cover_photo.run_json_prompt",
               return_value={"index": 0, "rationale": "r"}):
        pick = select_cover_photo(cands, exclude_paths=[c["path"] for c in cands])

    assert pick["path"] in {c["path"] for c in cands}, "the day must still get a cover"
    note = capsys.readouterr().err
    assert "already used" in note.lower(), (
        "the fallback ships a repeated cover, so it has to say so: a guard that "
        f"quietly chooses a different defect is worse than none. Got: {note!r}")


def test_an_excluded_path_that_is_not_a_candidate_changes_nothing(tmp_path):
    for name in ("a.jpg",):
        (tmp_path / name).write_bytes(b"x")
    cands = [{"path": str(tmp_path / "a.jpg")}]

    pick = select_cover_photo(cands, exclude_paths=["/somewhere/else.jpg"])

    assert pick["path"] == str(tmp_path / "a.jpg")


def test_paths_are_compared_after_normalising(tmp_path):
    # The used-elsewhere set and the candidate list come from different places
    # in the manifest, so one may carry a redundant ./ or a trailing slash.
    (tmp_path / "a.jpg").write_bytes(b"x")
    (tmp_path / "b.jpg").write_bytes(b"x")
    cands = [{"path": str(tmp_path / "a.jpg")}, {"path": str(tmp_path / "b.jpg")}]

    pick = select_cover_photo(
        cands, exclude_paths=[str(tmp_path) + "/./a.jpg"])

    assert pick["path"] == str(tmp_path / "b.jpg")


# ── wired into the run ────────────────────────────────────────────────────────

def test_the_media_run_keeps_fridays_cover_off_thursdays_photo(tmp_path):
    """A picker nothing passes the used set to is the same as no picker."""
    from PIL import Image

    from postroll.ai import generate_media as gm

    shared = tmp_path / "shared.jpg"
    Image.new("RGB", (300, 200), (10, 20, 30)).save(shared)
    other = tmp_path / "other.jpg"
    Image.new("RGB", (300, 200), (90, 20, 30)).save(other)

    excluded_seen: list[list[str]] = []

    def spy_pick(candidates, **kw):
        excluded_seen.append(list(kw.get("exclude_paths") or []))
        return {"index": 0, "path": candidates[0]["path"], "rationale": "r"}

    manifest = {
        "event": "E", "org": "O", "venue": "V", "date": "2026-04-05",
        "days": {
            "thursday": {"photos": [str(shared), str(other)]},
            "friday": {"raw_photo": str(shared), "edited_photo": str(other)},
        },
    }
    with patch("postroll.ai.generate_media.select_cover_photo", side_effect=spy_pick):
        gm.generate_media(manifest, tmp_path / "out", static_only=True)

    assert excluded_seen, "no cover pick was attempted, so this proves nothing"
    assert any(paths for paths in excluded_seen), (
        "every cover pick was told nothing about the rest of the week")
