"""The guard prover and the suite stop reporting each other's work (#920).

`tools/check_guards.py` proves a guard by editing a real source file, running
one test, and putting the file back. A `pytest tests/` run alongside it reads a
file mid perturbation, and
`test_guard_mutation_registry.py::test_every_anchor_still_matches_its_file_exactly_once`
fails on whichever entry was in flight.

The failure names a real registry entry, so the obvious reading is that the
entry is stale rather than that two tools collided. It cost two false alarms on
2026-08-27 and two more on 2026-08-28, all four of which passed immediately on
a re-run.

## Three outcomes, three messages

The whole point is telling states apart, so a skip may never stand in for all
of them (L11, L98).

* no lock: the registry check runs and means what it says.
* a lock held by a LIVE process: the check cannot judge, and says so naming the
  guard and the process, so nobody reads it as a stale entry.
* a lock file whose process is GONE: that is a stale lock, and it must be loud
  rather than quiet. A stale lock skipped silently would disable the registry
  check for as long as the file sits there, and a check that cannot fail is
  indistinguishable from one that passes (L182).
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

from tools.perturbation_lock import (Lock, Verdict, _somebody_holds, current,
                                     held_for, lock_path, verdict)


def test_nothing_is_held_in_a_clean_checkout(tmp_path):
    assert current(tmp_path) is None


def test_a_lock_is_visible_while_it_is_held(tmp_path):
    with held_for("a-named-guard", tmp_path):
        held = current(tmp_path)
        assert held is not None
        assert held.guard == "a-named-guard"
        assert held.pid == os.getpid()
        assert held.is_live, "the process holding it is this one, which is alive"


def test_the_lock_is_gone_afterwards(tmp_path):
    with held_for("a-named-guard", tmp_path):
        pass
    assert current(tmp_path) is None


def test_the_lock_is_released_even_when_the_body_raises(tmp_path):
    """A prover that died mid guard must not leave the suite refusing forever.

    The release belongs on every exit path, not only the happy one (L514,
    L515).
    """
    with pytest.raises(ValueError):
        with held_for("a-named-guard", tmp_path):
            raise ValueError("the guard run fell over")

    assert current(tmp_path) is None


def test_a_lock_whose_process_is_gone_reads_as_not_live(tmp_path):
    """Written by hand, because the point is a process that no longer exists.

    A PID that was never running is the same situation as one that has since
    died, and it is the only one a test can produce without racing.
    """
    path = lock_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # PID 0 is never a real user process, so this cannot accidentally name
    # something running on the machine under test.
    path.write_text('{"guard": "abandoned", "pid": 0, "started_at": 1}')

    held = current(tmp_path)
    assert held is not None, "the file is there, so something must be reported"
    assert held.guard == "abandoned"
    assert not held.is_live, (
        "nothing is running, so this is a leftover rather than a live run, and "
        "the two must not read the same")


def test_an_unreadable_lock_is_reported_rather_than_treated_as_absent(tmp_path):
    """Corrupt is not the same as clean.

    Answering None on a file that exists but cannot be parsed would let a
    damaged lock read as a checkout with nothing running, which is the exact
    substitution this file exists to prevent (L215).
    """
    path = lock_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("not json at all")

    held = current(tmp_path)
    assert held is not None
    assert not held.is_live
    assert held.guard == Lock.UNREADABLE, (
        "an unparseable lock names itself as unreadable rather than borrowing "
        "the name of a guard nobody can read")


def test_only_a_REAL_HOLDER_reads_as_live(tmp_path):
    """Naming a running process is not the same as holding the lock.

    This test used to write a live process's id into the file and expect that
    to count. It did, and that was the defect: ids are recycled, so an
    abandoned lock whose number the system reissues would have read as a live
    run and stood the registry check down for ever, silently (L182).

    Liveness now comes from the kernel, which releases the lock when its holder
    dies for any reason. So the fixture has to be a process that actually takes
    it, and the negative half, a file naming a running process without holding
    anything, has to come back NOT live.
    """
    import subprocess
    import sys
    import textwrap

    path = lock_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)

    # The negative half first: a real, running process named in the file, which
    # holds nothing. This is the case that used to pass and must not.
    idle = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    try:
        path.write_text('{"guard": "named-only", "pid": %d, "started_at": 1}'
                        % idle.pid)
        held = current(tmp_path)
        assert held is not None and not held.is_live, (
            "a file naming a running process holds nothing, and treating it as "
            "live is the recycled-id hole this replaced")
    finally:
        idle.kill()
        idle.wait()

    # And the positive half, so the negative one is not passing because the
    # check stopped seeing anything at all (L159).
    holder = subprocess.Popen([sys.executable, "-c", textwrap.dedent(f"""
        import fcntl, sys, time
        handle = open({str(path)!r}, "a+")
        fcntl.flock(handle, fcntl.LOCK_EX)
        handle.seek(0); handle.truncate()
        handle.write('{{"guard": "really-held", "pid": 1, "started_at": 1}}')
        handle.flush()
        sys.stdout.write("locked\\n"); sys.stdout.flush()
        time.sleep(60)
    """)], stdout=subprocess.PIPE, text=True)
    try:
        assert holder.stdout.readline().strip() == "locked", "the holder never took it"
        held = current(tmp_path)
        assert held is not None and held.is_live
        assert held.guard == "really-held"
    finally:
        holder.kill()
        holder.wait()

    # And once that process is gone the kernel has already released it, with no
    # cleanup of any kind having run.
    assert path.exists(), "the killed holder left its file behind, as a kill does"
    after = current(tmp_path)
    assert after is not None and not after.is_live, (
        "a killed holder's lock is released by the kernel, so what remains is "
        "an abandoned file and must read as one")


def test_the_lock_lives_outside_the_working_tree(tmp_path):
    """Inside it, the lock is a stray file every other tool has an opinion
    about, and the registry test's own directory read would see it."""
    path = lock_path(tmp_path)
    assert ".git" in path.parts, path
    assert tmp_path in path.parents, "it still belongs to this checkout"


