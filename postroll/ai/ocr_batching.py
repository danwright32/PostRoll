"""Keep a multi-page program's OCR request inside the size the API accepts (#216).

Splitting oversized pages into bands (#208) doubled how many images one OCR
call carries, and that call had no size cap at all. Measured: a band encodes to
roughly 2.3 MB against a 32 MB ceiling, so a two-page program is comfortable at
about 9 MB while an eight-page program photographed at phone resolution becomes
16 bands and around 36 MB, refused outright rather than degrading.

Sending several requests introduces its own trap. A merge that returns whichever
batch answered last silently drops everything the others found, and it drops it
in the fields nobody checks: the prose blocks, not the performer list. That is
the same shape as a review pass that returned a whole new object and quietly
lost a field it was not asked about. So every field here is merged, and the
merge is enumerated rather than inferred, so a field added to the schema
later cannot fall through by omission.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

#: Prose fields in the OCR schema. Enumerated on purpose: a field left out of
#: the merge silently becomes whichever batch happened to mention it.
PROSE_FIELDS = (
    "organization_notes",
    "program_notes",
    "venue_notes",
    "production_details",
    "other",
)

#: List fields, merged by concatenation with duplicates removed.
LIST_FIELDS = ("performers", "pieces", "scenes")


_SIZE_CACHE: dict[tuple[str, int, float], int] = {}


def encoded_size(paths: list[str | Path]) -> int:
    """What these images will actually weigh in the request body.

    Measured by building the real content block, because the file on disk is
    not the unit the limit is expressed in. The bands the splitter writes are
    full-resolution crops, and every image is downscaled again just before
    upload, so a band's file can be several times the bytes that ever travel.
    Sizing on the file would over-split and make an ordinary two page program
    pay for extra requests to solve a problem only large programs have.

    The encode itself is cached in `claude_client` (#220), so measuring a page
    here and then sending it costs one encode rather than two, and a batching
    pass that considers the same page in several candidate groupings pays for
    it once.
    """
    from .claude_client import _image_block

    total = 0
    for p in paths:
        path = Path(p)
        try:
            stat = path.stat()
            key = (str(path), stat.st_size, stat.st_mtime)
        except OSError:
            continue
        if key not in _SIZE_CACHE:
            try:
                _SIZE_CACHE[key] = len(_image_block(path)["source"]["data"])
            except Exception:  # noqa: BLE001
                # Unreadable here means unreadable at send time too; count it at
                # its on-disk size so it is never treated as weightless.
                _SIZE_CACHE[key] = (stat.st_size + 2) // 3 * 4
        total += _SIZE_CACHE[key]
    return total


def batch_images(paths: list[str | Path], *, limit_bytes: int,
                 max_images: int | None = None) -> list[list[str]]:
    """Group images into requests that each stay under the request's ceilings.

    Reading order is preserved across and within batches: a program read out of
    order is a different program.

    TWO ceilings, because the API has two (#470). Bytes is the one a scanned
    program hits: a handful of full-resolution pages is already tens of
    megabytes. Count is the one a photo set hits: a full show's worth of
    reel photos is small individually and far too many to attach to one
    request. A caller measuring only bytes is refused on exactly the large
    input it batched for.

    `max_images` is optional so the OCR callers, which have never been near the
    count ceiling, keep the grouping they already have rather than being
    re-split by a limit that was not what stopped them.
    """
    from .claude_client import ClaudeError

    batches: list[list[str]] = []
    current: list[str] = []
    current_size = 0

    for p in paths:
        one = encoded_size([p])
        if one > limit_bytes:
            raise ClaudeError(
                f"{Path(p).name} is too large to send on its own "
                f"({one / 1e6:.1f} MB against a {limit_bytes / 1e6:.0f} MB limit). "
                "Re-export the program at a lower resolution and try again."
            )
        too_heavy = current and current_size + one > limit_bytes
        too_many = max_images is not None and len(current) >= max_images
        if too_heavy or too_many:
            batches.append(current)
            current, current_size = [], 0
        current.append(str(p))
        current_size += one

    if current:
        batches.append(current)
    return batches


def _dedupe(items: list[Any]) -> list[Any]:
    seen: set[str] = set()
    out: list[Any] = []
    for item in items:
        key = repr(sorted(item.items())) if isinstance(item, dict) else repr(item)
        if key not in seen:
            seen.add(key)
            out.append(item)
    return out


def merge_program_data(results: list[dict[str, Any] | None]) -> dict[str, Any]:
    """Combine per-batch OCR results without losing any of them.

    A batch that failed contributes nothing rather than erasing the others: a
    page that could not be read is a gap, not a reason to discard the pages that
    could.
    """
    usable = [r for r in results if isinstance(r, dict)]
    if not usable:
        return {}
    if len(usable) == 1:
        return usable[0]

    merged: dict[str, Any] = {}

    for field in LIST_FIELDS:
        combined: list[Any] = []
        for result in usable:
            value = result.get(field)
            if isinstance(value, list):
                combined.extend(value)
        if combined:
            merged[field] = _dedupe(combined)

    for field in PROSE_FIELDS:
        parts = []
        for result in usable:
            value = result.get(field)
            if isinstance(value, str) and value.strip():
                parts.append(value.strip())
        if parts:
            # Joined rather than replaced: the last batch winning would drop the
            # program notes from every earlier page.
            merged[field] = "\n\n".join(_dedupe(parts))

    # Anything the schema grows later still survives, taking the first batch
    # that filled it rather than vanishing because this file was not updated.
    for result in usable:
        for key, value in result.items():
            if key not in merged and value not in (None, "", [], {}):
                merged[key] = value

    return merged


def merge_rescan(previous: dict[str, Any], rescanned: dict[str, Any] | None,
                 *, rescanned_pages: list[str]) -> dict[str, Any]:
    """Fold a targeted rescan into the result already stored on the event (#518).

    A large programme is read in several paid calls, and a call that dies takes
    its pages with it while the rest are kept. This is what lets the gap be
    closed by paying for only the pages that went unread, instead of re-running
    the whole scan.

    The content merge is `merge_program_data`, unchanged, so a rescan combines
    with the first run exactly the way two batches of one run do. There is no
    second implementation of that rule to drift from it.

    `unread_pages` is the one field that cannot go through it. Every other field
    is a collection of things found, where more is strictly better; this one is
    a statement about the CURRENT state, and the ordinary merge would keep the
    first non-empty value, leaving a page listed as unread by the very run that
    read it. It is therefore computed here, deliberately:

        still unread = (what was unread and was NOT looked at again)
                     + (what was looked at again and still could not be read)

    Written that way rather than as "whatever the rescan reported" so that
    rescanning a SUBSET does not silently declare the pages nobody looked at to
    be read. Nothing offers a subset today; it would be wrong the day something
    does (L98).

    A `rescanned` that is not a dict raises. An unusable answer must never be
    allowed to look like an empty one, because the caller writes the result of
    this back over the good data (L105).
    """
    if not isinstance(previous, dict):
        raise ValueError("the stored result to merge into is not a dict")
    if not isinstance(rescanned, dict):
        raise ValueError(
            "the rescan produced no usable result, so there is nothing to merge "
            "and the stored result must be left alone")

    merged = merge_program_data([previous, rescanned])

    was_unread = [p for p in previous.get("unread_pages", []) if isinstance(p, str)]

    # A rescan that reported no `unread_pages` at all made no statement about
    # what it managed to read, so nothing here may conclude it read anything.
    # Every completed run sets the key, including to an empty list on a clean
    # read, so its ABSENCE means this is not a completed run: an empty result
    # from a rescan that fell over. Reading that as "nothing left unread" would
    # clear the warning on the strength of a failure (L98, L11).
    if "unread_pages" not in rescanned:
        merged["unread_pages"] = was_unread
        return merged

    looked_at = set(rescanned_pages)
    still_unread_now = {p for p in rescanned["unread_pages"] if isinstance(p, str)}

    # Order taken from the earlier report, so the gap is listed the way it was
    # first described rather than reshuffled by which run last touched it.
    merged["unread_pages"] = [
        page for page in was_unread
        if page not in looked_at or page in still_unread_now
    ]
    return merged
