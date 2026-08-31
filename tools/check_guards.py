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
import contextlib
import ast
import enum
import json
import os
import platform
import re
import signal
import fcntl
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

# As a module, deliberately: this file has its own `Verdict` and importing the
# other one by name would shadow it silently.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from tools import guard_entry_costs, perturbation_lock  # noqa: E402

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
    #: How long this ONE entry took, which is the reading #1090 exists for.
    #: The run printed elapsed-since-start and stored nothing, so the only
    #: number anyone could derive was an average over a whole sweep, and an
    #: average across costs that differ by 90x hides everything (L296).
    seconds: float = 0.0


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


#: The module a prover holds while it has a source file deliberately broken
#: (#920). A check that consults it and stands down is a check that cannot
#: report anything while a sweep is running, which is exactly when an entry
#: naming it would be proved.
PERTURBATION_LOCK = "perturbation_lock"


def _lock_names(tree: ast.Module) -> set[str]:
    """Every name in this module that refers to the perturbation lock.

    Both spellings, because the two files that read it use one each:
    `from tools import perturbation_lock` binds the module, and
    `from tools.perturbation_lock import verdict` binds the function. A rule
    that knew only the first would pass every file written the second way.
    """
    bound: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                leaf = alias.name.split(".")[-1]
                if leaf == PERTURBATION_LOCK:
                    bound.add(alias.asname or leaf)
        elif isinstance(node, ast.ImportFrom):
            from_lock = (node.module or "").split(".")[-1] == PERTURBATION_LOCK
            for alias in node.names:
                if from_lock or alias.name == PERTURBATION_LOCK:
                    bound.add(alias.asname or alias.name)
    return bound


def _identifiers_in(node: ast.AST) -> set[str]:
    return {child.id for child in ast.walk(node) if isinstance(child, ast.Name)} | {
        child.attr for child in ast.walk(node) if isinstance(child, ast.Attribute)}


def _calls_in(node: ast.AST) -> set[str]:
    called: set[str] = set()
    for child in ast.walk(node):
        if not isinstance(child, ast.Call):
            continue
        if isinstance(child.func, ast.Name):
            called.add(child.func.id)
        elif isinstance(child.func, ast.Attribute):
            called.add(child.func.attr)
    return called


def _functions(tree: ast.Module) -> list[ast.FunctionDef | ast.AsyncFunctionDef]:
    return [node for node in ast.walk(tree)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))]


#: The two calls in the lock module that report its STATE, as opposed to the
#: ones that merely name a path or take it.
#:
#: Narrowed to these deliberately. Deriving from any lock function at all read
#: `path = lock_path(tmp_path)` as a stand-down decision, which made the
#: read-only case in `tests/test_perturbation_lock.py` look like a helper that
#: silences itself, and that file is the alternative this whole refusal
#: recommends. A rename here would weaken the detection silently, so
#: `test_the_real_stand_down_helper_is_recognised` holds these names to the
#: helper that actually exists (L96).
LOCK_STATE_READERS = ("verdict", "current")


def _lock_derived(node: ast.AST, lock: set[str]) -> set[str]:
    """Names assigned out of a call that reports the lock's state.

    `outcome, why = perturbation_lock.verdict(root)` binds two of them, and the
    skip that follows is usually written against those rather than against the
    module, so a rule reading only the module name would miss the shape it
    exists to catch.
    """
    derived: set[str] = set()
    for child in ast.walk(node):
        if not isinstance(child, ast.Assign) or not isinstance(child.value, ast.Call):
            continue
        called = _calls_in(child.value)
        if not (_identifiers_in(child.value.func) & lock
                and called & set(LOCK_STATE_READERS)):
            continue
        for target in child.targets:
            derived |= {name.id for name in ast.walk(target)
                        if isinstance(name, ast.Name)}
    return derived


