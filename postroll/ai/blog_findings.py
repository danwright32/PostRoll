"""The blog checker's finding vocabulary, and nothing else (#1128).

`Finding` and `finding_entry` were defined in `blog_quality.py`, alongside every
blog rule. Three caption modules import the pair purely for the vocabulary, so
each of them dragged the whole checker in behind a three field dataclass; after
the repair milestone that checker sits one import away from a model call.

This module is a LEAF. It imports nothing from `postroll.ai`, which is what
makes importing the vocabulary cost nothing, and
`tests/test_blog_findings_module_is_a_leaf.py` asserts it rather than trusting
the next person to remember.

Not named `findings.py`, deliberately. `postroll/ai/analyze_posts.py` defines a
DIFFERENT `finding_entry(raw: dict)` for the `insight_finding` payload, with its
own entry in the bridge contract. Two same named functions with different
behaviour on either side of a generic module name is L263: the shared name reads
as evidence of shared behaviour and nobody ever compares them. The name says
which findings these are.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Finding:
    code: str
    message: str
    detail: str


def finding_entry(finding: Finding) -> dict[str, str]:
    """One finding, in exactly the fields the app decodes (#274).

    Three modules built this dict by hand, so a field added to Finding reached
    the app from whichever of them was remembered. One derivation, and the
    payload contract has one place to read.
    """
    return {"code": finding.code, "message": finding.message, "detail": finding.detail}
