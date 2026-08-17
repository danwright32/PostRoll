"""Wait for one commit's checks, and refuse to call an empty answer green.

#564. `gh pr checks <n>` reports nothing at all in the window between a push
and the checks being registered. Twice on 2026-08-14 a wait loop read that as
settled and green; trusting it would have merged a commit nothing had run
against. That is L98: finding zero subjects is indistinguishable from
everything passing, and the empty reply arrives exactly when the work has not
started, which is the moment a green verdict is most likely to be believed.

#669 is the same defect one push later, and gh cannot help with it at all: its
rows are keyed by workflow and check NAME, with no notion of which commit
produced them. Measured on #667 on 2026-08-17, three consecutive pushes each
reported `red: failed: Tests / python` within seconds, every one of them the
previous commit's run. The mirror is the dangerous half, a superseded run that
PASSED reporting green for a commit nothing has judged yet.

So this asks the Actions API about a SHA instead. The head commit is resolved
first and carried into every later question, every run and every job is checked
against it again on the way back, and a run still in flight is never green
(L173). Every line printed names the commit judged, so a green can be held up
against the commit about to be merged rather than trusted.

The fix for both is to know what the wait is waiting FOR. The expected checks are
derived from the workflow files rather than pinned here, so adding a job raises
the bar with no edit to this file: a hand-written list would only ever check
what somebody remembered to add, and the entries you remember are the ones
already safe (L96).

Exit codes, all distinct, because "green", "red" and "nothing ever showed up"
are three different things and only one of them may be merged on:

    0  green          every expected check settled, none failing
    1  red            an expected check failed, was cancelled, or skipped
                      where the workflow said it should run
    2  never appeared the deadline passed with an expected check absent
    3  still running  the deadline passed with everything present but pending
    4  unusable       gh could not be asked, or the workflows could not be read

Usage:

    python tools/wait_for_checks.py <pr-number> [--timeout 1800] [--interval 20]

Reads the workflows as text rather than parsing YAML, for the reason
`tests/test_ci_gates.py` gives: a YAML parser is not worth a runtime dependency
for this. The cost is that a rule written in a shape these patterns do not
match goes unread, so every such case RAISES here instead of being skipped. A
bar this cannot compute is not a bar of zero.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable, Sequence


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"

EXIT_GREEN = 0
EXIT_RED = 1
EXIT_NEVER_APPEARED = 2
EXIT_STILL_RUNNING = 3
EXIT_UNUSABLE = 4

#: The two job conditions this can classify. Anything else is refused rather
#: than guessed at, because a guessed bar reads as authoritative.
RUNS_ON_PULL_REQUEST = "github.event_name == 'pull_request'"
SKIPS_ON_PULL_REQUEST = "github.event_name != 'pull_request'"


class UnreadableWorkflow(Exception):
    """The workflows do not say what checks to expect, so there is no bar."""


class GhUnusable(Exception):
    """gh could not be asked. Distinct from gh answering "nothing yet"."""


@dataclass(frozen=True, order=True)
class ExpectedCheck:
    """One check GitHub will report on a pull request.

    Keyed on the workflow as well as the name, because two workflows may use
    one name: `macos` is a job in Tests, and `macOS` is a whole workflow. A bar
    keyed on the name alone would let one answer for the other (L70).
    """

    workflow: str
    name: str
    #: True where the job's own `if:` says it does not run on pull requests, so
    #: its skip is the workflow working rather than a job silently dropped.
    skips_on_pull_request: bool = False


@dataclass(frozen=True)
class Verdict:
    state: str  # "green" | "red" | "missing" | "running"
    failed: list[str] = field(default_factory=list)
    missing: list[ExpectedCheck] = field(default_factory=list)
    running: list[str] = field(default_factory=list)
    summary: str = ""


# ── deriving the bar from the workflows ───────────────────────────────────────


def _unwrap(value: str) -> str:
    """A quoted scalar's contents, leaving an unquoted one alone.

    Stripping quote characters off both ends instead would eat the closing
    quote of `github.event_name == 'pull_request'` and leave a condition this
    could no longer recognise.
    """
    text = value.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    return text


def _job_blocks(text: str) -> list[tuple[str, str]]:
    """Each job's key and body, body ending at the next two-space-indented key."""
    after = re.split(r"^jobs:[ \t]*$", text, maxsplit=1, flags=re.M)
    if len(after) != 2:
        return []
    found = re.findall(
        r"^  ([A-Za-z0-9_.-]+):[ \t]*$(.*?)(?=^  \S|\Z)", after[1], re.M | re.S)
    return [(key, body) for key, body in found]


