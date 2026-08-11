"""Judge the subscription path against the metered one, on the same work (#213).

The evidence for the subscription transport is two captions and three OCR runs
on one event, which the red team is right to call thin. This runs the SAME work
down both paths and reports what differs: the output, the wall clock, and what
each one spends.

Record and replay, not two independent runs
───────────────────────────────────────────
One metered pass captures the exact prompts a real week makes, and the
subscription pass replays those same prompts. Two separate generations would
differ in their inputs as well as their transports, and nothing would say which
caused a difference.

The capture patches `_run_sdk` and `_run_cli`, not `run_prompt`. Several modules
do `from .claude_client import run_prompt`, which binds the function into their
own namespace at import, so a recorder patching the attribute would miss those
calls entirely and hand back an empty capture that reads as a week where nothing
happened.

What this can and cannot compare
────────────────────────────────
The subscription transport routes through the Claude Code CLI, which cannot
attach images. Any call carrying photographs is REFUSED here rather than sent
with the images stripped, because a prompt that says "read this programme" with
no programme attached comes back with plausible text invented from nothing. So
the honest comparison covers the text-only steps, and the report says out loud
how much of the week that leaves out.

Usage
─────
    # free: what a week is made of, and how much of it the CLI could carry
    python -m tools.compare_transports inventory --capture capture.jsonl

    # paid: one metered pass over a real week, recording every call
    python -m tools.compare_transports record --manifest week.json \
        --capture capture.jsonl --i-accept-the-cost

    # replays the captured prompts on the subscription path and reports
    python -m tools.compare_transports replay --capture capture.jsonl \
        --report report.md --i-accept-the-cost
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from postroll.ai import usage_log  # noqa: E402
from postroll.ai.transport import SUBSCRIPTION_ENV  # noqa: E402


class NothingCaptured(RuntimeError):
    """A comparison was asked for and there is nothing in it.

    Its own error rather than an empty report, because zero captured calls
    arrives exactly when the run did not happen, which is the moment a clean
    verdict is most likely to be believed and acted on (L98).
    """


@dataclass(frozen=True)
class CallRecord:
    """One AI call, and what it cost to make it."""

    step: str
    model: str
    prompt: str
    image_count: int
    transport: str
    seconds: float
    output: str
    error: str | None = None

    @property
    def carries_images(self) -> bool:
        return self.image_count > 0

    @property
    def failed(self) -> bool:
        return self.error is not None


# ── recording a metered pass ─────────────────────────────────────────────────


class RecordingRunner:
    """Wraps the app's prompt runner and records every call it makes.

    Delegates rather than replaces: the run being measured has to be a real one,
    or the capture is of a week that never happened.

    `clock` and `sink` are injected so the tests can drive this with no wall
    clock and no API, and so that nothing here can reach a paid endpoint by
    accident (L2).
    """

    def __init__(self, inner: Callable[..., str],
                 clock: Callable[[], float] = time.monotonic,
                 sink: Callable[[CallRecord], None] | None = None):
        self._inner = inner
        self._clock = clock
        self._records: list[CallRecord] = []
        self._sink = sink if sink is not None else self._records.append

    @property
    def records(self) -> list[CallRecord]:
        return list(self._records)

    def __call__(self, prompt: str, **kwargs) -> str:
        step = kwargs.get("step", "unknown")
        model = kwargs.get("model", "unknown")
        images = len(kwargs.get("image_paths") or ())
        started = self._clock()
        try:
            output = self._inner(prompt, **kwargs)
        except Exception as exc:
            # Recorded BEFORE re-raising. A failed step left with no trace is
            # indistinguishable from one that was never attempted, so the run
            # would report as clean while having lost the work (L47).
            self._sink(CallRecord(
                step=step, model=model, prompt=prompt, image_count=images,
                transport="sdk", seconds=self._clock() - started, output="",
                error=str(exc)))
            raise
        self._sink(CallRecord(
            step=step, model=model, prompt=prompt, image_count=images,
            transport="sdk", seconds=self._clock() - started, output=output))
        return output


#: The functions every AI call ends up in, whichever public helper it entered
#: through. NOT `run_prompt`: `generate_blog` and `generate_captions` do
#: `from .claude_client import run_prompt`, which binds the function into their
#: own namespace at import, so a recorder patching the attribute on
#: `claude_client` would never see those calls and would report a clean empty
#: week. These two resolve as module globals inside `claude_client` itself, so
#: patching them catches every caller (L3: built is not wired).
SEAMS = ("_run_sdk", "_run_cli")


def install_recorder(claude_client, clock: Callable[[], float] = time.monotonic):
    """Patch the seams, returning (records, restore).

    The CLI seam takes no `step`, so a call that routes there is recorded
    against the transport that ran it and an unknown step rather than being
    given a step it did not carry.
    """
    records: list[CallRecord] = []
    originals = {name: getattr(claude_client, name) for name in SEAMS}

    def wrap(name, inner, transport):
        def recorded(prompt, **kwargs):
            started = clock()
            step = kwargs.get("step", "unknown")
            model = kwargs.get("model", "unknown")
            images = len(kwargs.get("image_paths") or ())
            try:
                output = inner(prompt, **kwargs)
            except Exception as exc:
                records.append(CallRecord(
                    step=step, model=model, prompt=prompt, image_count=images,
                    transport=transport, seconds=clock() - started, output="",
                    error=str(exc)))
                raise
            records.append(CallRecord(
                step=step, model=model, prompt=prompt, image_count=images,
                transport=transport, seconds=clock() - started, output=output))
            return output
        return recorded

    for name, transport in zip(SEAMS, ("sdk", "cli")):
        setattr(claude_client, name, wrap(name, originals[name], transport))

    def restore() -> None:
        for name, original in originals.items():
            setattr(claude_client, name, original)

    return records, restore


#: Why a call carrying photographs is not replayed on the subscription path.
IMAGES_REFUSED = (
    "the subscription transport runs through the Claude Code CLI, which cannot "
    "attach images; sending this prompt without its {n} image(s) would return "
    "text invented from nothing")


def replay(baseline: Sequence[CallRecord], runner: Callable[..., str],
           clock: Callable[[], float] = time.monotonic) -> list[CallRecord]:
    """Re-run each captured prompt on the other transport.

    A call carrying images is refused and recorded as refused, never sent with
    the images dropped and never quietly skipped.
    """
    out: list[CallRecord] = []
    for call in baseline:
        if call.carries_images:
            out.append(CallRecord(
                step=call.step, model=call.model, prompt=call.prompt,
                image_count=call.image_count, transport="cli", seconds=0.0,
                output="", error=IMAGES_REFUSED.format(n=call.image_count)))
            continue

        started = clock()
        try:
            output = runner(call.prompt, step=call.step, model=call.model)
            error = None
        except Exception as exc:
            output, error = "", str(exc)
        out.append(CallRecord(
            step=call.step, model=call.model, prompt=call.prompt,
            image_count=call.image_count, transport="cli",
            seconds=clock() - started, output=output, error=error))
    return out


# ── the report ───────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Row:
    """One step, on both paths."""

    step: str
    verdict: str          # identical | differs | refused | failed | missing
    identical: bool
    baseline_seconds: float
    candidate_seconds: float | None
    diff: str

    @property
    def seconds_delta(self) -> float | None:
        if self.candidate_seconds is None:
            return None
        return self.candidate_seconds - self.baseline_seconds


@dataclass(frozen=True)
class Report:
    rows: list[Row]
    baseline_seconds: float
    candidate_seconds: float
    calls_total: int
    calls_carrying_images: int

    @property
    def carried_share(self) -> float:
        """Fraction of the week's calls the subscription path could take."""
        if not self.calls_total:
            return 0.0
        return 1 - self.calls_carrying_images / self.calls_total


