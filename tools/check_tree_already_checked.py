"""Whether this exact tree already had this check succeed on a pull request (#990).

`tests.yml` and `swift.yml` run on a push to main as well as on a pull request.
Every one of the 60 most recent commits on main is a squash merge made by
`tools/wait_for_checks.py --merge`, which refuses a head that does not contain
main (exit 6, #680) and merges the exact commit it judged. A squash of a head
containing its base produces the head's tree byte for byte, so those jobs
re-run the pull request's checks against an identical tree.

Measured over the last 24 pushes to main on 2026-08-30, as job medians: 481s
for `Tests / macos`, 434s for `macOS / swift-unit`, 130 to 170s for each of the
three `reference-frames` shards and 206s for `Tests / python`. That is 23 macOS
runner-minutes per merge, at 33 merges in the week to 2026-08-30. GitHub allows
five concurrent macOS runners and a pull request here asks for six, so those
minutes come out of the queue every pull request sits in.

The premise was measured rather than assumed: over the 25 most recent merges,
each had exactly one associated pull request and the merged tree matched that
pull request's head tree in 25 of 25 cases.

## The six answers, and why five of them run

    ALREADY_CHECKED        this tree, this check, green on the pull request → skip
    NO_PULL_REQUEST        nothing associates this commit with one          → run
    SEVERAL_PULL_REQUESTS  more than one, so which proved it is unclear     → run
    TREE_DIFFERS           there is a pull request and its tree is not this → run
    CHECK_NOT_GREEN        this check did not succeed on that head          → run
    HISTORY_UNREADABLE     the association could not be asked               → run

Only the first skips. The failure direction that costs money is a job that runs
when it could have skipped; the one that costs coverage is a job that skips when
it should have run, and that one is silent (L98). Each answer says which it was
in its own words, because a shared message leaves a reader unable to tell a
broken query from a real one (L11).

An EMPTY association in particular is never a pass. GitHub's commit-to-pull-
request association is a derived index that can be missing or stay permanently
incomplete, and a missing entry is indistinguishable from a commit that really
had no pull request (L119).

## Why a step and not a job

A new job is a new CHECK NAME, and `tools/wait_for_checks.py` derives the bar a
pull request has to clear from these workflow files, calibrated against a
recorded reply from a real green pull request. Adding a name means a run
carrying it can only be green once the fixture already holds it, so there is no
green run to record from and breaking the loop costs a knowingly red merge
(L48). The guard sweep's gate is a step for the same reason (#989).

## Why the duration series had to change with it

A gated job that skips still checks out, asks this gate and exits successful in
under a minute. That is a positive duration, so `tools/check_job_durations.py`
would read it as the job having become fast and the series would hold two
populations decided by the week's merge pattern (L102, L331). The jobs this
gate can skip therefore end with a step named `WORK_STEP`, and the series drops
any job carrying that step which did not actually run it. It is one shared name
across every gated job rather than a per-workflow table somebody has to
remember to extend (L96).
"""

from __future__ import annotations

import argparse
import enum
import json
import os
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Mapping

REPO_ROOT = Path(__file__).resolve().parent.parent

#: The step every gated job ends with, so a job that skipped its work can be
#: told from one that did it. Read by `tools/check_job_durations.py`; a job with
#: no step by this name is unaffected, which is what lets one name serve every
#: workflow.
WORK_STEP = "Confirm this job ran its checks"

#: The step id the workflows give this gate, and the exact condition every
#: gated step asks. One definition, because two readers need it: the guard that
#: holds the wiring together and the parser in
#: `tests/test_golden_drift_is_reported.py` that has to subtract this clause
#: before working out which shards a step selects (L41).
#:
#: `!= 'false'` and never `== 'true'`. The gate is deliberately absent on a
#: pull request, so an absent answer has to RUN the work; equality would invert
#: that and skip it, silently, on the path the merge is judged by (L72).
GATE_ID = "already"
ASKS_THE_GATE = f"steps.{GATE_ID}.outputs.run != 'false'"

