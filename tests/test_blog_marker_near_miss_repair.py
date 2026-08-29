"""#962: a marker whose filename is a near miss of a real one is corrected.

Measured on Dan's own post. The photographs are named

    DiGangi With A “G” (The Green Room 42) @dwphotony-141.jpg

with typographic quotes, and every one of the seven markers the model wrote
named

    DiGangi With A "G" (The Green Room 42) @dwphotony-141.jpg

with ASCII ones. `_marker_filename_findings` compares casefolded, which cannot
see that, so all seven markers were reported as naming a file that was never
sent AND all seven photos as never placed: fourteen of the twenty three checks
Dan was handed, from one punctuation difference, rendered in the panel as the
same seven filenames listed twice.

Nothing here needs a model. The real spelling is in hand, the marker names the
same file, and correcting it is the same shape as `_fix_wrong_names`.

The refusals matter as much as the repairs. A name that is not a near miss of
anything sent was genuinely invented and must still be reported, because
snapping it to the closest file would attach the wrong photograph to prose
written about a different one. And a fold that matches TWO sent files names a
family rather than a member (L521), so it repairs neither.
"""

from __future__ import annotations

import unicodedata
from unittest.mock import patch

from PIL import Image

from postroll.ai import generate_blog
from postroll.ai.blog_quality import check_blog, repair_marker_filenames


CURLY = "DiGangi With A “G” (The Green Room 42) @dwphotony-141.jpg"
STRAIGHT = 'DiGangi With A "G" (The Green Room 42) @dwphotony-141.jpg'


def _body(*markers: str) -> str:
    parts = []
    for marker in markers:
        parts.append("A paragraph of prose about the evening and the room.")
        parts.append(marker)
    return "\n\n".join(parts)


# -- the measured defect ------------------------------------------------------

def test_a_marker_differing_only_in_its_quote_characters_is_repaired():
    body = _body(f"[PHOTO: {STRAIGHT} | Alt text for the opening number.]")

    repaired, corrections = repair_marker_filenames(body, [CURLY])

    assert CURLY in repaired, "the marker must name the file that was sent"
    assert STRAIGHT not in repaired
    assert corrections == [(STRAIGHT, CURLY)]


def test_the_repaired_body_reports_neither_filename_finding():
    # The whole point: the fourteen findings have to actually go away.
    body = _body(f"[PHOTO: {STRAIGHT} | Alt text for the opening number.]")

    repaired, _ = repair_marker_filenames(body, [CURLY])

    codes = [f.code for f in check_blog(repaired, photo_filenames=[CURLY])]
    assert "blog_marker_unknown_photo" not in codes
    assert "blog_marker_missing_photo" not in codes


def test_the_unrepaired_body_reports_both_so_the_test_above_measures_something():
    body = _body(f"[PHOTO: {STRAIGHT} | Alt text for the opening number.]")

    codes = [f.code for f in check_blog(body, photo_filenames=[CURLY])]
    assert "blog_marker_unknown_photo" in codes
    assert "blog_marker_missing_photo" in codes


# -- what it must refuse to repair --------------------------------------------

def test_a_filename_that_is_not_a_near_miss_of_anything_is_left_alone():
    body = _body("[PHOTO: DSC9999.jpg | Alt text for a photo nobody sent.]")

    repaired, corrections = repair_marker_filenames(body, ["DSC4821.jpg"])

    assert repaired == body
    assert corrections == []
    codes = [f.code for f in check_blog(repaired, photo_filenames=["DSC4821.jpg"])]
    assert "blog_marker_unknown_photo" in codes


def test_two_sent_files_that_fold_to_one_key_repair_neither():
    # An ASCII hyphen and a non-breaking one fold to the same key.
    # Picking either is a coin toss that attaches the wrong photograph, so the
    # marker stays as it is and the check goes on reporting it. The dashes are
    # written as escapes because the style gate refuses the literal characters.
    sent = ["a-1.jpg", "a\u20111.jpg"]
    body = _body("[PHOTO: A\u20131.JPG | Alt text for an ambiguous name.]")

    repaired, corrections = repair_marker_filenames(body, sent)

    assert repaired == body
    assert corrections == []