def _triggers_on_pull_request(text: str) -> bool:
    block = re.search(r"^on:(.*?)(?=^\S|\Z)", text, re.M | re.S)
    if not block:
        return False
    head, body = block.group(0).split("\n", 1) if "\n" in block.group(0) else (
        block.group(0), "")
    if "pull_request" in head:
        return True
    return bool(re.search(r"^\s+pull_request:?", body, re.M))


def _under(text: str, header: str) -> tuple[str, str]:
    """The first line matching `header`, and everything nested beneath it.

    Nesting is decided by indentation rather than by a lookahead for the next
    key at the same depth, which is the difference between reading the matrix
    and reading the whole rest of the job: the steps that follow a matrix are
    indented LESS than its entries, so a lookahead for "same indent, non-space"
    never fires and the block runs to the end. That is how `shard.name` once
    expanded to include a step called "Set up Python".
    """
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if not re.match(header, line):
            continue
        depth = len(line) - len(line.lstrip())
        body: list[str] = []
        for following in lines[index + 1:]:
            if following.strip() and len(following) - len(following.lstrip()) <= depth:
                break
            body.append(following)
        return line, "\n".join(body)
    return "", ""


def _matrix_values(body: str, expression: str, job: str) -> list[str]:
    """The values a `${{ matrix.… }}` expression takes, expanded from the job.

    Only the two shapes this repo uses are understood. Anything else raises: a
    check name guessed wrong is worse than no check name, because the wait then
    blocks forever on a subject that will never appear.
    """
    parts = expression.split(".")
    if len(parts) not in (2, 3) or parts[0] != "matrix":
        raise UnreadableWorkflow(
            f"the {job!r} job's name interpolates {expression!r}, which this "
            "cannot expand from the matrix")

    _, matrix = _under(body, r"\s+matrix:[ \t]*$")
    if not matrix.strip():
        raise UnreadableWorkflow(
            f"the {job!r} job's name interpolates {expression!r} but the job "
            "declares no matrix, so the checks it produces cannot be listed")
    if re.search(r"^\s+(include|exclude):", matrix, re.M):
        raise UnreadableWorkflow(
            f"the {job!r} job's matrix uses include/exclude, which this cannot "
            "expand, so the checks it produces cannot be listed")

    key = parts[1]
    header, block = _under(matrix, rf"\s+{re.escape(key)}:[ \t]*(\[.*\])?[ \t]*$")
    if not header:
        raise UnreadableWorkflow(
            f"the {job!r} job's name interpolates {expression!r} but its matrix "
            f"declares no {key!r}, so the checks it produces cannot be listed")

    if len(parts) == 2:
        inline = re.search(r"\[(.*)\]", header)
        if inline:
            return [item.strip() for item in inline.group(1).split(",") if item.strip()]
        values = re.findall(r"^\s+-\s*([^\s#][^\n]*?)[ \t]*$", block, re.M)
        if not values:
            raise UnreadableWorkflow(
                f"the {job!r} job's matrix {key!r} lists no values")
        return values

    field_name = parts[2]
    values = re.findall(rf"^\s+-\s*{re.escape(field_name)}:[ \t]*(\S+)", block, re.M)
    if not values:
        raise UnreadableWorkflow(
            f"the {job!r} job's matrix {key!r} has no entries carrying "
            f"{field_name!r}, so {expression!r} cannot be expanded")
    return values


