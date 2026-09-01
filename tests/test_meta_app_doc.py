"""The Meta app document is held to the constants the code uses (#988).

The document tells Dan which permissions to tick and which API version PostRoll
speaks. Both are things the shipping code decides, so a document maintained
beside them drifts, and a drifted one is worse than none: it sends somebody
through a Meta console granting the wrong set, and the failure that follows is
an empty result rather than a refusal naming the missing permission.

So the permission list and the version live in `postroll/ai/meta_app.py`, which
is the constant #1002 imports, and this guard fails the moment the prose and
the constant disagree. Held in BOTH directions (L283): a permission dropped
from the module while the document still names it reads as the document being
right, and the reader grants an access nobody needs.

Every reader raises rather than returning an empty answer, for the reason the
other document guards give: a scan that has stopped matching would report a
document naming every permission at the moment it can see no permission at all
(L98, L100).
"""

from __future__ import annotations

import re
from pathlib import Path

from postroll.ai.meta_app import (
    GRAPH_API_VERSION,
    GRAPH_API_VERSION_AVAILABLE_UNTIL,
    REQUIRED_PERMISSIONS,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
DOC = REPO_ROOT / "docs" / "META-APP.md"


def doc_text() -> str:
    text = DOC.read_text(encoding="utf-8")
    assert len(text) > 2_000, (
        f"{DOC} is {len(text)} characters, which is not the Meta app document. "
        "A guard reading the wrong file passes by finding nothing to disagree "
        "with.")
    return text


def permissions_named_in_doc(text: str) -> set[str]:
    """Every Meta permission the document names, in backticks.

    Matched on the backticked form so a permission mentioned in prose without
    being presented as a value to tick is not counted, and so the sentence
    explaining that `ads_management` is the wider alternative does not read as
    a sixth thing to grant.
    """
    found = set(re.findall(r"`((?:instagram|pages|ads)_[a-z_]+)`", text))
    assert found, (
        "the document names no permission at all, so the match has stopped "
        "working and a document naming none would pass.")
    return found


def test_the_document_names_exactly_the_permissions_the_code_requires():
    named = permissions_named_in_doc(doc_text())
    # `ads_management` is named only as the wider alternative that is
    # deliberately NOT used, so it is expected in the prose and not in the set.
    named.discard("ads_management")
    assert named == set(REQUIRED_PERMISSIONS), (
        "the Meta app document and postroll/ai/meta_app.py disagree about "
        f"which permissions the token needs. Document: {sorted(named)}. "
        f"Code: {sorted(REQUIRED_PERMISSIONS)}.")


def test_the_document_pins_the_same_api_version_as_the_code():
    text = doc_text()
    versions = set(re.findall(r"\*\*(v\d+\.\d+)\*\*", text))
    assert versions, (
        "the document pins no version in bold, so the match has stopped "
        "working and a document pinning nothing would pass.")
    assert versions == {GRAPH_API_VERSION}, (
        f"the document pins {sorted(versions)} and the code pins "
        f"{GRAPH_API_VERSION}.")


def test_the_document_carries_the_versions_expiry_date():
    """The pin's whole justification is that its expiry can be diarised.

    Pinning a version whose end date nobody records is the thing the document
    argues against, so the date is part of the claim and not decoration (L316).
    """
    assert GRAPH_API_VERSION_AVAILABLE_UNTIL in doc_text(), (
        f"the document does not name {GRAPH_API_VERSION_AVAILABLE_UNTIL}, the "
        f"date {GRAPH_API_VERSION} stops working, so the reason given for "
        "pinning it cannot be checked by the reader.")
