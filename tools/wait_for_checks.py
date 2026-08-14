"""Wait for a pull request's checks, and refuse to call an empty answer green.

#564. `gh pr checks <n>` reports nothing at all in the window between a push
and the checks being registered. Twice on 2026-08-14 a wait loop read that as
settled and green; trusting it would have merged a commit nothing had run
against. That is L98: finding zero subjects is indistinguishable from
everything passing, and the empty reply arrives exactly when the work has not
started, which is the moment a green verdict is most likely to be believed.

The fix is to know what the wait is waiting FOR. The expected checks are
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

#: gh's own words when a branch has no checks registered yet, read out of the
#: shipped binary (gh 2.89.0) rather than remembered (L52):
#:
#:     no checks reported on the '%s' branch
#:
#: Matched loosely because the branch name is interpolated into it, and on
#: either stream because which one gh uses is its choice rather than a fact
#: worth depending on.
NO_CHECKS = "no checks reported"

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


# ── reading what gh said ──────────────────────────────────────────────────────


def read_reply(*, exit_code: int, stdout: str, stderr: str) -> list[dict]:
    """gh's reply as rows, with "nothing yet" told apart from "cannot ask".

    gh exits non-zero both when checks are failing and when there are none at
    all, so the exit code alone cannot separate them. Collapsing the two would
    put an auth failure on the same path as patience, and the wait would spend
    its whole timeout looking like it was working.
    """
    body = stdout.strip()
    if NO_CHECKS in (body + stderr).lower():
        return []
    if body:
        try:
            rows = json.loads(body)
        except json.JSONDecodeError as error:
            raise GhUnusable(
                f"gh printed something that is not JSON ({error}): {body[:200]!r}"
            ) from error
        if not isinstance(rows, list):
            raise GhUnusable(f"gh returned {type(rows).__name__}, not a list of checks")
        return rows

    raise GhUnusable(
        f"gh exited {exit_code} with no usable output: {stderr.strip() or '(silence)'}")


def fetch_checks(number: str) -> list[dict]:
    """Ask gh about one pull request's checks."""
    try:
        done = subprocess.run(
            ["gh", "pr", "checks", number, "--json", "name,state,bucket,workflow"],
            capture_output=True, text=True, check=False)
    except FileNotFoundError as error:
        raise GhUnusable("gh is not installed or not on PATH") from error
    return read_reply(exit_code=done.returncode, stdout=done.stdout, stderr=done.stderr)


# ── judging it ────────────────────────────────────────────────────────────────


def _label(check: ExpectedCheck) -> str:
    return f"{check.workflow} / {check.name}"


def verdict(expected: Iterable[ExpectedCheck], reported: Sequence[dict]) -> Verdict:
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
    elif running:
        state, summary = "running", "still running: " + ", ".join(running)
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


def main(
    argv: Sequence[str],
    *,
    fetch: Callable[[str], list] = fetch_checks,
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

    while True:
        try:
            reported = fetch(number)
        except GhUnusable as error:
            out(f"cannot ask gh: {error}")
            return EXIT_UNUSABLE

        answer = verdict(expected, reported)
        if answer.state == "green":
            out(f"green: {answer.summary}")
            return EXIT_GREEN
        if answer.state == "red":
            out(f"red: {answer.summary}")
            return EXIT_RED

        left = deadline - now()
        if left <= 0:
            break
        # Elapsed and a count on every tick, so a wait that is progressing and
        # one that is stuck do not look identical.
        out(f"  {now() - started:.0f}s elapsed, {len(reported)} reported: "
            f"{answer.summary}")
        sleep(min(interval, left))

    out(f"gave up after {timeout:.0f}s. {answer.summary}")
    return EXIT_NEVER_APPEARED if answer.missing else EXIT_STILL_RUNNING


if __name__ == "__main__":  # pragma: no cover - exercised through main()
    sys.exit(main(sys.argv[1:]))
