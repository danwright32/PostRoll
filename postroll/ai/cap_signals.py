"""Recognise a subscription usage cap in a CLI failure, and admit when we cannot.

Dan's decision (#211) is that hitting a cap STOPS the week and asks him rather
than spending anything further. #206 built the halt; this decides when to pull
it.

**These patterns are uncalibrated.** The issue is explicit that the signal must
be observed rather than taken from documentation, and no real subscription cap
has been hit yet: it is not something that can be triggered on demand. So this
ships in the only honest shape available.

* A failure matching a known cap signal halts the week.
* A failure matching nothing is NOT quietly treated as ordinary. It is recorded
  verbatim, so the first real cap this app meets leaves behind the exact text
  needed to fix these patterns, rather than being swallowed and spent.
* An unknown failure does NOT halt. Stopping a week that had nothing wrong with
  it costs Dan an evening, and an unknown failure is far more likely to be a
  blip than a cap.

`CALIBRATED` stays False until a real cap has been seen and the patterns are
checked against it. Activation is tracked on #211 so the observe-only state
cannot quietly become permanent.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

#: False until a real subscription cap has been observed and these patterns
#: checked against its actual text. A guard that has never seen the thing it
#: matches is a hypothesis, and saying so is the difference between a reader
#: trusting it and a reader verifying it.
CALIBRATED = False

#: Specific on purpose. A false positive halts a week that was fine.
_CAP_PATTERNS = (
    re.compile(r"usage limit reached", re.I),
    re.compile(r"reached your usage limit", re.I),
    re.compile(r"\b\d+\s*-?\s*hour limit reached", re.I),
    re.compile(r"rate limit exceeded for your (?:plan|subscription)", re.I),
)

#: Ordinary, retryable trouble. Named separately so it can never be confused
#: with a cap, in either direction.
_TRANSIENT_PATTERNS = (
    re.compile(r"\b5\d\d\b"),
    re.compile(r"overloaded", re.I),
    re.compile(r"connection (?:reset|refused|aborted)", re.I),
    re.compile(r"timed? ?out", re.I),
)

_RESET_PATTERNS = (
    re.compile(r"reset(?:s|ting)?(?: at)?\s+([0-9]{1,2}(?::[0-9]{2})?\s*(?:am|pm))", re.I),
    re.compile(r"reset(?:s|ting)?(?: at)?\s+([0-9]{1,2}:[0-9]{2})", re.I),
)


@dataclass(frozen=True)
class Signal:
    #: "cap" | "transient" | "unknown"
    kind: str
    detail: str
    resets_at: str | None = None


def _find_reset(text: str) -> str | None:
    for pattern in _RESET_PATTERNS:
        m = pattern.search(text)
        if m:
            return m.group(1).strip()
    return None


def _record(text: str, path: Path) -> None:
    """Keep an unrecognised failure so the next attempt is not another guess.

    Never raises: this runs on a failure path and must not add a second one.
    """
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"text": text[:4000]}, ensure_ascii=False) + "\n")
    except OSError as e:
        print(f"warning: could not record unrecognised failure: {e}",
              file=sys.stderr, flush=True)


def default_record_path() -> Path:
    from .usage_log import default_log_path

    return default_log_path().parent / "unrecognised-failures.jsonl"


def unrecognised(path: Path | str | None = None) -> list[str]:
    """Failures recorded because nothing could classify them (#217).

    The file was write-only: `_record` appended to it so the first real
    subscription cap would leave its exact wording behind for calibration, and
    then nothing read it, surfaced it, or prompted anyone to look. A cap cannot
    be triggered on demand, so there is one cheap chance to capture the real
    text, and a write-only file is precisely how that chance gets missed.

    Never raises: this is read on the way out of a run that may already have
    gone wrong.
    """
    target = Path(path) if path is not None else default_record_path()
    try:
        lines = target.read_text(encoding="utf-8").splitlines()
    except OSError:
        return []
    out: list[str] = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            # A half-written line is still evidence something happened.
            out.append(line)
            continue
        text = entry.get("text")
        out.append(text if isinstance(text, str) else line)
    return out


def report_unrecognised(path: Path | str | None = None) -> str | None:
    """A message naming what was recorded, or None when there is nothing.

    Deliberately repeats on every run while the file has contents. This is the
    one artifact that turns CALIBRATED from a hypothesis into a fact, so being
    mildly annoying until somebody deals with it is the point.
    """
    entries = unrecognised(path)
    if not entries:
        return None
    target = Path(path) if path is not None else default_record_path()
    header = (
        f"{len(entries)} failure(s) could not be classified as a usage cap or as "
        f"ordinary trouble, and were recorded at {target}."
    )
    if not CALIBRATED:
        header += (
            " The cap patterns are still uncalibrated, so if any of these IS a "
            "real cap, its wording is what calibrates them. Check it, update "
            "_CAP_PATTERNS, then set CALIBRATED = True and clear the file."
        )
    quoted = "\n".join(f"  - {e[:200]}" for e in entries[:5])
    if len(entries) > 5:
        quoted += f"\n  ... and {len(entries) - 5} more"
    return header + "\n" + quoted


def classify(text: str, *, record_to: Path | str | None = None,
             announce: bool = False) -> Signal:
    """What kind of failure this is, as far as we can currently tell."""
    text = text or ""

    for pattern in _CAP_PATTERNS:
        m = pattern.search(text)
        if m:
            return Signal("cap", f"matched '{m.group(0)}' in: {text[:300]}",
                          _find_reset(text))

    for pattern in _TRANSIENT_PATTERNS:
        m = pattern.search(text)
        if m:
            return Signal("transient", f"matched '{m.group(0)}' in: {text[:300]}")

    target = Path(record_to) if record_to is not None else default_record_path()
    _record(text, target)
    if announce:
        print(
            "warning: did not recognise this failure as either a usage cap or "
            f"ordinary trouble, so the run continues: {text[:200]}",
            file=sys.stderr, flush=True,
        )
    return Signal("unknown", text[:300])


def should_halt(signal: Signal) -> bool:
    """Only a recognised cap stops the week.

    An unknown failure deliberately does not. Halting on anything we do not
    understand would turn every new error string into a cancelled evening, and
    unknown failures are far more often blips than caps.
    """
    return signal.kind == "cap"
