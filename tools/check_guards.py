"""Prove the named guard tests can still go red (#416).

A guard is only real once it has been seen to fail (L1). On 2026-08-12 four
newly written guards were green against code that had been deliberately broken,
each caught only because someone broke the code by hand and watched. This makes
that a mechanism: `tests/fixtures/guard_mutations.json` records, per guard, a
one line perturbation of the code it protects. For each entry this tool applies
the perturbation, runs only that guard, requires it to FAIL, and restores the
file byte for byte.

Deliberately not part of the normal build, because it has to modify the working
tree and, for the Swift guards, pay a build per entry. Run it when a guard is
added or changed:

    make check-guards
    venv/bin/python tools/check_guards.py [--only <name>]

Three outcomes per entry, kept distinct on purpose (L11):
  KILLED    the guard went red on the broken code, which is the pass.
  SURVIVED  the guard stayed green on broken code: coverage that does not
            exist. The run fails.
  ERROR     the verdict could not be taken: the anchor no longer matches the
            code (the registry is stale), the target file has uncommitted
            changes, the build broke, or the test never ran. Zero tests
            executed is an error, never a kill (L98): a mutation that breaks
            compilation fails every test trivially and proves nothing about
            the guard.

`tests/test_guard_mutation_registry.py` keeps the registry honest inside the
normal suite: every anchor still matches its file exactly once and every named
test still exists, so an entry whose target has moved fails there long before
anyone runs this.
"""

from __future__ import annotations

import argparse
import enum
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REQUIRED_FIELDS = ("name", "file", "find", "replace", "test", "breaks")
DEFAULT_REGISTRY = Path("tests/fixtures/guard_mutations.json")

# The grand total xcodebuild prints after the per-suite lines; the last match
# in the transcript is the 'All tests' total.
EXECUTED = re.compile(r"Executed (\d+) tests?, with (\d+) failures?")


class RegistryError(Exception):
    """The registry itself is malformed. Nothing runs until it is fixed."""


class Outcome(enum.Enum):
    KILLED = "KILLED"
    SURVIVED = "SURVIVED"
    ERROR = "ERROR"


@dataclass(frozen=True)
class Entry:
    name: str
    file: str
    find: str
    replace: str
    test: str
    breaks: str


@dataclass(frozen=True)
class Verdict:
    outcome: Outcome
    detail: str = ""


@dataclass(frozen=True)
class Result:
    entry: Entry
    outcome: Outcome
    detail: str = ""


def load_registry(path: Path) -> list[Entry]:
    data = json.loads(path.read_text())
    entries: list[Entry] = []
    names: set[str] = set()
    for raw in data.get("entries", []):
        missing = [f for f in REQUIRED_FIELDS if f not in raw]
        if missing:
            raise RegistryError(
                f"entry {raw.get('name', '<unnamed>')} is missing "
                f"{', '.join(missing)}")
        entry = Entry(**{f: raw[f] for f in REQUIRED_FIELDS})
        if entry.name in names:
            raise RegistryError(f"two entries are named {entry.name}")
        names.add(entry.name)
        if entry.find == entry.replace:
            raise RegistryError(
                f"{entry.name} changes nothing: find and replace are identical, "
                "so a green run would prove nothing (L1)")
        if not (entry.test.startswith("PostRollTests/")
                or entry.test.startswith("tests/")):
            raise RegistryError(
                f"{entry.name} names a test this tool does not know how to run: "
                f"{entry.test}")
        entries.append(entry)
    return entries


def command_for(entry: Entry, repo_root: Path) -> list[str]:
    if entry.test.startswith("PostRollTests/"):
        return [
            "xcodebuild",
            "-project", str(repo_root / "PostRollApp" / "PostRoll.xcodeproj"),
            "-scheme", "PostRollTests",
            "-destination", "platform=macOS",
            f"-only-testing:{entry.test}",
            "test",
        ]
    return [str(repo_root / "venv" / "bin" / "python"), "-m", "pytest",
            entry.test, "-q"]


def classify_swift(returncode: int, output: str) -> Verdict:
    totals = EXECUTED.findall(output)
    if not totals:
        return Verdict(Outcome.ERROR,
                       "the test never ran: no executed-tests total in the "
                       "transcript, so the build broke or the test does not "
                       "exist, and neither is a verdict on the guard")
    executed, failures = (int(n) for n in totals[-1])
    if executed == 0:
        return Verdict(Outcome.ERROR,
                       "0 tests executed: the spec matched nothing, which is "
                       "not a green run (L98)")
    if failures > 0:
        # xcodebuild counts assertion failures, so this can exceed the number
        # of tests when one test records several.
        return Verdict(Outcome.KILLED,
                       f"{failures} failure{'s' if failures != 1 else ''} "
                       f"across {executed} test{'s' if executed != 1 else ''}")
    if returncode == 0:
        return Verdict(Outcome.SURVIVED,
                       f"all {executed} passed on the broken code")
    return Verdict(Outcome.ERROR,
                   f"xcodebuild exited {returncode} with no failing test, "
                   "which is a tooling problem rather than a verdict")


