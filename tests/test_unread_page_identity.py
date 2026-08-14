"""#558: the gap must be keyed to something a move cannot break.

`unread_pages` recorded the pages a partial scan could not read as their full
file paths, and the targeted rescan matched on those same strings. That works
only while the app hands back exactly what Python wrote.

It stops working the moment the programme images are moved or rebased, which
this repo does do: `rebasePaths` exists for that. The stored gap would then name
paths nothing can find, the rescan would refuse them as missing, and the only
route left is re-uploading the whole programme and paying for every page again,
which is the cost the feature exists to avoid. Nothing reports it as a defect;
it reads as an ordinary refusal (L15).

So the identity is the page's POSITION in the uploaded programme, resolved to a
path at scan time. The paths are still carried, because they are what those
pages were called when the scan ran and because results written before this
change have nothing else, but they are no longer what the merge matches on.
"""

from __future__ import annotations

import pytest

from postroll.ai.ocr_batching import merge_rescan
from postroll.ai.ocr_program import unread_gap


def result(**over):
    base = {"performers": [], "pieces": [], "scenes": [],
            "unread_pages": [], "unread_page_numbers": []}
    return {**base, **over}


# ── numbering the gap ─────────────────────────────────────────────────────────


def test_the_gap_carries_the_position_of_every_page_it_names() -> None:
    paths, numbers = unread_gap(
        unread=["/programs/p3.jpg"],
        order=["/programs/p1.jpg", "/programs/p2.jpg", "/programs/p3.jpg"],
        numbers=[1, 2, 3])

    assert paths == ["/programs/p3.jpg"]
    assert numbers == [3]


def test_the_two_lists_are_always_the_same_length() -> None:
    """They describe one fact between them, so a reader may pair them by index.

    Letting them fall out of step would put one page's number against another
    page's path, which is worse than carrying no number at all.
    """
    paths, numbers = unread_gap(
        unread=["/programs/p2.jpg", "/somewhere/else.jpg"],
        order=["/programs/p1.jpg", "/programs/p2.jpg"],
        numbers=[1, 2])

    assert len(paths) == len(numbers) == 2


def test_a_page_the_caller_never_listed_is_kept_with_no_position() -> None:
    """Zero means "no position known", not page zero.

    Dropping it instead would lose a page from the very list that exists to say
    which pages were lost (L11).
    """
    paths, numbers = unread_gap(
        unread=["/somewhere/else.jpg"],
        order=["/programs/p1.jpg"],
        numbers=[1])

    assert paths == ["/somewhere/else.jpg"]
    assert numbers == [0]


def test_a_rescan_numbers_its_pages_by_where_they_sit_in_the_whole_programme() -> None:
    """A rescan is passed a SUBSET, so counting its own images would renumber
    page 7 as page 1 and the merge would strike off the wrong page."""
    paths, numbers = unread_gap(
        unread=["/programs/p7.jpg"],
        order=["/programs/p3.jpg", "/programs/p7.jpg"],
        numbers=[3, 7])

    assert paths == ["/programs/p7.jpg"]
    assert numbers == [7]


def test_a_page_split_into_bands_is_still_one_page() -> None:
    paths, numbers = unread_gap(
        unread=["/programs/p2.jpg", "/programs/p2.jpg"],
        order=["/programs/p1.jpg", "/programs/p2.jpg"],
        numbers=[1, 2])

    assert paths == ["/programs/p2.jpg"]
    assert numbers == [2]


def test_a_numbering_that_does_not_match_the_pages_is_refused() -> None:
    """A short list would silently number the tail of the programme as unknown.

    Which reads as "these pages have no position" when what actually happened
    is that the caller lost track of them.
    """
    with pytest.raises(ValueError, match="one page number per page"):
        unread_gap(unread=[], order=["/a.jpg", "/b.jpg"], numbers=[1])


# ── merging on position ───────────────────────────────────────────────────────