def _stands_down_on_the_lock(node: ast.AST, lock: set[str]) -> bool:
    """Whether this function skips BECAUSE of what the lock said.

    Reading the lock and skipping somewhere in the same function is not enough,
    and getting that wrong would refuse the remedy along with the defect (L104).
    `tests/test_perturbation_lock.py` reads the lock harder than anything else
    here, and one of its cases skips when the process can write through a
    read-only file, which has nothing to do with a prover: that test is the
    alternative this refusal recommends, so it has to survive the rule.

    What separates them is what GOVERNS the skip. A stand-down is a skip whose
    condition, or whose reason, comes from the lock.
    """
    governed = lock | _lock_derived(node, lock)
    for child in ast.walk(node):
        if isinstance(child, ast.If) and _identifiers_in(child.test) & governed:
            if any("skip" in _calls_in(branch)
                   for branch in (*child.body, *child.orelse)):
                return True
        if isinstance(child, ast.Call) and "skip" in _calls_in(child):
            if any(_identifiers_in(arg) & governed for arg in child.args):
                return True
    return False


def _own_nodes(node: ast.AST):
    """Everything inside this function except the bodies of functions nested in
    it, so a catch belonging to an inner helper is not read as the outer one's.
    """
    stack = list(ast.iter_child_nodes(node))
    while stack:
        child = stack.pop()
        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        yield child
        stack.extend(ast.iter_child_nodes(child))


def _skip_catchers_in(tree: ast.Module) -> set[str]:
    """Functions that CATCH the stand-down rather than being stopped by it.

    This is the pattern the refusal recommends, so it has to survive the rule
    that the refusal implements. `tests/test_perturbation_lock.py::_reaction`
    calls the real helper with an injected checkout and converts the skip into a
    value, and the registered entry `a-lock-nobody-holds-is-loud` points at a
    test that goes through it. Following the call graph without noticing the
    catch refuses that entry, and the message would then forbid the thing it
    tells people to do (L104).

    A catch breaks the chain in both directions: such a function can never be
    silenced itself, and a caller reaching the helper only through it cannot be
    silenced either, because no skip escapes.
    """
    caught: set[str] = set()
    for node in _functions(tree):
        for child in _own_nodes(node):
            if isinstance(child, ast.ExceptHandler) and child.type is not None:
                if "skip" in _identifiers_in(child.type):
                    caught.add(node.name)
                    break
            # `with pytest.raises(pytest.skip.Exception)` catches it too. The
            # helper in this repository deliberately does NOT use that form,
            # because a skip escaping a `raises` marks the whole test SKIPPED,
            # but a rule that only knew try/except would refuse a file written
            # the other way (L173).
            if (isinstance(child, ast.Call) and "raises" in _calls_in(child)
                    and any("skip" in _identifiers_in(arg) for arg in child.args)):
                caught.add(node.name)
                break
    return caught


def _silencers_in(tree: ast.Module) -> set[str]:
    """Functions in this module that stand a check down for the lock."""
    lock = _lock_names(tree)
    if not lock:
        return set()
    return {node.name for node in _functions(tree)
            if _stands_down_on_the_lock(node, lock)} - _skip_catchers_in(tree)


#: Parsed modules are kept, because `load_registry` runs several times in one
#: collection and the tests directory does not change underneath a run.
_HELPER_CACHE: dict[str, frozenset[str]] = {}


def stand_down_helpers(tests_dir: Path) -> frozenset[str]:
    """Every function under `tests_dir` that stands a check down for the lock.

    Scanned across the whole directory rather than per module, because the
    helper is declared in one file and any other file may call it by importing
    it. A file that cannot be parsed is passed over rather than raising: this
    answers a question about the registry, and a syntax error somewhere else in
    the suite is not that question and will be reported by the run itself.
    """
    key = str(tests_dir)
    if key in _HELPER_CACHE:
        return _HELPER_CACHE[key]

    found: set[str] = set()
    for path in sorted(tests_dir.rglob("*.py")):
        try:
            tree = ast.parse(path.read_text(encoding="utf-8"))
        except (OSError, SyntaxError):
            continue
        found |= _silencers_in(tree)
    result = frozenset(found)
    _HELPER_CACHE[key] = result
    return result


#: Which functions in a given module the prover can silence, by module path.
#:
#: Per module rather than per entry: 413 entries name barely a hundred distinct
#: files between them, and without this every entry re-parsed its module, which
#: measured at 1.5 seconds per registry load. `load_registry` runs several times
#: in one collection, in every xdist worker.
_SILENCED_CACHE: dict[str, frozenset[str]] = {}