def test_a_body_with_nothing_to_repair_reports_no_corrections():
    # A pass that had nothing to fix and a pass that fixed nothing must read
    # differently (L98). The empty list is how the caller tells them apart from
    # a pass that returned corrections.
    body = _body("[PHOTO: DSC4821.jpg | Alt text for the opening number.]")

    repaired, corrections = repair_marker_filenames(body, ["DSC4821.jpg"])

    assert repaired == body
    assert corrections == []


def test_no_photo_list_repairs_nothing():
    # Same refusal `check_blog` makes: with no list there is nothing to be a
    # near miss OF, and guessing is worse than leaving it.
    body = _body("[PHOTO: DSC9999.jpg | Alt text.]")

    repaired, corrections = repair_marker_filenames(body, None)

    assert repaired == body
    assert corrections == []


# -- what it must not disturb -------------------------------------------------

def test_only_the_filename_changes_and_the_alt_text_is_untouched():
    alt = "Ryan at the piano at The Green Room 42, hands raised above the keys."
    body = _body(f"[PHOTO: {STRAIGHT} | {alt}]")

    repaired, _ = repair_marker_filenames(body, [CURLY])

    assert f"| {alt}]" in repaired


def test_prose_that_happens_to_quote_the_wrong_name_is_not_rewritten():
    # The repair is addressed to markers, not to the body's text. A whole-body
    # replace would rewrite the prose too (#109 is the same lesson).
    prose = f"I kept coming back to {STRAIGHT} while editing."
    body = f"{prose}\n\n[PHOTO: {STRAIGHT} | Alt text for the opening number.]"

    repaired, _ = repair_marker_filenames(body, [CURLY])

    assert repaired.split("\n\n")[0] == prose


def test_a_decomposed_accent_in_the_real_filename_is_repaired():
    # macOS writes filenames decomposed, so a file on disk is "Café.jpg"
    # while the model writes the composed "Café.jpg". Same file, and the
    # panel shows the two as identical.
    plain = "Caf\u00e9 Carlyle-12.jpg"
    on_disk = unicodedata.normalize("NFD", plain)
    written = unicodedata.normalize("NFC", plain)
    assert on_disk != written, "the two spellings must differ"
    body = _body(f"[PHOTO: {written} | Alt text for the opening number.]")

    repaired, corrections = repair_marker_filenames(body, [on_disk])

    assert on_disk in repaired
    assert corrections == [(written, on_disk)]


# -- it runs on the path a real generation takes ------------------------------

def test_generate_blog_repairs_the_marker_before_it_checks(tmp_path):
    # Built is not wired (L3). The repair is worth nothing unless it sits
    # between the last rewriter and `check_blog` on the shipping path.
    photo = tmp_path / CURLY
    Image.new("RGB", (60, 40), (40, 60, 80)).save(photo)

    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None,
                      image_paths=None, image_labels=None, **kwargs):
        return {"body": f"It's a paragraph.\n\n[PHOTO: {STRAIGHT} | Alt text]",
                "photo_count": 1}

    def refuse(*args, **kwargs):
        raise AssertionError("a live prompt call; stub it rather than paying for it")

    with patch("postroll.ai.generate_blog.run_json_prompt", side_effect=fake_run_json), \
         patch("postroll.ai.generate_blog.run_prompt", side_effect=refuse):
        result = generate_blog.generate_blog(
            event="E", org="O", venue="V", date="2026-04-05",
            program={"performers": [], "pieces": []}, photo_paths=[str(photo)],
            skip_humanizer=True, skip_voice_pass=True)

    codes = [f["code"] for f in result["findings"]]
    assert "blog_marker_unknown_photo" not in codes
    assert "blog_marker_missing_photo" not in codes
    assert CURLY in result["body"]