def test_a_rescan_after_the_pages_moved_still_closes_the_gap() -> None:
    """The defect, stated as a test.

    The stored gap names the paths as they were; the rescan sends the paths as
    they are now. Matching on the strings finds nothing in common, so the page
    that was just read and paid for stays listed as unread forever.
    """
    previous = result(unread_pages=["/old/place/p3.jpg"], unread_page_numbers=[3])
    rescanned = result(unread_pages=[], unread_page_numbers=[])

    merged = merge_rescan(previous, rescanned,
                          rescanned_pages=["/new/place/p3.jpg"],
                          rescanned_page_numbers=[3])

    assert merged["unread_pages"] == []
    assert merged["unread_page_numbers"] == []


def test_a_page_still_unreadable_after_the_move_stays_in_the_gap() -> None:
    previous = result(unread_pages=["/old/p3.jpg", "/old/p7.jpg"],
                      unread_page_numbers=[3, 7])
    rescanned = result(unread_pages=["/new/p7.jpg"], unread_page_numbers=[7])

    merged = merge_rescan(previous, rescanned,
                          rescanned_pages=["/new/p3.jpg", "/new/p7.jpg"],
                          rescanned_page_numbers=[3, 7])

    assert merged["unread_page_numbers"] == [7]
    # The path reported is the one the rescan just used, because that is where
    # the page actually is. Keeping the stale one would hand the next rescan a
    # path that has already been proved wrong.
    assert merged["unread_pages"] == ["/new/p7.jpg"]


def test_a_page_nobody_looked_at_again_is_not_declared_read() -> None:
    previous = result(unread_pages=["/old/p3.jpg", "/old/p9.jpg"],
                      unread_page_numbers=[3, 9])
    rescanned = result(unread_pages=[], unread_page_numbers=[])

    merged = merge_rescan(previous, rescanned,
                          rescanned_pages=["/new/p3.jpg"],
                          rescanned_page_numbers=[3])

    assert merged["unread_page_numbers"] == [9]
    assert merged["unread_pages"] == ["/old/p9.jpg"]


def test_a_rescan_that_reported_nothing_leaves_the_gap_alone() -> None:
    """An absent key is a run that fell over, not a clean read (L98)."""
    previous = result(unread_pages=["/old/p3.jpg"], unread_page_numbers=[3])
    rescanned = {"performers": [], "pieces": [], "scenes": []}

    merged = merge_rescan(previous, rescanned,
                          rescanned_pages=["/new/p3.jpg"],
                          rescanned_page_numbers=[3])

    assert merged["unread_page_numbers"] == [3]
    assert merged["unread_pages"] == ["/old/p3.jpg"]


# ── results written before any of this existed ────────────────────────────────


def test_a_stored_gap_with_no_numbers_still_merges_on_paths() -> None:
    """Every gap stored before this change carries paths and nothing else.

    Refusing to merge those would make the feature they were recorded for stop
    working on exactly the results that already need it (L15).
    """
    previous = {"performers": [], "pieces": [], "scenes": [],
                "unread_pages": ["/programs/p3.jpg", "/programs/p9.jpg"]}
    rescanned = result(unread_pages=[], unread_page_numbers=[])

    merged = merge_rescan(previous, rescanned,
                          rescanned_pages=["/programs/p3.jpg"],
                          rescanned_page_numbers=[3])

    assert merged["unread_pages"] == ["/programs/p9.jpg"]


def test_an_old_gap_merged_on_paths_comes_back_numbered() -> None:
    """So the next rescan of that programme is not path-matched all over again.

    The rescan just proved which page each of those paths is, and throwing that
    away would leave the result no better keyed than it arrived.
    """
    previous = {"performers": [], "pieces": [], "scenes": [],
                "unread_pages": ["/programs/p3.jpg", "/programs/p9.jpg"]}
    rescanned = result(unread_pages=["/programs/p3.jpg"], unread_page_numbers=[3])

    merged = merge_rescan(previous, rescanned,
                          rescanned_pages=["/programs/p3.jpg"],
                          rescanned_page_numbers=[3])

    # Both survive: page 3 was looked at again and still could not be read, and
    # nobody looked at page 9 at all. Only page 3 comes back with a position,
    # because that is the only one this run learned anything about.
    assert merged["unread_pages"] == ["/programs/p3.jpg", "/programs/p9.jpg"]
    assert merged["unread_page_numbers"] == [3, 0]