def _diff(before: str, after: str) -> str:
    return "\n".join(difflib.unified_diff(
        before.splitlines(), after.splitlines(),
        fromfile="metered", tofile="subscription", lineterm="", n=1))


def compare(baseline: Sequence[CallRecord],
            candidate: Sequence[CallRecord]) -> Report:
    """Both passes, step by step.

    Matched by position within a step name, so a step called more than once in a
    week lines up call for call rather than collapsing onto the first.
    """
    if not baseline:
        raise NothingCaptured(
            "there are no recorded calls to compare, which is what a run that "
            "never started looks like from here. Record a metered pass first.")

    remaining: dict[str, list[CallRecord]] = {}
    for call in candidate:
        remaining.setdefault(call.step, []).append(call)

    rows: list[Row] = []
    for call in baseline:
        queue = remaining.get(call.step) or []
        if not queue:
            rows.append(Row(call.step, "missing", False, call.seconds, None,
                            "the subscription pass never made this call"))
            continue
        other = queue.pop(0)

        if other.failed:
            verdict = "refused" if call.carries_images else "failed"
            rows.append(Row(call.step, verdict, False, call.seconds,
                            other.seconds, other.error or ""))
            continue

        identical = other.output == call.output
        rows.append(Row(
            call.step, "identical" if identical else "differs", identical,
            call.seconds, other.seconds,
            "" if identical else _diff(call.output, other.output)))

    return Report(
        rows=rows,
        baseline_seconds=sum(c.seconds for c in baseline),
        candidate_seconds=sum(c.seconds for c in candidate),
        calls_total=len(baseline),
        calls_carrying_images=sum(1 for c in baseline if c.carries_images),
    )