# ── What the suite should DO about each state ────────────────────────────────
#
# Kept as a pure verdict rather than a function that calls pytest.skip, so the
# policy can be asserted directly. A helper that skips can only be tested by
# catching the skip, and a skip that escapes its catch reports the test as
# SKIPPED, which is no verdict at all: that exact trap cost a guard proof
# earlier in this project's history.


def test_a_clean_checkout_proceeds(tmp_path):
    outcome, why = verdict(tmp_path)
    assert outcome is Verdict.PROCEED
    assert why == "", "there is nothing to explain when nothing is held"


def test_a_live_prover_means_the_check_cannot_judge(tmp_path):
    with held_for("collage-design-version-parity", tmp_path):
        outcome, why = verdict(tmp_path)

    assert outcome is Verdict.CANNOT_JUDGE
    assert "collage-design-version-parity" in why, (
        "naming the guard is what separates this from a stale entry, which is "
        "the misreading the whole issue is about")
    assert str(os.getpid()) in why, "and the process, so it can be looked up"


def test_a_leftover_lock_is_its_own_outcome(tmp_path):
    path = lock_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('{"guard": "abandoned", "pid": 0, "started_at": 1}')

    outcome, why = verdict(tmp_path)

    assert outcome is Verdict.STALE, (
        "a lock nobody is holding must not be quiet: skipped silently it would "
        "disable the registry check for as long as the file sits there (L182)")
    assert "abandoned" in why
    assert "delete" in why.lower(), "the remedy has to be in the sentence (L111)"


def test_the_three_outcomes_are_actually_three(tmp_path):
    """A guard against the fix collapsing back into a boolean.

    Two of these sharing one value is the defect: the point is that a running
    prover and a dead one need different reactions from the suite (L11, L260).
    """
    assert len({Verdict.PROCEED, Verdict.CANNOT_JUDGE, Verdict.STALE}) == 3


# ── What the registry check actually DOES with the verdict ───────────────────


def _reaction(repo_root):
    """Which of the three the helper produces, named rather than inferred.

    Explicit try/except rather than `pytest.raises`: a skip escaping a
    `raises` block marks the whole test SKIPPED, which is no verdict at all and
    reads as a pass. That trap cost a real guard proof in this project.
    """
    from test_guard_mutation_registry import refuse_if_a_prover_is_working
    try:
        refuse_if_a_prover_is_working(repo_root)
    except pytest.skip.Exception as skipped:
        return "stood down", str(skipped)
    except pytest.fail.Exception as failed:
        return "failed", str(failed)
    return "proceeded", ""


def test_the_registry_check_proceeds_when_nothing_is_held(tmp_path):
    assert _reaction(tmp_path)[0] == "proceeded"


def test_the_registry_check_stands_down_for_a_working_prover(tmp_path):
    with held_for("a-guard-being-proved", tmp_path):
        how, why = _reaction(tmp_path)

    assert how == "stood down"
    assert "a-guard-being-proved" in why


def test_the_registry_check_FAILS_on_a_lock_nobody_holds(tmp_path):
    """The load bearing half.

    Standing down here would disable the registry check for as long as the file
    sits on disk, and a check that cannot fail is indistinguishable from one
    that passes (L182). This is the assertion a well meaning simplification
    would break, so it is the one worth a mutation entry.
    """
    path = lock_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('{"guard": "abandoned", "pid": 0, "started_at": 1}')

    how, why = _reaction(tmp_path)

    assert how == "failed", (
        f"a lock nobody holds must be loud, and this {how} instead")
    assert "abandoned" in why