#: How long a proof stands before the job runs whatever the tree says (#1075).
#:
#: A tree is not the only input to these checks. The runner image, the Xcode
#: `PostRollApp/.ci-xcode-version` pins, ffmpeg and Homebrew packages all move
#: with no commit here, so an unchanged tree is not an unchanged result. Before
#: the gate, the post-merge run met the new environment; with it, nothing does
#: until somebody opens the next pull request.
#:
#: One day rather than the guard sweep's seven (`UNCONDITIONAL_AFTER` in
#: `tools/check_guard_sweep_due.py`), because the two are protecting different
#: gaps. The sweep's window is how long a proof of an unchanged tree stays
#: meaningful in absolute terms. This one is the gap between a pull request's
#: run and the merge that lands it, which is normally minutes: a pull request
#: still merging a day later is exactly the case worth re-running, and the cost
#: of being wrong is one job that need not have run.
UNCONDITIONAL_AFTER = timedelta(days=1)

#: The one conclusion that is a proof. Everything else runs the job, including
#: `skipped`, which is what this gate itself produces: reading one as a proof
#: would latch the gate off permanently, each merge finding the last merge's
#: skip and skipping again, green throughout (L98, L106).
GREEN = "success"


def _spoken(span: timedelta) -> str:
    """A duration a person reads, rather than a float of seconds."""
    hours = span.total_seconds() / 3600
    if hours >= 48:
        return f"{int(hours // 24)} days"
    return f"{int(hours)} hours" if hours >= 2 else f"{int(span.total_seconds() // 60)} minutes"


class HistoryUnreadable(Exception):
    """The association could not be read, which is not the same as it being
    empty. Never allowed to collapse into an empty list (L119)."""


class Answer(enum.Enum):
    ALREADY_CHECKED = "already checked"
    NO_PULL_REQUEST = "no pull request"
    SEVERAL_PULL_REQUESTS = "several pull requests"
    TREE_DIFFERS = "tree differs"
    CHECK_NOT_GREEN = "check not green"
    PROOF_IS_STALE = "proof is stale"
    HISTORY_UNREADABLE = "history unreadable"


@dataclass(frozen=True)
class PullRequest:
    """One pull request associated with the commit being asked about."""

    number: int
    head_sha: str
    #: The tree its head points at. This, not the head sha, is what a squash
    #: merge preserves.
    tree_sha: str
    #: Check run name to conclusion, lowercased. A name that is absent never
    #: ran; it is not the same as one that ran and concluded nothing, and both
    #: run the job.
    checks: Mapping[str, str]
    #: When the named check finished on this head. None when it could not be
    #: read, which is treated as stale rather than as fresh: an unreadable value
    #: landing on the permissive side of an age comparison is the one way a
    #: check reports healthy for a reason unrelated to the truth (L50).
    checked_at: datetime | None = None


@dataclass(frozen=True)
class Decision:
    answer: Answer
    message: str

    @property
    def run(self) -> bool:
        return self.answer is not Answer.ALREADY_CHECKED