def silenced_functions(module_path: Path, repo_root: Path) -> frozenset[str]:
    """Every test in this module that a running prover would stand down.

    A function is silenced when it reaches a stand-down helper and the skip can
    still escape. A function that CATCHES the skip is neither silenced nor a
    route to it, which is what keeps the recommended pattern legal.
    """
    key = str(module_path)
    if key in _SILENCED_CACHE:
        return _SILENCED_CACHE[key]

    try:
        tree = ast.parse(module_path.read_text(encoding="utf-8"))
    except (OSError, SyntaxError):
        # A NON-ANSWER, not a measurement of nothing. Deliberately not cached,
        # because caching it would turn "could not read this module" into "this
        # module silences nobody" for the rest of the process, and those two are
        # indistinguishable once they share a representation (L215).
        #
        # Passed over rather than raised because it is not this check's
        # question: a test module that cannot be parsed fails collection in the
        # run itself, loudly and by name, and refusing here as well would give
        # one fault two names and the wrong one first (L11).
        return frozenset()

    # A name defined in THIS module wins over the same name found elsewhere, so
    # a local function that happens to share a helper's name is judged on what
    # it actually does rather than on where its name has been seen before.
    local = _silencers_in(tree)
    declared_here = {node.name for node in _functions(tree)}
    catchers = _skip_catchers_in(tree)
    targets = ((stand_down_helpers(repo_root / "tests")
                - (declared_here - local)) | local) - catchers
    if not targets:
        _SILENCED_CACHE[key] = frozenset()
        return _SILENCED_CACHE[key]

    reaching = {node.name for node in _functions(tree)
                if node.name not in catchers and _calls_in(node) & targets}
    changed = True
    while changed:
        changed = False
        for node in _functions(tree):
            if node.name in reaching or node.name in catchers:
                continue
            if _calls_in(node) & reaching:
                reaching.add(node.name)
                changed = True

    _SILENCED_CACHE[key] = frozenset(reaching | targets)
    return _SILENCED_CACHE[key]


def silenced_by_the_prover(entry: Entry, repo_root: Path) -> str | None:
    """Why this entry can never be proved, or None when it can (#931).

    The prover holds the perturbation lock across each entry, and any check
    that consults that lock stands down while it is held. An entry naming one
    of those checks therefore has its code broken, its test skipped, and no
    failure seen, on every sweep for ever.

    The sweep does not go quiet about it, but what it says is wrong: a
    skip-only run has been reported as ERROR since #665, and the message that
    ERROR carries blames a missing external, which sends the reader off to
    install ffmpeg over a problem that has nothing to do with one (L11). So the
    refusal belongs at load time, where the cause is known.

    Silent on an entry whose test file is not there. That is a real fault and a
    real fix, but it is `test_every_named_test_still_exists`'s to report, and a
    second check answering for it would give the same fault two names (L11).
    """
    if not entry.test.startswith("tests/"):
        return None
    path_part, *rest = entry.test.split("::")
    if not rest:
        return None
    # A parametrised node id carries its case in brackets; the function the
    # file declares is the part before them.
    method = rest[-1].split("[")[0]

    module_path = repo_root / path_part
    if not module_path.is_file():
        return None
    if method not in silenced_functions(module_path, repo_root):
        return None

    return (
        f"{entry.name} names {entry.test}, which stands down while a guard "
        f"prover holds the perturbation lock (#920). The prover holds that "
        f"lock across every entry, so this one would have its code broken, "
        f"its test skipped and no failure seen, on every sweep for ever. "
        f"Point the entry at the policy helper instead and inject a checkout "
        f"of your own, which is what tests/test_perturbation_lock.py does: "
        f"that runs the same rule with nothing standing it down.")


