#!/usr/bin/env python3
"""Parameters that look injectable but bind at definition time (#1325).

In Python a default argument is evaluated ONCE, when the `def` runs. So writing

    def measure_repeatedly(paths, run=measure):

gives you a parameter a caller can pass, and nothing else. A test that does
`monkeypatch.setattr(module, "measure", fake)` is ignored, because the default
already holds the original object, and the function runs the real collaborator.

## Why it is worth a guard rather than a note

It fails in the direction that looks fine. Nothing raises, nothing warns, and
the test that was supposed to be driving a fake goes green while driving the
real thing. Both instances found on 2026-09-04 were caught by running the code,
never by reading it:

- `tools/record_test_durations.measure_repeatedly(run=measure)` would have run
  the entire Python suite three times instead of counting three recorded passes;
- `tools/check_no_such_account_calibration.observations(path=OBSERVATIONS)` read
  the real fixture while its test was pointing it at a tmp_path.

The second is the shape that matters most here. `tools/event_manifest.py` had
`def event_names(store=DEFAULT_STORE)` where `DEFAULT_STORE` is Dan's live
Application Support folder, so the parameter that exists to keep a test off live
data could not be replaced by the route a test reaches for first (L2, L201).

## What it refuses, and what it does not

Refused, because the object is a HANDLE on something outside the function and
the whole point of naming it is that it can be swapped:

- a function, class or lambda, whether defined here, imported, or reached
  through a module (`time.monotonic`, `os.walk`, `subprocess.run`);
- a `Path`;
- anything CALLED in the signature, which freezes one result forever.

Allowed, because the value IS the point and it cannot go stale: numbers,
strings, tuples, booleans, `None`, and constants holding them.

## The remedy, in one shape

    def measure_repeatedly(paths, run=None):
        if run is None:
            run = measure

`if run is None` rather than `run = run or measure`, because `or` also replaces
a deliberately passed falsy collaborator, and the two read identically.

## How a name is resolved

By parsing, never by importing: importing every tool to inspect it would run
whatever those modules do at import time. A name bound in the same file, or
imported from a module inside this repository, is resolved by reading that
module. For an import this repository does not contain (the standard library, a
package), the resolution falls back to the CASE of the name: ALL_CAPS is a
constant, anything else is a collaborator. That is a convention rather than a
fact, and it is stated here so a reader can see where the certainty stops.

    venv/bin/python tools/check_default_argument_seams.py
"""

from __future__ import annotations

import argparse
import ast
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

#: Where the Python this repository owns lives. Named rather than swept from the
#: root, because a recursive glob also collects every nested checkout inside the
#: repo, and this repo routinely holds agent worktrees (L234).
SOURCE_DIRECTORIES = ("tools", "tests", "postroll")


class CannotRead(Exception):
    """A file could not be parsed, which is not the same as it being clean.

    Its own refusal, because a scan that skipped what it could not read would
    report the same empty result as a scan that read everything (L98).
    """


@dataclass(frozen=True)
class Seam:
    """One default argument that binds at definition time."""

    file: str
    line: int
    function: str
    parameter: str
    default: str
    kind: str


def scanned_files(root=None) -> list[Path]:
    """Every Python file this guard actually reads, in a stable order."""
    base = Path(root) if root is not None else REPO_ROOT
    if root is not None:
        # A caller-supplied tree is taken whole: it is a fixture, and requiring
        # it to mirror this repo's folder names would make every test set up
        # scaffolding that proves nothing.
        return sorted(base.rglob("*.py"))
    found: list[Path] = []
    for directory in SOURCE_DIRECTORIES:
        found.extend(sorted((base / directory).rglob("*.py")))
    return found


def _parse(path: Path) -> ast.Module:
    try:
        return ast.parse(path.read_text(), filename=str(path))
    except (SyntaxError, UnicodeDecodeError) as bad:
        raise CannotRead(f"{path} could not be parsed: {bad}") from bad


def _bindings(tree: ast.Module) -> dict[str, ast.AST | None]:
    """Module level name to the node it was bound to, `None` for an import."""
    found: dict[str, ast.AST | None] = {}
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            found[node.name] = node
        elif isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    found[target.id] = node.value
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            found[node.target.id] = node.value
    return found


def _imports(tree: ast.Module) -> dict[str, tuple[str | None, str]]:
    """Imported name to `(module it came from, name inside that module)`."""
    found: dict[str, tuple[str | None, str]] = {}
    for node in tree.body:
        if isinstance(node, ast.Import):
            for alias in node.names:
                found[alias.asname or alias.name.split(".")[0]] = (None, alias.name)
        elif isinstance(node, ast.ImportFrom):
            for alias in node.names:
                found[alias.asname or alias.name] = (node.module, alias.name)
    return found