def test_a_caller_that_names_no_numbers_at_all_still_merges() -> None:
    """The old call shape, kept working rather than made a hard error."""
    previous = {"performers": [], "pieces": [], "scenes": [],
                "unread_pages": ["/programs/p3.jpg"]}
    rescanned = {"performers": [], "pieces": [], "scenes": [], "unread_pages": []}

    merged = merge_rescan(previous, rescanned, rescanned_pages=["/programs/p3.jpg"])

    assert merged["unread_pages"] == []


def test_a_numbering_the_rescan_cannot_pair_up_is_refused() -> None:
    previous = result(unread_pages=["/old/p3.jpg"], unread_page_numbers=[3])

    with pytest.raises(ValueError, match="one page number per page"):
        merge_rescan(previous, result(),
                     rescanned_pages=["/new/p3.jpg", "/new/p7.jpg"],
                     rescanned_page_numbers=[3])


# ── the boundary the sentinel shares with real positions (#576) ───────────────


def _refused_page_number(value, tmp_path, monkeypatch, capsys):
    """Run the CLI with one --page-number and report (exit code, stderr).

    `extract_program` is replaced with something that cannot be called quietly,
    so a guard that lets the value through fails as a paid call that ran rather
    than as a wrong number somewhere downstream.
    """
    from postroll.ai import ocr_program

    page = tmp_path / "p1.jpg"
    page.write_bytes(b"not really a jpeg")
    out = tmp_path / "out.json"

    def the_paid_call(*args, **kwargs):
        raise AssertionError(
            f"--page-number {value} reached the paid call instead of being refused")

    monkeypatch.setattr(ocr_program, "extract_program", the_paid_call)

    code = ocr_program.main(["--image", str(page), "--output", str(out),
                             "--page-number", str(value)])

    assert not out.exists(), "nothing may be written by a refused run"
    return code, capsys.readouterr().err


def test_the_sentinel_is_refused_as_a_page_number(tmp_path, monkeypatch, capsys) -> None:
    """0 is NO_PAGE_NUMBER, "position not known", not a position.

    Measured before the fix: a rescan passing 0 strikes EVERY page of unknown
    position out of `unread_pages`, because they all carry 0 and the merge reads
    them as pages this run just looked at. The two meanings cannot be told apart
    downstream, so the only place to separate them is the boundary.
    """
    code, err = _refused_page_number(0, tmp_path, monkeypatch, capsys)

    assert code != 0
    # The reason names the sentinel, so it is on screen rather than in a
    # constant the person running this cannot see.
    assert "--page-number 0" in err
    assert "not known" in err
    assert "1-based" in err


def test_a_page_number_below_the_sentinel_is_refused(tmp_path, monkeypatch, capsys) -> None:
    """Negatives are no more a position than 0 is, and argparse takes any int."""
    code, err = _refused_page_number(-3, tmp_path, monkeypatch, capsys)

    assert code != 0
    assert "--page-number -3" in err


def test_the_first_real_page_is_still_accepted(tmp_path, monkeypatch) -> None:
    """The guard must refuse only what cannot be a position (L54).

    Page 1 sits directly against the sentinel, so an off-by-one here would
    silently refuse every single-page rescan.
    """
    from postroll.ai import ocr_program

    page = tmp_path / "p1.jpg"
    page.write_bytes(b"not really a jpeg")
    out = tmp_path / "out.json"

    seen: list[list[int] | None] = []

    def fake_extract(images, output_path=None, progress_path=None,
                     page_numbers=None):
        seen.append(page_numbers)
        return result()

    monkeypatch.setattr(ocr_program, "extract_program", fake_extract)

    code = ocr_program.main(["--image", str(page), "--output", str(out),
                             "--page-number", "1"])

    assert code == 0
    assert seen == [[1]]
