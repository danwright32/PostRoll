"""Repair a caption's alt text, the way the blog's is repaired (#1155).

The blog checks repair themselves and say what they tried; the caption checks
could only report. Both sides already shared `Finding` and `finding_entry`, so
the vocabulary was common while the behaviour was not, and Phase 4 widened the
shared payload with a `repair` field that every caption finding carried empty:
a state meaning "never attempted" on a path where nothing could ever attempt
anything.

This is `blog_repair.repair_alt_text`'s shape on a list rather than a body of
markers, and it shares the parts that decide things rather than copying them:

  * the rules that SELECT an alt text are the rules that ACCEPT the rewrite,
    through `check_one_alt_text`, so acceptance cannot drift from selection
    (L263);
  * the damage gate is `alt_text_damage`, the same three rules the blog gate
    applies to one alt text, with the constants measured on 55 of Dan's own
    corrections;
  * the states are `RepairState`, meaning what they mean there, because they
    invite the same actions.

What is different is the target. A blog alt text lives in a `[PHOTO: name |
alt]` marker and is spliced back into prose; a caption's lives at an index in a
list, beside the photograph `alt_text_photo_paths` anchors it to (#1008, #1035).
So the key here is the INDEX, and the photograph is the path at that index.

Every seam the blog pass takes is taken here: the runner, the clock and the
deadline all arrive as arguments, so nothing in the suite reaches a model or
waits on one (L2, L524).
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

from .blog_findings import Finding, RepairState
from .blog_repair import MAX_ROUNDS, PROMPT, render_examples
from .blog_repair_damage import alt_text_damage
from .caption_quality import check_one_alt_text
from .claude_client import ClaudeError, run_json_prompt
from .blog_photo_stamps import decode_photo_path
from .ai_tells import strip_em_dashes

#: How long one rewrite may take. The blog pass's own call timeout, because it
#: is the same call with the same photograph attached.
CALL_TIMEOUT = 120


@dataclass
class CaptionRepairOutcome:
    """What the pass did, in a form its caller can render and record."""

    alt_texts: list[str]
    #: The indexes the pass chose to attempt.
    selected: list[int] = field(default_factory=list)
    #: One state per selected index. Total against `selected`.
    states: dict[int, RepairState] = field(default_factory=dict)
    #: Every attempt, for a journal or a log line.
    attempts: list[dict[str, Any]] = field(default_factory=list)
    #: Whether the pass RAN. A post with nothing to repair and a pass that never
    #: started are different things and must not read the same (L98).
    ran: bool = False
    #: What each index describes, so a state can be matched back to a finding.
    names: list[str] = field(default_factory=list)

    def repair_for(self, finding: Finding) -> RepairState:
        """What to render beside one finding that SURVIVED the pass.

        Matched on the photograph the finding names, which is the same string
        `check_one_alt_text` was given as `where`. Never `REPAIRED`: a repaired
        finding does not survive, because the alt text stops failing the check
        that selected it.

        A finding the pass never selected is never-attempted, which is the
        correct answer and renders exactly as every caption finding does today.
        """
        detail = (finding.detail or "").casefold()
        for index, state in self.states.items():
            name = self.names[index].casefold() if index < len(self.names) else ""
            if name and (detail == name or detail.startswith(name)):
                return RepairState.NEVER if state is RepairState.REPAIRED else state
        return RepairState.NEVER


def repair_caption_alt_texts(
        alt_texts: list[str],
        *,
        band: tuple[int, int] | None,
        photo_paths: list[str],
        photo_names: list[str] | None = None,
        program: dict[str, Any] | None = None,
        venue: str = "",
        runner: Callable[..., Any] | None = None,
        now: Callable[[], float] | None = None,
        deadline: float | None = None,
        max_rounds: int = MAX_ROUNDS,
        timeout: int = CALL_TIMEOUT,
        say: Any | None = None,
) -> CaptionRepairOutcome:
    """Rewrite the alt texts that break a rule, and say what happened to each.

    `deadline` is ABSOLUTE on `now()`'s scale, never a number of seconds: the
    process ceiling is shared differently on every path, and a budget expressed
    as a constant is safe only for whichever path calibrated it (L227, L522).
    Without one the pass does not run, because a pass with no budget is the one
    route able to carry a week run past its ceiling.

    The alt texts are returned whole, repaired where a rewrite was accepted and
    unchanged everywhere else, so a caller writes back one list rather than
    merging two.
    """
    runner = runner or run_json_prompt
    if now is None:
        import time
        now = time.monotonic

    names = list(photo_names or [])
    if len(names) < len(alt_texts):
        names += [Path(p).name if i < len(photo_paths) else str(i + 1)
                  for i, p in enumerate(photo_paths[len(names):]
                                        + [""] * len(alt_texts))][
            :len(alt_texts) - len(names)]

    outcome = CaptionRepairOutcome(alt_texts=list(alt_texts), names=names)

    failing = {
        index: check_one_alt_text(alt, band=band, where=_where(names, index))
        for index, alt in enumerate(outcome.alt_texts)
    }
    outcome.selected = sorted(i for i, found in failing.items() if found)
    if not outcome.selected:
        return outcome

    outcome.ran = True
    if deadline is None:
        # No budget is not an unlimited one. Every selected item is reported as
        # not reached, which is what a caller renders and what says the pass
        # could not be run rather than that it found nothing (L98, L110).
        for index in outcome.selected:
            outcome.states[index] = RepairState.NOT_REACHED
        return outcome

    for position, index in enumerate(outcome.selected, start=1):
        outcome.states[index] = _repair_one(
            index, outcome, band=band, photo_paths=photo_paths,
            program=program, venue=venue, runner=runner, now=now,
            deadline=deadline, max_rounds=max_rounds, timeout=timeout,
            say=say, position=position, total=len(outcome.selected))
    return outcome


def _where(names: list[str], index: int) -> str:
    return names[index] if index < len(names) else str(index + 1)


def _repair_one(index, outcome, *, band, photo_paths, program, venue, runner,
                now, deadline, max_rounds, timeout, say, position,
                total) -> RepairState:
    """Up to `max_rounds` attempts at one alt text. Returns its final state."""
    name = _where(outcome.names, index)

    if index >= len(photo_paths) or not str(photo_paths[index] or "").strip():
        # No photograph on this path at all, and there never will be on this
        # run: the revise path carries filenames without paths. Different from
        # a file that has gone missing, which is worth retrying (#1132).
        _record(outcome, index=index, name=name, before=outcome.alt_texts[index],
                after=None, codes=[], state=RepairState.UNAVAILABLE,
                reason="no photograph was sent with this alt text")
        return RepairState.UNAVAILABLE

    state = RepairState.TRIED
    for _attempt in range(max_rounds):
        alt = outcome.alt_texts[index]
        found = check_one_alt_text(alt, band=band, where=name)
        if not found:
            return RepairState.REPAIRED

        if now() + timeout > deadline:
            return RepairState.NOT_REACHED

        try:
            resolved = decode_photo_path(str(photo_paths[index] or ""))
            if not resolved or not Path(resolved).is_file():
                raise OSError(f"no photograph on disk for {name}")
        except OSError as error:
            # No call is paid for: there is nothing to attach, and the rewrite
            # is a rewrite WITH the photograph. Blocked, not tried: this is
            # worth trying again once the file is back.
            _record(outcome, index=index, name=name, before=alt, after=None,
                    codes=[f.code for f in found], state=RepairState.BLOCKED,
                    reason=str(error))
            print(f"[caption_repair] {name}: {error}", flush=True, file=sys.stderr)
            return RepairState.BLOCKED

        if say is not None:
            say.step("Caption: rewriting alt text", index=position, total=total)

        naming = f"- Name the venue: {venue.strip()}.\n" if venue.strip() else ""
        low, high = band or (0, 0)
        prompt = PROMPT.format(
            alt=alt,
            findings="".join(f"- {f.code}: {f.message}\n" for f in found),
            min_words=low, max_words=high, naming=naming,
            examples=render_examples())

        try:
            answer = runner(prompt, timeout=timeout, image_paths=[resolved],
                            image_labels=[name], step="caption_repair_alt_text")
        except (ClaudeError, OSError, TimeoutError) as error:
            # A network blip is not "the app tried and cannot do better": for
            # that, `tried`'s claim is simply false (L11).
            _record(outcome, index=index, name=name, before=alt, after=None,
                    codes=[f.code for f in found], state=RepairState.BLOCKED,
                    reason=str(error))
            print(f"[caption_repair] {name}: could not reach the model ({error})",
                  flush=True, file=sys.stderr)
            return RepairState.BLOCKED

        candidate = strip_em_dashes(str((answer or {}).get("alt", "")).strip())

        # Acceptance, in this order: re-run literally the rules that selected
        # it, then the damage gate. Both have to pass, and neither is a
        # restatement of the other: the rules say the rewrite is legal, the gate
        # says it still describes the photograph.
        remaining = check_one_alt_text(candidate, band=band, where=name)
        if remaining:
            _record(outcome, index=index, name=name, before=alt, after=candidate,
                    codes=[f.code for f in found], state=RepairState.TRIED,
                    reason="; ".join(f.code for f in remaining))
            state = RepairState.TRIED
            continue

        harm = alt_text_damage(alt, candidate, program=program, venue=venue,
                               photo_filenames=list(outcome.names))
        if harm:
            _record(outcome, index=index, name=name, before=alt, after=candidate,
                    codes=[f.code for f in found], state=RepairState.TRIED,
                    reason="; ".join(harm))
            state = RepairState.TRIED
            continue

        outcome.alt_texts[index] = candidate
        _record(outcome, index=index, name=name, before=alt, after=candidate,
                codes=[f.code for f in found], state=RepairState.REPAIRED,
                reason="")
        return RepairState.REPAIRED

    return state


def _record(outcome, *, index, name, before, after, codes, state, reason) -> None:
    """One attempt, kept whether it landed or not.

    Repairs are SILENT by design, so a pass that repaired nothing and a pass
    that never ran would otherwise read identically to the only surface that
    reports either (L98).
    """
    outcome.attempts.append({
        "index": index,
        "photo": name,
        "before": before,
        "after": after,
        "codes": list(codes),
        "outcome": state.value,
        "reason": reason,
    })