def load_registry(path: Path, repo_root: Path | None = None) -> list[Entry]:
    """Every entry in the registry directory, one per file.

    Each file holds a single entry object whose `name` is the file's own stem,
    so a name can never be claimed twice and any message naming a guard names
    the file to open.

    `repo_root` is where a `tests/...` node id is resolved from, so an entry
    naming a check the prover itself silences can be refused here rather than
    reported wrongly on every sweep (#931). Derived from the registry's own
    location when it is not given, which is the real layout: the registry lives
    at tests/fixtures/guard_mutations.
    """
    root = repo_root if repo_root is not None else path.resolve().parents[2]
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
        silenced = silenced_by_the_prover(entry, root)
        if silenced:
            raise RegistryError(silenced)
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


#: A pytest summary reporting skips and nothing that ran.
#:
#: Read off the summary line rather than the exit code because a skip exits 0,
#: exactly as a pass does. Both halves are required: a run where one case skipped
#: and another really executed IS a verdict, and only a run where nothing
#: executed at all is not.
_SKIPPED = re.compile(r"\b\d+ skipped\b")
_PASSED = re.compile(r"\b\d+ passed\b")


def classify_pytest(returncode: int, output: str = "") -> Verdict:
    if returncode == 1:
        return Verdict(Outcome.KILLED, "pytest reported failing tests")
    if returncode == 0 and _SKIPPED.search(output) and not _PASSED.search(output):
        # SURVIVED is an accusation: it says the guard is not protecting its
        # code and needs rewriting. A test that never ran cannot support it, and
        # a guard needing an external this runner lacks would be sent back to be
        # rewritten while the missing external went unnamed (#665, measured: the
        # clip reel's legibility guard reported SURVIVED on a runner with no
        # ffmpeg).
        return Verdict(Outcome.ERROR,
                       "the guard's test SKIPPED rather than running, so there "
                       "is no verdict on it. Whatever it needs (ffmpeg, the "
                       "macOS fonts) is missing here, not from the guard.")
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
    return classify_pytest(returncode, output)


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



# ── One build at a time, and saying so while it waits (#642, #641) ────────────


def build_lock_path(repo_root: Path) -> str | None:
    """The lock every xcodebuild sharing the cache takes, or None when this
    checkout names no cache to contend over.

    Beside the cache and derived from the same shell definition, never spelled
    again: two spellings of one location is how a second lock quietly starts
    protecting nothing (L41)."""
    cache = derived_data_path(repo_root)
    return f"{cache}.lock" if cache else None


@contextlib.contextmanager
def build_lock(path: str | None, log=print):
    """Hold the build lock for the duration, saying so if it has to wait.

    Since #621 the sweep builds into the same DerivedData as `make build` and
    `make test`, which was the point. Two xcodebuilds against one DerivedData
    produce errors that read like real compile failures in whichever run
    notices first, and this tool would report that as a guard ERROR rather than
    as contention, which is a verdict on the guard it did not earn.

    A wait announces itself, because a run held up by another build otherwise
    looks exactly like the hang #641 is about."""
    if path is None:
        yield
        return

    Path(path).parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            log(f"another build is using the shared cache; waiting for it "
                f"({path})")
            waited = time.monotonic()
            fcntl.flock(handle, fcntl.LOCK_EX)
            log(f"the other build finished after "
                f"{time.monotonic() - waited:.0f}s; carrying on")
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def say(message: str) -> None:
    """The default logger, flushed.

    `print` buffers whenever stdout is a pipe or a file, so a redirected run
    left its log at zero bytes for twenty minutes and then arrived all at once.
    A sweep that is working and one that has hung have to look different
    (#641)."""
    print(message, flush=True)


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


def run_entry(entry: Entry, repo_root: Path, runner, log=say) -> Result:
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
    # Held across the WHOLE window, from before the break lands to after the
    # restore, so anything else reading the tree can tell "a prover is part way
    # through" from "this entry is stale" (#920). Those two look identical from
    # the outside and the second is what the suite used to report, four times
    # in two days, every one of them green on a re-run.
    began = time.monotonic()
    with perturbation_lock.held_for(entry.name, repo_root):
        _PENDING[target] = original
        target.write_bytes(text.replace(entry.find, entry.replace).encode("utf-8"))
        try:
            # Swift entries build; Python ones do not, so only the former
            # contend for the shared cache.
            lock = (build_lock_path(repo_root)
                    if entry.test.startswith("PostRollTests/") else None)
            with build_lock(lock, log=log):
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
    return Result(entry, verdict.outcome, verdict.detail,
                  seconds=time.monotonic() - began)


