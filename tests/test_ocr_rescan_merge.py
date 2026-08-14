"""#518: merging a targeted rescan into the result already on the event.

A large programme is read in several paid calls. When one dies, its pages are
kept as a gap and the rest are saved, so closing the gap used to mean re-running
the whole scan and paying again for every page already read.

`merge_program_data` already merges batches WITHIN one run. What this adds is
the same merge ACROSS two runs, plus the one field that must not be merged the
same way: `unread_pages` is not a list of things collected, it is a statement
about the current state, and unioning the old list with the new one would leave
a page listed as unread by the very run that read it (L46, L83).
"""

from __future__ import annotations

import pytest

from postroll.ai.ocr_batching import merge_rescan


def result(**fields):
    base = {"performers": [], "pieces": [], "scenes": [], "unread_pages": []}
    base.update(fields)
    return base


def test_the_rescanned_pages_stop_being_listed_as_unread():
    """The whole point. A page read by the rescan must not still be named in the
    warning, or the notice becomes a stored error that outlives its fix."""
    previous = result(performers=[{"name": "Ana"}], unread_pages=["p3.jpg"])
    rescanned = result(performers=[{"name": "Bo"}], unread_pages=[])

    merged = merge_rescan(previous, rescanned, rescanned_pages=["p3.jpg"])

    assert merged["unread_pages"] == []


def test_a_page_the_rescan_also_failed_on_stays_unread():
    previous = result(unread_pages=["p3.jpg", "p4.jpg"])
    rescanned = result(unread_pages=["p4.jpg"])

    merged = merge_rescan(previous, rescanned,
                          rescanned_pages=["p3.jpg", "p4.jpg"])

    assert merged["unread_pages"] == ["p4.jpg"]


def test_a_page_that_was_not_rescanned_keeps_its_place_in_the_gap():
    """Selecting a subset must not silently declare the rest read. Nothing
    offers a partial selection today, and a merge that quietly cleared pages
    nobody looked at would be wrong the day something does (L98)."""
    previous = result(unread_pages=["p3.jpg", "p9.jpg"])
    rescanned = result(unread_pages=[])

    merged = merge_rescan(previous, rescanned, rescanned_pages=["p3.jpg"])

    assert merged["unread_pages"] == ["p9.jpg"]


def test_what_the_first_run_read_survives_the_merge():
    """A rescan adds; it never replaces. This is the paid work the whole
    feature exists to protect."""
    previous = result(performers=[{"name": "Ana"}], pieces=[{"title": "Suite"}],
                      program_notes="First half.", unread_pages=["p3.jpg"])
    rescanned = result(performers=[{"name": "Bo"}], program_notes="Second half.")

    merged = merge_rescan(previous, rescanned, rescanned_pages=["p3.jpg"])

    names = [p["name"] for p in merged["performers"]]
    assert names == ["Ana", "Bo"]
    assert merged["pieces"] == [{"title": "Suite"}]
    assert "First half." in merged["program_notes"]
    assert "Second half." in merged["program_notes"]


def test_a_rescan_that_read_nothing_at_all_loses_none_of_the_first_run():
    """The failure the issue names explicitly: a rescan that fails again must
    not wipe the pages that were read the first time."""
    previous = result(performers=[{"name": "Ana"}], program_notes="Kept.",
                      unread_pages=["p3.jpg"])

    merged = merge_rescan(previous, {}, rescanned_pages=["p3.jpg"])

    assert merged["performers"] == [{"name": "Ana"}]
    assert merged["program_notes"] == "Kept."
    assert merged["unread_pages"] == ["p3.jpg"], (
        "a rescan that read nothing must leave the gap exactly as it was")


def test_a_rescan_result_that_is_not_a_dict_is_refused_rather_than_merged():
    """An unusable answer must not be allowed to look like an empty one: the
    caller would write the merge back over good data (L105)."""
    previous = result(performers=[{"name": "Ana"}], unread_pages=["p3.jpg"])
    with pytest.raises(ValueError):
        merge_rescan(previous, None, rescanned_pages=["p3.jpg"])