def decide(*, tree: str, check: str, pulls: list[PullRequest] | None,
           now: datetime,
           unconditional_after: timedelta = UNCONDITIONAL_AFTER) -> Decision:
    """What this job should do about a commit whose tree is `tree`.

    `pulls` is None when the association could not be read, which is a different
    fact from an empty list and must not be able to arrive as one (L119). `now`
    is injected so a test pins both ends of the age comparison rather than one
    (L130).
    """
    if not tree:
        raise ValueError(
            "asked whether a tree was already checked without naming a tree, "
            "which cannot be answered about anything (L320)")
    if not check:
        raise ValueError(
            "asked whether a tree was already checked without naming a check, "
            "and 'some check passed' is not a proof that this job's did")

    short = tree[:12]

    if pulls is None:
        return Decision(Answer.HISTORY_UNREADABLE, (
            f"The pull requests for this commit could not be read, so whether "
            f"{check!r} already passed on tree {short} is unknown. It runs: a "
            "query that failed must never pass for a proof that succeeded."))

    if not pulls:
        return Decision(Answer.NO_PULL_REQUEST, (
            f"No pull request is associated with this commit, so nothing says "
            f"{check!r} has passed on tree {short} before. It runs. An empty "
            "association reads the same whether the commit had no pull request "
            "or the index simply does not hold it yet (L119)."))

    if len(pulls) > 1:
        numbers = ", ".join(f"#{p.number}" for p in sorted(
            pulls, key=lambda p: p.number))
        return Decision(Answer.SEVERAL_PULL_REQUESTS, (
            f"This commit is associated with more than one pull request "
            f"({numbers}), so which of them proved tree {short} is not settled "
            f"and {check!r} runs. Many matches is a refusal here, not an "
            "absence (L521)."))

    pull = pulls[0]
    if pull.tree_sha != tree:
        return Decision(Answer.TREE_DIFFERS, (
            f"Pull request #{pull.number} is associated with this commit, but "
            f"its head {pull.head_sha[:12]} carries tree "
            f"{pull.tree_sha[:12]} and this commit carries {short}, so what it "
            f"proved is not what is here. {check!r} runs."))

    concluded = str(pull.checks.get(check, "")).lower()
    if concluded != GREEN:
        was = f"concluded {concluded!r}" if concluded else "never ran"
        return Decision(Answer.CHECK_NOT_GREEN, (
            f"Pull request #{pull.number} carries this exact tree {short}, but "
            f"the check {check!r} {was} on its head, so nothing has proved this "
            f"tree against it. It runs."))

    # Asked LAST, after the tree and the check, on purpose. A stale reading
    # about the wrong tree is not staleness, and reporting it as such would send
    # a reader looking at the runner image for what is really a different
    # commit (L11).
    age = None if pull.checked_at is None else now - pull.checked_at
    if age is None or age > unconditional_after:
        when = ("its finish time could not be read"
                if age is None
                else f"it finished {_spoken(age)} ago, past the "
                     f"{_spoken(unconditional_after)} window")
        return Decision(Answer.PROOF_IS_STALE, (
            f"Pull request #{pull.number} carries this exact tree {short} and "
            f"{check!r} succeeded on its head, but {when}. The runner image, "
            "the pinned Xcode and Homebrew packages all move with no commit "
            "here, so an unchanged tree is not an unchanged result (#1075). "
            "It runs."))

    return Decision(Answer.ALREADY_CHECKED, (
        f"Pull request #{pull.number} carries this exact tree {short} and "
        f"{check!r} succeeded on its head {pull.head_sha[:12]} "
        f"{_spoken(age)} ago, so this job would re-run a check that has "
        "already passed on identical content. Skipping its work."))


# ── reading the answer out of GitHub ─────────────────────────────────────────

def _gh_json(path: str):
    done = subprocess.run(["gh", "api", path], cwd=REPO_ROOT,
                          capture_output=True, text=True, check=False)
    if done.returncode != 0:
        raise HistoryUnreadable(
            f"gh api {path} exited {done.returncode}: "
            f"{done.stderr.strip()[:300]}")
    try:
        return json.loads(done.stdout)
    except json.JSONDecodeError as broken:
        raise HistoryUnreadable(
            f"gh api {path} did not return JSON ({broken})") from None


def _when(stamp: object) -> datetime | None:
    """One API timestamp, or None when it cannot be read.

    Never defaulted to now. An unreadable stamp landing on the permissive side
    of the age comparison would report a proof as fresh for a reason unrelated
    to the truth (L50).
    """
    try:
        return datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


