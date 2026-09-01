"""#1130 (Phase 2b): what decides a photograph is the SAME photograph.

Retaining an alt text is deciding to SKIP work, so the comparison behind it has
to change whenever the content changes (L40). This app's own `ThumbnailStore`
already states the rule: photos here are EDITED IN PLACE, a crop or a resize
rewrites the file and leaves the path alone, and both the modification date and
the size move when the bytes move, so both are in the key.

Nothing stored could answer that question. `BlogOutput` carried title, body,
photo_count, generated_body, findings and findings_body, and no photo paths, no
stat and no per-marker anchor. So the post records a stamp per placed
photograph, which does two jobs: it is the retention key, and it is the durable
record of WHICH seven of twelve photographs the post was written around,
replacing the evidence `blog_marker_missing_photo` was providing incidentally
(L277).

The three-state answer is the part that has to be got right. `blogPhotoPaths`
are percent-encoded `file://` URL strings, so a naive stat fails on every one of
them, answers every photograph as new, and the whole saving stops happening
while every test stays green (L289). "Retained", "new because nothing was
recorded" and "new because the file could not be read" are three different
things, and folding the last two together makes a broken decoder look exactly
like a first run.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from PIL import Image

from postroll.ai.blog_photo_stamps import (
    Retention, decode_photo_path, photo_stamps, retention_for)


@pytest.fixture
def photo(tmp_path):
    path = tmp_path / "DSC4821.jpg"
    Image.new("RGB", (60, 40), (40, 60, 80)).save(path)
    return path


# --- decoding ----------------------------------------------------------------

def test_a_percent_encoded_file_url_is_decoded_before_it_is_stat_ed(photo):
    """Measured on the stored events: every path is one of these.

    All 12 photo paths on the DiGangi event return False from os.path.exists on
    the raw string and True after decoding. A stat against the raw string fails
    silently, so every photograph is answered as new and the saving this whole
    phase exists for never happens once.
    """
    directory = photo.parent / "vocal colors"
    directory.mkdir()
    spaced = directory / "Vocal Colors (Lincoln Center)-115.jpg"
    Image.new("RGB", (60, 40), (1, 2, 3)).save(spaced)

    quoted = ("file://" + str(spaced).replace(" ", "%20")
              .replace("(", "%28").replace(")", "%29"))

    assert Path(quoted).exists() is False, "the fixture is not encoded at all"
    assert decode_photo_path(quoted) == str(spaced)
    assert Path(decode_photo_path(quoted)).exists()


def test_a_plain_path_is_left_alone(photo):
    assert decode_photo_path(str(photo)) == str(photo)


# --- stamping ----------------------------------------------------------------

def test_a_stamp_moves_when_the_bytes_move(photo, tmp_path):
    """The whole reason the size and the modification date are both in it.

    A photo edited in place keeps its path, so a key built from the path alone
    would keep the alt text describing the picture that used to be there.
    """
    before = photo_stamps(["a.jpg"], [str(photo)])
    Image.new("RGB", (120, 90), (200, 30, 30)).save(photo)
    after = photo_stamps(["a.jpg"], [str(photo)])

    assert before["a.jpg"] != after["a.jpg"], (
        "the stamp did not move when the photograph was re-exported in place, "
        "so a swap would keep alt text describing a different picture")


def test_a_stamp_is_keyed_on_the_folded_filename(tmp_path):
    """Folded the way markers fold, so a near miss resolves to its photograph."""
    curly = tmp_path / 'Cast “Live”.jpg'
    Image.new("RGB", (10, 10), (0, 0, 0)).save(curly)

    stamps = photo_stamps(['Cast “Live”.jpg'], [str(curly)])
    assert 'cast "live".jpg' in stamps


def test_a_file_that_cannot_be_read_is_left_out_of_the_stamps(tmp_path):
    # Absent is not "stamped as zero" (L215): a stamp nobody can verify would
    # answer every later comparison as retained.
    assert photo_stamps(["gone.jpg"], [str(tmp_path / "gone.jpg")]) == {}


# --- the three states --------------------------------------------------------

def test_an_unchanged_photograph_with_a_recorded_stamp_is_retained(photo):
    stamps = photo_stamps(["a.jpg"], [str(photo)])

    assert retention_for("a.jpg", str(photo), stamps) is Retention.RETAINED


def test_a_photograph_with_no_recorded_stamp_is_new(photo):
    """Every post written before this shipped. Named, not assumed away (L223)."""
    assert retention_for("a.jpg", str(photo), {}) is Retention.NEW_NO_STAMP


def test_a_photograph_whose_file_cannot_be_read_says_so_rather_than_new(tmp_path):
    """The state that must never collapse into the one above it (L11, L289).

    A first run and a broken path decoder both answer "nothing is retained". If
    they share a name, the day the decoder breaks looks exactly like the day the
    feature shipped, and the saving stops with nothing reporting it.
    """
    stamps = {"a.jpg": [123, 456]}

    assert retention_for("a.jpg", str(tmp_path / "gone.jpg"),
                         stamps) is Retention.NEW_UNREADABLE


def test_a_photograph_edited_since_the_post_was_written_is_new(photo):
    stamps = photo_stamps(["a.jpg"], [str(photo)])
    Image.new("RGB", (120, 90), (200, 30, 30)).save(photo)

    assert retention_for("a.jpg", str(photo), stamps) is Retention.NEW_EDITED


def test_the_three_new_states_are_distinguishable_from_each_other():
    """Distinct causes, distinct answers, and none of them is a bare boolean."""
    assert len({Retention.NEW_NO_STAMP, Retention.NEW_UNREADABLE,
                Retention.NEW_EDITED, Retention.RETAINED}) == 4
    for state in Retention:
        assert state.reason, f"{state} has no wording, so nothing can report it"


def test_a_stored_stamp_survives_json_round_tripping(photo):
    """It travels through a payload, so it has to be plain JSON."""
    stamps = photo_stamps(["a.jpg"], [str(photo)])
    revived = json.loads(json.dumps(stamps))

    assert retention_for("a.jpg", str(photo), revived) is Retention.RETAINED


def test_an_encoded_path_is_retained_rather_than_reported_unreadable(photo):
    """The end to end version of the decoding test: the bug it prevents is that
    every photograph reads as new while nothing fails."""
    stamps = photo_stamps(["a.jpg"], [str(photo)])
    quoted = "file://" + str(photo).replace(" ", "%20")

    assert retention_for("a.jpg", quoted, stamps) is Retention.RETAINED


# --- the fold is the checker's own, and the module stays cheap ---------------

def test_the_fold_is_the_checkers_own_and_not_a_copy():
    """Two same-named folds on either side of a boundary are never compared
    and can drift indefinitely, while each side reads as correct (L263)."""
    from postroll.ai import blog_photo_stamps, blog_quality

    assert blog_photo_stamps.fold_filename is blog_quality._fold_filename


def test_the_stamp_module_cannot_reach_a_model_runner():
    """It is imported by the repair loop and by the gate, and the gate is
    defined by having no import that can reach one."""
    import ast
    from pathlib import Path as _Path

    ai_dir = _Path(__file__).resolve().parent.parent / "postroll" / "ai"
    seen, queue = set(), ["blog_photo_stamps"]
    while queue:
        name = queue.pop()
        if name in seen:
            continue
        seen.add(name)
        path = ai_dir / f"{name}.py"
        if not path.is_file():
            continue
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            if isinstance(node, ast.ImportFrom) and node.level and node.module:
                queue.append(node.module.split(".")[0])

    assert "claude_client" not in seen, (
        f"blog_photo_stamps reaches claude_client through {sorted(seen)}; "
        "importing it would put a model runner one import away from the gate")
