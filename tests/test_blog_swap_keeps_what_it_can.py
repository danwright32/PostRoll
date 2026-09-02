"""#1131: a photo swap re-describes only the photographs that changed.

`swap_blog_photos` sent EVERY photo and told the model to rewrite EVERY marker.
Its own docstring admitted it: "This path REWRITES every alt text in the post,
so it is the one most likely to break the alt text rules." Swap one photo of
seven and six good alt texts were regenerated and six photographs re-uploaded
for nothing, every one of them a fresh chance to break a rule Dan had already
fixed by hand.

Three defects that are live today, closed here:

  * the retained photographs are re-described at all;
  * the prompt says "Do NOT change any prose. Not one word" and NOTHING verified
    it: the call has no validator;
  * a marker moving to a different point in the post is invisible, because at
    the time the repo's only marker guard sorted. Since #1141 it compares the
    ordered (filename, alt text) pairs, but this path is guarded by the splice
    rather than by that validator.

The fallback is a COST regression, never a correctness one, and it is announced
because it is a failure of the app's own machinery rather than a finding about
the post.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from PIL import Image

from postroll.ai import swap_blog_photos as swap
from postroll.ai.blog_photo_stamps import photo_stamps


PROSE_1 = "It's a paragraph about the evening, and the room didn't empty early."
PROSE_2 = "The band stayed on after, and I didn't put the camera down."
# Fifteen to twenty five words, so check_blog reports nothing about them and a
# refusal in these tests can only come from what the test is about.
ALT_A = ("Alt one describing exactly what the first photograph shows on the "
         "small stage under a low warm light")
ALT_B = ("Alt two describing exactly what the second photograph shows at the "
         "back of the room beside the bar")
ALT_C = ("A new description of the third photograph, taken from the balcony "
         "with the whole stage in the frame")


@pytest.fixture
def photos(tmp_path):
    made = []
    for name in ("a.jpg", "b.jpg", "c.jpg"):
        path = tmp_path / name
        Image.new("RGB", (60, 40), (40, 60, 80)).save(path)
        made.append(str(path))
    return made


def _body(*markers: str) -> str:
    out = [PROSE_1]
    for marker in markers:
        out.append(marker)
        out.append(PROSE_2)
    return "\n\n".join(out)


INCOMING = _body(f"[PHOTO: a.jpg | {ALT_A}]", f"[PHOTO: b.jpg | {ALT_B}]")


def _swap(photos, returned_body, *, stamps, paths=None):
    captured = {}

    def fake(prompt, timeout=300, image_paths=None, image_labels=None, **kw):
        # Per call, not overwritten: a fallback makes a SECOND call, and a
        # single slot would report the fallback's photographs as the first
        # call's and hide the saving entirely.
        captured.setdefault("sent", []).append(list(image_labels or []))
        captured.setdefault("prompts", []).append(prompt)
        return {"body": returned_body, "photo_count": len(image_paths or [])}

    with patch.object(swap, "run_json_prompt", side_effect=fake):
        captured["result"] = swap.swap_blog_photos(
            body=INCOMING, photo_paths=paths if paths is not None else photos[:2],
            photo_stamps_in=stamps)
    captured["calls"] = len(captured.get("sent", []))
    captured["image_labels"] = captured["sent"][0] if captured.get("sent") else []
    return captured


def test_only_the_changed_photograph_is_sent(photos):
    """The saving. One of two photos replaced, one photograph uploaded."""
    stamps = photo_stamps(["a.jpg"], [photos[0]])
    got = _swap(photos, _body(f"[PHOTO: a.jpg | {ALT_A}]",
                              f"[PHOTO: c.jpg | {ALT_C}]"),
                stamps=stamps, paths=[photos[0], photos[2]])

    assert got["image_labels"] == ["c.jpg"], (
        f"the swap sent {got['image_labels']}; a photograph nobody touched was "
        "re-uploaded and re-described for nothing")


def test_the_retained_marker_comes_back_byte_identical(photos):
    stamps = photo_stamps(["a.jpg"], [photos[0]])
    got = _swap(photos,
                _body("[PHOTO: a.jpg | The model rewrote this one anyway]",
                      f"[PHOTO: c.jpg | {ALT_C}]"),
                stamps=stamps, paths=[photos[0], photos[2]])

    assert f"[PHOTO: a.jpg | {ALT_A}]" in got["result"]["body"]


def test_a_prose_paragraph_the_model_altered_is_refused(photos, capsys):
    """The prompt has said "Do NOT change any prose" since it was written and
    nothing has ever verified it. This is the check that does."""
    stamps = photo_stamps(["a.jpg"], [photos[0]])
    tampered = "\n\n".join([
        "A completely different opening paragraph the model invented.",
        f"[PHOTO: a.jpg | {ALT_A}]", PROSE_2,
        f"[PHOTO: c.jpg | {ALT_C}]", PROSE_2])

    _swap(photos, tampered, stamps=stamps, paths=[photos[0], photos[2]])

    printed = capsys.readouterr().err
    assert "REFUSED" in printed and "prose" in printed.lower(), printed


def test_prose_the_fallback_also_altered_is_reported_rather_than_shipped_silently(
        photos, capsys):
    """The fallback is today's behaviour and today's behaviour ships whatever
    comes back, so the gate does not REFUSE there: that would leave Dan with the
    photographs he asked to replace and no way forward (L109).

    It still says so. The whole-rewrite path has never had anything checking
    that its own "Do NOT change any prose" instruction was obeyed.
    """
    stamps = photo_stamps(["a.jpg"], [photos[0]])
    tampered = "\n\n".join([
        "A completely different opening paragraph the model invented.",
        f"[PHOTO: a.jpg | {ALT_A}]", PROSE_2,
        f"[PHOTO: c.jpg | {ALT_C}]", PROSE_2])

    _swap(photos, tampered, stamps=stamps, paths=[photos[0], photos[2]])

    printed = capsys.readouterr().err
    assert "the whole rewrite also" in printed and "prose" in printed.lower(), printed


def test_a_refused_swap_falls_back_and_says_why(photos, capsys):
    stamps = photo_stamps(["a.jpg"], [photos[0]])
    tampered = "\n\n".join([
        "A completely different opening paragraph the model invented.",
        f"[PHOTO: a.jpg | {ALT_A}]", PROSE_2,
        f"[PHOTO: c.jpg | {ALT_C}]", PROSE_2])

    got = _swap(photos, tampered, stamps=stamps, paths=[photos[0], photos[2]])

    assert got["calls"] == 2, (
        "the swap did not fall back to the whole rewrite, so a refused splice "
        "leaves the post without the photographs Dan asked for")
    printed = capsys.readouterr().err
    assert "fall" in printed.lower() or "fell back" in printed.lower(), printed


def test_a_swap_with_no_recorded_stamps_sends_everything(photos):
    """Every post written before #1130. A first run, not an error: it retains
    nothing and costs exactly what it costs today (L223)."""
    got = _swap(photos, _body(f"[PHOTO: a.jpg | {ALT_A}]", f"[PHOTO: b.jpg | {ALT_B}]"),
                stamps={})

    assert sorted(got["image_labels"]) == ["a.jpg", "b.jpg"]


def test_a_photograph_edited_since_the_post_was_written_is_sent_again(photos):
    stamps = photo_stamps(["a.jpg", "b.jpg"], photos[:2])
    Image.new("RGB", (200, 200), (1, 2, 3)).save(photos[0])

    got = _swap(photos, _body(f"[PHOTO: a.jpg | {ALT_A}]", f"[PHOTO: b.jpg | {ALT_B}]"),
                stamps=stamps)

    assert got["image_labels"] == ["a.jpg"], (
        "a re-exported photograph kept the alt text describing the picture "
        "that used to be there, which is the failure the stamp exists for")


def test_a_photograph_that_is_not_there_refuses_the_whole_run(photos):
    """On THIS path an unreadable photograph is a hard refusal, not a retention
    state: the staging loop requires every file before anything is sent.

    The three-way "retained / no stamp / could not read" distinction still
    matters, and it is tested where it can actually occur, in
    tests/test_blog_photo_stamps.py. Asserting it here would be asserting about
    a branch this path cannot reach (L159).
    """
    with pytest.raises(FileNotFoundError) as caught:
        swap.swap_blog_photos(body=INCOMING,
                              photo_paths=[photos[0], "/nowhere/b.jpg"])

    assert "b.jpg" in str(caught.value)


def test_nothing_changed_means_no_call_at_all(photos):
    """Idempotence. The app can and does re-run a swap, and a swap where every
    photograph is retained has nothing to ask a model."""
    stamps = photo_stamps(["a.jpg", "b.jpg"], photos[:2])

    def refuse(*a, **k):
        raise AssertionError("a paid call was made for a swap that changes nothing")

    with patch.object(swap, "run_json_prompt", side_effect=refuse):
        result = swap.swap_blog_photos(body=INCOMING, photo_paths=photos[:2],
                                       photo_stamps_in=stamps)

    assert result["body"] == INCOMING