# ── what it will cost, before anything is spent ──────────────────────────────


@dataclass(frozen=True)
class Estimate:
    usd: float
    complete: bool
    unpriced: list[str] = field(default_factory=list)


def estimate_usd(calls: Sequence[CallRecord], tokens_per_call: int) -> Estimate:
    """A rough bill for running `calls` again, from the published prices.

    An unpriced model is counted separately and the estimate reports itself
    incomplete, never folded in at zero: zero would under-report the bill
    hardest in exactly the case where somebody changed the model, which is when
    the number matters most.
    """
    total = 0.0
    unpriced: list[str] = []
    for call in calls:
        prices = usage_log.PRICES_USD_PER_MTOK.get(usage_log.base_model(call.model))
        if prices is None:
            unpriced.append(call.model)
            continue
        # Split evenly between input and output, which is a guess and is
        # labelled as one wherever this is printed.
        input_usd, output_usd = prices
        total += (tokens_per_call / 2) / 1_000_000 * (input_usd + output_usd)
    return Estimate(usd=total, complete=not unpriced,
                    unpriced=sorted(set(unpriced)))


# ── persistence ──────────────────────────────────────────────────────────────


def write_capture(calls: Iterable[CallRecord], path: Path) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    written = 0
    # Written to a temp name and renamed, so an interrupted write cannot leave
    # a half capture that reads as a complete week (L5).
    tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        for call in calls:
            handle.write(json.dumps(asdict(call)) + "\n")
            written += 1
    os.replace(tmp, path)
    return written


def read_capture(path: Path) -> list[CallRecord]:
    calls: list[CallRecord] = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            calls.append(CallRecord(**json.loads(line)))
        except (json.JSONDecodeError, TypeError) as exc:
            # Reported, never skipped. A dropped line is indistinguishable from
            # a call that never happened.
            raise ValueError(f"{path}:{number} is not a call record: {exc}") from exc
    if not calls:
        raise NothingCaptured(f"{path} holds no calls")
    return calls


def format_report(report: Report) -> str:
    lines = [
        "# Subscription path against the metered path (#213)",
        "",
        f"- calls in the week: {report.calls_total}",
        f"- carrying images, so the subscription path cannot take them: "
        f"{report.calls_carrying_images}",
        f"- share the subscription path could carry: {report.carried_share:.0%}",
        f"- wall clock, metered: {report.baseline_seconds:.1f}s",
        f"- wall clock, subscription: {report.candidate_seconds:.1f}s",
        "",
        "| step | verdict | metered | subscription | delta |",
        "| --- | --- | --- | --- | --- |",
    ]
    for row in report.rows:
        candidate = "n/a" if row.candidate_seconds is None else f"{row.candidate_seconds:.1f}s"
        delta = "n/a" if row.seconds_delta is None else f"{row.seconds_delta:+.1f}s"
        lines.append(f"| {row.step} | {row.verdict} | {row.baseline_seconds:.1f}s "
                     f"| {candidate} | {delta} |")

    differing = [row for row in report.rows if row.verdict == "differs"]
    if differing:
        lines += ["", "## Where the output differs", ""]
        for row in differing:
            lines += [f"### {row.step}", "", "```diff", row.diff, "```", ""]
    return "\n".join(lines) + "\n"


