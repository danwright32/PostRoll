"""Rewrite the alt text a check refused, with the photograph attached (#1133).

Rule 4 licenses this and nothing else in the checker: alt text is the one
finding class where the app can do better than report, because the picture is in
hand, so rewriting it invents nothing. Everything else in `blog_quality` reports
for the reason that file states: nobody can supply the true number that replaces
an invented one.

Rule 1 makes the repair SILENT. Nothing on the panel says one happened, so
nothing invites Dan to check, so every safeguard here has to hold without him:
the damage gate refuses a repair that made the post worse, the acceptance check
re-runs literally the rules that selected the marker, and the five-way partition
is asserted total so no target can end the pass carrying the never-attempted
default, which renders exactly like today's findings.

**Every collaborator is a seam, injected from the first commit (L524, L284).**
The pass takes its model runner, its clock, its stat function and its journal
path, and reads none of them from the ambient environment. A budget that read
the clock directly would make `not_reached` an outcome the design enumerates and
no test can produce in its interesting form ("reached 3 of 7, then ran out"),
and the only way to build one would be burning real wall clock in a suite this
repo measures per file.

`blog_quality` never imports this. Several test files import `check_blog`
directly, and a `check_blog(repair=True)` flag would put a model call one import
away from all of them.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from .ai_tells import strip_em_dashes
from .blog_findings import Finding, RepairState
from .blog_photo_stamps import decode_photo_path
from .blog_quality import (ALT_MAX_WORDS, ALT_MIN_WORDS, _PHOTO_MARKER,
                           _fold_filename, _markers, check_alt_text)
from .blog_repair_damage import Touched, blog_repair_damage
from .claude_client import ClaudeError, run_json_prompt

#: How long one call may take before it is cut, and how much of the budget an
#: attempt RESERVES before it is started.
#:
#: MEASURED, not cloned (#1127). Three real image-carrying calls on 2026-09-01
#: took 2.8s, 3.1s and 3.1s, on photographs from 1.5 MB to 3.6 MB, and the file
#: size made no difference. The plan's 300 was copied from
#: `swap_blog_photos.py`, whose 300 was never measured either.
#:
#: 120 rather than the 9 that three times the slowest reading would give,
#: because the harm is ASYMMETRIC: too low cuts a call that DID start and
#: reports it as `blocked`, telling Dan the app could not reach the model on a
#: rewrite it had begun, which is the claim L11 forbids. Too high costs only
#: that a dead call is noticed later, and the deadline below protects the
#: process regardless.
#:
#: Re-measure rather than argue:
#:     venv/bin/python tools/measure_alt_text_call.py --photo <a photograph>
CALL_TIMEOUT = 120

#: Attempts per target per pass, keyed on the folded filename.
#:
#: Two, which is where the plan wanted it. The plan then reasoned that at 300
#: seconds a call, seven markers at two rounds is 4,200 seconds against an 1,800
#: second process ceiling, so the cap would have to drop to one. Measured, that
#: budget is 43 seconds, so it does not.
MAX_ROUNDS = 2

#: The process ceiling every blog path runs under, mirrored from
#: `PythonBridge.processTimeout` (1800). Named here rather than written as a
#: literal, because a number spelled in two places is a number the two can
#: disagree about (L41); `tests/test_blog_repair_budget.py` pins the pair.
PROCESS_CEILING = 1800.0

#: How much of the ceiling the pass leaves alone.
#:
#: A deadline EQUAL to the ceiling races it, and whichever fires first decides
#: what Dan is told. PythonBridge says exactly this about its own timeout: a
#: caller's deadline has to sit OUTSIDE the thing it is waiting on. When 1,800
#: fires the process is SIGTERM'd, `outputMissing` is thrown, and every paid
#: call in the whole week is destroyed, which is worse than any finding this
#: pass exists to fix.
CEILING_HEADROOM = 120.0


def deadline_from(*, started_at: float, now: Callable[[], float],
                  ceiling: float = PROCESS_CEILING) -> float:
    """An ABSOLUTE deadline on `now()`'s scale, from the caller's process start.

    Never a constant number of seconds (L227, L522). The 1,800 second ceiling is
    shared differently on each path: a revision spends 600 + 600 + 600 of model
    timeouts against it, while a week run reaches the blog as its LAST step,
    after seven days of caption generation have already spent most of it. A
    budget expressed as a constant is safe only for whichever path calibrated
    it.

    A process already past its ceiling gets no budget rather than a negative
    one, which a comparison written the other way round would read as infinite.
    """
    return max(now(), started_at + ceiling - CEILING_HEADROOM)


PROMPT = """\
Rewrite the alt text for ONE photograph, attached. Return JSON only.

The current alt text is:
{alt}

It breaks these rules and must stop breaking them:
{findings}

Rules for the replacement:
- {min_words} to {max_words} words.
{naming}\
- Describe what the camera recorded. No inferred inner states: nothing about
  what somebody felt, and nothing about who an expression was aimed at.
- Name people by name, never by appearance or gender.
- Keep describing THIS photograph. Do not drop what it shows in order to
  satisfy a rule: a description that names the venue and the performer and says
  nothing about the picture is worse than the one it replaces.

