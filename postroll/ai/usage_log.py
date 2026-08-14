"""What the metered path actually costs, per call and per week (#207).

Every AI call in the app funnels through one SDK call in `claude_client`, so
that is where usage is recorded. Each record is one JSON line: model, tokens,
the step that spent them, and the event it was spent on.

Two rules shape this file, and both exist because a cost report that is quietly
wrong is worse than no report:

* An UNPRICED model is never folded in at zero. It is counted separately and
  the summary reports itself as incomplete. Zero would under-report the bill
  hardest in exactly the case where somebody changed the model, which is when
  the number matters most.
* An UNREADABLE line is counted, not skipped. A dropped line is
  indistinguishable from a call that never happened.

Accounting must never take down a paid-for generation, so `record` reports a
write failure to its caller and to stderr rather than raising.
"""

from __future__ import annotations

import json
import os
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Re-exported rather than defined: this was `base_model`'s home before #361
# moved it somewhere `page_regions` can share it. `usage_log.base_model` stays
# a working name so callers and tests do not have to care.
from .model_ids import base_model  # noqa: F401

#: Published list prices, US dollars per million tokens, keyed by base model id.
#: Source: Anthropic model pricing table as of 2026-06-24. Update alongside any
#: model change; an id missing here reports as unpriced rather than free.
_LIST_PRICES: dict[str, tuple[float, float]] = {
    "claude-fable-5":    (10.00, 50.00),
    "claude-mythos-5":   (10.00, 50.00),
    "claude-opus-5":     (5.00, 25.00),
    "claude-opus-4-8":   (5.00, 25.00),
    "claude-opus-4-7":   (5.00, 25.00),
    "claude-opus-4-6":   (5.00, 25.00),
    "claude-opus-4-5":   (5.00, 25.00),
    "claude-sonnet-5":   (3.00, 15.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-sonnet-4-5": (3.00, 15.00),
    "claude-haiku-4-5":  (1.00, 5.00),
}


@dataclass(frozen=True)
class PriceEra:
    """A price table and the instant it came into force.

    History is stamped at write time, and reading a past period must read that
    period's state rather than the live present (L37, #484). `summarize` used
    to reprice everything from one live table, so a legitimate price change
    retroactively rewrote what every past week had cost, and there was no way
    to ask what a given month came to.
    """

    effective_from: datetime
    prices: dict[str, tuple[float, float]]


def _utc(text: str) -> datetime:
    return datetime.fromisoformat(text)


#: Every price table this app has billed against, oldest first.
#:
#: The first era's date is the log's own beginning rather than a real pricing
#: announcement: nothing older than it exists, and refusing to price the oldest
#: records would silently shrink every historical total.
#:
#: The sonnet-5 introductory rate is recorded as its own era, from the note
#: this file already carried: $2.00 / $10.00 through 2026-08-31, list rate
#: after. The app pins sonnet-4-6, so no real number moves either way; what it
#: buys is that the mechanism is exercised rather than shipped as a single era
#: nobody has ever seen work (L65).
PRICE_ERAS: list[PriceEra] = [
    PriceEra(
        effective_from=_utc("2026-01-01T00:00:00+00:00"),
        prices={**_LIST_PRICES, "claude-sonnet-5": (2.00, 10.00)},
    ),
    PriceEra(
        effective_from=_utc("2026-09-01T00:00:00+00:00"),
        prices=dict(_LIST_PRICES),
    ),
]

#: What a call made RIGHT NOW costs. One spelling, derived from the eras rather
#: than kept beside them, because two tables that must agree drift and the one
#: that drifts is the one nothing reads (L41).
PRICES_USD_PER_MTOK: dict[str, tuple[float, float]] = PRICE_ERAS[-1].prices

#: Cache reads bill at roughly a tenth of the input rate; writes at 1.25x.
CACHE_READ_MULTIPLIER = 0.1
CACHE_WRITE_MULTIPLIER = 1.25

_A_MILLION = 1_000_000


@dataclass(frozen=True)
class Usage:
    """One SDK response's token counts."""

    model: str
    input_tokens: int
    output_tokens: int
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0


@dataclass
class Totals:
    calls: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float = 0.0


@dataclass
class Summary:
    calls: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float = 0.0
    #: Calls whose model has no published price here. Their tokens ARE counted;
    #: their dollars are not, because we do not know them.
    unpriced_calls: int = 0
    #: Lines that could not be read as a usage record (a crash mid-append, a
    #: hand edit, a partial write).
    unreadable_lines: int = 0
    by_step: dict[str, Totals] = field(default_factory=dict)

    @property
    def complete(self) -> bool:
        """False when `cost_usd` is missing money it cannot account for."""
        return self.unpriced_calls == 0 and self.unreadable_lines == 0


def prices_in_force(at: datetime | None, eras: list[PriceEra] | None = None) -> dict[str, tuple[float, float]]:
    """The price table that applied at `at`.

    A record from before the earliest recorded era is priced at that earliest
    era. Nothing older exists to price it with, and refusing would drop the
    oldest calls out of every total, which is the same silent shrinkage this
    whole change is about.
    """
    table = eras if eras is not None else PRICE_ERAS
    if at is None:
        return table[-1].prices
    chosen = table[0].prices
    for era in table:
        if era.effective_from <= at:
            chosen = era.prices
    return chosen


def cost_usd(usage: Usage, *, at: datetime | None = None,
             eras: list[PriceEra] | None = None) -> float | None:
    """Dollars for one call, or None when the model has no published price.

    `at` is when the call was made. Omitted, it prices at today's rate, which
    is right for a call being recorded now and wrong for one being read back
    out of history, so `summarize` always passes it.
    """
    price = prices_in_force(at, eras).get(base_model(usage.model))
    if price is None:
        return None
    per_in, per_out = price
    billable_input = (
        usage.input_tokens
        + usage.cache_read_tokens * CACHE_READ_MULTIPLIER
        + usage.cache_write_tokens * CACHE_WRITE_MULTIPLIER
    )
    return (billable_input * per_in + usage.output_tokens * per_out) / _A_MILLION


def default_log_path() -> Path:
    """Where the app's usage log lives.

    POSTROLL_DATA_DIR is exported by the Swift app from `AppPaths.root`, so the
    log always sits beside the rest of the app's data. The fallback is the
    post-migration data root, for CLI and test runs launched by hand.
    """
    override = (os.environ.get("POSTROLL_DATA_DIR") or "").strip()
    if override:
        return Path(override) / "usage.jsonl"
    return (
        Path.home() / "Library" / "Application Support" / "PostRoll" / "usage.jsonl"
    )


def record(
    usage: Usage,
    *,
    step: str,
    event: str | None = None,
    path: Path | str | None = None,
) -> bool:
    """Append one call to the usage log. Returns False if it could not be written.

    Never raises: a generation that has already been paid for must not die
    because its bookkeeping failed. The failure is still reported, both to the
    caller and on stderr, so the resulting total is known to be short.
    """
    target = Path(path) if path is not None else default_log_path()
    if event is None:
        # One Python process handles one event, so the app exports it once
        # rather than every call site threading it through.
        event = (os.environ.get("POSTROLL_EVENT") or "").strip() or None
    line = {
        "model": usage.model,
        "step": step,
        "event": event,
        # When it happened, in UTC, so the same week reads the same on any Mac
        # and history can be priced at the rate that was in force (#484, L37,
        # L39).
        "at": datetime.now(timezone.utc).isoformat(),
        "input_tokens": usage.input_tokens,
        "output_tokens": usage.output_tokens,
        "cache_read_tokens": usage.cache_read_tokens,
        "cache_write_tokens": usage.cache_write_tokens,
        "cost_usd": cost_usd(usage),
    }
    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(line, ensure_ascii=False) + "\n")
    except OSError as e:
        print(
            f"warning: could not write AI usage record for {step}: {e}. "
            "The spend total will be short by this call.",
            file=sys.stderr,
            flush=True,
        )
        return False
    return True


