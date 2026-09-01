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
                           _fold_filename, _markers, check_alt_text,
                           check_blog_targeted, repair_marker_placement,
                           shared_opening_groups)
from .blog_repair_damage import (CROSS_MARKER_CODES, Touched,
                                 blog_repair_damage)
from .repair_log import RepairLog
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
@dataclass(frozen=True)
class NoRepairReason:
    """Why a check code has no repairer, and where the decision is tracked.

    The issue number is not decoration (L65, L346). A component shipped
    deliberately inactive needs the issue that activates it filed in the same
    change; without one the reason is read forever after as a settled decision
    and the next reader argues with the reason instead of reopening the work.
    That is exactly what happened to `_is_real_handle` in this repo (#926,
    #1105).

    `gate` is what would have to be true to build it, and it exists because the
    two claim-deleting codes needed a gate that can actually be WRITTEN (L90):
    conditioning them on a false positive rate measured through the journal
    fails, because a DECLINED record says the check FIRED and never that it
    fired WRONGLY, so the rate reads as zero indistinguishably from a real
    reading and the deferral becomes permanent while looking scheduled.
    """
    reason: str
    issue: str
    gate: str = ""
    settled: str = ""


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
    #: The journal, held here so `_record` reaches it without being threaded
    #: through every frame. Private because it is plumbing, not an outcome.
    _log: Any = None

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
        log: RepairLog | None = None,
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

    outcome = RepairOutcome(body=body, ran=False)
    try:
        return _run_pass(body, outcome, program=program, venue=venue,
                         photo_paths=photo_paths, runner=runner, now=now,
                         deadline=deadline, max_rounds=max_rounds,
                         timeout=timeout, journal=journal, log=log, say=say,
                         performers=performers)
    finally:
        # On EVERY exit path, including the ones that threw above the loop
        # (L514, L515). Rule 1 removed every other signal, so without this a
        # pass that made no attempt, a post with nothing to repair, a pass that
        # threw before its loop, and a run killed at the process ceiling all
        # read identically (L98).
        if log is not None:
            log.finish(ran=outcome.ran, selected=len(outcome.selected),
                       attempted=len(outcome.attempts),
                       remaining=outcome.remaining,
                       placed=[n for n, _a in _markers(outcome.body)])


def _run_pass(body, outcome, *, program, venue, photo_paths, runner, now,
              deadline, max_rounds, timeout, journal, log, say, performers):
    """The loop. Separated so the PASS record's `finally` cannot be skipped."""
    # `ran` is set on the way OUT, never on the way in. It means the pass ran to
    # COMPLETION, which is the question the panel asks: a pass that threw
    # partway checked nothing Dan can rely on, and claiming otherwise would put
    # "checked, nothing outstanding" on a post nothing finished checking.
    outcome._log = log

    # Which markers a check refused. Selected from `check_alt_text`, which is
    # literally the call the acceptance check re-runs, so a marker cannot be
    # selected by one rule and accepted by a different reading of it (L263).
    def components(current: str) -> dict[str, frozenset[str]]:
        """Every marker to the set of markers it is repaired WITH (#1159).

        A marker alone is its own component. Markers the opening rule names
        together are one, because rewriting any of them changes what the others
        break: the rule is a fact about the relationship between them.
        """
        out: dict[str, frozenset[str]] = {}
        for group in shared_opening_groups(current):
            keys = frozenset(_fold_filename(n) for n in group)
            for key in keys:
                out[key] = keys
        return out

    def cross_marker(current: str) -> dict[str, list[Finding]]:
        """The cross-marker findings, attributed to every marker they NAME.

        Read from `check_blog_targeted` rather than rebuilt, so the finding the
        pass acts on is the checker's own (L263). It is TARGETED on the first
        marker of the group, because a finding needs one stable key, but it is
        ABOUT all of them, and selection has to see it on each.
        """
        by_target: dict[str, Finding] = {}
        for finding, target in check_blog_targeted(current, program=program,
                                                   venue=venue):
            if finding.code in CROSS_MARKER_CODES and target.kind == "marker":
                by_target[target.key] = finding
        out: dict[str, list[Finding]] = {}
        for key, group in components(current).items():
            for target_key, finding in by_target.items():
                if target_key in group:
                    out.setdefault(key, []).append(finding)
        return out

    # Which markers a check refused. The per-marker rules come from
    # `check_alt_text`, which is literally the call the acceptance check
    # re-runs, so a marker cannot be selected by one rule and accepted by a
    # different reading of it (L263). The cross-marker rule is added here
    # because `check_alt_text` is the six rules about ONE marker and cannot
    # produce it at all: before this, the repairer table claimed
    # `alt_text_repeated_opening` was repaired and no marker was ever selected
    # for it (#1159).
    def failing(current: str) -> dict[str, list[Finding]]:
        out: dict[str, list[Finding]] = {}
        cross = cross_marker(current)
        for name, alt in _markers(current):
            key = _fold_filename(name)
            found = list(check_alt_text(name, alt, venue=venue,
                                        performers=performers))
            found += cross.get(key, [])
            if found:
                out[key] = found
        return out

    selected = failing(body)
    outcome.selected = sorted(selected)
    _record_declined(log, body, program=program, venue=venue)
    if not selected:
        outcome.remaining = deadline - now()
        outcome.ran = True
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
            total=len(outcome.selected),
            failing=failing, components=components)
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

    outcome.ran = True
    return outcome


