"""Rebuild the manifest the app sends Python, from a stored event (#213).

Running any `postroll.ai` module against a REAL past event means reconstructing
what `PythonBridge.swift` builds in Swift. Doing that by hand went wrong on the
first attempt in a way worth keeping fixed: the store keeps photo paths as
percent-encoded `file://` URLs (`absoluteString`) and the bridge sends
`$0.path`. Reading the stored value as a path finds nothing on disk, and that
looks exactly like an event whose media has been reclaimed, so all nineteen
stored events reported as having no photos left. They all had them.

The store is a parameter rather than a constant, so the tests never read the
real events file.

Usage:
    python -m tools.event_manifest --list
    python -m tools.event_manifest --event "BLUDLINE: A Hip-Hop Odyssey" \
        --out week.json
"""

from __future__ import annotations

import argparse
import datetime
import json
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

#: Where the app keeps its events. Passed in everywhere below; this is only the
#: default for the command line.
DEFAULT_STORE = (Path.home() / "Library" / "Application Support" / "PostRoll"
                 / "events.json")

#: Foundation's reference date. Stored dates are seconds since this, NOT since
#: the Unix epoch: reading one as Unix time lands in 1995 and every date-derived
#: line in the output is about the wrong evening.
REFERENCE_DATE = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)

#: Stored `ShootType` raw value to the `pythonValue` the bridge sends, both read
#: from `PostRollApp/Sources/Models/Event.swift`. Note the two sides differ: the
#: store holds "Performance" and "Combo", NOT the enum's case names.
#:
#: The generators write different prose depending on what Dan actually
#: witnessed, so an unmapped value is refused rather than defaulted. The first
#: draft of this guessed the keys from the case names and defaulted the misses
#: to "performance", which silently turned every "Combo" shoot into a full show
#: and would have dropped the rehearsal half out of the writing.
SHOOT_TYPES = {
    "Performance": "performance",
    "Photo Call": "photo_call",
    "Rehearsal": "rehearsal",
    "Combo": "rehearsal_and_performance",
}


def as_path(value: str) -> str:
    """The POSIX path the bridge sends, from whatever the store holds."""
    if not value.startswith("file://"):
        return value
    return unquote(urlparse(value).path)


def _events(store: Path) -> list[dict[str, Any]]:
    data = json.loads(Path(store).read_text(encoding="utf-8"))
    return data if isinstance(data, list) else data.get("events", [])


def event_names(store: Path = DEFAULT_STORE) -> list[str]:
    return [e.get("name", "") for e in _events(store)]


def build(store: Path, name: str) -> dict[str, Any]:
    """The manifest `generate_week` expects, for the stored event called `name`."""
    for event in _events(store):
        if event.get("name") == name:
            break
    else:
        raise KeyError(
            f"no stored event called {name!r}. Returning an empty manifest here "
            f"would run a whole week against nothing and bill for it, which "
            f"reads as a quiet event rather than a wrong name.")

    stored_shoot = event.get("shootType", "")
    if stored_shoot not in SHOOT_TYPES:
        raise ValueError(
            f"{stored_shoot!r} is not a shoot type this knows how to send. Add "
            f"it alongside ShootType.pythonValue rather than defaulting, or the "
            f"generators will describe an evening Dan did not attend.")

    date = (REFERENCE_DATE + datetime.timedelta(seconds=event["date"])).date()

    days: dict[str, Any] = {}
    for day, stored in (event.get("days") or {}).items():
        photos = [as_path(p) for p in (stored.get("photoPaths") or [])]
        if not photos:
            continue
        entry: dict[str, Any] = {"photos": photos}
        if stored.get("tagHandles"):
            entry["tag_handles"] = stored["tagHandles"]
        if stored.get("nameMentions"):
            entry["name_mentions"] = stored["nameMentions"]
        if stored.get("notes"):
            entry["notes"] = stored["notes"]
        tags = {as_path(k): v for k, v in (stored.get("photoTags") or {}).items() if v}
        if tags:
            entry["photo_tags"] = tags
        days[day] = entry

    manifest: dict[str, Any] = {
        "event": event["name"],
        "org": event.get("org", ""),
        "venue": event.get("venue", ""),
        "venue_context": event.get("venueContext", "") or "",
        "date": date.isoformat(),
        "shoot_type": SHOOT_TYPES[stored_shoot],
        "program": event.get("ocrResult") or {},
        "days": days,
    }

    wednesday = (event.get("days") or {}).get("wednesday", {}).get("photoPaths")
    if wednesday:
        manifest["caption_context_photos"] = {
            "wednesday": [as_path(p) for p in wednesday]}
    if event.get("blogPhotoPaths"):
        manifest["blog_photos"] = [as_path(p) for p in event["blogPhotoPaths"]]
    if event.get("eventURL"):
        manifest["event_url"] = event["eventURL"]
    return manifest


def referenced_media(manifest: dict[str, Any]) -> list[str]:
    """Every file the manifest names, day photos and blog photos alike.

    One shared predicate behind both the count and the verdict about it (L16).
    The listing used to count day photos and report missing files out of a
    larger population that also held the blog photos, so an event with 39 day
    photos and 12 blog photos read as "39 photos, 51 missing": more missing than
    it has.
    """
    referenced = [p for day in manifest.get("days", {}).values()
                  for p in day.get("photos", [])]
    return referenced + list(manifest.get("blog_photos", []))


def missing_media(manifest: dict[str, Any]) -> list[str]:
    """Every file the manifest names that is not on disk.

    Checked before a paid run rather than during one: most stored events have
    had their media reclaimed, and finding that out halfway through costs the
    calls already made.
    """
    return [p for p in referenced_media(manifest) if not Path(p).exists()]


def describe(manifest: dict[str, Any]) -> str:
    """One line saying whether this event can still be run, and on what."""
    total = len(referenced_media(manifest))
    gone = len(missing_media(manifest))
    if not total:
        state = "no media referenced"
    elif gone == total:
        state = "media reclaimed"
    elif gone:
        state = f"{gone} missing"
    else:
        state = "all media present"
    return f"{total:4d} files   {state}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--store", default=str(DEFAULT_STORE))
    parser.add_argument("--list", action="store_true",
                        help="the events the store holds, and whether their media survives")
    parser.add_argument("--event")
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    store = Path(args.store)

    if args.list:
        for name in event_names(store):
            try:
                manifest = build(store, name)
            except ValueError as exc:
                print(f"{name[:40]:42s} unreadable: {exc}")
                continue
            print(f"{name[:40]:42s} {describe(manifest)}")
        return 0

    if not args.event or not args.out:
        parser.error("--event and --out are required unless --list is given")

    manifest = build(store, args.event)
    gone = missing_media(manifest)
    Path(args.out).write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    photos = sum(len(d["photos"]) for d in manifest["days"].values())
    print(f"{manifest['event']}: {len(manifest['days'])} days, {photos} photos, "
          f"{len(manifest.get('blog_photos', []))} blog photos, {manifest['date']}")
    if gone:
        print(f"WARNING: {len(gone)} referenced file(s) are not on disk, "
              f"starting with {gone[0]}")
        return 1
    print(f"written to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