def _check_names(job: str, body: str) -> list[str]:
    """What GitHub will call this job's checks, one per matrix shard."""
    declared = re.search(r"^    name:[ \t]*(.+?)[ \t]*$", body, re.M)
    if not declared:
        return [job]

    template = _unwrap(declared.group(1))
    expressions = re.findall(r"\$\{\{\s*([^}]+?)\s*\}\}", template)
    if not expressions:
        return [template]
    if len(expressions) > 1:
        raise UnreadableWorkflow(
            f"the {job!r} job's name interpolates more than one matrix "
            "expression, which this cannot expand")

    values = _matrix_values(body, expressions[0], job)
    return [re.sub(r"\$\{\{[^}]+\}\}", value, template) for value in values]


def _skips_on_pull_request(job: str, body: str) -> bool:
    condition = re.search(r"^    if:[ \t]*(.+?)[ \t]*$", body, re.M)
    if not condition:
        return False
    text = " ".join(_unwrap(condition.group(1)).split())
    text = re.sub(r"^\$\{\{\s*|\s*\}\}$", "", text)
    if text == RUNS_ON_PULL_REQUEST:
        return False
    if text == SKIPS_ON_PULL_REQUEST:
        return True
    raise UnreadableWorkflow(
        f"the {job!r} job carries `if: {text}`, which this cannot classify. "
        "Teach it that condition rather than leaving the bar to a guess: a "
        "job wrongly expected to run blocks the wait forever, and one wrongly "
        "expected to skip is a check nobody waits for.")


def expected_checks(workflows: Path = WORKFLOWS) -> set[ExpectedCheck]:
    """Every check a pull request will report, derived from the workflow files."""
    files = sorted(
        path for path in workflows.glob("*.y*ml") if path.suffix in (".yml", ".yaml"))
    if not files:
        raise UnreadableWorkflow(
            f"no workflow files under {workflows}, so there is nothing to wait "
            "for. That is a failure rather than an empty bar: an empty bar "
            "makes every reply green, including no reply at all.")

    expected: set[ExpectedCheck] = set()
    for path in files:
        text = path.read_text(encoding="utf-8")
        if not _triggers_on_pull_request(text):
            continue
        titled = re.search(r"^name:[ \t]*(.+?)[ \t]*$", text, re.M)
        workflow = _unwrap(titled.group(1)) if titled else str(
            path.relative_to(workflows.parent.parent)
            if workflows.parent.parent in path.parents else path.name)
        jobs = _job_blocks(text)
        if not jobs:
            raise UnreadableWorkflow(
                f"{path.name} runs on pull requests but no jobs could be read "
                "out of it, so the bar silently drops by however many checks "
                "it produces and the wait reports green having waited for none "
                "of them")
        for job, body in jobs:
            skips = _skips_on_pull_request(job, body)
            for name in _check_names(job, body):
                expected.add(ExpectedCheck(workflow, name, skips))
    return expected


# ── asking about one commit ───────────────────────────────────────────────────


def gh_json(path: str) -> dict:
    """One `gh api` call, with "cannot ask" told apart from a real answer.

    Deliberately not `gh pr checks`. That command reports rows keyed by
    workflow and check NAME with no notion of which commit produced them (#669),
    so it answers about whatever GitHub last attached to the branch. Every path
    here names a SHA or a run id, so a reply that is about another commit can be
    recognised as one.
    """
    try:
        done = subprocess.run(
            ["gh", "api", "-H", "Accept: application/vnd.github+json", path],
            capture_output=True, text=True, check=False)
    except FileNotFoundError as error:
        raise GhUnusable("gh is not installed or not on PATH") from error

    body = done.stdout.strip()
    if done.returncode != 0 or not body:
        raise GhUnusable(
            f"gh api {path} exited {done.returncode}: "
            f"{(done.stderr.strip() or body)[:200] or '(silence)'}")
    try:
        reply = json.loads(body)
    except json.JSONDecodeError as error:
        raise GhUnusable(
            f"gh api {path} printed something that is not JSON ({error}): "
            f"{body[:200]!r}") from error
    if not isinstance(reply, dict):
        raise GhUnusable(
            f"gh api {path} returned {type(reply).__name__}, not an object")
    return reply


