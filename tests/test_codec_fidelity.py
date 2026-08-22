"""#818: telling a render that moved by codec fidelity from one that moved by design.

`tests/test_media_design_fingerprint.py` offers two outcomes when a template's
source moves, and #811 was neither: dropping `-preset veryfast` from the clip
reel's last encode moved 0.27% of its pixels, which fails the reference frame,
while the two frames are indistinguishable side by side. The version bump was
the only door left, and a bump badges every cached asset of that template as out
of date, which is a false alarm for a change nobody can see (L36).

So there is a third outcome, and the whole of it rests on being able to tell the
two apart from the evidence a comparison already produces. These hold the
thresholds to the readings they were chosen from: every entry in
`MEASURED_SHAPES` was taken by rendering a real template against its committed
reference frame, never by painting pixels into a synthetic one (L48).

A threshold that stops separating them fails here rather than reading as a
current fact in a comment (L32).
"""

from __future__ import annotations

import pytest

from golden_drift import (
    CODEC_MAX_FILL,
    CODEC_MEDIAN_DELTA,
    MEASURED_SHAPES,
    Reading,
    why_it_is_not_codec_fidelity,
)


def reading_of(entry) -> Reading:
    what, _, changed, total, box, median = entry
    return Reading(name=what, changed=changed, total=total, box=box,
                   median_delta=median)


@pytest.mark.parametrize("entry", MEASURED_SHAPES, ids=lambda e: e[0])
def test_every_measured_reading_is_read_the_way_it_was_taken(entry):
    """The whole table, each entry against the verdict it has to get.

    Both directions in one check, because the thresholds are only worth
    anything while they separate the two populations: one that accepted every
    codec reading and refused nothing would pass a test written only over the
    codec half.
    """
    what, is_codec = entry[0], entry[1]
    reason = why_it_is_not_codec_fidelity(reading_of(entry))

    if is_codec:
        assert reason is None, (
            f"{what} was measured on a render whose design did not change and "
            f"is being refused: {reason}. A codec change refused costs a design "
            f"version bump, which badges every cached asset of that template.")
    else:
        assert reason is not None, (
            f"{what} is a design change and is being waved through as codec "
            f"fidelity, so its reference frame could be re-recorded with the "
            f"staleness badge left off and every cached asset left rendering "
            f"the old look. That is what the fingerprint guard exists to stop.")


def test_the_table_holds_both_kinds():
    """The control for the check above (L159).

    A table that had drifted to one kind would make the parametrised check pass
    while proving only that the verdict says one thing.
    """
    kinds = {entry[1] for entry in MEASURED_SHAPES}

    assert kinds == {True, False}, (
        f"MEASURED_SHAPES carries only {kinds}, so the check over it can only "
        f"prove the verdict answers one way")


def test_each_threshold_is_the_only_thing_refusing_some_reading():
    """No condition is decoration, and neither can be dropped.

    Not merely "each fires on something": each has to be the ONLY thing
    refusing some real reading, because a condition whose every case the other
    one also catches is uncalibrated and could be deleted with nothing noticing,
    while it goes on reading as protection (L182). A third condition, on how
    much of the canvas the box covers, was measured and dropped for failing
    exactly this.

    The two readings that make it true are worth naming. Two elements a screen
    apart each moved one pixel stretches the box between them and its fill
    collapses to 0.83%, sparser than an encoder, so only amplitude refuses it.
    Type recoloured in place moves each pixel by 8, which is what an encoder
    does, so only fill refuses it.
    """
    alone = {"amplitude": [], "fill": []}
    for entry in MEASURED_SHAPES:
        if entry[1]:
            continue
        reading = reading_of(entry)
        by_amplitude = reading.median_delta > CODEC_MEDIAN_DELTA
        by_fill = reading.fill > CODEC_MAX_FILL
        if by_amplitude and not by_fill:
            alone["amplitude"].append(entry[0])
        if by_fill and not by_amplitude:
            alone["fill"].append(entry[0])

    for condition, readings in alone.items():
        assert readings, (
            f"every design reading the {condition} threshold refuses is refused "
            f"by the other one too, so nothing measured needs it. Either it is "
            f"uncalibrated and should go, or the reading it exists for has "
            f"never been taken.")


def test_a_reading_with_no_amplitude_is_refused_rather_than_read():
    # A line written before #818 carries no median. That is not "the pixels
    # barely moved", it is "nobody measured", and reading one as the other
    # would wave through the case with no evidence at all (L98).
    reading = Reading(name="clip_reel", changed=7189, total=2073600,
                      box=(0, 127, 1080, 1903), median_delta=None)

    reason = why_it_is_not_codec_fidelity(reading)

    assert reason is not None and "amplitude" in reason, reason


def test_a_frame_that_did_not_move_is_not_a_codec_change():
    # `getbbox()` answers None when nothing is set. Nothing moved is not a
    # codec change to be recorded; it is the other door entirely.
    reading = Reading(name="story", changed=0, total=2073600, box=None,
                      median_delta=0)

    reason = why_it_is_not_codec_fidelity(reading)

    assert reason is not None and "nothing changed" in reason, reason


def test_the_thresholds_sit_between_the_two_populations():
    """The margins, said as numbers rather than left to the parametrised pass.

    Each threshold is measured against the codec readings on one side and the
    design readings IT is responsible for on the other, which is not every
    design reading: two elements a screen apart fill 0.83% of the stretched box
    between them, sparser than an encoder, and it is amplitude that has to catch
    that one. Anchoring the fill ceiling on it would be anchoring it on a
    reading it was never meant to separate (L209).

    A new measurement that closes one of these gaps asks for the threshold to be
    chosen again rather than letting it drift (L172).
    """
    codec = [reading_of(e) for e in MEASURED_SHAPES if e[1]]
    design = [reading_of(e) for e in MEASURED_SHAPES if not e[1]]
    #: The design readings each threshold is the only refusal for.
    amplitude_must_catch = [r for r in design if r.fill <= CODEC_MAX_FILL]
    fill_must_catch = [r for r in design if r.median_delta <= CODEC_MEDIAN_DELTA]

    assert amplitude_must_catch and fill_must_catch, (
        "one of the thresholds has nothing of its own to catch, so the margins "
        "below would be measured against readings the other one already covers")

    assert max(r.median_delta for r in codec) * 2 <= CODEC_MEDIAN_DELTA
    assert CODEC_MEDIAN_DELTA * 2 <= min(r.median_delta for r in amplitude_must_catch)
    assert max(r.fill for r in codec) * 1.5 <= CODEC_MAX_FILL
    assert CODEC_MAX_FILL * 1.5 <= min(r.fill for r in fill_must_catch)