#: The exact wording tools/check_job_durations.py matches. Named here rather
#: than only in the pattern, because a line and the regex reading it are two
#: halves of one contract and the pattern is the half that fails silently: it
#: returns None on a miss, which both readers treat as "could not measure"
#: (#1085). tests/test_guard_work_line.py holds the two together.
GUARD_WORK_PREFIX = "guard work: "


def guard_work_line(results: list[Result]) -> str:
    """How much RECORDED work this run proved, as one line for the log.

    Falls back to naming the reason when the record cannot answer, rather than
    printing a zero: a zero divisor is not a measurement of a job that did
    nothing, it is the absence of one, and the two must not read alike (L11).
    """
    kinds = {r.entry.name: r.entry.test.startswith("PostRollTests/")
             for r in results}
    if not kinds:
        return f"{GUARD_WORK_PREFIX}no entries were proved, so there is no work to report"
    try:
        costs = guard_entry_costs.costs_for(kinds)
    except guard_entry_costs.CostRecordError as refusal:
        return (f"{GUARD_WORK_PREFIX}unmeasured, because the cost record could "
                f"not answer: {refusal}")
    total = sum(costs.of(name) for name in kinds)
    # Milliseconds, as a whole number, because the reader on the other side
    # parses an integer and a `changed` run proving one Python entry is under a
    # second: rounded to seconds that run reports ZERO work, and a zero divisor
    # is refused as unmeasurable rather than read as a very fast job (L11).
    return (f"{GUARD_WORK_PREFIX}{round(total * 1000)} recorded entry-ms over "
            f"{len(kinds)} entries, {costs.measured} of them measured")