#: What a job's status and conclusion mean, in the vocabulary `verdict` judges.
#:
#: Listed rather than derived because it is GitHub's vocabulary, not ours, and
#: an entry missing from it must not quietly take a default: a word this has
#: never heard of is read as a failure, which is the side that stops a merge
#: rather than allowing one (L35, L113).
CONCLUSION_BUCKETS = {
    "success": "pass",
    "neutral": "pass",
    "skipped": "skipping",
    "cancelled": "cancel",
    "failure": "fail",
    "timed_out": "fail",
    "action_required": "fail",
    "startup_failure": "fail",
    "stale": "fail",
}


def bucket_of(status: str, conclusion: str | None) -> str:
    """One job's state, as a bucket."""
    if status != "completed":
        return "pending"
    return CONCLUSION_BUCKETS.get(conclusion or "", "fail")


@dataclass(frozen=True)
class Poll:
    """One reading of a pull request, about one commit and saying which.

    `unfinished` names the workflow runs at that commit which have not finished.
    It is part of the answer rather than a detail of it: every job a run has
    started can be listed and settled in the seconds the run spends finalising,
    and a green read there is a green for work still going on.
    """

    head_sha: str
    rows: list[dict] = field(default_factory=list)
    unfinished: list[str] = field(default_factory=list)


def _all_of(reply: dict, key: str, path: str) -> list[dict]:
    """Every item GitHub said it had, refusing a page that did not hold them.

    A short page is a smaller bar, and a smaller bar is a cheaper green.
    """
    items = reply.get(key) or []
    total = reply.get("total_count")
    if isinstance(total, int) and total != len(items):
        raise GhUnusable(
            f"gh api {path} said {total} {key} and sent {len(items)}, so the "
            "reply did not fit on one page and the bar this would judge "
            "against is incomplete")
    return list(items)


def poll_checks(number: str, *, api: Callable[[str], dict] = gh_json) -> Poll:
    """Every check at the pull request's head commit, and nothing from another.

    The head SHA is resolved first and then carried into every later question,
    so a run belonging to a superseded push cannot answer for this one. GitHub
    filters by `head_sha` server side; the SHA is checked again on each run and
    again on each job, because a check whose two sides come from one lookup can
    only prove that lookup is self-consistent (L70). A job carries its own
    `head_sha`, which is a second reply and therefore a second witness.
    """
    pull = api(f"repos/{{owner}}/{{repo}}/pulls/{number}")
    head_sha = str(((pull.get("head") or {}).get("sha") or ""))
    repo = str((((pull.get("base") or {}).get("repo") or {}).get("full_name") or ""))
    if not head_sha or not repo:
        raise GhUnusable(
            f"pull request {number} reported no head commit or no base "
            "repository, so there is no commit to ask about")

    runs_path = f"repos/{repo}/actions/runs?head_sha={head_sha}&per_page=100"
    runs = _all_of(api(runs_path), "workflow_runs", runs_path)

    rows: list[dict] = []
    unfinished: list[str] = []
    #: Newest run per workflow, so a re-run supersedes rather than doubles.
    latest: dict[str, dict] = {}
    for run in runs:
        if str(run.get("head_sha")) != head_sha:
            raise GhUnusable(
                f"the runs at {head_sha[:12]} include one at "
                f"{str(run.get('head_sha'))[:12]}, which is not an answer to "
                "the question asked")
        # The bar is derived from what a pull request triggers, so the rows
        # must be too: a workflow that also runs on push would otherwise report
        # its jobs twice at one commit, under names the bar holds once.
        if run.get("event") != "pull_request":
            continue
        name = str(run.get("name") or "")
        if int(run.get("id") or 0) >= int(latest.get(name, {}).get("id") or 0):
            latest[name] = run

    for name, run in sorted(latest.items()):
        if run.get("status") != "completed":
            unfinished.append(name)
        jobs_path = f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100"
        for job in _all_of(api(jobs_path), "jobs", jobs_path):
            if str(job.get("head_sha")) != head_sha:
                raise GhUnusable(
                    f"the job {job.get('name')!r} in run {run['id']} names "
                    f"commit {str(job.get('head_sha'))[:12]}, not the "
                    f"{head_sha[:12]} it was asked about")
            rows.append({
                "workflow": str(job.get("workflow_name") or name),
                "name": str(job.get("name") or ""),
                "bucket": bucket_of(str(job.get("status") or ""),
                                    job.get("conclusion")),
            })
    return Poll(head_sha=head_sha, rows=rows, unfinished=unfinished)


