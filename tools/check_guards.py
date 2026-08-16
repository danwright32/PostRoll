"""Prove the named guard tests can still go red (#416).

A guard is only real once it has been seen to fail (L1). On 2026-08-12 four
newly written guards were green against code that had been deliberately broken,
each caught only because someone broke the code by hand and watched. This makes
that a mechanism: `tests/fixtures/guard_mutations/` records, per guard, a one
line perturbation of the code it protects. For each entry this tool applies the
perturbation, runs only that guard, requires it to FAIL, and restores the file
byte for byte.

The registry is a DIRECTORY, one JSON file per entry, named for the entry it
holds, and read by globbing (#506). It was one shared file until 2026-08-13,
when ten commits across five branches all appended to it and every rebase
between them conflicted in the same place; each hand resolution was a chance to
drop an entry, which would remove a guard proof with nothing noticing. One file
per entry means two branches adding different guards never touch the same file.

Deliberately not part of the normal build, because it has to modify the working
tree and, for the Swift guards, pay a build per entry. Run it when a guard is
added or changed:

    make check-guards
    venv/bin/python tools/check_guards.py [--only <name>] [--changed]

`--changed` scopes the run to the entries the diff against main actually
touches (the protected file, the guard's own test file, or the entry's
registry record), because the full sweep pays a Swift build per Swift entry
and a price that high is how a habit dies (#426). A scoped run says how many
entries it skipped, since proving two guards says nothing about the other
thirty six (L98).

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
import os
import re
import signal
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REQUIRED_FIELDS = ("name", "file", "find", "replace", "test", "breaks")
DEFAULT_REGISTRY = Path("tests/fixtures/guard_mutations")
# The one non-entry file the registry directory is allowed to hold: the prose
# explaining the mechanism and which guards are deliberately unregistered.
REGISTRY_README = "README.md"

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


def entry_files(registry_dir: Path) -> list[Path]:
    """Every entry file in the registry directory, in a stable order.

    Anything else in there is refused rather than skipped: a `.json.bak` or a
    `.jsonc` globbed past is an entry silently missing from every sweep, and a
    sweep that quietly checked one fewer guard looks exactly like a full one
    (L100). Dotfiles are the exception, because the Finder writes .DS_Store
    into any directory Dan opens.
    """
    if not registry_dir.is_dir():
        raise RegistryError(
            f"the guard mutation registry {registry_dir} does not exist, and a "
            "missing registry is not an empty one (L98)")
    files: list[Path] = []
    for path in sorted(registry_dir.iterdir()):
        if path.name.startswith("."):
            continue
        if path.name == REGISTRY_README:
            continue
        if path.is_dir() or path.suffix != ".json":
            raise RegistryError(
                f"{path.name} sits in {registry_dir} but is not an entry file. "
                f"Every entry is one <name>.json; rename it or move it out, "
                f"because a file globbed past is a guard nobody checks.")
        files.append(path)
    return files


def load_registry(path: Path) -> list[Entry]:
    """Every entry in the registry directory, one per file.

    Each file holds a single entry object whose `name` is the file's own stem,
    so a name can never be claimed twice and any message naming a guard names
    the file to open.
    """
    entries: list[Entry] = []
    for source in entry_files(path):
        try:
            raw = json.loads(source.read_text())
        except ValueError as exc:
            raise RegistryError(
                f"{source.name} is not valid JSON ({exc}), so it cannot be "
                "read as an entry. A malformed entry stops the run rather "
                "than being skipped, because a skipped entry reads exactly "
                "like a guard nobody registered.") from exc
        except OSError as exc:
            raise RegistryError(f"{source.name} could not be read: {exc}") from exc
        if not isinstance(raw, dict):
            raise RegistryError(
                f"{source.name} holds {type(raw).__name__}, not one entry "
                "object. Every file in the registry is exactly one entry.")
        missing = [f for f in REQUIRED_FIELDS if f not in raw]
        if missing:
            raise RegistryError(
                f"{source.name} is missing {', '.join(missing)}")
        entry = Entry(**{f: raw[f] for f in REQUIRED_FIELDS})
        if entry.name != source.stem:
            raise RegistryError(
                f"{source.name} declares the name {entry.name!r}. Each entry "
                f"file is named for the entry it holds, so it belongs in "
                f"{entry.name}.json; that rule is also what stops two files "
                f"claiming one name.")
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


#: Where the project's one build cache is defined, for the Makefile,
#: build-install.sh and now this tool. Read rather than copied: two spellings of
#: one location is how a second cache quietly starts filling (L41).
DERIVED_DATA_DEFINITION = Path("PostRollApp") / "derived-data-path.sh"


def derived_data_path(repo_root: Path) -> str | None:
    """The shared build cache, or None when this checkout cannot name one.

    Sourced through a shell for the same reason the Makefile sources it: the
    definition is a shell script, and parsing it here would be a second
    implementation of the expansion that only agrees with the first until the
    script says something more interesting than a plain assignment.

    None rather than a guessed default, because a guess would put builds
    somewhere nothing else looks and still read as sharing.
    """
    script = repo_root / DERIVED_DATA_DEFINITION
    if not script.is_file():
        return None
    try:
        completed = subprocess.run(
            ["bash", "-c", '. "$1"; printf %s "$POSTROLL_DERIVED_DATA"',
             "_", str(script)],
            capture_output=True, text=True, timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    path = completed.stdout.strip()
    # An empty answer is an absent one, not a valid location: a templating or
    # shell read routinely renders a missing setting as the empty string, and
    # accepting it would build into the current directory (L138).
    return path or None


def command_for(entry: Entry, repo_root: Path) -> list[str]:
    if entry.test.startswith("PostRollTests/"):
        cmd = [
            "xcodebuild",
            "-project", str(repo_root / "PostRollApp" / "PostRoll.xcodeproj"),
            "-scheme", "PostRollTests",
            "-destination", "platform=macOS",
            f"-only-testing:{entry.test}",
        ]
        # One warm cache across every entry (#621). Each entry perturbs a single
        # file, so a shared cache recompiles that file and its dependents rather
        # than the whole app: the sweep used to pass no path at all, which sends
        # xcodebuild to a location of its own choosing that starts empty and is
        # never the one `make build` has already filled.
        cache = derived_data_path(repo_root)
        if cache is not None:
            cmd += ["-derivedDataPath", cache]
        return cmd + ["test"]
    return [python_for(repo_root), "-m", "pytest", entry.test, "-q"]


def python_for(repo_root: Path) -> str:
    """Which interpreter runs the Python guards.

    The repo's venv when there is one, because that is where this project's
    pytest and its dependencies live and it is how every local run is invoked.
    Otherwise the interpreter running this file, which is what a CI runner has:
    the path was hardcoded, so every Python entry reported "the runner failed:
    no such file" the first time this ran anywhere but Dan's Mac (#541).

    Note that is the tool being honest rather than the tool working. An entry
    whose command cannot start is an ERROR, not a pass, which is why the job
    went red rather than reporting the guards proven.
    """
    venv = repo_root / "venv" / "bin" / "python"
    return str(venv) if venv.exists() else sys.executable


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


def _git(repo_root: Path, *args: str) -> str | None:
    completed = subprocess.run(["git", *args], cwd=repo_root,
                               capture_output=True, text=True)
    if completed.returncode != 0:
        return None
    return completed.stdout


def merge_base(repo_root: Path) -> str | None:
    """What a scoped run diffs against: main first, the upstream only as a
    fallback.

    Main first because the question is "does my unmerged work touch a
    registered guard", and a branch's own upstream already holds the change
    the moment it is pushed, so a run based there answers "nothing to verify"
    about work main has never seen."""
    for candidate in ("origin/main", "origin/master", "@{upstream}"):
        out = _git(repo_root, "merge-base", candidate, "HEAD")
        if out and out.strip():
            return out.strip()
    return None


def changed_files(repo_root: Path, base: str) -> set[str] | None:
    """Everything the diff against the base touches, uncommitted work
    included, because the moment --changed serves is mid-edit.

    None when git itself failed: a failed diff must never read as an empty
    one, or the scoped run silently skips every entry (L11)."""
    diff = _git(repo_root, "diff", "--name-only", f"{base}..HEAD")
    status = _git(repo_root, "status", "--porcelain")
    if diff is None or status is None:
        return None
    files = {line for line in diff.splitlines() if line.strip()}
    files.update(line[3:] for line in status.splitlines() if len(line) > 3)
    return files


def changed_registry_names(repo_root: Path, registry_path: Path,
                           base: str) -> set[str]:
    """Names of entries that are new or edited relative to the base, so a
    reworded perturbation re-proves itself without dragging the whole
    registry along.

    Compared field by field rather than by file text, so reindenting an entry
    does not select it while any change to what the perturbation actually does
    always will."""
    changed: set[str] = set()
    for entry in load_registry(registry_path):
        source = registry_path / f"{entry.name}.json"
        try:
            rel = source.resolve().relative_to(repo_root.resolve())
        except ValueError:
            continue  # registry outside the repo: no record diff to take
        old_text = _git(repo_root, "show", f"{base}:{rel.as_posix()}")
        if old_text is None:
            changed.add(entry.name)  # this entry is new at this base
            continue
        try:
            old = json.loads(old_text)
        except ValueError:
            changed.add(entry.name)
            continue
        if not isinstance(old, dict):
            changed.add(entry.name)
            continue
        if any(old.get(f) != getattr(entry, f) for f in REQUIRED_FIELDS):
            changed.add(entry.name)
    return changed



# ── Narrowing a scoped run to the guard that actually moved (#634) ────────────
#
# `--changed` selected an entry whenever its guard TEST FILE was in the diff.
# BannerLegibilityTests.swift holds around forty entries, so editing one guard
# in it re-proved all forty, at the 12 to 22 seconds each that #621 measured.
#
# The narrowing has an honest half and a dangerous half. A guard's behaviour
# lives as much in the matcher it calls as in the function that asserts on it,
# and editing a shared helper leaves every test function byte for byte
# identical, so selecting only changed FUNCTIONS would skip precisely the
# entries whose meaning just changed. Anything outside the test functions
# therefore selects them all.


def _swift_test_bodies(text: str) -> dict[str, str] | None:
    """Each `func testX` mapped to its body, or None if the braces do not close.

    None rather than a best effort, because a file this cannot read is one it
    knows nothing about, and the safe answer is to run everything (L11)."""
    bodies: dict[str, str] = {}
    for match in re.finditer(r"\bfunc\s+(test[A-Za-z0-9_]*)\s*\(", text):
        opening = text.find("{", match.end())
        if opening == -1:
            return None
        depth, index = 0, opening
        while index < len(text):
            if text[index] == "{":
                depth += 1
            elif text[index] == "}":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        if depth != 0:
            return None
        bodies[match.group(1)] = text[match.start():index + 1]
    return bodies


def _python_test_bodies(text: str) -> dict[str, str] | None:
    """The same for module level `def test_x`, bounded by the next top level
    line."""
    bodies: dict[str, str] = {}
    lines = text.split("\n")
    starts = [(i, m.group(1))
              for i, line in enumerate(lines)
              if (m := re.match(r"def\s+(test[A-Za-z0-9_]*)\s*\(", line))]
    for position, (start, name) in enumerate(starts):
        end = len(lines)
        for later in range(start + 1, len(lines)):
            if lines[later] and not lines[later][0].isspace():
                end = later
                break
        bodies[name] = "\n".join(lines[start:end])
        _ = position
    return bodies


def test_bodies(text: str, path: str) -> dict[str, str] | None:
    return (_python_test_bodies(text) if path.endswith(".py")
            else _swift_test_bodies(text))


def _outside_the_tests(text: str, bodies: dict[str, str]) -> str:
    """Everything in the file that is not inside a test function: the imports,
    the fixtures, and the matchers the tests lean on."""
    for body in bodies.values():
        text = text.replace(body, "")
    return text


def test_method(entry: Entry) -> str:
    """The function name inside the guard test file."""
    return (entry.test.split("::")[-1].split("[")[0] if entry.test.startswith("tests/")
            else entry.test.split("/")[-1])


def guards_touched_by(repo_root: Path, base: str, path: str,
                      entries: list[Entry], log=print) -> set[str] | None:
    """Which of `entries` a change to guard test file `path` really affects.

    None when it cannot tell, which the caller treats as "all of them"."""
    target = repo_root / path
    new_text = target.read_text() if target.is_file() else None
    old_text = _git(repo_root, "show", f"{base}:{path}")
    if new_text is None or old_text is None:
        log(f"{path}: it could not be read at both ends of the diff, so every "
            "guard in it is being re-proven rather than guessed at")
        return None

    new_bodies = test_bodies(new_text, path)
    old_bodies = test_bodies(old_text, path)
    if new_bodies is None or old_bodies is None:
        log(f"{path}: the test functions could not be read, so every guard in "
            "it is being re-proven rather than guessed at")
        return None

    # Anything outside the test functions is shared: a matcher, a fixture, a
    # threshold. Changing one of those changes what every test in the file
    # means while leaving each function identical.
    if _outside_the_tests(new_text, new_bodies) \
            != _outside_the_tests(old_text, old_bodies):
        return {e.name for e in entries}

    return {e.name for e in entries
            if new_bodies.get(test_method(e)) != old_bodies.get(test_method(e))}


def guard_test_path(entry: Entry, repo_root: Path) -> str | None:
    """The file the entry's guard test lives in, repo-relative."""
    if entry.test.startswith("tests/"):
        return entry.test.split("::")[0]
    class_name = entry.test.split("/")[1]
    tests_dir = repo_root / "PostRollApp" / "Tests"
    if tests_dir.is_dir():
        pattern = re.compile(rf"\bclass {re.escape(class_name)}\b")
        for path in sorted(tests_dir.glob("*.swift")):
            if pattern.search(path.read_text()):
                return path.relative_to(repo_root).as_posix()
    return None