def write_timings(path: Path, results: list[Result], repo_root: Path) -> int:
    """Write one run's per-entry readings, for `tools/record_guard_costs.py`.

    Only entries that reached a VERDICT are written. An entry that errored
    because the build broke finished in whatever time a broken build takes, and
    a run that never reached an entry has no reading at all: recording either as
    the entry's cost would put a very small number where a real one belongs,
    and nothing downstream could tell it from a genuinely fast entry (L331).

    The run this came from is written beside the readings, because a record that
    mixes runners or dates without saying so cannot be re-measured or corrected
    (L224, #1038). `GITHUB_RUN_ID` when there is one, the machine's name when
    there is not, so a local sweep is never mistaken for a runner's.
    """
    usable = [r for r in results
              if r.outcome in (Outcome.KILLED, Outcome.SURVIVED) and r.seconds > 0]
    run = os.environ.get("GITHUB_RUN_ID") or f"local-{platform.node()}"
    payload = {
        "run": run,
        "measured_on": time.strftime("%Y-%m-%d"),
        "commit": head_commit(repo_root),
        "shard": os.environ.get("GUARD_SHARD", ""),
        "seconds": {r.entry.name: round(r.seconds, 2) for r in usable},
        "kinds": {r.entry.name: r.entry.test.startswith("PostRollTests/")
                  for r in usable},
        "skipped": sorted(r.entry.name for r in results if r not in usable),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")
    return len(usable)


def head_commit(repo_root: Path) -> str:
    """The commit these readings were taken at, or a word saying it is unknown.

    Never an empty string. A blank field reads as a record with no provenance
    rather than as one whose provenance could not be taken (L11).
    """
    try:
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo_root,
                             capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return "unknown"
    return out.stdout.strip() or "unknown"


def shard_of(entries: list[Entry], index: int, total: int,
             costs: guard_entry_costs.Costs | None = None) -> list[Entry]:
    """The `index` of `total` slice of `entries`, one runner's share (#719 follow-up).

    The post-merge sweep stopped finishing: it hit the workflow's 60 minute cap,
    which GitHub reports as CANCELLED, and that is what a superseded run reports
    too, so the sweep dying looked exactly like one somebody replaced (L11).
    Splitting it across runners is what makes it fit.

    Dealt by MEASURED cost since #1090, largest first, each entry going to
    whichever shard is currently cheapest. Until then it was round robin within
    two cost classes, Swift and Python, which balanced the COUNT of expensive
    entries rather than the work: measured over ten runs the real per-entry cost
    ran from 1,174ms to 106,500ms, a factor of 90, so two Swift entries are not
    the same amount of work and a count is a proxy rather than a measure of it
    (L63, L296).

    The cost record is `tests/fixtures/guard_entry_costs.json`. An entry it has
    never seen takes the median of the measured entries of its own KIND, never
    zero: an entry priced at nothing is dealt as free and the shard receiving it
    silently carries more than the deal intended (L98).

    A record that cannot be read at all is a REFUSAL, not a quiet fall back to
    the old class-wise deal. A fallback that is merely worse rather than wrong
    fails silently, so the saving stops happening while every shard stays green
    (L289); and the deadline projection in
    tests/test_guard_sweep_fits_its_deadline.py is derived from the same record,
    so a sweep running on an unreadable one is a sweep nobody has sized.

    Every entry lands in exactly one shard, which is the property the whole
    split rests on: a partition that drops one leaves every shard green and that
    guard unproven, with nothing anywhere mentioning it (L98).
    """
    if total < 1:
        raise ValueError(f"a sweep cannot be split {total} ways")
    if not 1 <= index <= total:
        raise ValueError(f"shard {index} is outside a {total} way split")
    if total > len(entries):
        # A runner that proves nothing and exits green is indistinguishable
        # from one that proved everything.
        raise ValueError(
            f"a {total} way split of {len(entries)} entries leaves at least "
            "one runner with nothing to prove, and a green run that checked "
            "nothing reads exactly like a clean sweep")

    kinds = {e.name: e.test.startswith("PostRollTests/") for e in entries}
    # Injected by the tests that drive the deal directly, so they are not
    # measuring whatever the live record happens to hold today; None here means
    # the real record, which is what the sweep uses (L196).
    costs = costs if costs is not None else guard_entry_costs.costs_for(kinds)
    dealt = guard_entry_costs.deal(list(kinds), total, costs.seconds)
    mine = set(dealt[index - 1])
    return [e for e in entries if e.name in mine]


def check_guards(repo_root: Path, registry_path: Path, runner,
                 only: str | None = None, changed_only: bool = False,
                 shard: tuple[int, int] | None = None,
                 deadline_seconds: float | None = None,
                 timings_path: Path | None = None,
                 log=say) -> int:
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

    if shard is not None:
        index, total = shard
        whole = len(entries)
        entries = shard_of(entries, index, total)
        # Said out loud for the same reason --changed says what it skipped:
        # proving one runner's share says nothing about the other shards, and a
        # shard's output must not read like a whole sweep.
        log(f"shard {index} of {total}: {len(entries)} of {whole} entries on "
            f"this runner; the other {whole - len(entries)} are proven by the "
            "other shards and by nothing here")
        # How much of the deal was MEASURED, because an estimate and a reading
        # deal identically and a partition of guesses looks exactly like a
        # partition of readings (L11, L98).
        kinds = {e.name: e.test.startswith("PostRollTests/") for e in entries}
        costs = guard_entry_costs.costs_for(kinds)
        log(f"dealt by measured cost: {costs.measured} of {len(kinds)} entries "
            f"on this shard carry a reading, {len(costs.estimated)} are "
            "estimated from the median of their kind")

    # Said out loud, because a sweep paying a whole build for every entry looks
    # exactly like one reusing a cache until somebody times it (#621). It is not
    # a refusal: the guards are still proven, just at the old cost.
    if any(e.test.startswith("PostRollTests/") for e in entries) \
            and derived_data_path(repo_root) is None:
        log(f"{DERIVED_DATA_DEFINITION} names no build cache here, so each "
            "Swift entry below pays a full app build of its own instead of "
            "reusing one")

    results = []
    unproven: list[Entry] = []
    started = time.monotonic()
    for number, entry in enumerate(entries, start=1):
        # Stop ourselves rather than let the runner's cap do it. A job killed by
        # `timeout-minutes` reports CANCELLED, which is also what a superseded
        # run reports, so the sweep running out of time was indistinguishable
        # from one that was replaced, and it went unnoticed for a day (L11).
        if deadline_seconds is not None \
                and time.monotonic() - started >= deadline_seconds:
            unproven = entries[number - 1:]
            log(f"the {deadline_seconds:.0f}s deadline passed with "
                f"{len(unproven)} entries never reached, so they are UNPROVEN. "
                "This is a failure, not a cancellation: split the sweep further "
                "or raise the deadline, but do not read it as a clean run.")
            break
        # How far in and how long so far, on every line, because the thing a
        # person watching needs to tell apart is progress from a hang (#641).
        where = f"[{number} of {len(entries)}, {time.monotonic() - started:.0f}s]"
        log(f"{where} {entry.name}: breaking {entry.file} "
            f"({entry.breaks}), expecting {entry.test} to go red")
        result = run_entry(entry, repo_root, runner, log=log)
        results.append(result)
        log(f"{where} {entry.name}: {result.outcome.value} in "
            f"{result.seconds:.1f}s"
            + (f", {result.detail}" if result.detail else ""))

    bad = [r for r in results if r.outcome is not Outcome.KILLED]
    log(f"{len(results)} guard{'s' if len(results) != 1 else ''} checked, "
        f"{len(results) - len(bad)} killed their mutation, {len(bad)} did not")
    # The unit this job's duration has to be divided by (#1041, #1090).
    #
    # A count of entries is the wrong divisor: a Swift entry rebuilds the app at
    # about 29s and a Python one is under a second, so two runs proving the same
    # NUMBER of entries can differ by 90x and a bare comparison of totals would
    # call that a regression.
    #
    # The RECORDED cost, not this run's own measurement. Dividing the duration
    # by the seconds this very run spent gives a ratio near one whatever
    # happens, which is dividing the reading by itself: it can never move and
    # would read as a stable rate for a job that had doubled (L63). Against the
    # record it is a real rate: a slower runner raises it, and a diff selecting
    # more expensive entries raises both halves and leaves it where it was.
    log(guard_work_line(results))
    if timings_path is not None:
        written = write_timings(timings_path, results, repo_root)
        log(f"wrote {written} entry timing(s) to {timings_path}")
    for skipped in unproven:
        log(f"  {skipped.name}: never reached before the deadline, so nothing "
            "here says whether it still protects "
            f"{skipped.file}")
    for r in bad:
        if r.outcome is Outcome.SURVIVED:
            log(f"  {r.entry.name}: the guard stayed GREEN on broken code. "
                f"It is not protecting {r.entry.file} and needs rewriting.")
        else:
            log(f"  {r.entry.name}: {r.detail}")
    return 1 if (bad or unproven) else 0


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
    parser.add_argument("--shard", default=None, metavar="I/N",
                        help="prove only this runner's share of the registry, "
                             "as I/N; every entry lands in exactly one shard")
    parser.add_argument("--timings", type=Path, default=None,
                        help="write this run's per-entry readings to PATH, for "
                             "tools/record_guard_costs.py to fold into "
                             "tests/fixtures/guard_entry_costs.json")
    parser.add_argument("--deadline-seconds", type=float, default=None,
                        help="stop and FAIL once this long has passed, naming "
                             "the entries never reached, rather than letting "
                             "the runner's own cap kill the job and report it "
                             "as a cancellation")
    args = parser.parse_args(argv)

    shard = None
    if args.shard is not None:
        try:
            index, total = (int(part) for part in args.shard.split("/", 1))
        except ValueError:
            parser.error(f"--shard wants I/N, not {args.shard!r}")
        shard = (index, total)

    repo_root = Path(__file__).resolve().parent.parent
    registry = args.registry or repo_root / DEFAULT_REGISTRY
    return check_guards(repo_root, registry, real_runner, only=args.only,
                        changed_only=args.changed, shard=shard,
                        deadline_seconds=args.deadline_seconds,
                        timings_path=args.timings)


if __name__ == "__main__":
    sys.exit(main())