def classify_pytest(returncode: int) -> Verdict:
    if returncode == 1:
        return Verdict(Outcome.KILLED, "pytest reported failing tests")
    if returncode == 0:
        return Verdict(Outcome.SURVIVED, "pytest passed on the broken code")
    if returncode == 5:
        return Verdict(Outcome.ERROR,
                       "pytest collected no tests: the spec matched nothing, "
                       "which is not a green run (L98)")
    return Verdict(Outcome.ERROR, f"pytest exited {returncode}, "
                   "which is not a verdict on the guard")


def classify(entry: Entry, returncode: int, output: str) -> Verdict:
    if entry.test.startswith("PostRollTests/"):
        return classify_swift(returncode, output)
    return classify_pytest(returncode)


def real_runner(cmd: list[str], cwd: Path) -> tuple[int, str]:
    completed = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return completed.returncode, completed.stdout + completed.stderr


def _dirty(path: Path, repo_root: Path) -> bool:
    status = subprocess.run(
        ["git", "status", "--porcelain", "--", str(path)],
        cwd=repo_root, capture_output=True, text=True, check=True)
    return bool(status.stdout.strip())


def run_entry(entry: Entry, repo_root: Path, runner) -> Result:
    target = repo_root / entry.file
    if not target.is_file():
        return Result(entry, Outcome.ERROR,
                      f"{entry.file} does not exist; the registry is stale")
    if _dirty(target, repo_root):
        return Result(entry, Outcome.ERROR,
                      f"{entry.file} has uncommitted changes; commit or stash "
                      "them first, so a failed restore is always recoverable "
                      "with git")

    original = target.read_bytes()
    text = original.decode("utf-8")
    matches = text.count(entry.find)
    if matches != 1:
        return Result(entry, Outcome.ERROR,
                      f"the anchor for {entry.name} matches {matches} places "
                      f"in {entry.file} instead of exactly one; the registry "
                      f"is stale. Anchor: {entry.find!r}")

    target.write_bytes(text.replace(entry.find, entry.replace).encode("utf-8"))
    try:
        code, output = runner(command_for(entry, repo_root), repo_root)
        verdict = classify(entry, code, output)
    except Exception as exc:  # noqa: BLE001  the restore below must always run
        verdict = Verdict(Outcome.ERROR, f"the runner failed: {exc}")
    finally:
        target.write_bytes(original)
        if target.read_bytes() != original:
            # Fail as loudly as possible: the working tree is now wrong.
            raise RuntimeError(
                f"{entry.file} could not be restored. Recover it with: "
                f"git checkout -- {entry.file}")
    return Result(entry, verdict.outcome, verdict.detail)


def check_guards(repo_root: Path, registry_path: Path, runner,
                 only: str | None = None, log=print) -> int:
    entries = load_registry(registry_path)
    if only is not None:
        entries = [e for e in entries if e.name == only]
        if not entries:
            log(f"no registered guard is named {only!r}")
            return 1
    if not entries:
        log("the registry holds no guards, so nothing was proven (L98)")
        return 1

    results = []
    for entry in entries:
        log(f"{entry.name}: breaking {entry.file} "
            f"({entry.breaks}), expecting {entry.test} to go red")
        result = run_entry(entry, repo_root, runner)
        results.append(result)
        log(f"{entry.name}: {result.outcome.value}"
            + (f", {result.detail}" if result.detail else ""))

    bad = [r for r in results if r.outcome is not Outcome.KILLED]
    log(f"{len(results)} guard{'s' if len(results) != 1 else ''} checked, "
        f"{len(results) - len(bad)} killed their mutation, {len(bad)} did not")
    for r in bad:
        if r.outcome is Outcome.SURVIVED:
            log(f"  {r.entry.name}: the guard stayed GREEN on broken code. "
                f"It is not protecting {r.entry.file} and needs rewriting.")
        else:
            log(f"  {r.entry.name}: {r.detail}")
    return 1 if bad else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--only", help="run a single registry entry by name")
    parser.add_argument("--registry", type=Path, default=None,
                        help=f"registry path (default {DEFAULT_REGISTRY})")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parent.parent
    registry = args.registry or repo_root / DEFAULT_REGISTRY
    return check_guards(repo_root, registry, real_runner, only=args.only)


if __name__ == "__main__":
    sys.exit(main())
