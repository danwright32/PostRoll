"""Keep a multi-page program's OCR request under the size the API accepts (#216).

Splitting oversized pages into bands (#208) doubled how many images a single
OCR call carries, and that call had no size cap at all. Measured: one band
encodes to roughly 2.3 MB against a 32 MB request ceiling, so a two-page
program is comfortable at about 9 MB while an eight-page program photographed
at phone resolution becomes 16 bands and around 36 MB, which is refused
outright rather than degrading. Six and eight page programs already exist in
the library.

The fix is to send several requests and merge, which introduces its own trap:
a merge that returns whichever batch answered last silently drops everything
the other batches found. That is the same shape as the review pass that dropped
a field it was not asked about, so every field is merged rather than replaced,
and the tests below check the fields nobody thinks about (the prose blocks) as
well as the obvious lists.
"""

from __future__ import annotations

import pytest

from postroll.ai import ocr_batching as ob


def _fake_images(tmp_path, count, kb_each):
    paths = []
    for i in range(count):
        p = tmp_path / f"page{i:02d}.png"
        p.write_bytes(b"\x89PNG" + b"0" * (kb_each * 1024))
        paths.append(str(p))
    return paths


# ── grouping ──────────────────────────────────────────────────────────────────

def test_a_small_program_stays_in_one_request(tmp_path):
    """A change that split every program into several calls would triple the
    cost and latency of the common case for no reason."""
    images = _fake_images(tmp_path, count=4, kb_each=100)

    batches = ob.batch_images(images, limit_bytes=10_000_000)

    assert len(batches) == 1
    assert batches[0] == images


def test_an_oversized_program_is_split_into_several_requests(tmp_path):
    images = _fake_images(tmp_path, count=10, kb_each=1000)

    batches = ob.batch_images(images, limit_bytes=3_000_000)

    assert len(batches) > 1


def test_no_batch_exceeds_the_limit(tmp_path):
    images = _fake_images(tmp_path, count=10, kb_each=1000)
    limit = 3_000_000

    for batch in ob.batch_images(images, limit_bytes=limit):
        assert ob.encoded_size(batch) <= limit


def test_every_page_appears_exactly_once(tmp_path):
    """Dropping a page loses whoever was printed on it, silently."""
    images = _fake_images(tmp_path, count=10, kb_each=1000)

    flat = [p for batch in ob.batch_images(images, limit_bytes=3_000_000) for p in batch]

    assert flat == images


def test_pages_stay_in_reading_order(tmp_path):
    images = _fake_images(tmp_path, count=8, kb_each=1000)

    batches = ob.batch_images(images, limit_bytes=3_000_000)

    assert [p for b in batches for p in b] == sorted(images)


def test_a_single_page_too_large_on_its_own_fails_loudly(tmp_path):
    """Silently sending it would fail at the API with a less useful message,
    after the upload time has already been spent."""
    from postroll.ai.claude_client import ClaudeError

    images = _fake_images(tmp_path, count=1, kb_each=5000)

    with pytest.raises(ClaudeError, match="too large"):
        ob.batch_images(images, limit_bytes=1_000_000)


# ── merging, where a careless fix loses data ──────────────────────────────────

def test_performers_from_every_batch_survive():
    merged = ob.merge_program_data([
        {"performers": [{"name": "A", "role": "actor"}]},
        {"performers": [{"name": "B", "role": "actor"}]},
    ])

    assert {p["name"] for p in merged["performers"]} == {"A", "B"}


def test_a_person_listed_on_two_pages_is_not_duplicated():
    merged = ob.merge_program_data([
        {"performers": [{"name": "A", "role": "actor"}]},
        {"performers": [{"name": "A", "role": "actor"}]},
    ])

    assert len(merged["performers"]) == 1


def test_prose_from_a_later_batch_does_not_replace_an_earlier_one():
    """The failure mode that is easy to ship: the last batch wins and the
    program notes from the first four pages are gone."""
    merged = ob.merge_program_data([
        {"program_notes": "notes from the first pages"},
        {"program_notes": "notes from the last pages"},
    ])

    assert "first pages" in merged["program_notes"]
    assert "last pages" in merged["program_notes"]


def test_an_empty_field_never_overwrites_a_filled_one():
    merged = ob.merge_program_data([
        {"organization_notes": "the real text"},
        {"organization_notes": ""},
    ])

    assert merged["organization_notes"] == "the real text"


