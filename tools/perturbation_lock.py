"""Whether a guard prover currently has a source file broken on purpose (#920).

`check_guards.py` proves a guard by editing a real source file, running one
test, and putting the file back. Anything else reading the tree during that
window sees code nobody wrote. The suite's own registry check is the reader
that noticed: it reports the entry being proved as having a stale anchor, which
names a real file and a real entry and reads exactly like a genuine problem.
Four false alarms in two days, every one of them green on a re-run.

This is the shared fact both sides read. The prover writes it; the registry
check asks. Neither infers it from the other's behaviour, because a rule that
lives in two places is two rules (L26, L53).

## Why the answer is a record rather than a boolean

A boolean would collapse three situations into two. A lock held by a running
prover means "cannot judge right now". A lock file whose process is gone means
"somebody's prover died and this file is lying", which has to be LOUD: left
quiet it would suppress the registry check for as long as the file sits there,
and a check that cannot fail is indistinguishable from one that passes (L182).
An unreadable file is a third thing again, and answering None for it would let
a damaged lock read as a clean checkout (L215).

So `current()` returns what it found, and the caller decides. It never answers
None for a file that exists.
"""

from __future__ import annotations

import contextlib
import enum
import fcntl
import json
import os
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Lock:
    """What a lock file says, plus whether the process it names still exists."""

    #: Stands in for the guard name when the file cannot be parsed. A real
    #: entry name can never collide with it: registry names are kebab-case
    #: slugs and this carries spaces and a capital.
    UNREADABLE = "an unreadable lock"
    #: Taken, but the prover has not said what it is proving yet. A real state
    #: with its own name rather than one borrowed from a damaged file (L11).
    STARTING = "a guard prover just starting"

    guard: str
    pid: int
    started_at: float
    is_live: bool

    @property
    def age_seconds(self) -> float:
        return max(0.0, time.time() - self.started_at)

    def describe(self) -> str:
        """One sentence a person can act on, naming what is happening and what
        to do about it. The two cases need different remedies, so they get
        different sentences (L11)."""
        if self.guard == self.UNREADABLE:
            # Says only what was established. The file exists and could not be
            # read, so what the run was doing, and whether it is still going,
            # are both unknown, and quoting the placeholder pid as a fact was
            # the defect a push scan caught (L11).
            return ("a guard prover's lock file is there and could not be "
                    "read, so this check cannot tell whether one is running. "
                    "The tree may hold a deliberate break. Check `git status`, "
                    "restore anything a prover did not, then delete the lock "
                    "file to re-enable this check.")
        if self.guard == self.STARTING and self.is_live:
            return ("a guard prover has just taken the lock and has not said "
                    "what it is proving yet, so this check cannot judge the "
                    "tree. Re-run in a moment, or run the two one at a time.")
        if self.is_live:
            return (f"a guard prover (pid {self.pid}) is part way through "
                    f"proving {self.guard!r} and has a source file broken on "
                    f"purpose right now, so this check cannot judge the tree. "
                    f"It started {self.age_seconds:.0f}s ago. Re-run once it "
                    f"finishes, or run the two one at a time.")
        return (f"a guard prover left a lock behind: it says it was proving "
                f"{self.guard!r} (started by pid {self.pid}) and nothing is "
                f"holding the lock any more, so that run died without cleaning "
                f"up. The tree may still hold a deliberate break. Check "
                f"`git status`, restore anything the prover did not, then "
                f"delete the lock file to re-enable this check.")


def lock_path(repo_root: Path) -> Path:
    """Under `.git/`, deliberately.

    Not in the working tree: a file there is one every other tool has an
    opinion about, it would need a `.gitignore` entry, and an ignore list is
    read by other tools as a different instruction than the one you meant
    (L250). Not in a shared temp directory either, because two checkouts of
    this repo are two independent trees and must not share one lock.
    """
    git_dir = repo_root / ".git"
    if git_dir.is_file():
        # A git WORKTREE has `.git` as a FILE naming the real directory
        # elsewhere, so `.git/` cannot be written into and mkdir would raise.
        # Agents in this setup run in worktrees routinely.
        #
        # Per worktree rather than shared, deliberately: the perturbation is
        # applied to ONE working tree's files, and a suite running in a
        # different worktree reads different files, so it must NOT stand down.
        pointer = git_dir.read_text().strip()
        if pointer.startswith("gitdir:"):
            resolved = Path(pointer.split("gitdir:", 1)[1].strip())
            git_dir = resolved if resolved.is_absolute() else (repo_root / resolved)
    return git_dir / "guard-perturbation.lock"


