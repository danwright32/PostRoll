"""#962: the filename rules run on all three blog paths, not just generation.

`check_blog` skips both filename rules when it is handed no `photo_filenames`,
which is the right refusal: a caller with no list must not have every marker
reported as naming an unknown photo. But two of the three callers were that
caller, and neither had to be.

`swap_blog_photos` already resolves the real filenames a few lines above its
`check_blog` call and passed none of them, so the path that REWRITES EVERY
MARKER in the post was the one path that could not notice a marker naming a
file that does not exist.

`revise_blog` had no list at all, so a repair loop reached from a revision
could not see the two largest categories of finding. The manifest carries the
names now, and the revision path is defensive about them: it is told to
preserve markers verbatim, so a marker that changed under it is exactly what
these rules exist to catch.

Both also get the near-miss repair from `repair_marker_filenames`, because a
check that fires on a fixable fault and reports it instead is the whole
complaint in this issue.
"""

from __future__ import annotations

import json
from unittest.mock import patch

import pytest

from postroll.ai import revise_blog as rb
from postroll.ai import swap_blog_photos as swap


CURLY = "Cast Party “Live”-12.jpg"
STRAIGHT = 'Cast Party "Live"-12.jpg'

PROSE = "A paragraph of prose about the evening and the room."


def _body(*markers: str) -> str:
    parts = []
    for marker in markers:
        parts.append(PROSE)
        parts.append(marker)
    return "\n\n".join(parts)


# -- the photo swap -----------------------------------------------------------

@pytest.fixture
def sent_photo(tmp_path):
    p = tmp_path / "DSC4821.jpg"
    p.write_bytes(b"fake jpeg bytes")
    return p


def _swap(returned_body: str, photo):
    with patch.object(swap, "run_json_prompt",
                      side_effect=lambda *a, **k: {"body": returned_body,
                                                   "photo_count": 1}):
        return swap.swap_blog_photos(body=_body("[PHOTO: old.jpg | old alt]"),
                                     photo_paths=[photo])


def test_the_swap_reports_a_marker_naming_a_photo_it_never_sent(sent_photo):
    # The path most able to break the filename rule was the one that could not
    # see it: every marker in the post is rewritten here.
    result = _swap(_body("[PHOTO: NEVER_SENT.jpg | Alt text]"), sent_photo)

    codes = [f["code"] for f in result["findings"]]
    assert "blog_marker_unknown_photo" in codes
    assert "blog_marker_missing_photo" in codes


def test_the_swap_leaves_a_correctly_named_marker_alone(sent_photo):
    result = _swap(_body("[PHOTO: DSC4821.jpg | Alt text]"), sent_photo)

    codes = [f["code"] for f in result["findings"]]
    assert "blog_marker_unknown_photo" not in codes
    assert "blog_marker_missing_photo" not in codes


def test_the_swap_repairs_a_near_miss_rather_than_reporting_it(tmp_path):
    photo = tmp_path / CURLY
    photo.write_bytes(b"fake jpeg bytes")

    result = _swap(_body(f"[PHOTO: {STRAIGHT} | Alt text]"), photo)

    assert CURLY in result["body"]
    codes = [f["code"] for f in result["findings"]]
    assert "blog_marker_unknown_photo" not in codes
    assert "blog_marker_missing_photo" not in codes


# -- the revision ---------------------------------------------------------

def _revise(returned_body: str, existing_body: str | None = None, **kwargs):
    existing = existing_body or _body("[PHOTO: DSC4821.jpg | alt]")
    with patch.object(rb, "run_json_prompt",
                      side_effect=lambda *a, **k: {"title": "T",
                                                   "body": returned_body}), \
         patch.object(rb, "_fix_second_person", side_effect=lambda b: b), \
         patch.object(rb, "_fix_missing_contractions", side_effect=lambda b: b):
        return rb.revise_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []},
            existing={"title": "T", "body": existing},
            feedback="tighten it", skip_humanizer=True, skip_voice_pass=True,
            **kwargs)


def test_a_revision_given_the_photo_list_reports_a_marker_it_renamed():
    # The revision prompt orders markers preserved verbatim. A marker that
    # changed anyway is precisely the fault these rules exist to catch, and
    # until now the revision path could not see it.
    result = _revise(_body("[PHOTO: NEVER_SENT.jpg | Alt text]"),
                     photo_filenames=["DSC4821.jpg"])

    codes = [f["code"] for f in result["findings"]]
    assert "blog_marker_unknown_photo" in codes
    assert "blog_marker_missing_photo" in codes


def test_a_revision_repairs_a_near_miss_rather_than_reporting_it():
    result = _revise(_body(f"[PHOTO: {STRAIGHT} | Alt text]"),
                     existing_body=_body(f"[PHOTO: {CURLY} | alt]"),
                     photo_filenames=[CURLY])

    assert CURLY in result["body"]
    codes = [f["code"] for f in result["findings"]]
    assert "blog_marker_unknown_photo" not in codes
    assert "blog_marker_missing_photo" not in codes


