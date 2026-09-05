"""The push that proposes a re-recorded fixture (#1311, #1321).

`record-suite-count.yml` and `record-guard-costs.yml` each re-measure a number,
write it into a fixture, and open a pull request from a branch named for the
DAY. The second run of any day therefore meets the first run's own branch.

#1321 fixed that by fetching the branch before pushing it with
`--force-with-lease`. It does not work, and nothing noticed for a day because
the test written beside it (test_recorders_survive_their_own_proposal.py) read
the workflow's TEXT and asserted the fetch line was PRESENT. A remedy that is
present and inert reads exactly like one that works (L1, L3).

What actually happens: `--force-with-lease` with no explicit value takes its
lease from the remote tracking ref, and it finds that ref through the
configured fetch refspec, not by looking in refs/remotes. actions/checkout
configures one refspec, for the branch it checked out, so the day branch is
untracked however many times it is fetched, the lease has no value, and git
refuses with `stale info`. Measured here, in the fixture below.

So the push is done differently, in ONE script both recorders call rather than
in a block copied into each of them: today's proposal is fetched and built ON,
and the push is an ordinary fast forward with no force and no lease. Nothing
another run wrote is discarded, which is what the lease was there to protect.

The git half of this runs for real against a local bare repository shaped the
way actions/checkout shapes a runner's. The `gh` half is a stub, so what these
tests prove about it is that the script calls it with the arguments written
below, not that GitHub answers them (L52); `test_the_gh_arguments_are_real`
covers the flags against gh itself.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest

from source_text import without_prose

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "tools" / "propose_recorded_change.sh"

RECORD = "tests/fixtures/swift_suite_count.json"
PREFIX = "suite-count"
TITLE = "Record how many tests the Swift suite holds (#1261)"
BODY = "Read off the newest green run."
DAY = "2026-09-04"
BRANCH = f"{PREFIX}/{DAY}"


# ── the fixture: a bare remote, plus a checkout shaped like a runner's ────────


def git(*args: str, cwd: Path, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(("git",) + args, cwd=cwd, check=check,
                          capture_output=True, text=True)


def make_remote(tmp_path: Path) -> Path:
    """A bare repository holding `main`, with the record file on it."""
    remote = tmp_path / "remote.git"
    git("init", "-q", "--bare", str(remote), cwd=tmp_path)

    seed = tmp_path / "seed"
    seed.mkdir()
    git("init", "-q", cwd=seed)
    git("config", "user.email", "seed@example.com", cwd=seed)
    git("config", "user.name", "seed", cwd=seed)
    (seed / "tests" / "fixtures").mkdir(parents=True)
    (seed / RECORD).write_text(json.dumps({"count": 2965}) + "\n")
    git("add", "-A", cwd=seed)
    git("commit", "-qm", "seed", cwd=seed)
    git("branch", "-M", "main", cwd=seed)
    git("remote", "add", "origin", str(remote), cwd=seed)
    git("push", "-q", "origin", "main", cwd=seed)
    return remote


def make_checkout(tmp_path: Path, remote: Path, name: str = "runner") -> Path:
    """A checkout with a tracking ref for `main` and for nothing else.

    This is the whole reason the defect exists, so it is built explicitly here
    rather than by `git clone`, which configures `+refs/heads/*` and makes the
    bug disappear (the first attempt at this fixture did exactly that and
    reported the broken command as working: L143, L159).
    """
    work = tmp_path / name
    work.mkdir()
    git("init", "-q", cwd=work)
    git("config", "user.email", "runner@example.com", cwd=work)
    git("config", "user.name", "runner", cwd=work)
    git("remote", "add", "origin", f"file://{remote}", cwd=work)
    git("config", "--unset-all", "remote.origin.fetch", cwd=work, check=False)
    git("config", "--add", "remote.origin.fetch",
        "+refs/heads/main:refs/remotes/origin/main", cwd=work)
    git("fetch", "-q", "--depth=1", "origin", "main", cwd=work)
    git("checkout", "-q", "-B", "main", "refs/remotes/origin/main", cwd=work)
    return work


def make_gh_stub(tmp_path: Path, open_heads: tuple[str, ...] = (),
                 name: str = "gh") -> tuple[Path, Path]:
    """A stub `gh` that answers `pr list` and records every call it is given.

    It answers from `open_heads`, so a merged pull request on the same head is
    representable as an absence: that is the state a recorder meets when its
    own proposal was merged and the branch deleted earlier the same day.
    """
    # One call log per stub, never one shared by every stub in a test. The
    # first version shared it, so the first run's `pr create` was still in the
    # file when the second run was asserted not to have made one, and two
    # tests failed for a reason that had nothing to do with the script.
    calls = tmp_path / f"{name}-calls.txt"
    stub = tmp_path / name / "gh"
    stub.parent.mkdir(parents=True, exist_ok=True)
    heads = " ".join(open_heads)
    stub.write_text(
        "#!/usr/bin/env bash\n"
        f'printf "%s\\n" "$*" >> {calls}\n'
        f'open_heads="{heads}"\n'
        'if [ "$1" = "pr" ] && [ "$2" = "list" ]; then\n'
        '  head=""\n'
        '  while [ $# -gt 0 ]; do\n'
        '    if [ "$1" = "--head" ]; then head="$2"; fi\n'
        '    shift\n'
        '  done\n'
        '  for h in ${open_heads}; do\n'
        '    if [ "${h}" = "${head}" ]; then echo 1; exit 0; fi\n'
        '  done\n'
        '  echo 0\n'
        '  exit 0\n'
        'fi\n'
        'if [ "$1" = "pr" ] && [ "$2" = "create" ]; then\n'
        '  echo "https://github.com/owner/repo/pull/1"\n'
        '  exit 0\n'
        'fi\n'
        'echo "the stub was asked something it does not answer: $*" >&2\n'
        'exit 64\n'
    )
    stub.chmod(0o755)
    return stub, calls


def propose(work: Path, gh: Path, *, record_value: dict,
            check: bool = True) -> subprocess.CompletedProcess:
    """Write a new record into the checkout and run the script over it."""
    (work / RECORD).write_text(json.dumps(record_value) + "\n")
    env = dict(os.environ, GH=str(gh), PROPOSAL_DATE=DAY)
    return subprocess.run(
        ["bash", str(SCRIPT), "--record", RECORD, "--branch-prefix", PREFIX,
         "--title", TITLE, "--body", BODY],
        cwd=work, env=env, check=check, capture_output=True, text=True)


def remote_record(remote: Path, branch: str) -> dict:
    shown = git("show", f"{branch}:{RECORD}", cwd=remote)
    return json.loads(shown.stdout)


def gh_calls(calls: Path) -> list[str]:
    return calls.read_text().splitlines() if calls.exists() else []


# ── the control: the fixture can see the failure it was built for ────────────


def test_the_lease_is_what_the_runner_refuses(tmp_path):
    """The positive control, and the diagnosis (L1, L159).

    `--force-with-lease` is refused in exactly this fixture, which is why the
    fetch #1321 added changed nothing. Without this, a green suite would be
    equally consistent with the defect never having existed.
    """
    remote = make_remote(tmp_path)
    first = make_checkout(tmp_path, remote, "first")
    git("checkout", "-q", "-b", BRANCH, cwd=first)
    (first / RECORD).write_text(json.dumps({"count": 3000}) + "\n")
    git("commit", "-qam", "first proposal", cwd=first)
    git("push", "-q", "origin", BRANCH, cwd=first)

    second = make_checkout(tmp_path, remote, "second")
    fetched = git("fetch", "origin",
                  f"+refs/heads/{BRANCH}:refs/remotes/origin/{BRANCH}",
                  cwd=second, check=False)
    assert fetched.returncode == 0, "the fetch #1321 added did not even run"
    assert git("rev-parse", "--verify", f"refs/remotes/origin/{BRANCH}",
               cwd=second, check=False).returncode == 0, (
        "the fetch did not create the tracking ref, so this control is "
        "measuring something other than the lease")

    git("checkout", "-q", "-b", BRANCH, cwd=second)
    (second / RECORD).write_text(json.dumps({"count": 3077}) + "\n")
    git("commit", "-qam", "second proposal", cwd=second)
    refused = git("push", "--force-with-lease", "origin", BRANCH,
                  cwd=second, check=False)

    assert refused.returncode != 0, (
        "the lease was accepted here, so this fixture no longer reproduces "
        "#1311 and every test below it is proving less than it claims")
    assert "stale info" in refused.stderr, (
        f"refused for some other reason than the missing lease: {refused.stderr}")


# ── the three states a recorder actually meets ───────────────────────────────


def test_the_first_run_of_the_day_opens_a_proposal(tmp_path):
    """No branch, no proposal: push it and open one."""
    remote = make_remote(tmp_path)
    work = make_checkout(tmp_path, remote)
    gh, calls = make_gh_stub(tmp_path)

    done = propose(work, gh, record_value={"count": 3077})

    assert remote_record(remote, BRANCH) == {"count": 3077}
    assert any(call.startswith("pr create") for call in gh_calls(calls)), (
        f"no pull request was opened: {gh_calls(calls)}")
    assert BRANCH in done.stdout


def test_the_second_run_of_the_day_updates_the_open_proposal(tmp_path):
    """The state #1321 was filed for, and #1326 did not actually fix.

    The branch is there and its pull request is open, so the new reading is
    pushed onto it and nothing new is opened.
    """
    remote = make_remote(tmp_path)
    first = make_checkout(tmp_path, remote, "first")
    gh, _ = make_gh_stub(tmp_path)
    propose(first, gh, record_value={"count": 3000})

    second = make_checkout(tmp_path, remote, "second")
    gh_open, calls = make_gh_stub(tmp_path, open_heads=(BRANCH,), name="second")
    done = propose(second, gh_open, record_value={"count": 3077})

    assert remote_record(remote, BRANCH) == {"count": 3077}, (
        "the second run's reading did not reach the open proposal")
    assert not any(call.startswith("pr create") for call in gh_calls(calls)), (
        "a second pull request was opened on a head that already has one")
    assert "already open" in done.stdout


def test_the_second_run_keeps_what_the_first_one_committed(tmp_path):
    """The reason the lease was there. Building ON today's proposal rather
    than force pushing over it means the earlier commit survives, so a run is
    additive rather than a rewrite of an open pull request (L5)."""
    remote = make_remote(tmp_path)
    first = make_checkout(tmp_path, remote, "first")
    gh, _ = make_gh_stub(tmp_path)
    propose(first, gh, record_value={"count": 3000})
    was = git("rev-parse", BRANCH, cwd=remote).stdout.strip()

    second = make_checkout(tmp_path, remote, "second")
    gh_open, _ = make_gh_stub(tmp_path, open_heads=(BRANCH,), name="second")
    propose(second, gh_open, record_value={"count": 3077})

    contains = git("merge-base", "--is-ancestor", was, BRANCH,
                   cwd=remote, check=False)
    assert contains.returncode == 0, (
        "the second run discarded the first run's commit rather than building "
        "on it, so a proposal can lose a reading nobody has seen")


def test_a_run_after_the_days_proposal_merged_opens_another(tmp_path):
    """The trap in asking `gh pr view` whether today's proposal is open.

    `gh pr view <branch>` answers about the newest pull request on that head
    WHATEVER its state, so once today's proposal is merged and its branch
    deleted, the check reads the merged one and reports the proposal as still
    open. The run would push a branch and open nothing, which is the shape of a
    success that did nothing (L98). Measured on 2026-09-04: #1322 merged at
    13:51 on the very day its branch would be reused.
    """
    remote = make_remote(tmp_path)
    first = make_checkout(tmp_path, remote, "first")
    gh, _ = make_gh_stub(tmp_path)
    propose(first, gh, record_value={"count": 3000})
    git("update-ref", "-d", f"refs/heads/{BRANCH}", cwd=remote)

    second = make_checkout(tmp_path, remote, "second")
    gh_merged, calls = make_gh_stub(tmp_path, open_heads=(), name="second")
    propose(second, gh_merged, record_value={"count": 3077})

    assert remote_record(remote, BRANCH) == {"count": 3077}
    assert any(call.startswith("pr create") for call in gh_calls(calls)), (
        "today's branch was pushed and no pull request was opened for it, so "
        f"the reading reaches nobody: {gh_calls(calls)}")


def test_a_run_that_re_reads_the_same_number_says_so(tmp_path):
    """Nothing to commit is a real outcome, not an error and not a proposal."""
    remote = make_remote(tmp_path)
    first = make_checkout(tmp_path, remote, "first")
    gh, _ = make_gh_stub(tmp_path)
    propose(first, gh, record_value={"count": 3077})
    unchanged = git("rev-parse", BRANCH, cwd=remote).stdout.strip()

    second = make_checkout(tmp_path, remote, "second")
    gh_open, calls = make_gh_stub(tmp_path, open_heads=(BRANCH,), name="second")
    done = propose(second, gh_open, record_value={"count": 3077})

    assert git("rev-parse", BRANCH, cwd=remote).stdout.strip() == unchanged, (
        "an empty commit was pushed onto today's proposal")
    assert "already carries this record" in done.stdout
    assert not any(call.startswith("pr create") for call in gh_calls(calls))


# ── the failure paths ────────────────────────────────────────────────────────


def test_a_record_that_matches_main_is_refused_rather_than_reported_as_done(tmp_path):
    """The caller runs this only when the record MOVED, so a record equal to
    what main already holds, with no branch to explain it, is a contradiction.
    Exiting 0 there would be a run that proposed nothing and said it had
    (L98)."""
    remote = make_remote(tmp_path)
    work = make_checkout(tmp_path, remote)
    gh, calls = make_gh_stub(tmp_path)

    refused = propose(work, gh, record_value={"count": 2965}, check=False)

    assert refused.returncode != 0, (
        f"a record identical to main was accepted as a proposal: {refused.stdout}")
    assert "nothing to propose" in refused.stderr, (
        f"the refusal does not say what it refused, so a missing script and a "
        f"record that did not move read the same (L11): {refused.stderr}")
    assert not any(call.startswith("pr create") for call in gh_calls(calls))


@pytest.mark.parametrize("missing", ["--record", "--branch-prefix", "--title", "--body"])
def test_every_argument_is_required(tmp_path, missing):
    """Each of the four names what is proposed or what it says. A default for
    any of them would let a caller that forgot it propose something else's
    record under something else's title (L168)."""
    remote = make_remote(tmp_path)
    work = make_checkout(tmp_path, remote)
    gh, _ = make_gh_stub(tmp_path)
    given = {"--record": RECORD, "--branch-prefix": PREFIX,
             "--title": TITLE, "--body": BODY}
    del given[missing]
    argv = [item for pair in given.items() for item in pair]

    refused = subprocess.run(["bash", str(SCRIPT), *argv], cwd=work,
                             env=dict(os.environ, GH=str(gh), PROPOSAL_DATE=DAY),
                             capture_output=True, text=True)

    assert refused.returncode != 0, f"{missing} was not required"
    assert missing in refused.stderr, (
        f"the refusal does not name {missing}: {refused.stderr}")


