"""#220: an image should be encoded once per run, not once per question asked.

`ocr_batching.encoded_size` builds each image's real content block to measure
what the request will weigh, then throws the block away and keeps the length.
`build_content` then builds the identical block again to send it. The caption
preflight added in #228 does the same thing a third time.

So every program page is opened, downscaled and base64-encoded at least twice.
On a thirty page programme that is sixty full-resolution resizes on a step that
already takes minutes, and it is pure waste: the second encode cannot produce a
different answer from the first.

The cache is bounded on purpose. A base64 page is a megabyte or two, so an
unbounded one would hold a whole programme in memory for the life of the
process to save work that may never be repeated.
"""

from __future__ import annotations

import pytest

from postroll.ai import claude_client as cc


@pytest.fixture
def page(tmp_path):
    from PIL import Image
    p = tmp_path / "page.jpg"
    # Over the long-edge budget so the resize path actually runs and the work
    # being saved is real work.
    Image.new("RGB", (4200, 3000), (30, 40, 50)).save(p)
    return p


@pytest.fixture(autouse=True)
def clear_cache():
    cc.clear_image_block_cache()
    yield
    cc.clear_image_block_cache()


def _encode_count(monkeypatch):
    """Count how many times the real encode runs underneath the cache."""
    calls = {"n": 0}
    original = cc._build_image_block

    def counting(path, *, model=""):
        calls["n"] += 1
        return original(path, model=model)

    monkeypatch.setattr(cc, "_build_image_block", counting)
    return calls


# ── the saving ────────────────────────────────────────────────────────────────

def test_the_same_image_is_encoded_once(page, monkeypatch):
    calls = _encode_count(monkeypatch)

    cc._image_block(page, model="sonnet")
    cc._image_block(page, model="sonnet")

    assert calls["n"] == 1


def test_measuring_then_sending_encodes_once(page, monkeypatch):
    # The actual sequence: batching measures the page, then the request is
    # built from the same page.
    from postroll.ai import ocr_batching

    calls = _encode_count(monkeypatch)

    ocr_batching.encoded_size([page])
    cc._image_block(page, model="")

    assert calls["n"] == 1


def test_the_second_answer_is_identical(page):
    # A cache that returned something different would be worse than no cache.
    first = cc._image_block(page, model="sonnet")
    second = cc._image_block(page, model="sonnet")

    assert first == second


# ── when it must NOT reuse ────────────────────────────────────────────────────

def test_a_different_model_gets_its_own_encode(page, monkeypatch):
    # The long-edge budget follows the resolved model, so a bigger-budget model
    # must not be handed pixels shrunk to a smaller one's limit (#218).
    calls = _encode_count(monkeypatch)

    cc._image_block(page, model="sonnet")
    cc._image_block(page, model="opus")

    assert calls["n"] == 2


def test_an_edited_file_is_re_encoded(page, monkeypatch):
    # Keyed on what the file is now. Serving the previous contents would send
    # a photo Dan has since replaced.
    from PIL import Image

    calls = _encode_count(monkeypatch)
    cc._image_block(page, model="sonnet")

    Image.new("RGB", (4200, 3000), (200, 10, 10)).save(page)
    cc._image_block(page, model="sonnet")

    assert calls["n"] == 2


def test_a_missing_file_still_raises(page):
    # The cache must not turn a missing photo into a stale success.
    cc._image_block(page, model="sonnet")
    page.unlink()

    # OSError specifically: a file that is not there fails when it is read,
    # which is what must still happen rather than a stale hit.
    with pytest.raises(OSError):
        cc._image_block(page, model="sonnet")


# ── it stays bounded ──────────────────────────────────────────────────────────

def test_the_cache_does_not_grow_without_limit(tmp_path):
    from PIL import Image

    for i in range(cc.IMAGE_BLOCK_CACHE_LIMIT + 6):
        p = tmp_path / f"page-{i}.jpg"
        Image.new("RGB", (900, 600), (i % 255, 40, 50)).save(p)
        cc._image_block(p, model="sonnet")

    assert cc.image_block_cache_size() <= cc.IMAGE_BLOCK_CACHE_LIMIT


def test_the_limit_covers_a_whole_caption_call():
    # A carousel is at most ten photos, preflighted and then sent. If the cache
    # were smaller than that the preflight would evict its own work before the
    # send reused it, which is the case this exists to fix.
    assert cc.IMAGE_BLOCK_CACHE_LIMIT >= 10