def real_runner(cmd: list[str], cwd: Path) -> tuple[int, str]:
    # No bytecode may be written from MUTATED source. The mutation and the
    # restore can land in the same clock second with the same file size, and
    # Python's cache validation checks exactly those two stand-ins, so a cache
    # compiled from the broken code would outlive the restore and later suite
    # runs would fail on code no file contains (L40; seen live 2026-08-12).
    env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
    completed = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                               env=env)
    return completed.returncode, completed.stdout + completed.stderr


# ── Putting the tree back when the sweep is interrupted (#547) ────────────────
#
# The try/finally in run_entry covers an exception and a ctrl-C, because both
# unwind the stack. SIGTERM does not: the default disposition terminates the
# process outright, so the finally never runs. A sweep killed to free the
# machine on 2026-08-13 left ProgramPDFBakery.swift holding
# `first(where: { _ in false })`, which compiles, reads plausibly, and makes the
# bake find no event.
#
# What is on disk while a perturbation is applied, so a handler can put it back.
# At most one entry is ever in flight, but this is keyed by path rather than
# held as a single value so a restore cannot be attributed to the wrong file.
_PENDING: dict[Path, bytes] = {}


def _restore_pending() -> tuple[list[Path], list[tuple[Path, OSError]]]:
    """Put every perturbed file back.

    Returns what it restored AND what it could not. A restore that fails is the
    single worst outcome this whole mechanism exists to prevent, so it is never
    swallowed: reporting only the successes would leave a broken file on disk
    looking exactly like a clean exit (L11).
    """
    restored: list[Path] = []
    failed: list[tuple[Path, OSError]] = []
    for path, original in list(_PENDING.items()):
        try:
            path.write_bytes(original)
        except OSError as exc:
            failed.append((path, exc))
            continue  # stays pending, and is reported
        _PENDING.pop(path, None)
        restored.append(path)
    return restored, failed