def _parse(line: str) -> dict[str, Any] | None:
    """A usage record, or None when the line cannot be trusted as one.

    A record missing its token counts is NOT read as a zero-cost call: that
    would let a partial write total as free.
    """
    try:
        data = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    for key in ("input_tokens", "output_tokens"):
        if not isinstance(data.get(key), int):
            return None
    if not isinstance(data.get("model"), str):
        return None
    return data


def _recorded_at(data: dict[str, Any]) -> datetime | None:
    """When a record says it was written, or None when it does not say.

    Every line already on disk predates the stamp, so None is an ordinary
    answer rather than a failure, and `prices_in_force` prices it at the
    earliest era rather than dropping it.
    """
    raw = data.get("at")
    if not isinstance(raw, str) or not raw.strip():
        return None
    try:
        parsed = datetime.fromisoformat(raw.strip())
    except ValueError:
        return None
    # A stamp with no zone cannot be compared against the eras, which carry
    # one. Read as UTC, which is what `record` writes.
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def summarize(
    *, path: Path | str | None = None, event: str | None = None
) -> Summary:
    """Total the log, optionally scoped to one event."""
    target = Path(path) if path is not None else default_log_path()
    summary = Summary()
    if not target.exists():
        return summary

    try:
        lines = target.read_text(encoding="utf-8").splitlines()
    except OSError as e:
        print(f"warning: could not read {target}: {e}", file=sys.stderr, flush=True)
        summary.unreadable_lines = 1
        return summary

    for raw in lines:
        if not raw.strip():
            continue
        data = _parse(raw)
        if data is None:
            summary.unreadable_lines += 1
            continue
        if event is not None and data.get("event") != event:
            continue

        summary.calls += 1
        summary.input_tokens += data["input_tokens"]
        summary.output_tokens += data["output_tokens"]

        step = str(data.get("step") or "unknown")
        bucket = summary.by_step.setdefault(step, Totals())
        bucket.calls += 1
        bucket.input_tokens += data["input_tokens"]
        bucket.output_tokens += data["output_tokens"]

        # Repriced from the recorded tokens rather than trusting the stored
        # dollar figure, so a correction to a price table applies to history
        # too, but priced AT THE RATE THAT WAS IN FORCE, so a genuine price
        # change does not rewrite what past weeks cost (#484).
        priced = cost_usd(
            Usage(
                model=data["model"],
                input_tokens=data["input_tokens"],
                output_tokens=data["output_tokens"],
                cache_read_tokens=int(data.get("cache_read_tokens") or 0),
                cache_write_tokens=int(data.get("cache_write_tokens") or 0),
            ),
            at=_recorded_at(data),
        )
        if priced is None:
            summary.unpriced_calls += 1
            continue
        summary.cost_usd += priced
        bucket.cost_usd += priced

    return summary


