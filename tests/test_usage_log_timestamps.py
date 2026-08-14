"""#484: what a week cost is a fact about the past, not about today's prices.

Usage records carried no timestamp, and `summarize` deliberately repriced all
history from the LIVE price table. So a legitimate price change rewrote what
every past week cost, retroactively, and with no stamp there was no way to
price a record at the rate in force when it was spent, or to answer what a
given month cost at all.

History is stamped at write time (L37). Records about the past carry the
point-in-time attributes captured then, and reading a past period reads that
period's state rather than the live present.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import pytest

from postroll.ai import usage_log
from postroll.ai.usage_log import Usage, cost_usd, record, summarize


SONNET = "claude-sonnet-4-6"


def _usage(model: str = SONNET) -> Usage:
    return Usage(model=model, input_tokens=1_000_000, output_tokens=1_000_000)


# ── every record says when it happened ───────────────────────────────────────

def test_a_recorded_call_carries_the_instant_it_happened(tmp_path):
    log = tmp_path / "usage.jsonl"
    before = datetime.now(timezone.utc)

    assert record(_usage(), step="captions", event="E", path=log)

    line = json.loads(log.read_text().strip())
    assert "at" in line, f"the record has no timestamp: {line}"
    stamped = datetime.fromisoformat(line["at"])
    assert stamped.tzinfo is not None, "the stamp carries no zone, so it cannot be compared"
    assert before - timedelta(seconds=5) <= stamped <= datetime.now(timezone.utc) + timedelta(seconds=5)


def test_the_stamp_is_utc_so_two_machines_agree(tmp_path):
    log = tmp_path / "usage.jsonl"
    record(_usage(), step="captions", path=log)

    stamped = datetime.fromisoformat(json.loads(log.read_text().strip())["at"])
    assert stamped.utcoffset() == timedelta(0), (
        "the stamp is in local time, so the same week reads differently depending "
        "on where the Mac was"
    )


# ── history is priced at the rate that was in force ──────────────────────────

def test_a_price_era_is_used_rather_than_todays_table():
    era_start = datetime(2020, 1, 1, tzinfo=timezone.utc)
    cheap = {SONNET: (1.00, 2.00)}
    dear = {SONNET: (100.00, 200.00)}
    eras = [
        usage_log.PriceEra(effective_from=era_start, prices=cheap),
        usage_log.PriceEra(
            effective_from=datetime(2030, 1, 1, tzinfo=timezone.utc), prices=dear
        ),
    ]

    spent_then = cost_usd(_usage(), at=datetime(2025, 6, 1, tzinfo=timezone.utc), eras=eras)
    spent_now = cost_usd(_usage(), at=datetime(2031, 6, 1, tzinfo=timezone.utc), eras=eras)

    assert spent_then == pytest.approx(3.0)
    assert spent_now == pytest.approx(300.0)


def test_a_call_before_the_first_era_uses_the_first_era():
    # There is no rate recorded from before the log existed, and refusing to
    # price the oldest records would silently shrink every historical total.
    eras = [usage_log.PriceEra(
        effective_from=datetime(2030, 1, 1, tzinfo=timezone.utc),
        prices={SONNET: (1.00, 2.00)},
    )]

    assert cost_usd(_usage(), at=datetime(2020, 1, 1, tzinfo=timezone.utc),
                    eras=eras) == pytest.approx(3.0)


def test_an_unknown_model_is_still_unpriced_rather_than_free():
    assert cost_usd(Usage(model="something-else", input_tokens=1, output_tokens=1)) is None


def test_a_summary_prices_each_line_at_its_own_era(tmp_path, monkeypatch):
    log = tmp_path / "usage.jsonl"
    monkeypatch.setattr(usage_log, "PRICE_ERAS", [
        usage_log.PriceEra(effective_from=datetime(2020, 1, 1, tzinfo=timezone.utc),
                           prices={SONNET: (1.00, 1.00)}),
        usage_log.PriceEra(effective_from=datetime(2026, 9, 1, tzinfo=timezone.utc),
                           prices={SONNET: (10.00, 10.00)}),
    ])
    for stamp in ("2026-06-01T12:00:00+00:00", "2026-10-01T12:00:00+00:00"):
        log.open("a").write(json.dumps({
            "model": SONNET, "step": "captions", "event": "E", "at": stamp,
            "input_tokens": 1_000_000, "output_tokens": 0,
        }) + "\n")

    total = summarize(path=log).cost_usd

    assert total == pytest.approx(11.0), (
        f"expected 1.00 for the old call plus 10.00 for the new one, got {total}"
    )


def test_a_record_written_before_stamps_existed_still_prices(tmp_path, monkeypatch):
    # Every line already on Dan's disk has no `at`. Dropping them, or pricing
    # them at nothing, would silently shrink the history this exists to keep.
    log = tmp_path / "usage.jsonl"
    monkeypatch.setattr(usage_log, "PRICE_ERAS", [
        usage_log.PriceEra(effective_from=datetime(2020, 1, 1, tzinfo=timezone.utc),
                           prices={SONNET: (2.00, 2.00)}),
    ])
    log.write_text(json.dumps({
        "model": SONNET, "step": "captions", "event": "E",
        "input_tokens": 1_000_000, "output_tokens": 0,
    }) + "\n")

    summary = summarize(path=log)

    assert summary.calls == 1
    assert summary.cost_usd == pytest.approx(2.0)
    assert summary.unpriced_calls == 0


# ── the eras themselves stay sane ────────────────────────────────────────────

def test_the_shipped_eras_are_in_order():
    stamps = [era.effective_from for era in usage_log.PRICE_ERAS]

    assert stamps == sorted(stamps), (
        "the price eras are out of order, so a lookup walking them returns the "
        f"wrong table: {stamps}"
    )


def test_every_shipped_era_carries_prices():
    for era in usage_log.PRICE_ERAS:
        assert era.prices, f"the era starting {era.effective_from} prices nothing"


def test_the_live_table_is_the_newest_era():
    # Two spellings of "what a call costs today" would drift, and the one that
    # drifts is the one nothing reads (L41).
    assert usage_log.PRICES_USD_PER_MTOK == usage_log.PRICE_ERAS[-1].prices


def test_a_stamp_that_will_not_parse_is_counted_rather_than_guessed(tmp_path):
    # A hand edit or a half-written line makes the era unknowable, and a cost
    # report would rather be short and say so than carry a guessed figure.
    log = tmp_path / "usage.jsonl"
    log.write_text(json.dumps({
        "model": SONNET, "step": "captions", "event": "E", "at": "not a date",
        "input_tokens": 1_000_000, "output_tokens": 0,
    }) + "\n")

    summary = summarize(path=log)

    assert summary.unreadable_lines == 1
    assert summary.calls == 0
    assert summary.complete is False, (
        "a record whose era cannot be known was folded into a total that still "
        "reports itself as complete"
    )