def install_interrupt_restore(repo_root: Path, log=print) -> None:
    """Restore the working tree on SIGINT and SIGTERM, then exit.

    The report is not decoration. A sweep that silently puts things back is
    indistinguishable from one that silently left them broken, and the operator
    has no reason to look at either (L11).
    """
    def shown(path: Path) -> str:
        try:
            return path.relative_to(repo_root).as_posix()
        except ValueError:
            return str(path)

    def handler(signum, _frame):
        name = signal.Signals(signum).name
        restored, failed = _restore_pending()
        for path in restored:
            log(f"interrupted by {name}: put {shown(path)} back")
        if not restored and not failed:
            log(f"interrupted by {name}: nothing was perturbed, "
                "so nothing needed putting back")
        # As loud as this can be made. The working tree is now holding broken
        # code that compiles and reads plausibly, which is the whole condition
        # this handler exists to prevent, and a quiet exit here would look
        # exactly like the clean one above.
        for path, exc in failed:
            log(f"interrupted by {name}: FAILED to put {shown(path)} back ({exc}). "
                f"It still holds the perturbation. Recover it with: "
                f"git checkout -- {shown(path)}")
        sys.stdout.flush()
        sys.stderr.flush()
        # Not sys.exit: this runs while the main thread is blocked in the test
        # runner, and unwinding from there would let the ordinary finally race
        # the restore that has already happened. The tree is right; leave now.
        #
        # A failed restore gets its own code, so a caller can tell "interrupted,
        # tree clean" from "interrupted, tree broken" without parsing the log.
        os._exit(1 if failed else 128 + signum)

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            signal.signal(sig, handler)
        except ValueError:
            # Not the main thread. Nothing to install, and the caller is a
            # library consumer rather than the command line tool.
            return


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

    # Recorded BEFORE the write, so a signal landing between the two finds the
    # original bytes to put back rather than nothing (#547).
    _PENDING[target] = original
    target.write_bytes(text.replace(entry.find, entry.replace).encode("utf-8"))
    try:
        code, output = runner(command_for(entry, repo_root), repo_root)
        verdict = classify(entry, code, output)
    except Exception as exc:  # noqa: BLE001  the restore below must always run
        verdict = Verdict(Outcome.ERROR, f"the runner failed: {exc}")
    finally:
        target.write_bytes(original)
        _PENDING.pop(target, None)
        if target.read_bytes() != original:
            # Fail as loudly as possible: the working tree is now wrong.
            raise RuntimeError(
                f"{entry.file} could not be restored. Recover it with: "
                f"git checkout -- {entry.file}")
    return Result(entry, verdict.outcome, verdict.detail)