def _looks_like_a_path(node: ast.AST | None, bindings=None) -> bool:
    """Whether a bound value is a filesystem path.

    Follows `/` back to what it was joined onto, because a path constant is
    routinely built from another one: `WORKFLOWS = REPO_ROOT / ".github" /
    "workflows"` names a directory just as plainly as `Path(...)` does, and a
    check that only looked for the constructor missed every one of those.
    """
    if node is None:
        return False
    rendered = ast.unparse(node)
    if "Path(" in rendered or rendered.startswith("Path."):
        return True
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Div):
        return _looks_like_a_path(node.left, bindings)
    if isinstance(node, ast.Name) and bindings is not None:
        # One step at a time, and never back through a name already followed,
        # so a pair of constants defined in terms of each other cannot loop.
        rest = {k: v for k, v in bindings.items() if k != node.id}
        return _looks_like_a_path(bindings.get(node.id), rest)
    return False


def _kind_of_binding(node: ast.AST | None, bindings=None) -> str | None:
    """What a module level binding IS, or `None` when it is an ordinary value."""
    if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef,
                         ast.Lambda)):
        return "a function defined here"
    if _looks_like_a_path(node, bindings):
        return "a path"
    return None


def _module_file(module: str, root: Path) -> Path | None:
    """The file a dotted module name refers to, when this repository holds it."""
    relative = Path(*module.split("."))
    for candidate in (root / relative.with_suffix(".py"),
                      root / relative / "__init__.py"):
        if candidate.is_file():
            return candidate
    return None


def _kind_of_import(name: str, origin: tuple[str | None, str],
                    root: Path) -> str | None:
    module, inside = origin
    if module is None:
        # `import time`, used bare as a default. A module object is a handle on
        # something outside the function in exactly the way this guard is about.
        return "a module"
    source = _module_file(module, root)
    if source is not None:
        theirs = _bindings(_parse(source))
        kind = _kind_of_binding(theirs.get(inside), theirs)
        if kind == "a function defined here":
            return "a function imported from here"
        return kind
    # Not a module this repository holds, so its source is not available to read
    # and the case of the name is all there is to go on. Stated in the docstring.
    return None if name.isupper() else "a function imported from here"


def _kind_of_default(default: ast.expr, bindings, imports, root) -> str | None:
    if isinstance(default, ast.Attribute):
        return "a function reached through another module"
    if isinstance(default, ast.Call):
        return "computed once, when the function was defined"
    if isinstance(default, ast.Lambda):
        return "a function defined here"
    if isinstance(default, ast.Name):
        if default.id in bindings:
            return _kind_of_binding(bindings[default.id], bindings)
        if default.id in imports:
            return _kind_of_import(default.id, imports[default.id], root)
    return None


def _defaults(node: ast.FunctionDef | ast.AsyncFunctionDef):
    """Every `(argument, default)` pair, positional and keyword only alike."""
    args = node.args
    positional = args.posonlyargs + args.args
    with_defaults = positional[len(positional) - len(args.defaults):]
    yield from zip(with_defaults, args.defaults)
    for argument, default in zip(args.kwonlyargs, args.kw_defaults):
        if default is not None:
            yield argument, default


def seams(root=None) -> list[Seam]:
    """Every default argument in the tree that binds a collaborator or a path."""
    base = Path(root) if root is not None else REPO_ROOT
    found: list[Seam] = []
    for path in scanned_files(root=root):
        tree = _parse(path)
        bindings, imports = _bindings(tree), _imports(tree)
        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            for argument, default in _defaults(node):
                kind = _kind_of_default(default, bindings, imports, base)
                if kind is None:
                    continue
                found.append(Seam(
                    file=str(path.relative_to(base)),
                    line=node.lineno,
                    function=node.name,
                    parameter=argument.arg,
                    default=ast.unparse(default),
                    kind=kind))
    return found


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Find default arguments that "
                                                 "bind at definition time.")
    parser.add_argument("--root", default=None,
                        help="scan this tree instead of the repository")
    args = parser.parse_args(argv)

    try:
        found = seams(root=args.root)
    except CannotRead as refusal:
        print(f"nothing scanned: {refusal}")
        return 2

    if not found:
        print("no default argument binds a collaborator or a path")
        return 0

    print(f"{len(found)} default argument(s) bind at definition time, so "
          f"replacing the name on the module does nothing:")
    for seam in found:
        print(f"  {seam.file}:{seam.line} "
              f"{seam.function}({seam.parameter}={seam.default}) is {seam.kind}")
    print("\nDefault each to None and resolve it in the body:")
    print("    def f(run=None):\n        if run is None:\n            run = measure")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
