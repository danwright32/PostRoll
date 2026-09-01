"""
PostRoll — Blog Reviser

Revises an existing blog post draft based on Dan's plain-English feedback.
Only the title and body change; photo markers ([PHOTO: filename.jpg | alt])
must be preserved verbatim.

Input manifest:
{
  "event": "...",
  "org": "...",
  "venue": "...",
  "date": "...",
  "shoot_type": "...",
  "program": { ...OCR dict... },
  "existing": {
    "title": "...",
    "body":  "..."
  },
  "feedback": "tighten the middle, cut the closing CTA",
  "photo_filenames": ["DSC4821.jpg", ...]   // optional; the names the post's
                                            // photos actually carry on disk
}

Output JSON (written to --output file):
{
  "title": "...",
  "body":  "...",
  "photo_count": <preserved from input>
}

Usage:
    python -m postroll.ai.revise_blog \\
        --manifest /path/to/revision.json \\
        --output   /path/to/result.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from .ai_tells import (
    BLOG_HUMANIZER_EXTRA_BANS,
    BLOG_VOICE_EXTRA_CHECKS,
    build_review_prompt,
    build_voice_review_prompt,
    is_humanizer_available,
    load_humanizer_rules,
    strip_em_dashes,
)
from .claude_client import run_json_prompt, run_review_pass, load_brand_voice, ClaudeError
from .blog_findings import RepairState
from .blog_marker_splice import splice_retained_markers
from .repair_log import RepairLog
from .blog_quality import _PHOTO_MARKER, _fold_filename
from .progress import ProgressWriter
from .blog_quality import (check_blog_targeted, filenames_used_by, finding_entry,
                           repair_marker_filenames,
                           repair_marker_placement)
from .generate_blog import (
    _fix_missing_contractions,
    _fix_second_person,
    _fix_wrong_names,
    _format_performers,
    _format_pieces,
    BLOG_STRUCTURE,
    BLOG_WRITING_RULES,
)


def ordered_markers_validator(prior_body: str, revised: dict) -> str | None:
    """A review pass may not add, drop, rename OR REORDER a photo marker (#1131).

    `markers_preserved_validator` SORTS the filenames it compares
    (`ai_tells.photo_marker_filenames` is a `sorted(...)`), so it cannot see a
    marker moving to a different point in the post. A photograph that swaps
    places with another, while the prose written about each stays put, passes it
    every time, and this is the repo's only marker guard.

    Takes the prior BODY rather than a prior dict, because the pass 1 call has
    no prior dict to compare against: it is the first thing that runs, and what
    it must preserve is the body Dan is revising.
    """
    def markers(body: str) -> list[str]:
        return [_fold_filename(name)
                for name, _alt in _PHOTO_MARKER.findall(body or "")]

    expected = markers(prior_body)
    got = markers(revised.get("body", ""))
    if expected != got:
        return f"changed or reordered the [PHOTO:] markers ({expected} -> {got})"
    return None


REVISE_PROMPT = """\
{brand_voice}

---

Dan Wright has reviewed the following blog post draft for {event} and
wants a revision. The brand voice rules above STILL APPLY — preserve the
10-12 short paragraph structure, continuous prose, no headings, no
bullets, honest framing of what Dan actually witnessed.

Existing title:
{title}

Existing body:
{body}

Dan's feedback:
{feedback}

Event context:
- Organization: {org}
- Venue: {venue}{venue_context_line}
- Date: {date}
- Shoot type: {shoot_type}

Performers (from program OCR):
{performers}

Repertoire (from program OCR):
{pieces}

Apply Dan's feedback to revise the title and body. Rules:

1. PRESERVE all [PHOTO: filename.jpg | alt text] markers from the existing
   body EXACTLY — same filenames, same alt text, same positions unless
   Dan's feedback explicitly asks you to move or change one. These are
   the only photos available; you cannot invent new ones.
2. Keep 10-12 short paragraphs separated by blank lines.
3. No headings, no bullets, no section breaks.

{blog_structure}

Prose rules (same as initial generation — all apply):
{blog_writing_rules}
- Inside the JSON "body" string, escape newlines as \\n so the JSON parses cleanly.

Return JSON ONLY (no markdown fences, no commentary) in this shape:

{{
  "title": "<revised title>",
  "body":  "<revised markdown body with [PHOTO: ...] markers preserved>"
}}
"""


def revise_blog(
    *,
    event: str,
    org: str,
    venue: str,
    date: str,
    shoot_type: str = "performance",
    program: dict[str, Any],
    existing: dict[str, Any],
    feedback: str,
    venue_context: str = "",
    event_id: str = "",
    photo_filenames: list[str] | None = None,
    humanizer_path: str | Path | None = None,
    skip_humanizer: bool = False,
    skip_voice_pass: bool = False,
    progress: ProgressWriter | None = None,
) -> dict[str, Any]:
    """Revise an existing blog post based on plain-English feedback.

    Photo markers in the body are preserved; only the prose is revised.
    Pipeline mirrors generate_blog: draft → voice pass → humanizer pass.

    `photo_filenames` are the names the post's photos carry on disk. With them
    the filename rules run, which is what makes a marker the revision renamed
    visible at all; without them those two rules stay off, exactly as
    `check_blog` documents, so an event whose photo paths are gone does not
    have every marker reported as unknown (#962).

    `progress` is where this run says what it is doing (#1128). Three
    sequential Claude calls at a 600 second timeout each said nothing on any
    channel the app reads, so a revision that was working, one that was hung
    and one whose process had died all presented as the same spinner. The
    standing rule is that no such action shows a bare indefinite one, and this
    milestone adds up to seven more calls to this path.
    """
    say = (progress or ProgressWriter(None))
    brand_voice_text = load_brand_voice()

    title = existing.get("title", "")
    body  = existing.get("body", "")
    photo_count = int(existing.get("photo_count", 0) or 0)

    venue_context_line = (
        f" — performed in {venue_context.strip()}"
        if venue_context and venue_context.strip() else ""
    )

    prompt = REVISE_PROMPT.format(
        brand_voice=brand_voice_text,
        blog_structure=BLOG_STRUCTURE,
        blog_writing_rules=BLOG_WRITING_RULES,
        event=event,
        org=org,
        venue=venue,
        venue_context_line=venue_context_line,
        date=date,
        shoot_type=shoot_type,
        title=title,
        body=body,
        feedback=feedback,
        performers=_format_performers(program.get("performers", [])),
        pieces=_format_pieces(program.get("pieces", [])),
    )

    say.step("Blog: making the revision")
    data = run_json_prompt(prompt, timeout=600, step="revise_blog")
    if not isinstance(data, dict):
        raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")

    # This call had NO validator at all (#1131), so a marker it dropped,
    # renamed or moved was pinned in place by the two review passes that follow
    # and reached the review screen preserved faithfully. Reported rather than
    # raised: the revision is still usable, and losing a paid pass over it would
    # be worse than saying so.
    problem = ordered_markers_validator(body, data)
    if problem:
        print(f"[revise_blog] the revision {problem}", flush=True, file=sys.stderr)

    blog_shape = (
        "{title: string, body: string with [PHOTO: filename.jpg | alt text]"
        " markers preserved exactly as-is}"
    )

    if not skip_voice_pass:
        say.step("Blog: checking it sounds like you")
        voice_prompt = build_voice_review_prompt(
            draft_json=json.dumps(data, ensure_ascii=False, indent=2),
            brand_voice=brand_voice_text,
            output_shape_description=blog_shape,
            extra_checks=BLOG_VOICE_EXTRA_CHECKS,
        )
        data = run_review_pass(
            voice_prompt, data, label="voice", timeout=600,
            runner=run_json_prompt,
            # The ordered comparison, not the sorted one: a reorder is
            # invisible to `markers_preserved_validator` (#1131).
            validate=lambda prior, revised: ordered_markers_validator(
                prior.get("body", ""), revised),
        )

    if not skip_humanizer and is_humanizer_available(humanizer_path):
        say.step("Blog: removing AI tells")
        humanizer_rules = load_humanizer_rules(humanizer_path)
        review_prompt = build_review_prompt(
            draft_json=json.dumps(data, ensure_ascii=False, indent=2),
            humanizer_rules=humanizer_rules,
            brand_voice=brand_voice_text,
            output_shape_description=blog_shape,
            extra_hard_bans=BLOG_HUMANIZER_EXTRA_BANS,
        )
        data = run_review_pass(
            review_prompt, data, label="humanizer", timeout=600,
            runner=run_json_prompt,
            validate=lambda prior, revised: ordered_markers_validator(
                prior.get("body", ""), revised),
        )

    # Every marker restored from the body being revised (#1131).
    #
    # A revision is under orders to keep each `[PHOTO: filename | alt text]`
    # verbatim and nothing checked it: the repo's only marker guard sorts the
    # filenames and never reads the alt text. The splice makes the instruction
    # unnecessary rather than better worded, needs no photograph, and costs
    # nothing.
    #
    # Applied after the review passes and before the dash strip, so what ships
    # is what Dan already had, dash stripped once like everything else.
    #
    # The count is reported because the splice DESTROYS the evidence it was
    # needed: a model that rewrote every marker and one that reproduced them all
    # produce a byte identical body afterwards (L340).
    revised_body = data.get("body", body)
    try:
        revised_body, drift = splice_retained_markers(
            body, revised_body,
            {name for name, _alt in _PHOTO_MARKER.findall(body)})
    except ValueError as e:
        # Not fatal, and not silent: the revision is still a usable draft and
        # a dropped marker cannot be put back without inventing a position for
        # it (#998). check_blog reports the loss below.
        print(f"[revise_blog] {e}", flush=True, file=sys.stderr)
    else:
        if drift:
            print(f"[revise_blog] RESTORED {drift} photo marker(s) the revision "
                  f"rewrote despite being told to preserve them verbatim",
                  flush=True, file=sys.stderr)
        data = dict(data, body=revised_body)

    say.step("Blog: running the checks")
    final_body = strip_em_dashes(data.get("body", body).strip())
    final_body = _fix_wrong_names(final_body, program)
    final_body = _fix_second_person(final_body)
    final_body = _fix_missing_contractions(final_body)
    # A revision is a live path back into the blog, and "add more detail" is
    # exactly the request most likely to reintroduce an invented number or a
    # performance review, so it runs the same deterministic checks the first
    # pass does (#201).
    # The list carries the photos AVAILABLE to this event, not the photos in
    # this post: generation subsamples to seven when more are assigned, and
    # Dan's DiGangi event holds twelve. Checked against all twelve, the five
    # nobody chose are reported as never placed on every single revision, which
    # is the check crying wolf (L36). The post's own set is stated by the body
    # being revised, which this pass is under orders to preserve verbatim.
    in_the_post = filenames_used_by(body, photo_filenames)
    if photo_filenames and not in_the_post:
        # Deliberate, and said out loud rather than fallen through to: no
        # marker in the existing body names any photo on this event, so which
        # photos the post holds is genuinely unknown. That is a different
        # situation from having been sent no list at all (L214), and the answer
        # is the same only because reporting every marker as unknown would be
        # worse than reporting none.
        print(f"[revise_blog] no marker in the existing body names any of the "
              f"{len(photo_filenames)} photos on this event, so the filename "
              f"rules are skipped rather than reporting every marker unknown",
              flush=True, file=sys.stderr)

    # A near-miss filename is repaired rather than reported (#962).
    final_body, repairs = repair_marker_filenames(final_body, in_the_post)
    for was, now in repairs:
        print(f"[revise_blog] REPAIRED marker filename: {was!r} -> {now!r}",
              flush=True, file=sys.stderr)
    # Move a marker the placement rules refused, deterministically (#1153, #1154).
    #
    # The second exception to the report-only rule, and it is narrow for the same
    # reason the first one is: nothing is invented. No prose is written or lost,
    # and photographs keep their order relative to each other. Both destinations
    # are read off the rules rather than judged, and a move with no derived
    # destination is refused and left for the checks to report (L98).
    #
    # Runs after the filename repair, because it reads marker names, and before
    # the checks, so the panel reports where a marker IS rather than where it was.
    placement = repair_marker_placement(final_body)
    final_body = placement.body
    # Recorded where it outlives publication (#1172). A move changes what
    # Dan published without saying so, and a REFUSAL is reported only on a
    # panel that clears while the condition stays, so neither survives to
    # answer the question afterwards unless it is written here.
    _placement_log = RepairLog(event=venue or "", event_id=event_id,
                               script="revise_blog")
    for marker, why in placement.moved:
        print(f"[revise_blog] MOVED marker {marker!r} ({why})",
              flush=True, file=sys.stderr)
        _placement_log.moved(marker=marker, rule=why, placed=True, reason="")
    for marker, why in placement.refused:
        print(f"[revise_blog] REFUSED to move marker {marker!r} ({why}): "
              f"no derived destination", flush=True, file=sys.stderr)
        _placement_log.moved(
            marker=marker, rule=why, placed=False,
            reason="no prose below the stack to move it into")

    # Targeted, so the payload can say which marker each finding is about
    # (#1160). Same findings, same order, targets kept.
    targeted = check_blog_targeted(final_body, program=program, venue=venue,
                                   photo_filenames=in_the_post or None)
    findings = [f for f, _t in targeted]
    for f in findings:
        print(f"[revise_blog] CHECK {f.code}: {f.message} ({f.detail})",
              flush=True, file=sys.stderr)

    say.finish()
    return {
        "title":       data.get("title", title).strip(),
        "body":        final_body,
        "photo_count": photo_count,
        # A revision has NO PHOTOGRAPH (#1132). Its manifest carries
        # photo_filenames and never paths, so alt text cannot be rewritten
        # here, and reporting those findings as never attempted would assert
        # something untrue about a path that structurally cannot do the work.
        # The other codes are left alone: only the alt text rules need a
        # photograph.
        "findings": [
            finding_entry(f, repair=(RepairState.UNAVAILABLE
                                     if f.code.startswith("alt_text_")
                                     else RepairState.NEVER),
                          target=t.key)
            for f, t in targeted],
        # The exact text those findings were measured against, so an edited
        # draft stops showing findings about the body before the edit. The
        # caption paths have emitted their sibling `findings_caption` since
        # #201; this one was named in the comment there and never sent, so
        # the blog panel could not go stale on any post ever generated
        # (#974).
        "findings_body": final_body,
        # Passed through, never recomputed (#1130). A revision has no
        # photographs at all: its manifest names filenames only, so it cannot
        # stat anything. Dropping the key would make the next swap treat a post
        # written yesterday as having no record and re-describe every
        # photograph in it.
        #
        # Always present, even when empty, so a reader never has to tell
        # "absent" from "nothing recorded" (L214). Every post written before
        # this shipped arrives here with nothing, and that is a first run.
        "photo_stamps": dict(existing.get("photo_stamps") or {}),
        # Honest: no pass ran here, and none ever can. The panel's own line
        # says so rather than claiming the post was checked (#1138).
        "repair_pass": {"ran": False, "selected": 0, "attempted": 0,
                        "ended_early": False},
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Revise a PostRoll blog draft based on feedback")
    parser.add_argument("--manifest", required=True, help="Path to revision manifest JSON")
    parser.add_argument("--output",   required=True, help="Path to write revised output JSON")
    parser.add_argument("--progress", help="Path to write step progress JSON")
    args = parser.parse_args()

    manifest_path = Path(args.manifest)
    if not manifest_path.exists():
        print(f"Manifest not found: {manifest_path}", file=sys.stderr)
        return 1

    m = json.loads(manifest_path.read_text(encoding="utf-8"))
    result = revise_blog(
        event=m["event"],
        org=m["org"],
        venue=m["venue"],
        venue_context=m.get("venue_context", "") or "",
        event_id=m.get("event_id", "") or "",
        date=m["date"],
        shoot_type=m.get("shoot_type", "performance"),
        program=m["program"],
        existing=m["existing"],
        feedback=m["feedback"],
        # Optional: an app build that predates #962 sends no such key, and a
        # revision must not fail on one. Absent means the filename rules stay
        # off, which is what shipped before.
        photo_filenames=m.get("photo_filenames"),
        progress=ProgressWriter(args.progress),
    )
    Path(args.output).write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"Revised blog written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