def _record_declined(log, body, *, program, venue) -> None:
    """One record per code the pass will not attempt, with its written reason.

    This is what produces the per-code FIRING rate the deferral gates in
    REPAIRERS are stated against. It counts how often the check fired and says
    nothing about whether it was right to, which the record's own field name
    carries (L90).
    """
    if log is None:
        return
    from collections import Counter

    from .blog_quality import check_blog

    counts = Counter(f.code for f in check_blog(body, program=program,
                                                venue=venue))
    for code, count in sorted(counts.items()):
        entry = REPAIRERS.get(code)
        if not isinstance(entry, NoRepairReason):
            continue
        log.declined(code=code, count=count, reason=entry.reason,
                     issue=entry.issue)


def _repair_one(key, outcome, *, photo_paths, venue, performers, program,
                runner, timeout, max_rounds, rounds, now, deadline, journal,
                say, index, total, failing, components) -> RepairState:
    """Up to `max_rounds` attempts at one marker. Returns its final state."""
    state = RepairState.TRIED

    for _attempt in range(max_rounds):
        current = {_fold_filename(n): (n, a) for n, a in _markers(outcome.body)}
        if key not in current:
            # The marker stopped resolving under an earlier splice.
            return RepairState.BLOCKED
        name, alt = current[key]

        found = failing(outcome.body).get(key, [])
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

        # Acceptance, in this order: strip, splice, re-run literally the rules
        # that selected it, then the gate over the whole body.
        #
        # Spliced FIRST because one of those rules is about the relationship
        # between markers, and a rule of that shape cannot be evaluated against
        # a candidate string on its own: whether this opening repeats depends on
        # what the other markers say (#1159).
        spliced = _splice_one(outcome.body, name, candidate)
        remaining = failing(spliced).get(key, [])
        if remaining:
            _record(journal, outcome, key=key, name=name, before=alt,
                    after=candidate, codes=[f.code for f in found],
                    outcome_state=RepairState.TRIED,
                    reason="; ".join(f.code for f in remaining))
            state = RepairState.TRIED
            continue

        # Licensed as a component, not as one marker. A repair that clears the
        # opening rule here can leave the remaining members still sharing with
        # each other, which per marker reads as a finding introduced on someone
        # the repair never touched.
        component = components(outcome.body).get(key, frozenset({key}))
        reasons = blog_repair_damage(
            outcome.body, spliced, program=program, venue=venue,
            photo_filenames=list(photo_paths),
            touched=Touched.marker(name, component=sorted(component)))
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
    if getattr(outcome, "_log", None) is not None:
        outcome._log.attempt(target=key, marker=name, codes=list(codes),
                             before=before, after=after,
                             outcome=outcome_state.value, reason=reason)


