"""#325: a renderer may not carry a tuning control that nothing reads.

`generate_reel_morph` declared `RAW_DESATURATION`, `RAW_DARKEN` and
`RAW_COOL_SHIFT` long after the code consuming them was deleted. They read as
live controls to anyone changing the file, so someone adjusting the RAW look
would set one and watch nothing happen. Same class as L46 (a field written and
never read), approached from the other side: declared and never read at all.

The subject list is DERIVED from the modules rather than written out here (L96):
a control this test forgot to name would be exempt from the very check meant to
catch it. Every module-level constant and function in the reel generators is
walked, and each has to be read somewhere in the repo.

Two things this guard has to get right, both of which it has been made to fail
on first (L1):

- References are counted through the AST, never a regex over the source, so a
  name surviving only in a comment or a docstring cannot keep its definition
  alive. That is the defect #315 was filed for.
- A reference has to resolve TO THIS MODULE. Four modules define `load_font` and
  two define `_tracked`, so a plain name union would let a dead copy pass on its
  live namesake elsewhere: the check would agree with itself while looking at
  the wrong file (L70).
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent

#: The renderers this guard covers. Both, in one pass, because a control deleted
#: from one generator and left in its sibling is the shape #325 actually found
#: (L30).
SUBJECTS = (
    REPO_ROOT / "postroll" / "media" / "generate_reel_morph.py",
    REPO_ROOT / "postroll" / "media" / "generate_reel_slider.py",
)

#: Where a reference may come from. The Swift app reaches these modules through
#: the CLI, never by name, so Python is the whole search space.
SEARCH_ROOTS = ("postroll", "tests", "tools")


def _python_files() -> list[Path]:
    found: list[Path] = []
    for root in SEARCH_ROOTS:
        found.extend((REPO_ROOT / root).rglob("*.py"))
    return found


def _parse(path: Path) -> ast.Module:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def _dotted(path: Path) -> str:
    return ".".join(path.relative_to(REPO_ROOT).with_suffix("").parts)


def _resolve_import(node: ast.ImportFrom, importer: Path) -> str:
    """The dotted module an ImportFrom names, resolving a relative import.

    `from ..media.generate_reel_morph import x` inside `postroll/ai/` has to
    come out as `postroll.media.generate_reel_morph`, or every reference from
    the app's own call site would be missed and the guard would report the whole
    module dead.
    """
    if not node.level:
        return node.module or ""
    package = _dotted(importer).split(".")[:-1]
    base = package[:len(package) - (node.level - 1)]
    return ".".join([*base, node.module] if node.module else base)


def _attribute_chain(node: ast.Attribute) -> str:
    """`a.b.c` as a dotted string, for `import postroll.media.x` style access."""
    parts = [node.attr]
    current = node.value
    while isinstance(current, ast.Attribute):
        parts.append(current.attr)
        current = current.value
    if isinstance(current, ast.Name):
        parts.append(current.id)
    return ".".join(reversed(parts))


def _defined_at_module_level(tree: ast.Module) -> set[str]:
    """Names this module DECLARES at the top level: constants and functions.

    Imports are excluded deliberately. A re-exported name is read by whoever
    imports it from here, and ruff already reports an import nothing uses.
    """
    names: set[str] = set()
    for node in tree.body:
        if isinstance(node, ast.Assign):
            names.update(t.id for t in node.targets if isinstance(t, ast.Name))
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            names.add(node.target.id)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            names.add(node.name)
    return names


def _names_read_within(tree: ast.Module) -> set[str]:
    """Every identifier a file reads in its own right.

    A load-context Name (`FPS`) or an attribute (`self.FPS`). Assignments and
    definitions are stores, so a name that is only ever written does not count
    as reading itself, and a name appearing only in prose is not a Name node at
    all.
    """
    read: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
            read.add(node.id)
        elif isinstance(node, ast.Attribute):
            read.add(node.attr)
    return read


def _names_read_from_module(module: str, tree: ast.Module, importer: Path) -> set[str]:
    """What `importer` reads out of the module dotted `module`, and only that."""
    package, _, leaf = module.rpartition(".")
    read: set[str] = set()
    aliases: set[str] = set()

    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            target = _resolve_import(node, importer)
            if target == module:
                read.update(alias.name for alias in node.names)
            elif target == package:
                # `from postroll.media import generate_reel_morph as morph_mod`
                aliases.update(alias.asname or alias.name
                               for alias in node.names if alias.name == leaf)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name == module:
                    aliases.add(alias.asname or alias.name)

    for node in ast.walk(tree):
        if not isinstance(node, ast.Attribute):
            continue
        if isinstance(node.value, ast.Name) and node.value.id in aliases:
            read.add(node.attr)
        elif isinstance(node.value, ast.Attribute):
            if _attribute_chain(node.value) == module:
                read.add(node.attr)

    return read


@pytest.fixture(scope="module")
def parsed() -> dict[Path, ast.Module]:
    return {path: _parse(path) for path in _python_files()}


def test_the_search_actually_reaches_the_repo(parsed):
    # Guards the derivation below. A search finding no files would make the
    # dead-control test pass on an empty reference set for the wrong reason,
    # and a search missing a SUBJECT would exempt it entirely (L98).
    assert len(parsed) >= 50, f"only found {len(parsed)} python files to search"
    for subject in SUBJECTS:
        assert subject in parsed, f"{subject.name} is not inside the search roots"


def test_a_reference_has_to_resolve_to_the_module_that_declares_it(parsed):
    # The self-check on the hard half. `load_font` is defined in four modules,
    # so if resolution were by bare name a dead copy would ride on a live
    # namesake. Prove the resolver tells the reel's own callers apart from
    # everyone else's.
    morph = "postroll.media.generate_reel_morph"
    scroll = REPO_ROOT / "postroll" / "media" / "generate_reel_scroll.py"
    legibility = REPO_ROOT / "tests" / "test_frame_legibility.py"

    assert "load_font" in _names_read_within(parsed[scroll]), (
        "generate_reel_scroll no longer reads its own load_font, so this test "
        "no longer demonstrates the collision it exists to rule out")
    assert "load_font" not in _names_read_from_module(morph, parsed[scroll], scroll)
    assert _names_read_from_module(morph, parsed[legibility], legibility), (
        "the reel's own legibility tests read nothing out of it, which means "
        "the resolver is failing to see real references")


@pytest.mark.parametrize("subject", SUBJECTS, ids=lambda p: p.stem)
def test_the_reel_generator_declares_nothing_it_never_reads(subject, parsed):
    module = _dotted(subject)
    declared = _defined_at_module_level(parsed[subject])
    assert declared, f"nothing parsed out of {subject.name}, so this asserts nothing"

    read = _names_read_within(parsed[subject])
    for path, tree in parsed.items():
        if path != subject:
            read |= _names_read_from_module(module, tree, path)

    dead = sorted(declared - read)

    assert not dead, (
        f"{subject.name} declares these and nothing anywhere reads them: {dead}. "
        "Wire them or delete them (L29). A constant that looks like a tuning "
        "control and changes nothing is worse than no control at all, because "
        "the person setting it has no way to tell.")


def test_a_name_kept_alive_only_by_a_comment_still_counts_as_dead(tmp_path):
    # The other way this guard could go quietly wrong: #315 was a parity guard
    # that regexed raw source, so a mention inside prose counted as a use.
    # Reading through the AST is what stops that, and this proves it does.
    module = tmp_path / "pretend_renderer.py"
    module.write_text(
        '"""A docstring naming RAW_DESATURATION."""\n'
        "RAW_DESATURATION = 0.0\n"
        "\n"
        "# RAW_DESATURATION used to be applied here.\n",
        encoding="utf-8")
    tree = _parse(module)

    assert "RAW_DESATURATION" in _defined_at_module_level(tree)
    assert "RAW_DESATURATION" not in _names_read_within(tree)
