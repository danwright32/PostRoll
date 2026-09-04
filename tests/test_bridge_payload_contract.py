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
import re

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


def keys_per_producer(payload: dict) -> dict[str, set[str]]:
    """What EACH producer of this payload writes, kept apart.

    `emitted_keys` below unions these, which is the right question for "does
    the contract declare everything Python writes" and the wrong one for "do
    the producers agree": a key only one of them writes satisfies the union,
    so two producers of one entry could disagree with nothing reporting it
    (#1023, #1353). tests/test_sibling_payloads_agree.py asks the other
    question from here.
    """
    per: dict[str, set[str]] = {}
    for source in payload["python"]:
        dynamic = {
            name: _resolve_dynamic(spec)
            for name, spec in (source.get("dynamic") or {}).items()
        }
        per[source["function"]] = payload_keys_from_file(
            source["module"],
            function=source["function"],
            variable=source.get("variable"),
            dynamic=dynamic,
            # Several payloads are LISTS the app decodes as arrays, so the keys
            # that matter are the entry's, not a wrapper's.
            element=source.get("element", False),
        )
    return per


def emitted_keys(payload: dict) -> set[str]:
    """Everything Python writes for this payload, however many producers."""
    per = keys_per_producer(payload)
    return set().union(*per.values()) if per else set()


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
        return

    # A `model` kind was exempt from the check that appears to cover it (#1132).
    #
    # Only the `reader` branch above resolved anything, so a model entry's
    # `type` was never looked for anywhere. `blog_finding` had pointed at
    # `BlogFinding` since it was written, and there is no such type in this app:
    # the real one is `QualityFinding`. Nothing caught it because nothing ever
    # looked, which is a check that reads as covering a thing it never touches
    # (L96).
    sources = list((CONTRACT_PATH.parent.parent.parent / "PostRollApp" / "Sources")
                   .rglob("*.swift"))
    assert sources, "no Swift sources found, so this would pass by finding nothing"
    declared = re.compile(
        rf"\b(?:struct|final class|class|enum)\s+{re.escape(swift['type'])}\b")
    assert any(declared.search(path.read_text(encoding="utf-8")) for path in sources), (
        f"{name}: the contract says Swift decodes this into `{swift['type']}`, and "
        f"no such type is declared anywhere in PostRollApp/Sources. Either the "
        f"type was renamed and the contract was not, or it never existed, and "
        f"either way every key this entry declares is proved against nothing."
    )


def test_the_contract_is_valid_json_with_a_comment_that_says_why():
    raw = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    assert raw.get("_comment"), (
        "the contract's own reason for existing has to be in the file. A "
        "guard whose purpose is only in a commit message becomes a rule "
        "nobody dares delete and nobody understands."
    )


# The text a payload's findings were measured against, per Swift model (#974).
#
# A findings list on its own can only say what was wrong with SOME text. The
# panel's whole job is to say whether the text on screen still has those
# problems, and it cannot answer that without the text they were measured
# against. The caption paths have sent theirs since #201; the blog paths never
# did, so a generated blog's panel went on asserting its findings however much
# of the draft had been rewritten, on all 21 events in the live store.
CHECKED_TEXT_KEY = {
    "DayCaption": "findings_caption",
    "BlogOutput": "findings_body",
    # The retry returns the body it ENDED with and measures its findings on
    # exactly that, so the checked text is the body itself rather than a second
    # field beside it (#1160). `findings_body` exists on BlogOutput because a
    # stored draft goes on being edited while its findings persist; a retry's
    # payload is consumed once, and the caller copies this straight into
    # `findingsBody`, so a separate key here would be two names for one string
    # and the pair could disagree.
    "BlogRepairRetryResult": "body",
}


def payloads_reporting_findings() -> list[str]:
    return sorted(name for name, payload in PAYLOADS.items()
                  if "findings" in payload["keys"])


def test_the_sweep_can_see_the_payloads_that_report_findings():
    # A parametrised list that came out empty passes every case below while
    # checking nothing (L98).
    found = payloads_reporting_findings()
    assert len(found) >= 5, (
        f"only {found} report findings, which is fewer than the caption and "
        f"blog paths that exist, so this sweep is looking at the wrong field")


@pytest.mark.parametrize("name", payloads_reporting_findings())
def test_a_payload_reporting_findings_also_pins_the_text_they_describe(name):
    payload = PAYLOADS[name]
    swift_type = payload["swift"].get("type")
    # A KeyError here rather than a skip: a new model carrying findings is
    # exactly the case this rule exists for, and skipping it would exempt the
    # one payload nobody has thought about yet (L129).
    expected = CHECKED_TEXT_KEY[swift_type]
    assert expected in payload["keys"], (
        f"{name} sends `findings` but no `{expected}`, so nothing downstream "
        f"can tell whether the text has been edited since they were measured. "
        f"The panel then keeps asserting findings about text that no longer "
        f"exists, which trains the reader to ignore it (#974, L11)."
    )