#: Every code `check_blog` can produce, and what the repair pass does about it.
#:
#: No default branch and no third state. A default renders the next finding code
#: somebody adds as a deliberate decision nobody made, and a table driven by a
#: hand written list checks only what the list names, so anything missing from
#: it is exempt from the very check meant to catch it (L96, L113, L233).
#: `tests/test_blog_repairer_table.py` derives the vocabulary from the
#: `Finding(` literals in `blog_quality.py` and holds this table to it.
#:
#: The firing rates below were measured on the 21 stored final bodies on
#: 2026-09-01, which are posts Dan considered finished. A rate says how often a
#: check fires and nothing at all about whether it was right to.
REPAIRERS: dict[str, "object"] = {
    # --- repaired, with the photograph attached (rule 4) --------------------
    "alt_text_empty": repair_alt_text,
    "alt_text_length": repair_alt_text,
    "alt_text_missing_venue": repair_alt_text,
    "alt_text_missing_performer": repair_alt_text,
    "alt_text_inferred_state": repair_alt_text,
    "alt_text_appearance_descriptor": repair_alt_text,
    # Repaired as part of a COMPONENT, and since #1159 the loop actually does
    # this. It was a claim nothing honoured: the pass picks its targets from
    # `check_alt_text`, which is the six rules about one marker and cannot
    # produce this code, so no marker was ever selected for it. Selection now
    # reads the cross-marker rule from `check_blog_targeted` and attributes it
    # to every marker the group names, the acceptance check runs on the SPLICED
    # body because whether an opening repeats depends on what the other markers
    # say, and the damage gate judges the code across the licensed component
    # rather than per marker, so relocating it while the group shrinks is not
    # read as a finding introduced on somebody the repair never touched.
    "alt_text_repeated_opening": repair_alt_text,

    # --- repaired already, deterministically, before this pass --------------
    "blog_marker_unknown_photo": NoRepairReason(
        reason="A near miss of a real filename is already corrected by "
               "repair_marker_filenames, deterministically and with no model "
               "call, because the true spelling is in hand. What is left after "
               "that is a name the model genuinely invented, and snapping it to "
               "the nearest file would put the wrong photograph under prose "
               "written about a different one.",
        issue="#1149",
        settled="Decided 2026-09-01 and closed. The deterministic half already "
                "runs, and what survives it is an invented name; snapping it "
                "to the nearest of the 0 candidate files that would be a real "
                "match is the failure, not the fix."),

    # --- no repairer in v1, each with the issue that would change that ------
    "blog_marker_missing_photo": NoRepairReason(
        reason="Placing a photograph means writing new descriptive prose about "
               "its content and choosing where in the flow it belongs, which "
               "exceeds rule 3 and rule 4 and sits on rule 9's drops a photo "
               "inverted. The evidence this finding was incidentally providing "
               "now has a deliberate home in photo_stamps (#1130, L277).",
        issue="#1149",
        settled="Decided 2026-09-01 and closed, not deferred. It fires 0 times "
                "on the 21 stored final bodies, because check_blog only runs "
                "the filename rules where a photo list is available, and the "
                "repair it would need writes new prose about a photograph's "
                "content, which no rule here permits."),
    "invented_number": NoRepairReason(
        reason="The only proposed repair that DELETES a claim from prose Dan "
               "publishes, and it already carries three suppression mechanisms "
               "added after false alarms. It fires 32 times across 15 of 21 "
               "stored posts he considered finished, which says its rate is "
               "high and nothing about its accuracy.",
        issue="#1150",
        settled="The first of the two gates was taken: a hand review of all 32 "
                "firings across the 21 stored final bodies, 2026-09-01. 8 "
                "fired on photo filenames and alt text leaking into the prose "
                "rule's input, 3 on numerals carrying no count (the years 1969 "
                "and 2009, and the festival name in 'America at 250'), and 21 "
                "on real counts in prose, many of them counting what is "
                "visible in the photograph directly above. None was a number a "
                "reader would call wrong. A silent deleter would have removed "
                "32 true or harmless claims from 15 of 21 published posts and "
                "0 false ones, which is the named failure this milestone "
                "exists to prevent."),
    "demographic_grouping": NoRepairReason(
        reason="The same shape as invented_number: a claim deleted from prose "
               "Dan publishes. It fires 0 times on the 21 stored posts, which "
               "is a weaker case for a repairer rather than a stronger one.",
        issue="#1151",
        settled="Settled with invented_number by the same hand review, "
                "2026-09-01: 0 firings across the 21 stored final bodies. A "
                "claim-deleting repair with no observed firing has no evidence "
                "it would delete the right claim, so 0 firings is a weaker "
                "case for building one than a high rate would be, not a "
                "stronger one."),
    "repeated_construction": NoRepairReason(
        reason="Rewriting it means choosing which of two uses of a construction "
               "to keep and what to put in place of the other, which is a "
               "judgement about the prose rather than a fact the app holds "
               "(rule 3). It fires 0 times on the 21 stored posts.",
        issue="#1152",
        settled="Decided 2026-09-01 and closed. 0 firings across the 21 stored "
                "final bodies, and the repair needs a judgement about which "
                "use of a construction to keep and what replaces the other, "
                "which is prose the app would be writing rather than a fact it "
                "already holds."),

    # --- repaired deterministically, by MOVING a marker (#1153, #1154) ------
    # Not a model call and not a rewrite. The destination is read off the rule
    # that fired rather than judged, no prose is written or lost, and
    # photographs keep their order relative to each other. Where no destination
    # can be derived it refuses and the check reports, which is why these two
    # codes can still appear on the panel after a pass (L98).
    "stacked_photos": repair_marker_placement,
    "late_first_photo": repair_marker_placement,
}
