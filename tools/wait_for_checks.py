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

    0  green          every expected check settled, none failing, and with
                      --merge that commit is now merged
    1  red            an expected check failed, was cancelled, or skipped
                      where the workflow said it should run
    2  never appeared the deadline passed with an expected check absent
    3  still running  the deadline passed with everything present but pending
    4  unusable       gh could not be asked, or the workflows could not be read
    5  not merged     the commit was green and GitHub refused to merge it,
                      which is what a head that moved in between looks like
    6  behind          the commit was green against a base that has since
                      moved, so nothing has judged it against what it would
                      land on

#674 is the last step of the same defect. Proving one named commit passed and
then merging in a separate step merges whatever is at the top of the branch by
then, so a push landing in the seconds between the two is merged with nothing
having judged it, and that is the step that cannot be undone. `--merge` closes
it by construction: GitHub's merge endpoint takes the commit as `sha` and
answers 409 when the head is not it.

#680 is the window #674 left open. Merging the exact commit that was judged
says nothing about the BASE it was judged against: two changes that are each
green against their own base merge into a broken main (L85). So the merge path
asks where the base branch is now and refuses a head that does not contain it,
under its own exit code, rather than leaving it to whoever remembers to rebase.

The comparison is taken immediately before the merge and against the commit
that was judged, which makes the window seconds wide rather than closing it:
GitHub's merge endpoint takes a head `sha` and has no matching precondition for
the base. Closing it by construction takes the repository level setting
("require branches to be up to date before merging"), which this cannot do for
anyone from here.

Usage:

    python tools/wait_for_checks.py <pr-number> [--timeout 1800]
                                    [--interval 20] [--merge]

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
EXIT_NOT_MERGED = 5
EXIT_BEHIND = 6

#: The two job conditions this can classify. Anything else is refused rather
#: than guessed at, because a guessed bar reads as authoritative.
RUNS_ON_PULL_REQUEST = "github.event_name == 'pull_request'"
SKIPS_ON_PULL_REQUEST = "github.event_name != 'pull_request'"


class UnreadableWorkflow(Exception):
    """The workflows do not say what checks to expect, so there is no bar."""


class GhUnusable(Exception):
    """gh could not be asked. Distinct from gh answering "nothing yet"."""


class MergeRefused(Exception):
    """The merge did not happen, and the pull request is still open.

    Its own exception rather than `GhUnusable`, because the two call for
    different things: one says the question could not be asked, and this says
    the answer was no. The commonest reason is the one this exists for, a head
    that moved between the green and the merge, and the response to that is to
    look at what landed rather than to merge again (L11).
    """


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


#: How this repository's pull requests land. Every commit on main is a squash
#: of one pull request, so a merge that made a merge commit here would be the
#: odd one out rather than a choice.
MERGE_METHOD = "squash"


def merge_commit(number: str, sha: str, *,
                 method: str = MERGE_METHOD,
                 run: Callable[..., object] = subprocess.run) -> str:
    """Merge pull request `number`, but only while its head is still `sha`.

    The green above proves that ONE named commit passed. Merging the top of the
    branch is a different act: a push landing in the seconds between the two
    merges a commit nothing has judged, which is #669 moved one step later and
    into the step that cannot be undone (#674).

    GitHub's merge endpoint takes the commit as `sha` and answers 409 when the
    head is not it, so this is closed by construction rather than by being
    quick. The reply is then read rather than the exit code trusted: gh exiting
    0 having been told "not mergeable" is not a merge, and reporting one over a
    pull request still sitting open is a success claim nobody verified (L12).
    """
    path = f"repos/{{owner}}/{{repo}}/pulls/{number}/merge"
    try:
        done = run(
            ["gh", "api", "-X", "PUT",
             "-H", "Accept: application/vnd.github+json", path,
             "-f", f"sha={sha}", "-f", f"merge_method={method}"],
            capture_output=True, text=True, check=False)
    except FileNotFoundError as error:
        raise MergeRefused("gh is not installed or not on PATH") from error

    body = (done.stdout or "").strip()
    if done.returncode != 0:
        raise MergeRefused(
            f"gh api PUT {path} exited {done.returncode}: "
            f"{((done.stderr or '').strip() or body)[:200] or '(silence)'}")
    try:
        reply = json.loads(body)
    except json.JSONDecodeError as error:
        raise MergeRefused(
            f"gh api PUT {path} printed something that is not JSON ({error}): "
            f"{body[:200]!r}") from error
    if not isinstance(reply, dict) or not reply.get("merged"):
        said = ""
        if isinstance(reply, dict):
            said = str(reply.get("message") or "")
        raise MergeRefused(
            f"GitHub did not merge {sha[:12]}: {said or body[:200] or '(silence)'}")
    return str(reply.get("sha") or sha)


@dataclass(frozen=True)
class BaseStanding:
    """Where one commit sits relative to the branch its pull request lands on.

    `base_sha` is where that branch was when this reading was taken, named so a
    refusal can say what moved rather than only that something did.
    """

    branch: str
    base_sha: str
    behind_by: int
    ahead_by: int


