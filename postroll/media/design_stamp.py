"""What design rendered a day's assets, recorded once per day folder (#286).

#160 gave the collage a version, carried in the layout sidecar that already sat
beside its PNG. The reels and the stills have no sidecar, so they need
somewhere to put the same fact, and the honest unit is the day rather than the
asset: regenerating rebuilds everything that day produced in one go, and "is
this day's output current" is then one read instead of one per file.

Written by `postroll/ai/generate_media.py` at the end of each day it renders.
`PostRollApp/Sources/Services/DesignStamp.swift` is the reading half, and
`tests/test_media_design_version.py` is the contract both satisfy.

Not written on a final export: the export folder is what Dan uploads, and a
bookkeeping file in it is noise. Staleness is a question about the cached
preview, which is the copy that survives to be rendered again.
"""

from __future__ import annotations

import json
from datetime import date
from pathlib import Path
from typing import Iterable

from .design_tokens import MEDIA_DESIGN_CHANGED, MEDIA_DESIGN_VERSIONS


#: The record's name inside a day folder.
STAMP_NAME = "design.json"


def design_stamp_path(day_dir: Path | str) -> Path:
    """The stamp belonging to a day folder."""
    return Path(day_dir) / STAMP_NAME


def write_design_stamp(day_dir: Path | str, templates: Iterable[str]) -> None:
    """Record the design version of every template this day just rendered.

    Raises KeyError for a template with no declared version, rather than
    skipping it. A stamp that quietly dropped what it did not recognise would
    leave that template exempt from the staleness check forever while the file
    still read as though it covered the whole day.

    Raises OSError if the file does not read back as what was written. The
    reader deliberately treats unreadable and absent as the same answer (no
    evidence), which is right for the badge but means a write that silently
    failed would disable the guard with nothing ever saying so. This repo has
    been bitten by a read that lied about a file under macOS's protections, so
    the write proves itself instead of assuming it landed.
    """
    recorded = {name: MEDIA_DESIGN_VERSIONS[name] for name in sorted(set(templates))}
    design_stamp_path(day_dir).write_text(
        json.dumps({"templates": recorded}), encoding="utf-8")
    if read_design_stamp(day_dir) != recorded:
        raise OSError(
            f"design stamp at {design_stamp_path(day_dir)} did not read back as "
            "what was just written")


def read_design_stamp(day_dir: Path | str) -> dict[str, int]:
    """The template versions recorded for a day, or {} if there is no record.

    Never raises. Every day folder rendered before this existed has no stamp,
    and that is a fact about the day rather than an error: there is no way to
    tell which design made it, so it reads as unstamped rather than as current.
    A version that is not an integer is dropped rather than believed, because a
    value that cannot be compared would otherwise land on the fresh side of
    every comparison it touches (L50).
    """
    try:
        doc = json.loads(design_stamp_path(day_dir).read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError):
        return {}
    if not isinstance(doc, dict):
        return {}
    templates = doc.get("templates")
    if not isinstance(templates, dict):
        return {}
    return {
        name: version
        for name, version in templates.items()
        if isinstance(name, str) and isinstance(version, int) and not isinstance(version, bool)
    }


def rendered_templates(day_result: dict[str, object], day_dir: Path | str) -> list[str]:
    """Which versioned templates a run's own results point at inside a day folder.

    Derived from what the run produced rather than from a list each of the
    dozen call sites has to remember to append to. Half a payload built by a
    helper and half by its caller has nowhere its completeness can be seen, so
    an entry missing from both halves is invisible to a reader of either (L94).

    A result that is not a path (Friday's clip plan, the cover pick) is skipped,
    and so is one written outside the day folder: Tuesday's before/after goes to
    a temp file on a final export, and stamping the day for it would claim a
    current asset the folder does not hold.
    """
    day_dir = Path(day_dir)
    found = set()
    for value in day_result.values():
        if not isinstance(value, str):
            continue
        path = Path(value)
        if path.parent == day_dir and path.stem in MEDIA_DESIGN_VERSIONS:
            found.add(path.stem)
    return sorted(found)


def cached_templates(day_dir: Path | str) -> list[str]:
    """Which versioned templates actually have an asset sitting in this folder.

    Read off the disk, not off the stamp. The question being asked is whether
    the cached assets are old, so the assets are what has to be enumerated: a
    stamp is a claim about them, and a folder full of assets with no stamp at
    all is precisely the case this was written for.
    """
    day_dir = Path(day_dir)
    try:
        entries = list(day_dir.iterdir())
    except OSError:
        return []
    return sorted({
        entry.stem for entry in entries
        if entry.is_file() and entry.stem in MEDIA_DESIGN_VERSIONS
    })