def test_every_schema_field_is_merged_rather_than_only_the_obvious_ones():
    """Enumerated deliberately: a field left out of the merge is silently
    whichever batch happened to mention it."""
    a = {k: f"a-{k}" for k in ob.PROSE_FIELDS}
    b = {k: f"b-{k}" for k in ob.PROSE_FIELDS}

    merged = ob.merge_program_data([a, b])

    for field in ob.PROSE_FIELDS:
        assert f"a-{field}" in merged[field], f"{field} lost the first batch"
        assert f"b-{field}" in merged[field], f"{field} lost the second batch"


def test_merging_one_batch_returns_it_unchanged():
    single = {"performers": [{"name": "A"}], "program_notes": "x"}

    assert ob.merge_program_data([single]) == single


def test_a_batch_that_failed_does_not_erase_the_others():
    merged = ob.merge_program_data([
        {"performers": [{"name": "A", "role": "actor"}]},
        None,
    ])

    assert merged["performers"]


# ── wired into the shipping OCR path ──────────────────────────────────────────

def test_a_large_program_reaches_the_model_in_several_calls(tmp_path, monkeypatch):
    import postroll.ai.ocr_program as op

    monkeypatch.setattr(op, "MAX_REQUEST_BYTES", 500_000)
    pages = _fake_images(tmp_path, count=6, kb_each=200)
    calls = []

    def fake_run_json(prompt, timeout=600, image_paths=None, **kwargs):
        calls.append(list(image_paths or []))
        n = len(calls)
        # Non-empty pieces so extract_program's recovery calls (which fire only
        # when a field comes back empty) do not add calls this test would
        # miscount as batches.
        return {"performers": [{"name": f"P{n}", "role": "actor"}],
                "pieces": [{"title": f"W{n}", "composer": "C"}],
                "program_notes": f"notes {n}"}  # all recovery-triggering fields filled

    monkeypatch.setattr(op, "run_json_prompt", fake_run_json)
    monkeypatch.setattr(op, "split_page", lambda p, d, **kw: [p])
    result = op.extract_program(pages)

    assert len(calls) > 1, "the whole program went out in one oversized request"
    assert len({p["name"] for p in result["performers"]}) == len(calls), \
        "a batch's performers were lost in the merge"


def test_a_normal_program_still_goes_out_in_one_call(tmp_path, monkeypatch):
    import postroll.ai.ocr_program as op

    pages = _fake_images(tmp_path, count=2, kb_each=100)
    calls = []

    def fake_run_json(prompt, timeout=600, image_paths=None, **kwargs):
        calls.append(list(image_paths or []))
        # Every field extract_program has a recovery call for is populated, so
        # this counts batches rather than recoveries.
        return {"performers": [{"name": "A", "role": "actor"}],
                "pieces": [{"title": "W", "composer": "C"}],
                "program_notes": "notes"}

    monkeypatch.setattr(op, "run_json_prompt", fake_run_json)
    monkeypatch.setattr(op, "split_page", lambda p, d, **kw: [p])
    op.extract_program(pages)

    assert len(calls) == 1


def test_size_is_measured_on_what_is_actually_sent_not_the_file_on_disk(tmp_path):
    """The bands written by the splitter are full-resolution crops, but images
    are downscaled again just before upload, so a band's file can be several
    times larger than the bytes that ever travel. Sizing on the file is a proxy
    for the real unit, and it over-splits: a two page program would be sent as
    several requests for no reason, tripling its cost and latency."""
    from PIL import Image

    big = tmp_path / "big.png"
    # Far above the upload cap in pixels, so the downscale does real work.
    Image.new("RGB", (4000, 4000), "white").save(big)

    on_disk = big.stat().st_size
    measured = ob.encoded_size([str(big)])

    assert measured < on_disk * 4 / 3, \
        "size was taken from the file rather than from what gets uploaded"


def test_a_two_page_program_of_real_bands_still_fits_one_request(tmp_path):
    """The common case. If this splits, every ordinary program pays for extra
    requests to fix a problem only large programs have."""
    from PIL import Image

    bands = []
    for i in range(4):                      # two pages, two bands each
        p = tmp_path / f"band{i}.png"
        Image.new("RGB", (3024, 2096), "white").save(p)
        bands.append(str(p))

    assert len(ob.batch_images(bands, limit_bytes=25_000_000)) == 1