def test_the_lock_works_in_a_git_worktree(tmp_path):
    """A worktree's `.git` is a FILE, not a directory.

    Writing the lock beside it would raise rather than lock, so a prover run
    from a worktree would die on its first guard. Agents in this setup run in
    worktrees routinely, and this was found by checking rather than by it
    failing in one (#920).

    Per worktree, not shared: the break is applied to ONE tree's files, so a
    suite in a different worktree reads different files and must go on judging.
    """
    import subprocess

    main = tmp_path / "main"
    main.mkdir()
    for args in (["init", "-q", "-b", "main"], ["config", "user.email", "t@e.com"],
                 ["config", "user.name", "T"]):
        subprocess.run(["git", *args], cwd=main, check=True, capture_output=True)
    (main / "a.txt").write_text("x\n")
    subprocess.run(["git", "add", "-A"], cwd=main, check=True, capture_output=True)
    subprocess.run(["git", "commit", "-qm", "first"], cwd=main, check=True,
                   capture_output=True)
    tree = tmp_path / "wt"
    subprocess.run(["git", "worktree", "add", "-q", str(tree)], cwd=main,
                   check=True, capture_output=True)

    assert (tree / ".git").is_file(), "the premise: a worktree's .git is a file"

    with held_for("a-guard-being-proved", tree):
        held = current(tree)
        assert held is not None and held.guard == "a-guard-being-proved"
        assert current(main) is None, (
            "the other tree's files are untouched, so its suite must go on "
            "judging rather than standing down for somebody else's break")

    assert current(tree) is None


def test_an_unreadable_lock_says_so_rather_than_inventing_a_dead_run(tmp_path):
    """Caught by the push scan, and it was right.

    A lock file that cannot be parsed took the abandoned-run branch, which told
    the reader a prover "died without cleaning up" while proving 'an unreadable
    lock', started by "pid -1". Not one of those claims was measured: the file
    could not be read, so what happened to the run is unknown, and -1 is a
    placeholder being read as a fact.

    Still a FAILURE, because a file nobody can read must not quietly stand the
    registry check down. Only the sentence changes, to one that says what was
    actually established (L11).
    """
    path = lock_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("not json at all")

    outcome, why = verdict(tmp_path)

    assert outcome is Verdict.STALE, "an unreadable lock is still loud"
    assert "could not be read" in why, f"got: {why}"
    assert "pid -1" not in why, (
        f"a placeholder must not be quoted as a process number: {why}")
    assert "died without cleaning up" not in why, (
        f"nothing established that a run died: {why}")
    assert "delete" in why.lower(), "the remedy still has to be there (L111)"


def test_a_prover_that_has_not_said_what_it_is_proving_yet_says_that(tmp_path):
    """The instant between taking the lock and writing into it.

    Real, not hypothetical: `held_for` locks BEFORE it writes, on purpose, so
    that a reader can never catch the file present and unheld. The cost is this
    window, where the file is locked and empty.

    It must not borrow the abandoned-run sentence, and it must not report
    itself as proving a guard called 'a guard prover just starting', which is
    the placeholder name leaking into a sentence as though it were a fact
    (L11).
    """
    import subprocess
    import sys

    path = lock_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch()

    # Written here rather than pointed at a file outside the repo: a test that
    # depends on a scratch directory surviving is a test that fails for a
    # reason it is not about.
    script = tmp_path / "silent_holder.py"
    script.write_text(
        "import fcntl, sys, time\n"
        "h = open(sys.argv[1], 'a+')\n"
        "fcntl.flock(h, fcntl.LOCK_EX)\n"
        "print('locked', flush=True)\n"
        "time.sleep(60)\n")

    holder = subprocess.Popen([sys.executable, str(script), str(path)],
                              stdout=subprocess.PIPE, text=True)
    try:
        assert holder.stdout.readline().strip() == "locked"

        outcome, why = verdict(tmp_path)

        assert outcome is Verdict.CANNOT_JUDGE, (
            "somebody is holding it, so this is a wait rather than a fault")
        assert "has not said what it is proving yet" in why, f"got: {why}"
        assert "just starting" not in why, (
            f"the placeholder name must not appear as a guard name: {why}")
        assert "died" not in why, f"nothing died: {why}"
    finally:
        holder.kill()
        holder.wait()


def test_a_READ_ONLY_lock_file_is_still_judged_rather_than_guessed_at(tmp_path):
    """The probe must not need write access it does not use.

    `current` reads the file, then asks the kernel whether anybody holds it.
    Those are two separate opens and the second used to ask for WRITE access,
    which a read-only lock file refuses, so the question became unanswerable
    and the code answered "nobody holds it" anyway. That is reported to the
    reader as a run that died without cleaning up, which nothing established
    (L11).

    `flock` works perfectly well on a read-only handle, so the fix is to stop
    asking for more than is used, and the case then has a real answer instead
    of a guess: this file is locked by nobody, so it IS abandoned, and saying
    so is now a measurement rather than a fallback.
    """
    import os
    import stat

    path = lock_path(tmp_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('{"guard": "real-name", "pid": 4, "started_at": 1}')
    os.chmod(path, stat.S_IRUSR)
    if os.access(path, os.W_OK):
        pytest.skip("running as a user that ignores file permissions")

    try:
        outcome, why = verdict(tmp_path)
        # And the positive half in the same fixture, so the answer above is not
        # simply the only one this code path can now produce (L159).
        assert _somebody_holds(path) is False, (
            "a read-only file must be probeable, not merely default to unheld")
    finally:
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)

    assert outcome is Verdict.STALE
    assert "real-name" in why, (
        f"it can read the file, so it must name what the run was proving: {why}")
    assert "could not be read" not in why, (
        f"the file read fine and the lock was probed, so nothing here is "
        f"unknown: {why}")
