"""The reference-frame matrix is split by the measurement, not by a typed figure (#795).

`.github/workflows/swift.yml` fans the visual checks over three runners, and the
comment above the matrix explained the balance with numbers typed in by hand:
the legibility file 580s, the golden frames 221s, the program plate 40s, the
gallery alignment 5s, summing to 846s. They were measured once, before #512 and
before #753 changed what several of those files render, and by 2026-08-21 they
disagreed with the suite: the three heavy files were 31.7%, 21.2% and 17.3% of
the run, and the goldens shard carried five more files the comment never
mentioned.

There is a machine-readable record of what every test file costs now,
`tests/fixtures/test_file_durations.json`, written for #766 and read by
`tests/file_durations.py`. The shard balance is the other consumer of exactly
that measurement and it was not using it, so a hand-kept copy and a derived one
sat side by side, which is the drift #766 was about one level up (L41).

WHAT IS COMPARED. A shard's cost is the summed cost of its files. `-n auto`
inside a shard divides that across the runner's cores and `--dist worksteal`
(#783) decides how evenly, but neither moves work BETWEEN shards, which is what
the matrix decides and the only thing this measures. The job's wall clock is its
heaviest shard.

WHAT IS ALLOWED. The best any split can do is bounded below by two things: the
largest single file, because a file cannot be divided, and a perfect third of
the total. Today the first of those binds, and the current split reaches it
exactly: the heaviest shard IS `test_frame_legibility.py`, alone. So the check
is how far the heaviest shard sits above what a split could achieve, not how far
the three sit from each other, because three equal shards are impossible when
one file is a third of the work and demanding them would be demanding a
rebalance that does not exist.

The seconds themselves are not asserted. They are wall time under contention and
move with the machine (#766); the shares barely move at all, and a threshold in
seconds would fire on a busy laptop.
"""

from __future__ import annotations

from pathlib import Path

import ci_workflow
from file_durations import RECORD, shares

#: How far above the best achievable split the heaviest shard may sit.
#:
#: Chosen against what a rebalance would actually save, rather than picked round
#: (L172). Measured on the macOS run for main on 2026-08-21, the three shards
#: took 2m40s, 2m41s and 1m40s of wall clock, against local shares of 31.7%,
#: 28.8% and 17.3%, so a shard's share does track its wall clock closely enough
#: to reason in. The heaviest is 160s, of which about 16s is checkout, pip and
#: ffmpeg that no rebalance can remove.
#:
#: At 1.25 this fires once roughly 36s of wall clock is sitting there to be
#: recovered, which is worth a commit. Below it, moving files between runners
#: buys less than the noise between two runs of the same job.
MAX_ABOVE_BEST = 1.25


def matrix_costs() -> dict[str, float]:
    """Every file the matrix runs, and its share of the whole suite.

    Raises on a file the record has never measured rather than treating it as
    free. A missing file would otherwise be spread silently: the shard carrying
    it would look lighter than it is, which is the direction that hides an
    imbalance rather than inventing one (L98).
    """
    measured = shares()
    costs: dict[str, float] = {}
    for _, files in ci_workflow.shards():
        for path in files:
            name = Path(path).name
            if name not in measured:
                raise AssertionError(
                    f"{name} is run by the reference-frame matrix and is not in "
                    f"{RECORD.name}, so its cost is unknown and every balance "
                    "below is computed over part of the job. Re-record with "
                    "`make record-test-durations`.")
            costs[name] = measured[name]
    return costs


def shard_costs() -> list[tuple[str, float]]:
    """Each shard and what it costs, heaviest first."""
    costs = matrix_costs()
    return sorted(
        ((name, sum(costs[Path(p).name] for p in files))
         for name, files in ci_workflow.shards()),
        key=lambda pair: -pair[1])


def best_possible() -> float:
    """The lightest any shard's cost could be made, as a share of the suite.

    Two floors, and the binding one is whichever is larger. A file cannot be
    split across runners, so no arrangement beats the largest single file; and
    nothing beats dealing the total out in equal parts.
    """
    costs = matrix_costs()
    return max(max(costs.values()), sum(costs.values()) / len(ci_workflow.shards()))


def suggested_split() -> list[list[str]]:
    """A split to compare the current one against, longest file first.

    Greedy: hand each file, heaviest first, to whichever shard is lightest so
    far. Not guaranteed optimal, and it does not need to be: it is what the
    failure message offers as a starting point, and the check itself is against
    `best_possible()`, which no arrangement can beat.
    """
    costs = matrix_costs()
    bins: list[list[str]] = [[] for _ in ci_workflow.shards()]
    weights = [0.0] * len(bins)
    for name, cost in sorted(costs.items(), key=lambda kv: -kv[1]):
        lightest = weights.index(min(weights))
        bins[lightest].append(name)
        weights[lightest] += cost
    return bins


def test_the_matrix_and_the_record_are_both_really_there():
    """The control. Every check below is a ratio of measured shares, and a
    matrix read as empty or a record read as empty would make it vacuous."""
    costs = matrix_costs()

    assert len(ci_workflow.shards()) >= 2, (
        "the reference-frame job has fewer than two shards, so there is no "
        "split to balance")
    assert len(costs) >= 4, (
        f"the matrix runs only {sorted(costs)}, which is not this job")
    assert sum(costs.values()) > 0.1, (
        f"the matrix's files are {sum(costs.values()):.1%} of the recorded "
        "suite, which is too little to be the reference frames")


def test_the_heaviest_shard_is_close_to_the_best_a_split_could_do():
    """The job's wall clock is its heaviest shard.

    Measured against what a split COULD achieve rather than against the other
    shards. One file is a third of the work and cannot be divided, so three
    equal shards are not available and asking for them would ask for a rebalance
    that does not exist.
    """
    heaviest, cost = shard_costs()[0]
    floor = best_possible()

    assert cost <= floor * MAX_ABOVE_BEST, (
        f"the `{heaviest}` shard is {cost:.1%} of the suite and the best any "
        f"split could do is {floor:.1%}, which is {cost / floor:.2f}x. The "
        f"shards today are {[(n, f'{c:.1%}') for n, c in shard_costs()]}. "
        f"Greedy longest-first would give {suggested_split()}. Re-measure with "
        "`make record-test-durations` first, in case the record is what moved.")


def test_no_shard_is_empty_of_measured_work():
    """A shard costing nothing is a runner started for no reason.

    It bills a checkout, a pip install and an ffmpeg install, about 16s, and
    reports a green check that measured almost nothing (L98).
    """
    idle = [(name, f"{cost:.2%}") for name, cost in shard_costs() if cost <= 0.005]

    assert not idle, (
        f"these shards run almost no measured work: {idle}. Each one still pays "
        "for a runner and its setup, and a shard that measures nothing reports "
        "the same green as one that measured everything.")