def check_guards(repo_root: Path, registry_path: Path, runner,
                 only: str | None = None, changed_only: bool = False,
                 log=print) -> int:
    # Installed here rather than in main() so every caller that can perturb the
    # tree is covered, including the tests that drive this directly (#547).
    install_interrupt_restore(repo_root, log=log)
    entries = load_registry(registry_path)
    if only is not None:
        entries = [e for e in entries if e.name == only]
        if not entries:
            log(f"no registered guard is named {only!r}")
            return 1
    if not entries:
        log("the registry holds no guards, so nothing was proven (L98)")
        return 1

    if changed_only:
        base = merge_base(repo_root)
        if base is None:
            log("--changed needs a base to diff against (an upstream branch "
                "or origin/main) and this repository has neither; run the "
                "full sweep instead")
            return 1
        touched = changed_files(repo_root, base)
        if touched is None:
            log(f"the diff against {base[:12]} could not be taken, and a "
                "failed diff must not pass for an empty one; run the full "
                "sweep instead")
            return 1
        stale = changed_registry_names(repo_root, registry_path, base)
        # Which entries the diff reaches through their guard TEST file, worked
        # out per file so one edit does not drag its neighbours along (#634).
        by_test_file: dict[str, list[Entry]] = {}
        for entry in entries:
            path = guard_test_path(entry, repo_root)
            if path is not None and path in touched:
                by_test_file.setdefault(path, []).append(entry)

        through_tests: set[str] = set()
        for path, sharing in by_test_file.items():
            affected = guards_touched_by(repo_root, base, path, sharing, log=log)
            through_tests |= ({e.name for e in sharing} if affected is None
                              else affected)

        selected = [e for e in entries
                    if e.file in touched or e.name in stale
                    or e.name in through_tests]
        log(f"--changed: {len(selected)} of {len(entries)} entries affected "
            f"by the diff against {base[:12]}; {len(entries) - len(selected)} "
            "skipped as untouched, which proves nothing about them (run "
            "without --changed for the full sweep)")
        if not selected:
            log("no registered guard is affected by this diff, so nothing "
                "was verified")
            return 0
        entries = selected

    # Said out loud, because a sweep paying a whole build for every entry looks
    # exactly like one reusing a cache until somebody times it (#621). It is not
    # a refusal: the guards are still proven, just at the old cost.
    if any(e.test.startswith("PostRollTests/") for e in entries) \
            and derived_data_path(repo_root) is None:
        log(f"{DERIVED_DATA_DEFINITION} names no build cache here, so each "
            "Swift entry below pays a full app build of its own instead of "
            "reusing one")

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
    parser.add_argument("--changed", action="store_true",
                        help="run only the entries whose protected file, "
                             "guard test file, or registry record changed "
                             "since the merge base with main")
    parser.add_argument("--registry", type=Path, default=None,
                        help="registry directory, one JSON file per entry "
                             f"(default {DEFAULT_REGISTRY})")
    args = parser.parse_args(argv)

    repo_root = Path(__file__).resolve().parent.parent
    registry = args.registry or repo_root / DEFAULT_REGISTRY
    return check_guards(repo_root, registry, real_runner, only=args.only,
                        changed_only=args.changed)


if __name__ == "__main__":
    sys.exit(main())
