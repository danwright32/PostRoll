"""What keys a Python bridge payload actually writes (#262).

The app decodes only the fields someone remembered to wire up. `stopped_reason`
was written on every halt and read by nothing, and the write really did run, so
every is-this-used check saw a live field (#257). That is a pattern, not a
one-off, so the two sides need something that forces them to agree.

This module answers one question about the Python side: given a function that
assembles a payload, which keys can end up in it. The answer is read from the
source rather than declared by hand, because a hand-maintained list of what the
code writes drifts the moment someone adds a key, which is the drift being
guarded against.

It REFUSES rather than guesses. A key it cannot resolve raises `UndeterminedKey`
and a source it cannot find raises `LookupError`, because an extractor that
quietly returns a short set makes the guard pass for exactly the case it exists
to catch: the comparison succeeds, and the missing key is the one nobody knew
about. A dynamic key (`results[day_name]`) has to be declared with the values it
takes, and that declaration is checked against the real symbol, so widening
`DAY_ORDER` widens the contract instead of slipping past it.
"""

from __future__ import annotations

import ast
import json
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = REPO_ROOT / "tests" / "fixtures" / "bridge_payload_contract.json"


class UndeterminedKey(RuntimeError):
    """A key whose name cannot be read from the source.

    Raised rather than skipped. Skipping would under-report what the payload
    carries, and an under-reported payload agrees with any consumer.
    """


@dataclass(frozen=True)
class DynamicKey:
    """A subscript key that is a variable, plus the values it can take.

    `values` is supplied by the contract and checked against the live symbol it
    claims to mirror, so a list that stops matching the code fails rather than
    freezing an old answer (L41: a list mirroring a source of truth is derived
    from it, never maintained by hand beside it).
    """
    values: list[str] = field(default_factory=list)


# ── extraction ────────────────────────────────────────────────────────────────

def _const_key(node: ast.expr) -> str | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    return None


def _dict_literal_keys(node: ast.Dict, where: str) -> set[str]:
    keys: set[str] = set()
    for key in node.keys:
        if key is None:
            # `{**base, ...}`: the keys live in whatever `base` is, which this
            # function cannot see. Refusing is the only honest answer.
            raise UndeterminedKey(
                f"{where}: a dict literal splats another mapping, so its full key "
                f"set is not readable here. Build the payload with explicit keys, "
                f"or point the contract at the function that does."
            )
        name = _const_key(key)
        if name is None:
            raise UndeterminedKey(
                f"{where}: a dict literal has a computed key "
                f"({ast.unparse(key)}), so what it writes cannot be read."
            )
        keys.add(name)
    return keys


class _PayloadVisitor(ast.NodeVisitor):
    """Collects payload keys inside one function, not its nested functions."""

    def __init__(self, variable: str | None, dynamic: dict[str, DynamicKey], where: str):
        self.variable = variable
        self.dynamic = dynamic
        self.where = where
        self.keys: set[str] = set()
        self.saw_variable = False
        self.used_dynamic: set[str] = set()
        self._depth = 0

    # Nested defs belong to their own payload, so they are not descended into.
    def visit_FunctionDef(self, node: ast.FunctionDef):  # noqa: N802
        if self._depth == 0:
            self._depth += 1
            self.generic_visit(node)
            self._depth -= 1

    visit_AsyncFunctionDef = visit_FunctionDef  # noqa: N815

    def visit_Return(self, node: ast.Return):  # noqa: N802
        if self.variable is None and isinstance(node.value, ast.Dict):
            self.keys |= _dict_literal_keys(node.value, self.where)
        self.generic_visit(node)

    def visit_Assign(self, node: ast.Assign):  # noqa: N802
        for target in node.targets:
            self._record_target(target, node.value)
        self.generic_visit(node)

    def visit_AnnAssign(self, node: ast.AnnAssign):  # noqa: N802
        if node.value is not None:
            self._record_target(node.target, node.value)
        self.generic_visit(node)

    def _record_target(self, target: ast.expr, value: ast.expr) -> None:
        if self.variable is None:
            return
        # `payload = {...}` / `payload: dict = {...}`
        if isinstance(target, ast.Name) and target.id == self.variable:
            self.saw_variable = True
            if isinstance(value, ast.Dict):
                self.keys |= _dict_literal_keys(value, self.where)
            return
        # `payload["key"] = ...`
        if (isinstance(target, ast.Subscript)
                and isinstance(target.value, ast.Name)
                and target.value.id == self.variable):
            self.saw_variable = True
            name = _const_key(target.slice)
            if name is not None:
                self.keys.add(name)
                return
            if isinstance(target.slice, ast.Name) and target.slice.id in self.dynamic:
                self.used_dynamic.add(target.slice.id)
                self.keys |= set(self.dynamic[target.slice.id].values)
                return
            raise UndeterminedKey(
                f"{self.where}: `{self.variable}[{ast.unparse(target.slice)}]` is "
                f"written with a key this cannot resolve. Declare it in the "
                f"contract's `dynamic` block with the values it takes, so the "
                f"guard knows what the payload can contain."
            )