# ── what the stub cannot prove ───────────────────────────────────────────────


def test_the_gh_arguments_are_real(tmp_path):
    """The stub answers whatever it is asked, so it cannot report a flag that
    gh does not have. gh's own help does, and it needs no network (L52)."""
    gh = subprocess.run(["gh", "pr", "list", "--help"],
                        capture_output=True, text=True)
    if gh.returncode != 0:
        pytest.skip("gh is not installed here")

    for flag in ("--head", "--state", "--json"):
        assert flag in gh.stdout, f"gh pr list has no {flag}"

    # Through without_prose, because the paragraph at the top of the script
    # explains this exact call, and a guard that reads raw text is answered by
    # the explanation as readily as by the code (L103, L135).
    body = without_prose(SCRIPT)
    assert 'pr list --head "${branch}" --state open --json number' in body, (
        "the script no longer asks gh the question these flags were checked "
        "for, so this test is guarding a call that is not made")


# ── provenance is not a measurement (#1392) ──────────────────────────────────


def _reading(count: int, *, run: str, commit: str) -> dict:
    """A record shaped the way the real one is: a measurement, plus the fields
    saying WHICH run measured it and WHEN. Every real recorder writes those,
    and they move on every run whether the number did or not."""
    return {"count": count, "measured_on": DAY,
            "measured_at_commit": commit, "measured_from_run": run,
            "measured_from": f"{count} tests, no failures, read from run {run}",
            "re_measure_with": "venv/bin/python tools/record_suite_count.py"}


