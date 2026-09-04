"""The Python half of the manifest contract (#266).

The mirror of test_bridge_payload_contract.py. That one guards what Python
writes and Swift reads; this guards what Swift sends and Python reads.

This direction matters more. A result key Swift stops decoding shows the wrong
thing on a screen. A manifest key Swift stops SENDING is silently replaced by
Python's own default, and generation carries on producing something subtly
different, with nothing anywhere reporting a problem.

The Swift half is PostRollApp/Tests/ManifestContractTests.swift, and it is the
half that catches the app dropping a key. This one catches Python starting to
read something nobody sends.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from bridge_payload_keys import CONTRACT_PATH, load_contract, manifest_reads_from_file

REPO_ROOT = Path(__file__).resolve().parent.parent

MANIFESTS = {k: v for k, v in (load_contract().get("manifests") or {}).items()
             if not k.startswith("_")}


def actual_reads(entry: dict) -> set[str]:
    keys: set[str] = set()
    for source in entry["python"]:
        keys |= manifest_reads_from_file(
            source["module"],
            function=source["function"],
            variable=source["variable"],
            dynamic=source.get("dynamic"),
        )
    return keys


def test_the_contract_declares_manifests_at_all():
    # An empty section passes every parametrised test below by having nothing
    # to parametrise over, which reads exactly like a suite that is guarding
    # something.
    assert MANIFESTS, f"no manifests declared in {CONTRACT_PATH}"


@pytest.mark.parametrize("name", sorted(MANIFESTS))
def test_python_reads_exactly_the_keys_the_contract_declares(name):
    entry = MANIFESTS[name]
    declared = set(entry["keys"])
    actual = actual_reads(entry)

    undeclared = actual - declared
    assert not undeclared, (
        f"{name}: Python now reads {sorted(undeclared)} out of this manifest, and "
        f"the contract has never heard of them. Nothing guarantees the app sends "
        f"them, and a key the app does not send does not fail: Python's default "
        f"quietly stands in and the output changes. Declare each one, and mark it "
        f"`always` only once Swift really does always send it."
    )

    stale = declared - actual
    assert not stale, (
        f"{name}: the contract declares {sorted(stale)}, which Python no longer "
        f"reads. Either the app is building something nobody wants, or the "
        f"contract is describing a version of the code that is gone."
    )


@pytest.mark.parametrize("name", sorted(MANIFESTS))
def test_every_key_says_whether_it_is_always_sent(name):
    for key, disposition in MANIFESTS[name]["keys"].items():
        if disposition == "always":
            continue
        assert isinstance(disposition, dict) and disposition.get("conditional"), (
            f"{name}.{key}: a manifest key is either `always` sent or "
            f"`conditional` WITH the condition written out. Got {disposition!r}. "
            f"Without the condition, the next person cannot tell a key that is "
            f"legitimately absent from one the app forgot to send."
        )
        why = disposition["conditional"]
        assert len(why.split()) >= 6, (
            f"{name}.{key}: \"{why}\" does not say WHEN it is sent, so an absence "
            f"still cannot be judged."
        )


@pytest.mark.parametrize("name", sorted(MANIFESTS))
def test_every_manifest_names_a_swift_builder_that_exists(name):
    builder = MANIFESTS[name]["swift"].split(".")[-1]
    bridge = CONTRACT_PATH.parent.parent.parent / "PostRollApp/Sources/Services/PythonBridge.swift"
    assert bridge.exists()
    assert f"func {builder}" in bridge.read_text(encoding="utf-8"), (
        f"{name}: PythonBridge has no `{builder}`, so the Swift half of this "
        f"entry is pointed at nothing and passes for the wrong reason."
    )


def test_the_required_keys_are_genuinely_required_on_the_python_side():
    """A key marked `always` should be one Python cannot do without.

    Not a formality: the `always` marks are what the Swift test asserts, and a
    key marked `always` that Python reads with a harmless default is a mark
    nobody needs to keep true. Anything read via a bare subscript raises a
    KeyError when absent, so those are required by construction, and every one
    of them must be `always`.
    """
    import ast
    from bridge_payload_keys import REPO_ROOT

    for name, entry in MANIFESTS.items():
        for source in entry["python"]:
            tree = ast.parse((REPO_ROOT / source["module"]).read_text(encoding="utf-8"))
            for node in ast.walk(tree):
                if (isinstance(node, ast.Subscript)
                        and isinstance(node.value, ast.Name)
                        and node.value.id == source["variable"]
                        and isinstance(node.ctx, ast.Load)
                        and isinstance(node.slice, ast.Constant)
                        and isinstance(node.slice.value, str)):
                    key = node.slice.value
                    if key not in entry["keys"]:
                        continue    # covered by the undeclared-keys test above
                    assert entry["keys"][key] == "always", (
                        f"{name}.{key}: Python reads it with a bare subscript, so "
                        f"its absence is a crash, but the contract calls it "
                        f"conditional. One of the two is wrong."
                    )

# ── every sender has an entry ────────────────────────────────────────────────
#
# The gap #1187 came through. Nothing noticed that `runBlogRepairRetry` sent a
# manifest no contract entry described, so the guard above did not look at that
# path at all, and adding `event_id` in #1162 was caught for `week`,
# `blog_revision` and `blog_photo_swap` while passing silently there.
#
# A guard is only as wide as its hand written registry (L96), and the fix for
# that is never another hand written list: it is enumerating the subjects from
# the code and requiring each to be declared (L247). The enumeration here is
# every function in PythonBridge.swift that hands Python a `--manifest`, which
# is the state that makes a function a sender, rather than a naming convention
# a new one might not follow.

BRIDGE = REPO_ROOT / "PostRollApp" / "Sources" / "Services" / "PythonBridge.swift"

#: A sender that deliberately has no contract entry, and why.
#:
#: Empty, and that is the current truth rather than a placeholder. An entry
#: here carries the REASON, because an exclusion with no reason is evidence
#: nobody reasoned about it (L233).
SENDERS_WITHOUT_A_CONTRACT: dict[str, str] = {}


def swift_functions() -> dict[str, str]:
    """Every function in PythonBridge.swift, by name, with its body.

    Read from the source rather than listed, so a sender added later is a
    subject of this check on the day it lands (L96, L247).
    """
    declaration = re.compile(r"^    (?:nonisolated )?(?:static )?func (\w+)")
    bodies: dict[str, list[str]] = {}
    current: str | None = None
    for line in BRIDGE.read_text(encoding="utf-8").splitlines():
        found = declaration.match(line)
        if found:
            current = found.group(1)
            bodies.setdefault(current, [])
        elif current:
            bodies[current].append(line)
    return {name: "\n".join(body) for name, body in bodies.items()}


def manifest_senders() -> set[str]:
    """The functions that hand Python a `--manifest`.

    That state is what makes a function a sender, rather than a naming
    convention a new one might not follow (L247).
    """
    return {name for name, body in swift_functions().items()
            if "--manifest" in body}


def test_the_enumeration_finds_the_senders_it_is_supposed_to():
    """The positive control. A regex that matched nothing would report every
    sender as declared and this whole section would guard nothing (L100, L98)."""
    senders = manifest_senders()

    assert len(senders) >= 10, (
        f"only {len(senders)} manifest senders were found in {BRIDGE.name}, "
        f"which is fewer than the app is known to have: {sorted(senders)}")
    assert "runWeekGeneration" in senders and "runBlogRevision" in senders


@pytest.mark.parametrize("sender", sorted(manifest_senders()))
def test_every_manifest_sender_is_described_by_the_contract(sender: str):
    """An entry describes a sender by naming either the sender itself or the
    builder it assembles the manifest with, because the contract anchors on
    whichever of the two is the one pure function (#266, #270). Both are read
    off the source rather than assumed, so an entry naming a function that has
    been renamed away stops describing anything and fails here."""
    declared = {
        (entry.get("swift") or "").split(".")[-1]
        for entry in MANIFESTS.values()
    }
    body = swift_functions().get(sender, "")
    described = {name for name in declared
                 if name == sender or f"{name}(" in body}

    if sender in SENDERS_WITHOUT_A_CONTRACT:
        pytest.skip(f"deliberately not described: "
                    f"{SENDERS_WITHOUT_A_CONTRACT[sender]}")

    assert described, (
        f"PythonBridge.{sender} sends Python a manifest and no entry under "
        f"`manifests` in {CONTRACT_PATH.name} describes it, so the guard does "
        f"not look at that path at all. A key the app stops sending there is "
        f"silently replaced by Python's own default and generation carries on "
        f"producing something subtly different (#1187, L96). Add the entry, or "
        f"add it to SENDERS_WITHOUT_A_CONTRACT with a written reason.")
