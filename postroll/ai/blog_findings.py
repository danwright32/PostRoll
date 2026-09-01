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

import enum
from dataclasses import dataclass


@dataclass(frozen=True)
class Finding:
    code: str
    message: str
    detail: str


class RepairState(enum.Enum):
    """What the repair pass did about one finding, or why it did nothing (#1132).

    Rule 2 says a repair that was tried and failed still SHOWS, marked as tried.
    It names two states. The wall clock budget, the structural gap on the revise
    path, and the difference between a refusal and an unreachable model create
    three more, and collapsing any of them back into "never attempted" is rule 2
    defeated: never-attempted renders exactly like today's findings, which is
    the one thing rule 2 forbids.

    `TRIED` and `BLOCKED` are two states, not one (L11, L260, L112). Folding a
    ClaudeError, a timeout, an unreadable photograph and a genuine refusal into
    `TRIED` makes a claim that is FALSE for a network blip, because `TRIED`
    exists to tell Dan the app will not get it next time either. The test for
    whether two states are one is whether they invite different actions, and
    these do: one says stop expecting the app to fix it, the other says try
    again. Rule 1 removed every other signal, so this panel is the only surface
    carrying the difference.

    `UNAVAILABLE` exists because of `revise_blog`. Its manifest carries
    `photo_filenames` only, never photo paths, so there is no photograph on that
    path and alt text cannot be rewritten there. Rendering those findings as
    never attempted would assert something untrue.

    The wording is what Dan reads, so it says what to DO rather than naming an
    internal status (L112).
    """
    #: The pass's own outcome for a finding it FIXED. It never travels in a
    #: payload, because the finding it describes no longer exists: a repaired
    #: alt text stops failing the check that selected it, so `check_blog` does
    #: not report it at all. It is here so the pass's partition can be asserted
    #: TOTAL over everything it selected (L47, L517): a target that ended in no
    #: state would carry the never-attempted default, and that renders exactly
    #: like today's findings, which is the one thing rule 2 forbids.
    REPAIRED = "repaired"
    NEVER = ""
    TRIED = "tried"
    BLOCKED = "blocked"
    UNAVAILABLE = "unavailable"
    NOT_REACHED = "not_reached"

    @property
    def wording(self) -> str:
        return {
            RepairState.REPAIRED:
                "the app rewrote this and its own checks accepted the result",
            RepairState.NEVER: "",
            RepairState.TRIED:
                "the app rewrote this and its own checks refused the result, so "
                "re-running will not help",
            RepairState.BLOCKED:
                "the app could not reach the model or could not read the "
                "photograph, so this is worth trying again",
            RepairState.UNAVAILABLE:
                "this path has no photograph to check against; regenerate or "
                "swap photos to have these rewritten",
            RepairState.NOT_REACHED:
                "the pass ran out of time before reaching this one, so it is "
                "worth trying again",
        }[self]


def finding_entry(finding: Finding, *,
                  repair: "RepairState | str" = "") -> dict[str, str]:
    """One finding, in exactly the fields the app decodes (#274).

    Three modules built this dict by hand, so a field added to Finding reached
    the app from whichever of them was remembered. One derivation, and the
    payload contract has one place to read.

    `repair` is UNCONDITIONAL in the returned literal (#1132).
    `tests/bridge_payload_keys.py` reads this dict literal and refuses a
    computed or conditional key, so a field added only when set would take the
    payload out of the contract's reach entirely. `Finding` stays a frozen
    dataclass of three strings, so its construction sites are untouched.
    """
    state = repair.value if isinstance(repair, RepairState) else str(repair or "")
    return {"code": finding.code, "message": finding.message,
            "detail": finding.detail, "repair": state}