def base_standing(number: str, sha: str, *,
                  api: Callable[[str], dict] = gh_json) -> BaseStanding:
    """How far `sha` is behind the branch pull request `number` would land on.

    The green above proves that one named commit passed the checks. It says
    nothing about what that commit was tested AGAINST: main moves while a
    branch waits, and two changes that are each green against their own base
    merge into a main neither of them was ever run against (L85).

    Asked about the judged commit rather than about the branch, so a push
    landing meanwhile cannot answer for it (L179), and against the base
    branch's current head commit rather than its name, so the refusal can name
    where main actually is.

    Anything this cannot read raises rather than returning a zero. Not knowing
    whether the base has moved is not the same as it not having moved, and zero
    is the answer that merges (L42).
    """
    pull = api(f"repos/{{owner}}/{{repo}}/pulls/{number}")
    base = pull.get("base") or {}
    repo = str(((base.get("repo") or {}).get("full_name") or ""))
    branch = str(base.get("ref") or "")
    if not repo or not branch:
        raise GhUnusable(
            f"pull request {number} named no base branch or no repository, so "
            "there is nothing to compare its head against")

    tip_path = f"repos/{repo}/commits/{branch}"
    base_sha = str(api(tip_path).get("sha") or "")
    if not base_sha:
        raise GhUnusable(
            f"gh api {tip_path} named no commit, so where {branch} is now is "
            "unknown and nothing can be said about what this was judged against")

    path = f"repos/{repo}/compare/{base_sha}...{sha}"
    reply = api(path)
    behind, ahead = reply.get("behind_by"), reply.get("ahead_by")
    if not isinstance(behind, int) or not isinstance(ahead, int):
        raise GhUnusable(
            f"gh api {path} did not say how far apart the two commits are "
            f"(behind_by {behind!r}, ahead_by {ahead!r}), so this cannot tell "
            f"a branch that contains {branch} from one that does not")

    # The same fact twice: a head that is behind by nothing is one whose merge
    # base with the branch IS the branch. This catches the reply meaning
    # something other than what is read here, not a wrong answer, since both
    # halves come from the one lookup (L70). Refused rather than resolved,
    # because picking a half is picking which defect to ship (L93).
    merge_base = str((reply.get("merge_base_commit") or {}).get("sha") or "")
    if (behind == 0) != (merge_base == base_sha):
        raise GhUnusable(
            f"gh api {path} says {behind} behind while its merge base is "
            f"{merge_base[:12] or '(unnamed)'} against a {branch} at "
            f"{base_sha[:12]}, and those two cannot both be true")

    return BaseStanding(branch=branch, base_sha=base_sha,
                        behind_by=behind, ahead_by=ahead)


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
    #: Merge the commit this judged, rather than leaving a second step to be
    #: taken against whatever is at the top of the branch by then (#674).
    merge: bool = False


def parse_arguments(argv: Sequence[str]) -> Arguments:
    """The pull request number and the knobs, with unknown flags refused."""
    numbers = {"--timeout": 1800.0, "--interval": 20.0}
    merge = False
    positional: list[str] = []
    rest = list(argv)
    while rest:
        word = rest.pop(0)
        if word == "--merge":
            merge = True
        elif word in numbers:
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
            "[--interval 20] [--merge]")
    return Arguments(positional[0], numbers["--timeout"], numbers["--interval"],
                     merge)


# How long one poll may be retried before gh is called unusable (#657, #936).
#
# One momentary API error is not evidence that gh cannot be asked: an HTTP 503
# four minutes into a 2400 second wait ended a whole run, so a GitHub wobble
# cost a full restart, and during a real incident, which is exactly when a
# status is hardest to read by hand, the wait could never finish.
#
# This retries the ASKING, never the verdict: a reply that arrives and says
# nothing usable is still answered by the same rules as before, and a failure
# that does not clear is still unusable, just later instead of instantly.
# Retrying every failure rather than only the ones that look transient keeps
# this free of a second, message-matching classifier that would eventually
# disagree with itself (L35). None of that changes here.
#
# What changed is the patience, and only the patience. It was three attempts
# with two fixed pauses, so six seconds, whatever the caller had asked to wait.
# On 2026-08-28 this machine ran out of network sockets under load from several
# concurrent builds and `dial tcp ... can't assign requested address` outlived
# those six seconds. The tool refused correctly rather than inventing an answer,
# and PR #934 was then left open and unmerged with nothing watching it, which in
# an unattended run means work silently does not land.
#
# So the budget is a share of the timeout the caller already passes: somebody
# willing to wait forty minutes is willing to spend two of them finding out
# whether GitHub is reachable, and somebody who asked for sixty seconds is not.
#
# A share and not the whole remaining wait, because the other half matters just
# as much: gh being genuinely unusable, not installed or not authenticated, has
# to be reported while somebody could still act on it rather than at the end of
# a wait they would otherwise have spent watching. The floor keeps a very short
# wait at least the two pauses it had before.
ASK_BUDGET_SHARE = 0.05
ASK_BUDGET_FLOOR_SECONDS = 6.0

