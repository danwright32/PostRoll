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

import pytest

from bridge_payload_keys import CONTRACT_PATH, load_contract, manifest_reads_from_file

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