def _somebody_holds(path: Path) -> bool:
    """Whether a process currently holds the OS lock on this file.

    Asked by trying to take it and giving it straight back. The kernel releases
    a `flock` when its holder dies, for ANY reason including a kill, so this
    cannot be fooled the way a process id can.

    It was a process id check first, and that was wrong: ids are recycled, so an
    abandoned lock whose number the system later reissues reads as a live run
    and stands the registry check down permanently and silently. That is the
    exact "a check that cannot fail looks like one that passes" failure the
    stale case exists to prevent (L182), reintroduced by the mechanism meant to
    detect it. `check_guards.build_lock` has used `flock` all along.
    """
    try:
        handle = open(path, "r+")
    except OSError:
        # Unreadable. Whether anybody holds it cannot be established, and
        # claiming "held" would stand the check down on a file nobody can read.
        return False
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return True
    else:
        fcntl.flock(handle, fcntl.LOCK_UN)
        return False
    finally:
        handle.close()


def current(repo_root: Path) -> Lock | None:
    """What is held, or None when the file genuinely is not there.

    Never None for a file that exists: an unreadable lock comes back named
    `Lock.UNREADABLE` and not live, so a damaged file cannot be mistaken for a
    clean checkout.
    """
    path = lock_path(repo_root)
    try:
        raw = path.read_text()
    except FileNotFoundError:
        return None
    except OSError:
        return Lock(guard=Lock.UNREADABLE, pid=-1, started_at=time.time(),
                    is_live=_somebody_holds(path))

    try:
        record = json.loads(raw)
        guard = str(record["guard"])
        pid = int(record["pid"])
        started_at = float(record["started_at"])
    except (ValueError, TypeError, KeyError):
        # An EMPTY file is the ordinary shape of a prover that has taken the
        # lock and not yet written what it is proving, so it is a live run
        # rather than a damaged file, and the lock is what says which.
        return Lock(guard=Lock.STARTING if not raw.strip() else Lock.UNREADABLE,
                    pid=-1, started_at=time.time(),
                    is_live=_somebody_holds(path))

    return Lock(guard=guard, pid=pid, started_at=started_at,
                is_live=_somebody_holds(path))


@contextlib.contextmanager
def held_for(guard: str, repo_root: Path):
    """Hold the lock for the duration of one guard's perturbation.

    The release is in a `finally`, so it happens on the exception path as well
    as the ordinary one: a prover that fell over mid guard must not leave the
    suite refusing for ever (L514, L515). A SIGKILL still leaves the file, which
    is exactly the stale case `current()` reports separately, because that state
    has to be representable rather than assumed away.
    """
    path = lock_path(repo_root)
    path.parent.mkdir(parents=True, exist_ok=True)

    # Opened without truncating and LOCKED BEFORE anything is written, because
    # the other order leaves a window in which the file exists and nobody holds
    # it, which is exactly the shape a reader reports as abandoned. A reader
    # catching this instant sees an empty file that IS locked, which `current`
    # names as a prover starting rather than as a damaged one.
    handle = open(path, "a+")
    fcntl.flock(handle, fcntl.LOCK_EX)
    try:
        handle.seek(0)
        handle.truncate()
        handle.write(json.dumps({"guard": guard, "pid": os.getpid(),
                                 "started_at": time.time()}))
        handle.flush()
        yield
    finally:
        # The file goes first, while the lock is still held, so no reader can
        # see it unlocked and alive at once. Then the lock, then the handle.
        # The kernel would drop the lock at close anyway, and on a kill, which
        # is the whole reason this is a lock rather than a process id (L514).
        try:
            path.unlink(missing_ok=True)
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)
            handle.close()


class Verdict(enum.Enum):
    """What a check reading the source tree should do about the lock.

    Three, not two. A running prover and a dead one both mean "the tree may be
    broken", but they need opposite reactions: one is a wait, the other is a
    fault somebody has to clear. Collapsing them is the defect (L11, L260).
    """

    #: Nothing is held. The check runs and means what it says.
    PROCEED = "proceed"
    #: A prover is mid guard. The check cannot judge and must say why.
    CANNOT_JUDGE = "cannot judge"
    #: A lock nobody is holding. Loud, because quiet would disable the check.
    STALE = "stale"


def verdict(repo_root: Path) -> tuple[Verdict, str]:
    """The outcome and the sentence explaining it.

    Returns the sentence rather than raising or skipping, so the policy can be
    asserted directly. A helper that calls `pytest.skip` can only be tested by
    catching the skip, and a skip escaping its catch marks the test SKIPPED,
    which is no verdict at all.
    """
    held = current(repo_root)
    if held is None:
        return Verdict.PROCEED, ""
    if held.is_live:
        return Verdict.CANNOT_JUDGE, held.describe()
    return Verdict.STALE, held.describe()
