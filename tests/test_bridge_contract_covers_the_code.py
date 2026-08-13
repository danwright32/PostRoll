"""The bridge payload contract, checked code to registry (#488).

Both existing halves run registry to code: Python parametrizes over the
contract's entries, and Swift checks each entry against a hand-kept proven list.
Neither can see a payload or a manifest that was added to the bridge WITHOUT a
contract entry, so anything missing from the registry is exempt from the entire
check. That is exactly how six payloads went undeclared before #273: the sweep
that claimed to cover them all passed, because it only ever looked at what the
registry listed (L96).

This is the missing direction. It reads `PythonBridge.swift` and requires the
contract to account for every module the bridge invokes and every manifest it
builds.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
BRIDGE = REPO_ROOT / "PostRollApp" / "Sources" / "Services" / "PythonBridge.swift"
CONTRACT = REPO_ROOT / "tests" / "fixtures" / "bridge_payload_contract.json"


def bridge_source() -> str:
    return BRIDGE.read_text(encoding="utf-8")


def bridge_lines() -> list[str]:
    """The source with comment lines dropped.

    A comment naming a builder is not a builder, and a guard that matches prose
    is indistinguishable from one that works (L103).
    """
    out = []
    for line in bridge_source().splitlines():
        stripped = line.strip()
        out.append("" if stripped.startswith("//") else line)
    return out


def contract() -> dict:
    return json.loads(CONTRACT.read_text(encoding="utf-8"))


def declared_modules() -> set[str]:
    """Every Python module the contract accounts for, in dotted form."""
    data = contract()
    modules: set[str] = set()

    def collect(entry: dict) -> None:
        for producer in entry.get("python", []):
            path = producer.get("module")
            if path:
                modules.add(path.replace("/", ".").removesuffix(".py"))

    for name, entry in data.items():
        if name.startswith("_") or not isinstance(entry, dict):
            continue
        if name == "manifests":
            for sub_name, sub in entry.items():
                if not sub_name.startswith("_"):
                    collect(sub)
        else:
            collect(entry)
    return modules


def invoked_modules() -> set[str]:
    """Every module the bridge runs with `python -m`."""
    text = "\n".join(bridge_lines())
    return set(re.findall(r'"-m",\s*"([a-z_][a-z0-9_.]*)"', text))


def manifest_builders() -> list[str]:
    """Every function in the bridge that assembles a manifest."""
    return sorted(set(re.findall(r"func (build\w*Manifest)\(", "\n".join(bridge_lines()))))


def callers_of(builder: str) -> set[str]:
    """The functions that call `builder`, so an entry may name either.

    The contract names whichever end reads best: some entries name the builder,
    others name the run function that sends what it built. Both are the same
    payload, so either satisfies this.
    """
    lines = bridge_lines()
    found: set[str] = set()
    for i, line in enumerate(lines):
        if f"{builder}(" not in line or f"func {builder}(" in line:
            continue
        for j in range(i, -1, -1):
            match = re.search(r"func (\w+)\s*[(<]", lines[j])
            if match:
                found.add(match.group(1))
                break
    return found


# ── guards on the guard ───────────────────────────────────────────────────────

def test_the_bridge_and_the_contract_are_both_readable():
    """Every assertion below passes vacuously against an empty read (L98)."""
    assert len(bridge_source()) > 10_000, "PythonBridge.swift is not where this expects"
    assert len(contract()) > 5, "the contract is missing or gutted"


def test_the_scan_finds_the_bridge_calls_it_is_about():
    assert len(invoked_modules()) >= 10, sorted(invoked_modules())
    assert len(manifest_builders()) >= 8, manifest_builders()


# ── the direction that was missing ────────────────────────────────────────────

@pytest.mark.parametrize("module", sorted(invoked_modules()))
def test_every_module_the_bridge_runs_is_in_the_contract(module: str):
    assert module in declared_modules(), (
        f"the bridge runs {module} and the contract says nothing about it, so "
        f"whatever it returns crosses to Swift unchecked. Add an entry naming "
        f"what it produces."
    )


@pytest.mark.parametrize("builder", manifest_builders())
def test_every_manifest_the_bridge_builds_is_in_the_contract(builder: str):
    data = contract()
    named: set[str] = set()
    for name, entry in data.get("manifests", {}).items():
        if name.startswith("_"):
            continue
        swift = entry.get("swift")
        if isinstance(swift, str):
            named.add(swift.split(".")[-1])

    accepted = {builder} | callers_of(builder)
    assert named & accepted, (
        f"{builder} assembles a manifest that is sent to Python and no contract "
        f"entry names it (or any of its callers: {sorted(callers_of(builder))}). "
        f"A manifest with no entry is exempt from both halves of the check."
    )
