"""#477: the blog's filename rule is checked against the photos actually sent.

The prompt's hardest photo rule is a filename one: copy the name verbatim from
that image's own `Photo N:` label, never guess it, and use all N photos. It had
no boundary check. `markers_preserved_validator` only pins passes 2 and 3 to
whatever pass 1 produced, so a wrong name invented in pass 1 was preserved
faithfully all the way to the review screen, and `check_blog` checked marker
placement and alt text without ever looking at the filenames (L27).

Both halves matter downstream. A marker naming a file that was never sent
matches no photo when the app lines markers up against the real files, so that
photo silently does not appear; a photo with no marker is a photo Dan chose for
the post and never sees in it.

The prompt was also teaching the wrong shape. Its worked example showed
`003_DSC4821.jpg`, carrying the `000_` staging prefix that `photo_filenames`
deliberately strips from every label the model is shown, so the one concrete
example in the prompt contradicted the rule stated above it.
"""

from __future__ import annotations

from unittest.mock import patch

import pytest
from PIL import Image

from postroll.ai import generate_blog
from postroll.ai.blog_quality import check_blog
from postroll.ai.generate_blog import PROMPT_TEMPLATE


SENT = ["DSC4821.jpg", "DSC4822.jpg"]


def _body(*markers: str) -> str:
    parts = []
    for marker in markers:
        parts.append("A paragraph of prose about the evening and the room.")
        parts.append(marker)
    return "\n\n".join(parts)


def _codes(body, **kw):
    return [f.code for f in check_blog(body, photo_filenames=SENT, **kw)]


def test_a_marker_naming_a_file_that_was_never_sent_is_caught():
    body = _body("[PHOTO: DSC4821.jpg | Alt text one]",
                 "[PHOTO: DSC9999.jpg | Alt text two]")

    assert "blog_marker_unknown_photo" in _codes(body)


def test_the_unknown_filename_is_quoted_so_it_can_be_fixed():
    body = _body("[PHOTO: DSC9999.jpg | Alt text]")

    detail = next(f.detail for f in check_blog(body, photo_filenames=SENT)
                  if f.code == "blog_marker_unknown_photo")

    assert "DSC9999.jpg" in detail


def test_a_photo_that_was_sent_and_never_placed_is_caught():
    body = _body("[PHOTO: DSC4821.jpg | Alt text one]")

    codes = _codes(body)
    assert "blog_marker_missing_photo" in codes
    detail = next(f.detail for f in check_blog(body, photo_filenames=SENT)
                  if f.code == "blog_marker_missing_photo")
    assert "DSC4822.jpg" in detail


def test_a_draft_using_every_photo_exactly_once_is_clean():
    body = _body("[PHOTO: DSC4821.jpg | Alt text one]",
                 "[PHOTO: DSC4822.jpg | Alt text two]")

    codes = _codes(body)
    assert "blog_marker_unknown_photo" not in codes
    assert "blog_marker_missing_photo" not in codes


def test_the_staging_prefix_is_not_a_valid_filename():
    # `photo_filenames` strips the 000_ prefix from every label the model is
    # shown, so a marker carrying it names a file the app cannot match.
    body = _body("[PHOTO: 003_DSC4821.jpg | Alt text]",
                 "[PHOTO: DSC4822.jpg | Alt text two]")

    assert "blog_marker_unknown_photo" in _codes(body)


def test_filenames_are_compared_without_case():
    # A case difference is not a wrong photo on a case-insensitive filesystem,
    # and reporting it would be the check crying wolf (L36).
    body = _body("[PHOTO: dsc4821.JPG | Alt text one]",
                 "[PHOTO: DSC4822.jpg | Alt text two]")

    assert "blog_marker_unknown_photo" not in _codes(body)


def test_no_photo_list_means_no_filename_findings():
    # Callers that have no list (a revision checking an existing body) must
    # not have every marker reported as unknown.
    body = _body("[PHOTO: anything.jpg | Alt text]")

    codes = [f.code for f in check_blog(body)]
    assert "blog_marker_unknown_photo" not in codes
    assert "blog_marker_missing_photo" not in codes


def test_the_prompts_worked_example_uses_a_filename_without_the_staging_prefix():
    # The one concrete example in the prompt taught the shape the rule above
    # it forbids, which is the strongest instruction in there.
    assert "003_DSC4821.jpg" not in PROMPT_TEMPLATE
    assert "DSC4821.jpg" in PROMPT_TEMPLATE


@pytest.mark.parametrize("marker", [
    "[PHOTO: DSC4821.jpg|Alt text one]",
    "[PHOTO:  DSC4821.jpg  |  Alt text one  ]",
])
def test_spacing_around_the_filename_does_not_make_it_unknown(marker):
    body = _body(marker, "[PHOTO: DSC4822.jpg | Alt text two]")

    assert "blog_marker_unknown_photo" not in _codes(body)


# ── the check actually runs in the shipping pipeline ──────────────────────────

def test_generate_blog_reports_a_marker_naming_a_photo_it_never_sent(tmp_path):
    # Built and not wired is the failure mode this repo keeps meeting (L3):
    # the rules above are worth nothing unless `generate_blog` passes the real
    # filename list to the checker on the path a run takes.
    photo = tmp_path / "DSC0001.jpg"
    Image.new("RGB", (60, 40), (40, 60, 80)).save(photo)

    def fake_run_json(prompt, timeout=600, allowed_dirs=None, allowed_tools=None,
                      image_paths=None, image_labels=None, **kwargs):
        return {"body": "It's a paragraph.\n\n[PHOTO: NEVER_SENT.jpg | Alt text]",
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
    assert "blog_marker_unknown_photo" in codes
    assert "blog_marker_missing_photo" in codes
