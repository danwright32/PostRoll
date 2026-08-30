"""Whether this shard of the guard sweep still has anything to prove (#989).

The full sweep re-proved all 433 registry entries on every push to main. Over
the two weeks to 2026-08-30 that was 3,079 of this repository's 6,207 macOS
runner-minutes, 50% of them, on a job nobody waits for: it runs after the merge,
and the entries the merge touched were already proved on the pull request by the
`changed` job. GitHub allows five concurrent macOS runners and this repository
asks for six per pull request, so those minutes came out of the queue every
pull request sits in: median wall clock 22.4 minutes against a longest single
job of 11.1 minutes.

The cadence is a daily schedule now, and this is what makes a daily schedule
cost nothing on a quiet day: it is the first step of each shard, and the rest of
that shard's steps run only if it says to.

## The four answers, and why three of them run

    ALREADY_PROVED     this exact tree, this shard, proved recently  → skip
    TREE_NOT_PROVED    nothing has proved this tree on this shard    → run
    PROOF_IS_STALE     the tree is proved but the proof is old       → run
    HISTORY_UNREADABLE the run history could not be asked            → run

Only the first skips. The failure direction that costs money is a sweep that
runs when it could have skipped; the direction that costs coverage is a sweep
that skips when it should have run, and that one is silent (L98). So every
answer that is not a positive proof runs the sweep and says which it was, in
its own words, because a shared message would leave the reader unable to tell a
broken query from a real one (L11).

## Why staleness runs an unchanged tree

The reason #551 gave the sweep a schedule at all. These proofs depend on things
no commit here touches: the macos-26 runner image, the Xcode that
`PostRollApp/.ci-xcode-version` pins, and Homebrew packages. Any of those can
move with no commit, so an unchanged tree is not an unchanged proof. The
unconditional window below is what the separate weekly cron used to be, folded
into the same decision so there is one rule rather than two cadences that have
to agree (L41).
"""

from __future__ import annotations

import argparse
import enum
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from tools.guard_sweep_history import (  # noqa: E402
    HistoryUnreadable, Sweep, sweeps_at, recent_sweeps)

#: How long a proof stands before the sweep runs whatever the tree says. This is
#: the weekly cron #551 added, expressed as an age instead of a second schedule.
UNCONDITIONAL_AFTER = timedelta(days=7)


class Due(enum.Enum):
    ALREADY_PROVED = "already proved"
    TREE_NOT_PROVED = "tree not proved"
    PROOF_IS_STALE = "proof is stale"
    HISTORY_UNREADABLE = "history unreadable"


@dataclass(frozen=True)
class Decision:
    due: Due
    message: str

    @property
    def run(self) -> bool:
        return self.due is not Due.ALREADY_PROVED


def decide(*, sha: str, shard: int, history: list[Sweep] | None,
           now: datetime, unconditional_after: timedelta = UNCONDITIONAL_AFTER,
           ) -> Decision:
    """What this shard should do about `sha`.

    `history` is None when it could not be read, which is a different fact from
    an empty history and must not be able to arrive as one (L119). `now` is
    injected so a test can pin both ends of the age comparison rather than one
    (L130).
    """
    if shard < 1:
        raise ValueError(f"shard {shard} is not a shard of anything")
    where = f"shard {shard} at {sha[:12]}"

    if history is None:
        return Decision(Due.HISTORY_UNREADABLE, (
            f"The guard sweep's run history could not be read, so whether "
            f"{where} has already been proved is unknown. Running the sweep: a "
            "query that failed must never pass for a proof that succeeded."))

    #: A run whose stamp could not be parsed is no evidence either way, so it is
    #: dropped here rather than compared. Dropping it can only make this run the
    #: sweep, never skip it.
    dated = [s for s in history if s.created_at is not None]

    proved_here = [s for s in dated
                   if s.head_sha == sha and shard in s.passed_shards]
    if not proved_here:
        return Decision(Due.TREE_NOT_PROVED, (
            f"Nothing has proved {where}, so the sweep runs. A run that carries "
            "this commit but skipped or failed its proof step is not a proof."))

    newest = max(s.created_at for s in dated if s.passed_shards)
    age = now - newest
    if age > unconditional_after:
        days = int(age.total_seconds() // 86400)
        return Decision(Due.PROOF_IS_STALE, (
            f"{where} was proved, but the newest guard proof of any tree is "
            f"{days} days old, past the {unconditional_after.days} day window. "
            "The runner image, the pinned Xcode and Homebrew packages all move "
            "with no commit here, so an unchanged tree is not an unchanged "
            "proof (#551). Running the sweep."))

    return Decision(Due.ALREADY_PROVED, (
        f"{where} was already proved by run {proved_here[0].run_id} and the "
        "newest proof is inside the window, so this shard has nothing to do."))


def _head_sha() -> str:
    recorded = os.environ.get("GITHUB_SHA")
    if recorded:
        return recorded
    done = subprocess.run(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT,
                          capture_output=True, text=True, check=False)
    return done.stdout.strip()


def _history(sha: str, repo: str | None, run_id: int | None,
             window: timedelta) -> list[Sweep] | None:
    """Runs at this commit, plus enough recent ones to age the newest proof.

    Two queries rather than one because they answer two different questions and
    a single window cannot serve both: the tree's own proof may be older than
    any page of recent runs, and the newest proof of ANY tree is what the
    staleness window is about.
    """
    try:
        at_sha = sweeps_at(sha, repo=repo, skip_run_id=run_id)
        recent = recent_sweeps(repo=repo, skip_run_id=run_id)
    except HistoryUnreadable as exc:
        print(f"the guard sweep history could not be read: {exc}")
        return None
    seen: dict[int, Sweep] = {s.run_id: s for s in at_sha + recent}
    return list(seen.values())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--shard", type=int, required=True)
    parser.add_argument("--sha", default=None)
    parser.add_argument("--repo", default=None)
    parser.add_argument("--window-days", type=int,
                        default=UNCONDITIONAL_AFTER.days)
    parser.add_argument("--output", default=os.environ.get("GITHUB_OUTPUT"),
                        help="where to write due=true|false for later steps")
    args = parser.parse_args(argv)

    sha = args.sha or _head_sha()
    if not sha:
        # Refusing to answer about a commit nobody named, rather than answering
        # about whatever the default scope happens to be (L320).
        print("::warning::no commit to ask about, so the sweep runs")
        decision = Decision(Due.HISTORY_UNREADABLE,
                            "no commit sha was available, so the sweep runs")
    else:
        window = timedelta(days=args.window_days)
        run_id = int(os.environ.get("GITHUB_RUN_ID") or 0) or None
        decision = decide(sha=sha, shard=args.shard,
                          history=_history(sha, args.repo, run_id, window),
                          now=datetime.now(timezone.utc),
                          unconditional_after=window)

    print(decision.message)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write(f"### Guard sweep, shard {args.shard}\n\n"
                     f"{decision.message}\n")
    if args.output:
        with open(args.output, "a", encoding="utf-8") as fh:
            fh.write(f"due={'true' if decision.run else 'false'}\n")
            fh.write(f"reason={decision.due.value}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