# ── judging it ────────────────────────────────────────────────────────────────


def _label(check: ExpectedCheck) -> str:
    return f"{check.workflow} / {check.name}"


def verdict(
    expected: Iterable[ExpectedCheck],
    reported: Sequence[dict],
    unfinished: Sequence[str] = (),
) -> Verdict:
    """One answer about a set of checks, with an empty reply never green."""
    rows = {(row.get("workflow", ""), row.get("name", "")): row for row in reported}

    failed: list[str] = []
    missing: list[ExpectedCheck] = []
    running: list[str] = []
    for check in sorted(expected):
        row = rows.get((check.workflow, check.name))
        if row is None:
            missing.append(check)
            continue
        bucket = str(row.get("bucket", "")).lower()
        if bucket in ("fail", "cancel"):
            failed.append(_label(check))
        elif bucket == "skipping" and not check.skips_on_pull_request:
            failed.append(_label(check))
        elif bucket == "pending":
            running.append(_label(check))

    if failed:
        state, summary = "red", "failed: " + ", ".join(failed)
    elif missing:
        state = "missing"
        summary = "never appeared: " + ", ".join(_label(check) for check in missing)
    elif running or unfinished:
        state = "running"
        parts = list(running) + [f"the {name} run has not finished"
                                 for name in unfinished]
        summary = "still running: " + ", ".join(parts)
    else:
        state, summary = "green", f"all {len(rows)} reported checks settled and green"
    return Verdict(state=state, failed=failed, missing=missing, running=running,
                   summary=summary)


# ── the wait ──────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Arguments:
    number: str
    timeout: float
    interval: float


def parse_arguments(argv: Sequence[str]) -> Arguments:
    """The pull request number and the two knobs, with unknown flags refused."""
    numbers = {"--timeout": 1800.0, "--interval": 20.0}
    positional: list[str] = []
    rest = list(argv)
    while rest:
        word = rest.pop(0)
        if word in numbers:
            if not rest:
                raise GhUnusable(f"{word} needs a number after it")
            try:
                numbers[word] = float(rest.pop(0))
            except ValueError as error:
                raise GhUnusable(f"{word} needs a number after it") from error
        elif word.startswith("--"):
            raise GhUnusable(f"unknown option {word}")
        else:
            positional.append(word)

    if len(positional) != 1:
        raise GhUnusable(
            "usage: wait_for_checks.py <pr-number> [--timeout 1800] "
            "[--interval 20]")
    return Arguments(positional[0], numbers["--timeout"], numbers["--interval"])