def cached_assets(day_dir: Path | str) -> dict[str, Path]:
    """The same assets, with the path each one was found at (#804).

    The path is what carries the modification date the unstamped rule reads.
    Kept beside `cached_templates` rather than replacing it, because the app
    and the tests both ask the plain question far more often than they ask
    where the file is.

    One entry per template: a folder holding two files with the same stem keeps
    whichever the scan reached last, which is the only arrangement a render
    never produces.
    """
    day_dir = Path(day_dir)
    try:
        entries = list(day_dir.iterdir())
    except OSError:
        return {}
    return {
        entry.stem: entry for entry in sorted(entries)
        if entry.is_file() and entry.stem in MEDIA_DESIGN_VERSIONS
    }


def predates_its_design_change(name: str, path: Path) -> bool:
    """Whether an asset was written before the day its template's design changed.

    The half of the badge that needs no stamp (#804). It answers False in every
    case where there is no evidence, and each of those is a different situation
    that must not be read as the others:

    * a template with no recorded design CHANGE has nothing to be older than.
      Its date in the table would only say when a number was first written
      down, and an asset older than that was made by the same design (L98).
    * a file whose date cannot be read says nothing about when it was made, so
      reporting it would be a claim this never measured (L11).

    Compared as local calendar dates, because the recorded change is a calendar
    date. An asset written ON the day of the change, before the change itself,
    reads as current: that under-reports by less than a day, which is the safe
    direction for a badge that sends somebody to re-render.

    A copied or synced file carries a modification date at or after its real
    render, never before it, so the same direction holds for a library that has
    been moved: it can hide a stale asset, it cannot invent one.
    """
    changed = MEDIA_DESIGN_CHANGED.get(name)
    if changed is None:
        return False
    try:
        written = date.fromtimestamp(path.stat().st_mtime)
    except (OSError, OverflowError, ValueError):
        return False
    return written < date.fromisoformat(changed.day)


def stale_templates(day_dir: Path | str) -> list[str]:
    """Which cached assets in a day folder predate the design this build renders.

    Sorted, because the app names them in a message and a set's order would
    reword it on every read.

    Reported on EVIDENCE only: a version was recorded, and it is behind. An
    asset with no record is not reported, even though that means an asset older
    than the stamp itself goes unmentioned.

    That was measured rather than assumed (2026-08-10). Treating "no record" as
    stale badged all 66 day folders on Dan's machine at once, because none
    carried a stamp yet, and a badge on every day is one nobody reads (L36).

    The second half of that reasoning was wrong, and re-measuring it is what
    closed #311 (2026-08-11). It said those assets were not old either, because
    the gallery redesign landed 2026-07-14 and the newest previews were rendered
    2026-08-07. That compared the redesign against the NEWEST preview only. Read
    across the whole library instead: 38 of the 66 day folders hold nothing
    rendered since 2026-07-14 at all, and two later changes (the bottom-only
    crop on 2026-08-07 22:07, the shared org and venue detail lines on
    2026-08-10) both postdate the newest asset on disk. So every cached asset
    predates the design this build renders, and the silent case is currently
    hiding the entire library rather than costing nothing.

    That cost is accepted deliberately, not overlooked. The alternative was to
    write a version onto those folders, and a stamp is a RECORD: asserting they
    were made by the current design would be a claim the file dates contradict,
    and it would permanently destroy the ability to tell a measured stamp from a
    guessed one. Saying nothing is the honest state until a day is rendered
    again, and every render from here leaves a stamp, so a future design change
    is caught by evidence rather than by absence.

    An asset stamped NEWER than this build is not stale either. Regenerating it
    here would replace a better asset with an older design, so sending the
    person to do that is worse than saying nothing.
    """
    recorded = read_design_stamp(day_dir)
    recorded = _with_collage_from_its_sidecar(day_dir, recorded)
    stale = []
    for name, path in sorted(cached_assets(day_dir).items()):
        if name in recorded:
            # A record beats an inference, in both directions: an asset stamped
            # current is not badged for being old, and one stamped behind is
            # badged however new the file is.
            if recorded[name] < MEDIA_DESIGN_VERSIONS[name]:
                stale.append(name)
        elif predates_its_design_change(name, path):
            stale.append(name)
    return stale


def _with_collage_from_its_sidecar(
    day_dir: Path | str, recorded: dict[str, int],
) -> dict[str, int]:
    """Fill in the collage's version from the sidecar #160 already writes.

    Every day folder on disk the day this ships is in exactly one state: no day
    stamp, and a collage whose layout sidecar already records the design that
    made it. Ignoring that would badge collages the app has always read as
    current, and send Dan to rebuild something that is not out of date.

    The day stamp wins where it has an entry: it is the record for the day, and
    a sidecar left by a partial write must not override what the day says about
    itself. A sidecar with no version (the bare-array shape written before #160)
    fills in nothing, so "no version recorded" cannot become a clean bill of
    health.
    """
    if "collage" in recorded:
        return recorded
    from .layout_sidecar import layout_sidecar_path, read_layout_sidecar

    version, _ = read_layout_sidecar(layout_sidecar_path(Path(day_dir) / "collage.png"))
    if version is None:
        return recorded
    return {**recorded, "collage": version}