def format_summary(summary: Summary) -> str:
    """A plain-language report, for the CLI and for the app to surface."""
    lines = [
        f"{summary.calls} AI call(s), "
        f"{summary.input_tokens:,} in / {summary.output_tokens:,} out tokens",
        f"Cost: ${summary.cost_usd:,.2f}"
        + ("" if summary.complete else "  (INCOMPLETE, see below)"),
    ]
    for step, totals in sorted(
        summary.by_step.items(), key=lambda kv: -kv[1].cost_usd
    ):
        lines.append(
            f"  {step}: {totals.calls} call(s), ${totals.cost_usd:,.2f}"
        )
    if summary.unpriced_calls:
        lines.append(
            f"  {summary.unpriced_calls} call(s) used a model with no price on "
            "record, so their cost is NOT in the total above."
        )
    if summary.unreadable_lines:
        lines.append(
            f"  {summary.unreadable_lines} log line(s) could not be read, so "
            "their cost is NOT in the total above."
        )
    return "\n".join(lines)


if __name__ == "__main__":  # pragma: no cover - operator entry point
    import argparse

    ap = argparse.ArgumentParser(description="Report recorded AI spend.")
    ap.add_argument("--path", default=None, help="usage log (default: app data dir)")
    ap.add_argument("--event", default=None, help="scope to one event")
    ns = ap.parse_args()
    print(format_summary(summarize(path=ns.path, event=ns.event)))