# How many times one poll is attempted before gh is called unusable, and how
# long to pause between attempts (#657).
#
# One momentary API error is not evidence that gh cannot be asked: an HTTP 503
# four minutes into a 2400 second wait ended a whole run, so a GitHub wobble
# cost a full restart, and during a real incident, which is exactly when a
# status is hardest to read by hand, the wait could never finish.
#
# Deliberately small and fixed. This retries the ASKING, never the verdict: a
# reply that arrives and says nothing usable is still answered by the same rules
# as before, and a failure that does not clear is still unusable, just seconds
# later instead of instantly. Retrying every failure rather than only the ones
# that look transient keeps this free of a second, message-matching classifier
# that would eventually disagree with itself (L35).
ASK_ATTEMPTS = 3
ASK_BACKOFF_SECONDS = (2.0, 4.0)


def ask(
    number: str,
    *,
    poll: Callable[[str], Poll],
    sleep: Callable[[float], None],
    out: Callable[[str], None],
) -> Poll:
    """One poll, retried a few times before gh is declared unusable.

    Each retry is said out loud, because a retry nobody can see is
    indistinguishable from a wait that has stalled (L106).
    """
    last: GhUnusable | None = None
    for attempt in range(1, ASK_ATTEMPTS + 1):
        try:
            return poll(number)
        except GhUnusable as error:
            last = error
            if attempt == ASK_ATTEMPTS:
                break
            pause = ASK_BACKOFF_SECONDS[min(attempt - 1,
                                            len(ASK_BACKOFF_SECONDS) - 1)]
            out(f"  gh failed ({error}), retrying in {pause:.0f}s "
                f"[attempt {attempt} of {ASK_ATTEMPTS}]")
            sleep(pause)
    assert last is not None
    raise last


def main(
    argv: Sequence[str],
    *,
    poll: Callable[[str], Poll] = poll_checks,
    now: Callable[[], float] | None = None,
    sleep: Callable[[float], None] | None = None,
    workflows: Path = WORKFLOWS,
    out: Callable[[str], None] = print,
) -> int:
    import time

    now = now or time.monotonic
    sleep = sleep or time.sleep

    try:
        arguments = parse_arguments(argv)
        expected = expected_checks(workflows)
    except (UnreadableWorkflow, GhUnusable) as error:
        out(f"cannot say what to wait for: {error}")
        return EXIT_UNUSABLE

    number, timeout, interval = (
        arguments.number, arguments.timeout, arguments.interval)
    out(f"waiting on {len(expected)} checks for pull request {number}, "
        f"up to {timeout:.0f}s")
    started = now()
    deadline = started + timeout
    answer = Verdict(state="missing", missing=sorted(expected))
    judged = ""

    while True:
        try:
            reading = ask(number, poll=poll, sleep=sleep, out=out)
        except GhUnusable as error:
            out(f"cannot ask gh: {error}")
            return EXIT_UNUSABLE

        # A commit landing mid-wait is said out loud rather than absorbed. A
        # green earned by the commit before it is not a green for this one, and
        # carrying on quietly would answer about work nothing had run against.
        if judged and reading.head_sha != judged:
            out(f"  head moved from {judged[:12]} to {reading.head_sha[:12]}, "
                "so everything before this judged another commit")
        judged = reading.head_sha

        answer = verdict(expected, reading.rows, reading.unfinished)
        if answer.state == "green":
            out(f"green at {judged[:12]}: {answer.summary}")
            return EXIT_GREEN
        if answer.state == "red":
            out(f"red at {judged[:12]}: {answer.summary}")
            return EXIT_RED

        left = deadline - now()
        if left <= 0:
            break
        # Elapsed and a count on every tick, so a wait that is progressing and
        # one that is stuck do not look identical.
        out(f"  {now() - started:.0f}s elapsed at {judged[:12]}, "
            f"{len(reading.rows)} reported: {answer.summary}")
        sleep(min(interval, left))

    out(f"gave up after {timeout:.0f}s at {judged[:12]}. {answer.summary}")
    return EXIT_NEVER_APPEARED if answer.missing else EXIT_STILL_RUNNING


if __name__ == "__main__":  # pragma: no cover - exercised through main()
    sys.exit(main(sys.argv[1:]))