# Doubling from here, capped at the caller's own polling interval, so a long
# outage is not answered by a busy loop against a service already struggling and
# the retries never go quieter than the ordinary ticks around them. Capped at
# the interval rather than at a number of its own, because that is a cadence the
# caller has already chosen and a second one here is a second thing to disagree
# with (L41).
ASK_BACKOFF_START_SECONDS = 2.0


def ask_budget(timeout: float) -> float:
    """How long one poll may be retried for, given the caller's whole timeout."""
    return max(ASK_BUDGET_FLOOR_SECONDS, timeout * ASK_BUDGET_SHARE)


def _commits(count: int) -> str:
    return f"{count} commit" if count == 1 else f"{count} commits"


def say(line: str) -> None:
    """One line out, flushed.

    Not bare `print`. Python block-buffers stdout the moment it is not a
    terminal, which is exactly how a wait this long is run: redirected to a
    file, or piped, while somebody watches for progress. Caught on 2026-08-17
    watching #671, where the output file stayed empty for the whole wait, so
    every elapsed line, every retry and every "the head moved" arrived at the
    end or not at all. A wait that says nothing while it works is
    indistinguishable from one that has stalled (L106).
    """
    print(line, flush=True)


def ask(
    number: str,
    *,
    poll: Callable[[str], Poll],
    sleep: Callable[[float], None],
    out: Callable[[str], None],
    now: Callable[[], float],
    deadline: float,
    budget: float,
    cap: float,
) -> Poll:
    """One poll, retried within a budget before gh is declared unusable.

    Bounded twice over, by the budget and by the overall deadline, and whichever
    runs out first ends it. The deadline matters on its own: a caller asking for
    a sixty second wait must not have it turn into a longer one because the
    retry budget had a floor under it.

    Each retry is said out loud, with what is left, because a retry nobody can
    see is indistinguishable from a wait that has stalled (L106).
    """
    started = now()
    pause = ASK_BACKOFF_START_SECONDS
    last: GhUnusable | None = None
    attempt = 0
    while True:
        attempt += 1
        try:
            reading = poll(number)
        except GhUnusable as error:
            last = error
        else:
            if attempt > 1:
                # Said once, on the way out, because a run that survived an
                # outage otherwise ends on "green" and "merged" with the only
                # trace a few lines that scrolled past. With the budget now
                # stretching to minutes that is the difference between a healthy
                # run and one that spent two of them unable to reach GitHub, and
                # nothing downstream could tell them apart (L77).
                #
                # Only when there was something to recover from: a line printed
                # on every run carries no information.
                out(f"  gh recovered after {now() - started:.0f}s and "
                    f"{attempt} attempts")
            return reading
        patience_left = budget - (now() - started)
        this = min(pause, patience_left, deadline - now())
        if this <= 0:
            break
        out(f"  gh failed ({last}), retrying in {this:.0f}s "
            f"[attempt {attempt}, {patience_left:.0f}s of patience left]")
        sleep(this)
        pause = min(pause * 2, cap)
    assert last is not None
    raise last


def main(
    argv: Sequence[str],
    *,
    poll: Callable[[str], Poll] = poll_checks,
    merge: Callable[[str, str], str] = merge_commit,
    base: Callable[[str, str], BaseStanding] = base_standing,
    now: Callable[[], float] | None = None,
    sleep: Callable[[float], None] | None = None,
    workflows: Path = WORKFLOWS,
    out: Callable[[str], None] = say,
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
            reading = ask(number, poll=poll, sleep=sleep, out=out, now=now,
                          deadline=deadline, budget=ask_budget(timeout),
                          cap=interval)
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
            if not arguments.merge:
                return EXIT_GREEN
            # What the green was earned AGAINST, asked as late as possible and
            # about this commit (#680). A base that has moved means nothing has
            # run this change against what it would land on.
            try:
                standing = base(number, judged)
            except GhUnusable as error:
                out(f"green at {judged[:12]} but not merged: cannot tell "
                    f"whether the branch is up to date: {error}")
                return EXIT_UNUSABLE
            if standing.behind_by:
                out(f"green at {judged[:12]} but not merged: it is "
                    f"{_commits(standing.behind_by)} behind {standing.branch}, "
                    f"now at {standing.base_sha[:12]}, so nothing has run this "
                    f"change against what it would land on. Rebase onto "
                    f"{standing.branch}, push, and wait again.")
                return EXIT_BEHIND
            out(f"  {judged[:12]} contains {standing.branch} at "
                f"{standing.base_sha[:12]}, so the green was earned against "
                "what it lands on")
            # The merge names the commit the green was earned by, so a push
            # landing in between is refused by GitHub rather than merged (#674).
            try:
                merged = merge(number, judged)
            except MergeRefused as error:
                out(f"green at {judged[:12]} but not merged: {error}")
                return EXIT_NOT_MERGED
            out(f"merged {merged[:12]}, which is the commit judged at "
                f"{judged[:12]}")
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