def test_a_rerun_measuring_the_same_number_does_not_recommit(tmp_path):
    """The whole of #1392.

    The script asks whether there is anything to add with `git diff --cached`
    over the WHOLE record, and every recorder stamps which run measured it. So
    a re-run that measured the identical number still writes a different file
    and still commits, and the open proposal's head moves away from the commit
    its checks belong to.

    Measured 2026-09-05 on PR #1383: three commits in half an hour, all
    recording 3175, differing only in `measured_at_commit` and
    `measured_from_run`. One green was refused at the merge because the branch
    had moved under it.
    """
    remote = make_remote(tmp_path)
    first = make_checkout(tmp_path, remote, "first")
    gh, _ = make_gh_stub(tmp_path)
    propose(first, gh, record_value=_reading(3175, run="111", commit="aaaaaaa"))
    unchanged = git("rev-parse", BRANCH, cwd=remote).stdout.strip()

    second = make_checkout(tmp_path, remote, "second")
    gh_open, calls = make_gh_stub(tmp_path, open_heads=(BRANCH,), name="second")
    done = propose(second, gh_open,
                   record_value=_reading(3175, run="222", commit="bbbbbbb"))

    assert git("rev-parse", BRANCH, cwd=remote).stdout.strip() == unchanged, (
        "the proposal was recommitted for a run that measured the same number, "
        "so its head moved away from the commit its checks belong to (#1392)")
    assert "already carries this" in done.stdout
    assert not any(call.startswith("pr create") for call in gh_calls(calls))


def test_a_rerun_measuring_a_different_number_still_recommits(tmp_path):
    """The positive control, in the SAME fixture (L159).

    Without it, a script that never commits anything at all passes the test
    above, and the two are indistinguishable from its result.
    """
    remote = make_remote(tmp_path)
    first = make_checkout(tmp_path, remote, "first")
    gh, _ = make_gh_stub(tmp_path)
    propose(first, gh, record_value=_reading(3175, run="111", commit="aaaaaaa"))
    before = git("rev-parse", BRANCH, cwd=remote).stdout.strip()

    second = make_checkout(tmp_path, remote, "second")
    gh_open, _ = make_gh_stub(tmp_path, open_heads=(BRANCH,), name="second")
    propose(second, gh_open, record_value=_reading(3201, run="222", commit="bbbbbbb"))

    assert git("rev-parse", BRANCH, cwd=remote).stdout.strip() != before, (
        "a genuinely new number was not committed onto today's proposal")
    assert remote_record(remote, BRANCH)["count"] == 3201