def test_photos_the_post_never_chose_are_not_reported_as_missing():
    """The trap in handing a revision the event's whole photo list.

    `generate_blog` subsamples to seven when more are assigned, and Dan's
    DiGangi event holds twelve. So the event's list is the photos AVAILABLE to
    the post, not the photos IN it, and checking the revision against all
    twelve would report the five nobody chose as never placed: five new
    findings, on every revision, none of them a fault. That is the check
    crying wolf (L36), and it is exactly the trained-to-skim failure this
    issue exists to stop.

    Which photos the post holds is stated by the body being revised, which the
    revision is under orders to preserve, so it is read from there.
    """
    available = [f"DSC{n}.jpg" for n in range(4821, 4833)]
    used = available[:7]
    existing = _body(*[f"[PHOTO: {n} | alt for {n}]" for n in used])

    result = _revise(existing, existing_body=existing, photo_filenames=available)

    codes = [f["code"] for f in result["findings"]]
    assert "blog_marker_missing_photo" not in codes, (
        "the five photos the post never chose are not a fault")
    assert "blog_marker_unknown_photo" not in codes


def test_a_marker_the_revision_dropped_is_still_reported_as_missing():
    """The other side of the narrowing: it must not switch the rule off.

    A photo the post HELD and the revision lost is a photo Dan chose and will
    never see, which is the fault the rule exists for. A narrowing that read
    the revised body instead of the original would report nothing here, and
    would pass the test above for a reason that is not true (L159).
    """
    available = [f"DSC{n}.jpg" for n in range(4821, 4833)]
    used = available[:7]
    existing = _body(*[f"[PHOTO: {n} | alt for {n}]" for n in used])
    revised = _body(*[f"[PHOTO: {n} | alt for {n}]" for n in used[:6]])

    result = _revise(revised, existing_body=existing, photo_filenames=available)

    codes = [f["code"] for f in result["findings"]]
    assert "blog_marker_missing_photo" in codes


def test_a_revision_with_no_photo_list_still_skips_the_filename_rules():
    # The refusal `check_blog` documents stays intact. An older event whose
    # photo paths are gone must not have every marker reported as unknown.
    result = _revise(_body("[PHOTO: NEVER_SENT.jpg | Alt text]"))

    codes = [f["code"] for f in result["findings"]]
    assert "blog_marker_unknown_photo" not in codes
    assert "blog_marker_missing_photo" not in codes


# -- the key actually reaches the function ------------------------------------

def test_the_revision_cli_passes_the_manifests_photo_filenames(tmp_path, monkeypatch):
    # Built is not wired (L3). The manifest key is worth nothing unless
    # `main` reads it and hands it on.
    manifest = tmp_path / "m.json"
    manifest.write_text(json.dumps({
        "event": "E", "org": "O", "venue": "V", "date": "2026-04-05",
        "program": {"performers": []},
        "existing": {"title": "T", "body": _body("[PHOTO: a.jpg | alt]")},
        "feedback": "tighten it",
        "photo_filenames": ["DSC4821.jpg"],
    }), encoding="utf-8")
    out = tmp_path / "out.json"

    seen = {}

    def fake_revise(**kwargs):
        seen.update(kwargs)
        return {"title": "T", "body": "b", "photo_count": 0, "findings": []}

    monkeypatch.setattr(rb, "revise_blog", fake_revise)
    monkeypatch.setattr("sys.argv",
                        ["revise_blog", "--manifest", str(manifest),
                         "--output", str(out)])

    rb.main()

    assert seen.get("photo_filenames") == ["DSC4821.jpg"]


def test_the_revision_cli_copes_with_a_manifest_that_omits_the_key(tmp_path, monkeypatch):
    # An app that has not been rebuilt yet sends no such key, and a revision
    # must not crash on it: the filename rules simply stay off, which is the
    # behaviour that shipped before this.
    manifest = tmp_path / "m.json"
    manifest.write_text(json.dumps({
        "event": "E", "org": "O", "venue": "V", "date": "2026-04-05",
        "program": {"performers": []},
        "existing": {"title": "T", "body": _body("[PHOTO: a.jpg | alt]")},
        "feedback": "tighten it",
    }), encoding="utf-8")
    out = tmp_path / "out.json"

    seen = {}

    def fake_revise(**kwargs):
        seen.update(kwargs)
        return {"title": "T", "body": "b", "photo_count": 0, "findings": []}

    monkeypatch.setattr(rb, "revise_blog", fake_revise)
    monkeypatch.setattr("sys.argv",
                        ["revise_blog", "--manifest", str(manifest),
                         "--output", str(out)])

    rb.main()

    assert seen.get("photo_filenames") is None