def payload_keys_from_source(source: str, *, function: str,
                             variable: str | None = None,
                             dynamic: dict[str, DynamicKey] | None = None,
                             where: str | None = None) -> set[str]:
    """Keys the named function can put into its payload.

    With `variable`, reads what is assigned onto that name. Without it, reads
    the dict literals the function returns.
    """
    dynamic = dynamic or {}
    where = where or function
    tree = ast.parse(source)

    target: ast.FunctionDef | ast.AsyncFunctionDef | None = None
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == function:
            target = node
            break
    if target is None:
        raise LookupError(
            f"{where}: the function `{function}` is absent. The contract points "
            f"at something that no longer exists, so it can no longer be "
            f"checking anything."
        )

    visitor = _PayloadVisitor(variable, dynamic, where)
    visitor._depth = 1
    visitor.generic_visit(target)

    if variable is not None and not visitor.saw_variable:
        raise LookupError(
            f"{where}: nothing is ever written to `{variable}` in `{function}`. "
            f"Either the payload was renamed or the contract is pointing at the "
            f"wrong place; both mean this entry checks nothing."
        )
    unused = set(dynamic) - visitor.used_dynamic
    if unused:
        raise LookupError(
            f"{where}: the contract declares dynamic key(s) {sorted(unused)} that "
            f"`{function}` never uses, so they are injecting keys the code stopped "
            f"writing."
        )
    if not visitor.keys:
        raise LookupError(
            f"{where}: `{function}` yielded no keys, which cannot be right for a "
            f"payload and would agree with any consumer. The usual cause is a "
            f"payload built inline inside a call "
            f"(`write_text(json.dumps({{...}}))`), which is neither returned nor "
            f"assigned: bind it to a variable and name that variable here."
        )
    return visitor.keys


def payload_keys_from_file(path: str | Path, **kwargs) -> set[str]:
    resolved = REPO_ROOT / path if not Path(path).is_absolute() else Path(path)
    if not resolved.exists():
        raise LookupError(f"{path}: the module the contract names does not exist.")
    return payload_keys_from_source(
        resolved.read_text(encoding="utf-8"), where=str(path), **kwargs
    )


# ── the read side: what Python takes OUT of a manifest the app sent ───────────
#
# The mirror of everything above. A key the app stops sending does not fail
# anywhere: `.get(key, default)` substitutes the default and generation carries
# on producing subtly different output, which is worse than the result-payload
# case because it changes what gets MADE rather than what gets shown (#266).


class _ReadVisitor(ast.NodeVisitor):
    """Collects the keys read off one variable inside one function."""

    def __init__(self, variable: str, dynamic: dict[str, list[str]], where: str):
        self.variable = variable
        self.dynamic = dynamic
        self.where = where
        self.keys: set[str] = set()
        self._depth = 0

    def visit_FunctionDef(self, node: ast.FunctionDef):  # noqa: N802
        if self._depth == 0:
            self._depth += 1
            self.generic_visit(node)
            self._depth -= 1

    visit_AsyncFunctionDef = visit_FunctionDef  # noqa: N815

    def visit_Call(self, node: ast.Call):  # noqa: N802
        # `variable.get("key")` / `variable.get("key", default)`
        if (isinstance(node.func, ast.Attribute) and node.func.attr == "get"
                and isinstance(node.func.value, ast.Name)
                and node.func.value.id == self.variable and node.args):
            self._record(node.args[0], f'{self.variable}.get(...)')
        self.generic_visit(node)

    def visit_Subscript(self, node: ast.Subscript):  # noqa: N802
        # A subscript in a LOAD context is a read; a STORE is a write and is not
        # part of what the app has to send.
        if (isinstance(node.value, ast.Name) and node.value.id == self.variable
                and isinstance(node.ctx, ast.Load)):
            self._record(node.slice, f'{self.variable}[...]')
        self.generic_visit(node)

    def _record(self, node: ast.expr, shape: str) -> None:
        name = _const_key(node)
        if name is not None:
            self.keys.add(name)
            return
        if isinstance(node, ast.Name) and node.id in self.dynamic:
            self.keys |= set(self.dynamic[node.id])
            return
        raise UndeterminedKey(
            f"{self.where}: `{shape}` is read with a key this cannot resolve "
            f"({ast.unparse(node)}). Declare it in the contract's `dynamic` "
            f"block with the values it takes."
        )


def manifest_reads_from_source(source: str, *, function: str, variable: str,
                               dynamic: dict[str, list[str]] | None = None,
                               where: str | None = None) -> set[str]:
    """Keys the named function reads off `variable`."""
    where = where or function
    tree = ast.parse(source)

    target = None
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == function:
            target = node
            break
    if target is None:
        raise LookupError(
            f"{where}: the function `{function}` is absent, so the contract "
            f"points at something that can no longer be checking anything."
        )

    visitor = _ReadVisitor(variable, dynamic or {}, where)
    visitor._depth = 1
    visitor.generic_visit(target)

    if not visitor.keys:
        raise LookupError(
            f"{where}: `{function}` reads no keys off `{variable}`, which cannot "
            f"be right for a manifest and would agree with any sender. The usual "
            f"cause is a renamed variable."
        )
    return visitor.keys


def manifest_reads_from_file(path: str | Path, **kwargs) -> set[str]:
    resolved = REPO_ROOT / path if not Path(path).is_absolute() else Path(path)
    if not resolved.exists():
        raise LookupError(f"{path}: the module the contract names does not exist.")
    return manifest_reads_from_source(
        resolved.read_text(encoding="utf-8"), where=str(path), **kwargs
    )


# ── the contract ──────────────────────────────────────────────────────────────

def load_contract() -> dict:
    """The shared key contract, read by this suite and by the Swift suite.

    One committed file rather than a list on each side, because two lists of the
    same thing agree only until somebody edits one (L26).
    """
    if not CONTRACT_PATH.exists():
        raise LookupError(f"the payload contract is missing at {CONTRACT_PATH}")
    return json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))


#: Top-level keys that are sections of the file rather than payloads. Named
#: rather than inferred, so adding a section cannot silently become a payload
#: that every consumer then fails to understand.
RESERVED_SECTIONS = frozenset({"manifests"})


def contract_payloads() -> dict[str, dict]:
    return {k: v for k, v in load_contract().items()
            if not k.startswith("_") and k not in RESERVED_SECTIONS}
