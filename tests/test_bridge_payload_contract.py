"""The Python half of the bridge payload key contract (#262).

Fails when a generator gains a key that nobody has said what to do with. The
motivating defect is a field written on every run and read by nothing: the
write really does run, so the field looks alive to any is-this-used check, and
the feature it was added for silently never happens (L46).

The Swift half lives in PostRollApp/Tests/BridgePayloadContractTests.swift and
reads the same committed file. Two lists of the same thing agree only until
somebody edits one (L26).
"""

from __future__ import annotations

import importlib
import json

import pytest

from bridge_payload_keys import (
    CONTRACT_PATH,
    DynamicKey,
    contract_payloads,
    payload_keys_from_file,
)

PAYLOADS = contract_payloads()


def _resolve_dynamic(spec: dict) -> DynamicKey:
    """Expand a declared dynamic key from the live symbol it names.

    Never a literal list in the fixture: a hand-kept copy of DAY_ORDER stops
    matching DAY_ORDER the moment a day is added, and the guard would then be
    checking last month's answer with total confidence (L41).
    """
    module_name, _, symbol = spec["from"].partition(":")
    module = importlib.import_module(module_name)
    try:
        value = getattr(module, symbol)
    except AttributeError as e:
        raise LookupError(
            f"the contract's dynamic key points at {spec['from']}, which does "
            f"not exist, so it is expanding to nothing"
        ) from e
    values = list(value.keys()) if isinstance(value, dict) else list(value)
    if not values:
        raise LookupError(f"{spec['from']} is empty, so it contributes no keys")
    return DynamicKey(values=values)


def emitted_keys(payload: dict) -> set[str]:
    keys: set[str] = set()
    for source in payload["python"]:
        dynamic = {
            name: _resolve_dynamic(spec)
            for name, spec in (source.get("dynamic") or {}).items()
        }
        keys |= payload_keys_from_file(
            source["module"],
            function=source["function"],
            variable=source.get("variable"),
            dynamic=dynamic,
        )
    return keys


def test_the_contract_file_is_where_both_suites_look_for_it():
    # A moved fixture makes the Swift guard skip rather than fail, and a
    # skipped guard reads exactly like a passing one.
    assert CONTRACT_PATH.exists(), f"the payload contract is missing at {CONTRACT_PATH}"
    assert PAYLOADS, "the contract declares no payloads, which passes vacuously"


@pytest.mark.parametrize("name", sorted(PAYLOADS))
def test_python_writes_exactly_the_keys_the_contract_declares(name):
    payload = PAYLOADS[name]
    declared = set(payload["keys"])
    actual = emitted_keys(payload)

    undeclared = actual - declared
    assert not undeclared, (
        f"{name}: Python now writes {sorted(undeclared)}, which the contract has "
        f"never heard of. Say what happens to each one: decode it on the Swift "
        f"side and mark it \"swift\", or mark it python_only with the reason. A "
        f"key nobody decided about is the defect this file exists to catch."
    )

    stale = declared - actual
    assert not stale, (
        f"{name}: the contract declares {sorted(stale)}, which Python no longer "
        f"writes. A contract naming keys that stopped existing checks less than "
        f"it appears to."
    )


@pytest.mark.parametrize("name", sorted(PAYLOADS))
def test_every_key_says_what_happens_to_it(name):
    for key, disposition in PAYLOADS[name]["keys"].items():
        if disposition == "swift":
            continue
        assert isinstance(disposition, dict) and disposition.get("python_only"), (
            f"{name}.{key}: a key is either read by Swift (\"swift\") or "
            f"deliberately python_only WITH a reason. Got {disposition!r}. "
            f"There is no unexplained third state, because an orphan parked "
            f"without a reason is how the last one survived (#257)."
        )
        reason = disposition["python_only"]
        assert len(reason.split()) >= 8, (
            f"{name}.{key}: \"{reason}\" does not explain why nothing reads this. "
            f"The next person has to be able to tell a deliberate choice from an "
            f"oversight without doing the sweep again."
        )


@pytest.mark.parametrize("name", sorted(PAYLOADS))
def test_every_payload_names_a_swift_side_that_exists(name):
    payload = PAYLOADS[name]
    swift = payload["swift"]
    assert swift["kind"] in ("model", "reader"), f"{name}: unknown swift kind {swift['kind']!r}"
    if swift["kind"] == "reader":
        path = CONTRACT_PATH.parent.parent.parent / swift["file"]
        assert path.exists(), f"{name}: the Swift reader file {swift['file']} does not exist"
        assert f"func {swift['function']}" in path.read_text(encoding="utf-8"), (
            f"{name}: {swift['file']} has no `{swift['function']}`, so the Swift "
            f"guard is pointed at nothing and passes for the wrong reason."
        )


def test_the_contract_is_valid_json_with_a_comment_that_says_why():
    raw = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    assert raw.get("_comment"), (
        "the contract's own reason for existing has to be in the file. A "
        "guard whose purpose is only in a commit message becomes a rule "
        "nobody dares delete and nobody understands."
    )