def test_the_order_of_the_remaining_gap_is_the_order_it_was_reported_in():
    previous = result(unread_pages=["p2.jpg", "p5.jpg", "p9.jpg"])
    rescanned = result(unread_pages=["p5.jpg"])

    merged = merge_rescan(previous, rescanned,
                          rescanned_pages=["p2.jpg", "p5.jpg", "p9.jpg"])

    assert merged["unread_pages"] == ["p5.jpg"]


def test_nothing_left_unread_by_either_run_is_reported_as_a_clean_read():
    previous = result(performers=[{"name": "Ana"}], unread_pages=["p3.jpg"])
    rescanned = result(performers=[{"name": "Bo"}])

    merged = merge_rescan(previous, rescanned, rescanned_pages=["p3.jpg"])

    assert merged["unread_pages"] == []


def test_saying_nothing_is_not_the_same_as_saying_nothing_was_left():
    """The two shapes are one character apart and mean opposite things.

    A completed run always writes `unread_pages`, to [] on a clean read. So the
    key being ABSENT is not a clean read, it is a run that did not get far
    enough to say. Clearing the warning on that would clear it on the strength
    of a failure.
    """
    previous = result(unread_pages=["p3.jpg"])

    said_it_read_everything = merge_rescan(
        previous, result(unread_pages=[]), rescanned_pages=["p3.jpg"])
    said_nothing = merge_rescan(
        previous, {"performers": []}, rescanned_pages=["p3.jpg"])

    assert said_it_read_everything["unread_pages"] == []
    assert said_nothing["unread_pages"] == ["p3.jpg"]


# ── The command line, which is how the app reaches this ───────────────────────


def test_the_cli_merges_into_the_stored_result_it_was_given(tmp_path, monkeypatch):
    """The app hands the result already on the event to the rescan, so the merge
    happens once, in the place that owns the merge rule, rather than being
    reimplemented on the Swift side (L16)."""
    import json

    from postroll.ai import ocr_program

    out = tmp_path / "out.json"
    page = tmp_path / "p3.jpg"
    page.write_bytes(b"not really a jpeg")

    # The stored gap holds the FULL path, because that is what extract_program
    # writes into unread_pages, and the app hands those same strings back as
    # --image. Spelling it any other way here would make this test agree with an
    # invented shape rather than with the pipeline (L48).
    stored = tmp_path / "stored.json"
    stored.write_text(json.dumps({
        "performers": [{"name": "Ana"}],
        "program_notes": "First half.",
        "unread_pages": [str(page)],
    }))

    def fake_extract(images, output_path=None, progress_path=None,
                     page_numbers=None):
        assert [str(i) for i in images] == [str(page)]
        return {"performers": [{"name": "Bo"}], "program_notes": "Second half.",
                "unread_pages": [], "unread_page_numbers": []}

    monkeypatch.setattr(ocr_program, "extract_program", fake_extract)
    code = ocr_program.main([
        "--image", str(page), "--output", str(out),
        "--merge-into", str(stored),
    ])

    assert code == 0
    merged = json.loads(out.read_text())
    assert [p["name"] for p in merged["performers"]] == ["Ana", "Bo"]
    assert merged["unread_pages"] == []


def test_the_cli_refuses_when_the_stored_result_cannot_be_read(tmp_path, monkeypatch):
    """Unreadable is not empty. Merging into {} would write a result built from
    nothing back over a programme that was read and paid for (L105)."""
    from postroll.ai import ocr_program

    out = tmp_path / "out.json"
    page = tmp_path / "p3.jpg"
    page.write_bytes(b"x")
    monkeypatch.setattr(ocr_program, "extract_program",
                        lambda *a, **k: {"unread_pages": []})

    code = ocr_program.main([
        "--image", str(page), "--output", str(out),
        "--merge-into", str(tmp_path / "does-not-exist.json"),
    ])

    assert code != 0
    assert not out.exists(), "nothing may be written when the merge cannot happen"