# ── command line ─────────────────────────────────────────────────────────────


def _inventory(args) -> int:
    calls = read_capture(Path(args.capture))
    with_images = [c for c in calls if c.carries_images]
    estimate = estimate_usd(calls, tokens_per_call=args.tokens_per_call)

    print(f"{len(calls)} calls captured across {len({c.step for c in calls})} steps")
    print(f"{len(with_images)} carry images and cannot run on the subscription path")
    for step in sorted({c.step for c in with_images}):
        print(f"    {step}")
    marker = "" if estimate.complete else "  (INCOMPLETE, unpriced: "\
        f"{', '.join(estimate.unpriced)})"
    print(f"replaying the text-only calls would cost roughly "
          f"${estimate.usd:.2f} on the metered path{marker}")
    print("that figure assumes "
          f"{args.tokens_per_call} tokens a call, split evenly in and out; it "
          "is an order of magnitude, not a quote")
    return 0


def _record(args) -> int:
    if not args.i_accept_the_cost:
        print("this runs a real week on the METERED path and bills it. "
              "Re-run with --i-accept-the-cost to go ahead.")
        return 2

    from postroll.ai import claude_client
    from postroll.ai.generate_week import generate_week

    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    records, restore = install_recorder(claude_client)
    try:
        generate_week(manifest, Path(args.out))
    finally:
        restore()
        # Written whatever happened, so a run that died halfway still leaves the
        # calls it did make. A capture lost on failure is the work paid for
        # twice.
        written = write_capture(records, Path(args.capture))
        print(f"recorded {written} calls to {args.capture}")

    if not records:
        raise NothingCaptured(
            "the week ran and no AI call was recorded, which means the recorder "
            "is patched somewhere the app does not go through. Do not read this "
            "as a week with no AI in it.")
    return 0


def _replay(args) -> int:
    baseline = read_capture(Path(args.capture))
    if not args.i_accept_the_cost:
        estimate = estimate_usd(baseline, tokens_per_call=args.tokens_per_call)
        print(f"this would replay {len(baseline)} calls on Dan's Claude Code "
              f"allowance (roughly ${estimate.usd:.2f} of equivalent metered "
              f"spend). Re-run with --i-accept-the-cost to go ahead.")
        return 2

    from postroll.ai import claude_client

    previous = os.environ.get(SUBSCRIPTION_ENV)
    os.environ[SUBSCRIPTION_ENV] = "1"
    try:
        candidate = replay(baseline, runner=claude_client.run_prompt)
    finally:
        # The switch goes back whatever happened. A comparison run that left it
        # on would silently spend the allowance on every later generation.
        if previous is None:
            os.environ.pop(SUBSCRIPTION_ENV, None)
        else:
            os.environ[SUBSCRIPTION_ENV] = previous

    report = compare(baseline, candidate)
    Path(args.report).write_text(format_report(report), encoding="utf-8")
    print(format_report(report))
    print(f"written to {args.report}")
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--tokens-per-call", type=int, default=20_000,
                        help="rough size of one call, for the cost estimate")
    sub = parser.add_subparsers(dest="command", required=True)

    inv = sub.add_parser("inventory", help="what a captured week is made of (free)")
    inv.add_argument("--capture", required=True)
    inv.set_defaults(func=_inventory)

    rec = sub.add_parser("record", help="one metered pass over a real week (PAID)")
    rec.add_argument("--manifest", required=True)
    rec.add_argument("--capture", required=True)
    rec.add_argument("--out", default="output/comparison_week.json")
    rec.add_argument("--i-accept-the-cost", action="store_true")
    rec.set_defaults(func=_record)

    rep = sub.add_parser("replay", help="replay a capture on the subscription path")
    rep.add_argument("--capture", required=True)
    rep.add_argument("--report", default="transport_comparison.md")
    rep.add_argument("--i-accept-the-cost", action="store_true")
    rep.set_defaults(func=_replay)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
