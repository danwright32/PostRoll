"""One record of what things cost, with the provenance of every reading (#1090).

`tools/record_test_durations.py` grew this shape for test FILES and #1090 needs
the same thing for guard registry ENTRIES: a map of name to seconds, plus a map
saying which RUN each reading came from and what it was scaled by, so readings
taken under different load are not silently mixed (L224, #1038).

Shared rather than cloned, because the second copy is the one that quietly
drifts: a refusal added to one and not the other leaves the other accepting a
reading the rule was written to stop (L41, L263). The wording of each refusal
takes the NOUN it is about, so a message about guard entries does not say
"file".

Every disagreement here is a REFUSAL rather than a 1.0. A scale of 1.0 is the
positive claim that this run matched the record's run, and that is precisely
what a run with nothing to compare against cannot know (L11, L98).
"""

from __future__ import annotations

import statistics

class Provenance:
    """How each recorded reading was taken, so a mixed record is visible.

    The record used to be a bare map of file to seconds, and nothing in it said
    which RUN each number came from. A full re-record takes every reading in one
    run, so they are all comparable; a hand-merged file is a reading from a
    different run under different load, and mixing the two silently is what
    #1038 is about (L224).
    """

    @staticmethod
    def full(run: str, names) -> dict[str, dict]:
        """Every file measured in one run, so nothing needed scaling."""
        return {name: {"run": run, "scale": 1.0} for name in sorted(names)}


def scale_from(recorded: dict[str, float],
               measured: dict[str, float],
               noun: str = "file") -> float:
    """How much to multiply this run's readings by to land in the record's run.

    `recorded` is what the record holds for the REFERENCE files, and `measured`
    is what this run made of the same ones. The answer is the MEDIAN of their
    ratios, because the spread is wide: measured on 2026-08-31 over seven
    references it ran 0.16 to 3.57, which is the contention this whole issue is
    about, and a median survives one reference having a bad run.

    Every disagreement below is a REFUSAL rather than a 1.0. A scale of 1.0 is
    the positive claim that this run matched the record's run, and that is
    precisely what a run with nothing to compare against cannot know (L11, L98).
    """
    if not measured:
        raise SystemExit(
            f"this run measured no reference {noun}, so there is no scale to put "
            "its readings on and no way to tell a fast machine from a slow "
            "one. Nothing was written.")

    strangers = sorted(set(measured) - set(recorded))
    if strangers:
        raise SystemExit(
            f"these were measured as references and are not in the record: "
            f"{strangers}. A {noun} the record has never seen cannot say how "
            "this run compares to it. Nothing was written.")

    absent = sorted(set(recorded) - set(measured))
    if absent:
        raise SystemExit(
            f"these references did not run: {absent}. A reference that "
            "skipped measures as free, and scaling against the ones that did "
            "run would quietly narrow what the median is taken over. Nothing "
            "was written.")

    ratios = []
    for name, seconds in sorted(measured.items()):
        if seconds <= 0:
            raise SystemExit(
                f"the reference {name} measured 0s in this run, so its ratio "
                "against the record is infinite and would be applied to "
                "whatever is being added. Nothing was written.")
        ratios.append(recorded[name] / seconds)
    return statistics.median(ratios)


def added(record: dict, measured: dict[str, float], run: str,
          noun: str = "file") -> dict:
    """`record` with the newly measured names added, scaled into its own run.

    `measured` holds both the new files and the reference files, as one run
    produces them. The ones the record already knows are the references and are
    what the scale comes from; the rest are what is being added.

    The files already in the record KEEP the readings they had. Re-writing them
    from this run is what a full re-record does, and doing it here would move
    every share in the record for files nobody changed, which is the churn
    #1038 exists to avoid.
    """
    seconds = dict(record.get("seconds") or {})
    stamped = dict(record.get("measured") or {})

    references = {name: value for name, value in measured.items()
                  if name in seconds}
    scale = scale_from({name: seconds[name] for name in references},
                       references, noun=noun)

    for name, reading in sorted(measured.items()):
        if name in seconds:
            continue
        seconds[name] = round(reading * scale, 2)
        stamped[name] = {"run": run, "scale": round(scale, 3)}

    return {"seconds": dict(sorted(seconds.items())),
            "measured": dict(sorted(stamped.items()))}