def _checks_on(sha: str) -> tuple[dict[str, str], dict[str, datetime | None]]:
    """The newest conclusion and finish time for each check run name on `sha`.

    Newest wins because that is what GitHub itself shows and what a re-run after
    a red check means. A run still in flight has no conclusion, so it lands here
    as the empty string and is not a proof.
    """
    reply = _gh_json(f"repos/{{owner}}/{{repo}}/commits/{sha}"
                     "/check-runs?per_page=100")
    runs = reply.get("check_runs")
    if not isinstance(runs, list):
        raise HistoryUnreadable(
            f"the check runs for {sha[:12]} came back without a list")
    newest: dict[str, tuple[str, str, datetime | None]] = {}
    for run in runs:
        name = str(run.get("name") or "")
        if not name:
            continue
        started = str(run.get("started_at") or "")
        if name not in newest or started >= newest[name][0]:
            newest[name] = (started,
                            str(run.get("conclusion") or "").lower(),
                            _when(run.get("completed_at")))
    return ({name: c for name, (_, c, _f) in newest.items()},
            {name: f for name, (_, _c, f) in newest.items()})


def pulls_for(sha: str, check: str) -> list[PullRequest]:
    """Every pull request GitHub associates with `sha`, with its head's tree.

    `check` names which check run's finish time to carry, because staleness is
    asked about THIS job's proof rather than about the pull request as a whole.
    """
    associated = _gh_json(
        f"repos/{{owner}}/{{repo}}/commits/{sha}/pulls?per_page=100")
    if not isinstance(associated, list):
        raise HistoryUnreadable(
            f"the pull requests for {sha[:12]} came back without a list")

    found = []
    for pull in associated:
        head = ((pull.get("head") or {}).get("sha")) or ""
        number = pull.get("number")
        if not head or not isinstance(number, int):
            raise HistoryUnreadable(
                "a pull request associated with this commit named no head sha "
                "or no number, so it cannot be compared against anything")
        commit = _gh_json(f"repos/{{owner}}/{{repo}}/commits/{head}")
        tree = ((commit.get("commit") or {}).get("tree") or {}).get("sha") or ""
        if not tree:
            raise HistoryUnreadable(
                f"the head {head[:12]} of #{number} reported no tree sha")
        conclusions, finished = _checks_on(head)
        found.append(PullRequest(number=number, head_sha=head, tree_sha=tree,
                                 checks=conclusions,
                                 checked_at=finished.get(check)))
    return found


def _tree_here(sha: str | None) -> str:
    what = f"{sha}^{{tree}}" if sha else "HEAD^{tree}"
    done = subprocess.run(["git", "rev-parse", what], cwd=REPO_ROOT,
                          capture_output=True, text=True, check=False)
    return done.stdout.strip() if done.returncode == 0 else ""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--check", required=True,
                        help="the check run name this job publishes")
    parser.add_argument("--sha", default=os.environ.get("GITHUB_SHA") or None)
    parser.add_argument("--output", default=os.environ.get("GITHUB_OUTPUT"),
                        help="where to write checked=true|false for later steps")
    args = parser.parse_args(argv)

    tree = _tree_here(args.sha)
    if not tree:
        # Refusing to answer about a tree nobody could name, rather than
        # answering about whatever git happened to have (L320).
        decision = Decision(Answer.HISTORY_UNREADABLE, (
            "this commit's tree could not be read from git, so whether "
            f"{args.check!r} has already passed on it is unknown. It runs."))
    else:
        try:
            pulls = pulls_for(args.sha or "HEAD", args.check)
        except HistoryUnreadable as unreadable:
            print(f"the pull request association could not be read: "
                  f"{unreadable}")
            pulls = None
        decision = decide(tree=tree, check=args.check, pulls=pulls,
                          now=datetime.now(timezone.utc))

    print(decision.message)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### {args.check}\n\n{decision.message}\n")
    if args.output:
        with open(args.output, "a", encoding="utf-8") as handle:
            handle.write(f"run={'true' if decision.run else 'false'}\n")
            handle.write(f"reason={decision.answer.value}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