Return JSON ONLY, no markdown fences:
{{"alt": "<the replacement>"}}"""


@dataclass
class RepairOutcome:
    """What the pass did, in a form its caller can render and record."""

    body: str
    #: Folded filenames the pass chose to attempt.
    selected: list[str] = field(default_factory=list)
    #: One state per selected target. Asserted TOTAL against `selected`.
    states: dict[str, RepairState] = field(default_factory=dict)
    #: Every attempt, for the journal.
    attempts: list[dict[str, Any]] = field(default_factory=list)
    #: Whether the pass RAN. A clean post and a pass that never started are
    #: different things and must not read the same (L98).
    ran: bool = False
    #: How much of the deadline was left when it finished.
    remaining: float = 0.0

    #: Every state the pass can end a target in. No default branch: a state
    #: nothing can produce is a state nothing tests (L113).
    STATES = (RepairState.REPAIRED, RepairState.TRIED, RepairState.BLOCKED,
              RepairState.UNAVAILABLE, RepairState.NOT_REACHED)

    def repair_for(self, finding: Finding) -> RepairState:
        """What to render beside one finding that SURVIVED the pass.

        Keyed on the finding's own target, which is the folded filename for
        every alt text rule. Never `REPAIRED`: a repaired finding does not
        survive, because the alt text stops failing the check that selected it.

        A finding on a target the pass never selected is never-attempted, which
        is the correct answer and renders exactly as it does today.
        """
        for key, state in self.states.items():
            if key in finding.detail.casefold() or finding.detail.casefold() \
                    .startswith(key):
                return RepairState.NEVER if state is RepairState.REPAIRED \
                    else state
        return RepairState.NEVER


def repair_alt_text(
        body: str,
        *,
        program: dict[str, Any] | None,
        venue: str,
        photo_paths: dict[str, str],
        runner: Callable[..., Any] = run_json_prompt,
        now: Callable[[], float] | None = None,
        deadline: float | None = None,
        max_rounds: int = MAX_ROUNDS,
        timeout: int = CALL_TIMEOUT,
        journal: Callable[[dict], None] | None = None,
        say: Any = None,
) -> RepairOutcome:
    """Rewrite every alt text a check refused, one call per marker.

    `photo_paths` maps a marker's filename to the file on disk. `deadline` is an
    ABSOLUTE value on `now()`'s scale, derived by the caller from its own process
    start, never a constant number of seconds: the 1,800 second process ceiling
    is shared differently on each path, and a budget expressed as a constant is
    safe only for whichever path calibrated it (L227, L522).
    """
    import time

    now = now or time.monotonic
    deadline = float("inf") if deadline is None else deadline
    performers = [str(p.get("name", "")).strip()
                  for p in (program or {}).get("performers") or []
                  if str(p.get("name", "")).strip()]

    outcome = RepairOutcome(body=body, ran=True)

    # Which markers a check refused. Selected from `check_alt_text`, which is
    # literally the call the acceptance check re-runs, so a marker cannot be
    # selected by one rule and accepted by a different reading of it (L263).
    def failing(current: str) -> dict[str, list[Finding]]:
        out: dict[str, list[Finding]] = {}
        for name, alt in _markers(current):
            found = check_alt_text(name, alt, venue=venue, performers=performers)
            if found:
                out[_fold_filename(name)] = found
        return out

    selected = failing(body)
    outcome.selected = sorted(selected)
    if not selected:
        outcome.remaining = deadline - now()
        return outcome

    rounds: dict[str, int] = {key: 0 for key in selected}

    for key in outcome.selected:
        # The deadline is checked BEFORE committing, and it reserves the whole
        # TIMEOUT rather than the measured cost: a call that hits its ceiling is
        # exactly the one that carries the process past its own, and when 1,800
        # seconds fires the process is SIGTERM'd and every paid call in the week
        # is destroyed, which is worse than any finding this exists to fix.
        if now() + timeout > deadline:
            outcome.states[key] = RepairState.NOT_REACHED
            continue

        state = _repair_one(
            key, outcome, photo_paths=photo_paths, venue=venue,
            performers=performers, program=program, runner=runner,
            timeout=timeout, max_rounds=max_rounds, rounds=rounds,
            now=now, deadline=deadline, journal=journal, say=say,
            index=outcome.selected.index(key) + 1,
            total=len(outcome.selected))
        outcome.states[key] = state

    outcome.remaining = deadline - now()

    # The partition, asserted total (L47, L517). A target can be lost without
    # throwing: alt text splices per marker, so a key that stops resolving would
    # otherwise end the pass carrying the never-attempted default, which renders
    # exactly like today's findings.
    missing = [k for k in outcome.selected if k not in outcome.states]
    if missing:
        raise RuntimeError(
            f"the repair pass selected {len(outcome.selected)} target(s) and "
            f"resolved {len(outcome.states)}; these ended in no state at all "
            f"and would have rendered as never attempted: {missing}")
    return outcome


def _repair_one(key, outcome, *, photo_paths, venue, performers, program,
                runner, timeout, max_rounds, rounds, now, deadline, journal,
                say, index, total) -> RepairState:
    """Up to `max_rounds` attempts at one marker. Returns its final state."""
    state = RepairState.TRIED

    for _attempt in range(max_rounds):
        current = {_fold_filename(n): (n, a) for n, a in _markers(outcome.body)}
        if key not in current:
            # The marker stopped resolving under an earlier splice.
            return RepairState.BLOCKED
        name, alt = current[key]

        found = check_alt_text(name, alt, venue=venue, performers=performers)
        if not found:
            # Nothing left to fix on this marker. Reached on the second round
            # after a first that landed, and on the first when an earlier
            # marker's splice cleared a cross-marker rule.
            return RepairState.REPAIRED

        if now() + timeout > deadline:
            return RepairState.NOT_REACHED

        path = photo_paths.get(name) or photo_paths.get(key)
        try:
            resolved = decode_photo_path(str(path or ""))
            if not resolved or not Path(resolved).is_file():
                raise OSError(f"no photograph on disk for {name}")
        except OSError as e:
            # No call is paid for: there is nothing to attach, and rule 4 is a
            # rewrite WITH the photograph. Blocked, not tried: this is worth
            # trying again once the file is back.
            _record(journal, outcome, key=key, name=name, before=alt, after=None,
                    codes=[f.code for f in found], outcome_state=RepairState.BLOCKED,
                    reason=str(e))
            print(f"[blog_repair] {name}: {e}", flush=True, file=sys.stderr)
            return RepairState.BLOCKED

        if say is not None:
            say.step("Blog: rewriting alt text", index=index, total=total)

        rounds[key] += 1
        naming = ""
        if venue.strip():
            naming += f"- Name the venue: {venue.strip()}.\n"
        if performers:
            naming += ("- Name the performer. The people on this bill are: "
                       + ", ".join(performers) + ".\n")

        prompt = PROMPT.format(
            alt=alt,
            findings="".join(f"- {f.code}: {f.message}\n" for f in found),
            min_words=ALT_MIN_WORDS, max_words=ALT_MAX_WORDS, naming=naming)

        try:
            answer = runner(prompt, timeout=timeout, image_paths=[resolved],
                            image_labels=[name], step="blog_repair_alt_text")
        except (ClaudeError, OSError, TimeoutError) as e:
            # A network blip is not "the app tried and cannot do better": for
            # that, `tried`'s claim is simply false (L11). An otherwise finished
            # draft is never lost to one, so the loop continues.
            _record(journal, outcome, key=key, name=name, before=alt, after=None,
                    codes=[f.code for f in found],
                    outcome_state=RepairState.BLOCKED, reason=str(e))
            print(f"[blog_repair] {name}: could not reach the model ({e})",
                  flush=True, file=sys.stderr)
            return RepairState.BLOCKED

        candidate = strip_em_dashes(str((answer or {}).get("alt", "")).strip())

        # Acceptance, in this order: strip, re-run literally the rules that
        # selected it, then the gate over the whole body.
        remaining = check_alt_text(name, candidate, venue=venue,
                                   performers=performers)
        if remaining:
            _record(journal, outcome, key=key, name=name, before=alt,
                    after=candidate, codes=[f.code for f in found],
                    outcome_state=RepairState.TRIED,
                    reason="; ".join(f.code for f in remaining))
            state = RepairState.TRIED
            continue

        spliced = _splice_one(outcome.body, name, candidate)
        reasons = blog_repair_damage(
            outcome.body, spliced, program=program, venue=venue,
            photo_filenames=list(photo_paths),
            touched=Touched.marker(name))
        if reasons:
            _record(journal, outcome, key=key, name=name, before=alt,
                    after=candidate, codes=[f.code for f in found],
                    outcome_state=RepairState.TRIED, reason="; ".join(reasons))
            state = RepairState.TRIED
            continue

        outcome.body = spliced
        _record(journal, outcome, key=key, name=name, before=alt,
                after=candidate, codes=[f.code for f in found],
                outcome_state=RepairState.REPAIRED, reason="")
        return RepairState.REPAIRED

    return state


def _splice_one(body: str, name: str, alt: str) -> str:
    """Replace exactly one marker's alt text, by folded filename."""
    target = _fold_filename(name)

    def _swap(match):
        if _fold_filename(match.group(1).strip()) != target:
            return match.group(0)
        return f"[PHOTO: {match.group(1).strip()} | {alt}]"

    return _PHOTO_MARKER.sub(_swap, body)


def _record(journal, outcome, *, key, name, before, after, codes,
            outcome_state, reason) -> None:
    """One ATTEMPT record, kept whether or not a journal is listening.

    Held on the outcome as well as handed to the journal, so a caller with no
    journal still has the evidence and the two cannot disagree about what
    happened (L41).
    """
    entry = {
        "target": key,
        "marker": name,
        "codes": list(codes),
        "before": before,
        "after": after,
        "outcome": outcome_state.value,
        "reason": reason,
    }
    outcome.attempts.append(entry)
    if journal is not None:
        journal(entry)
