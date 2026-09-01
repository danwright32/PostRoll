"""
PostRoll — Blog Photo Marker Swapper

Replaces [PHOTO: filename | alt text] markers in an existing blog body with
new markers for a different set of photos. Every word of prose is preserved
exactly. Only the marker lines change.

Input manifest:
{
  "body": "<current blog body with [PHOTO: ...] markers>",
  "photo_paths": ["/path/to/p1.jpg", ...],
  "program": {"performers": [{"name": "..."}]},   // optional, for alt text naming
  "venue": "...",                                  // optional, for alt text naming
  "venue_context": "...",                          // optional, the gate reads it
  "org": "...",                                    // optional, the gate reads it
  "photo_stamps": {"a.jpg": [mtime_ns, size]}      // optional, what the incoming
                                                   // alt text was written against
}

Output JSON:
{
  "body": "<updated body with new markers>",
  "photo_count": <N>,
  "findings": [{"code": "...", "message": "...", "detail": "..."}],
  "photo_stamps": {"a.jpg": [mtime_ns, size]}      // what THIS post placed
}
"""

from __future__ import annotations

import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path

from .ai_tells import strip_em_dashes
from .blog_marker_splice import splice_retained_markers
from .blog_photo_stamps import Retention, photo_stamps, retention_for
from .blog_repair import repair_alt_text
from .blog_repair_damage import Touched, blog_repair_damage
from .repair_log import RepairLog
from .blog_quality import (_PHOTO_MARKER, _fold_filename, check_blog,
                           filenames_used_by, finding_entry,
                           refuse_colliding_filenames,
                           repair_marker_filenames,
                           repair_marker_placement)
from .claude_client import run_json_prompt, ClaudeError
from .ocr_program import HEIC_SUFFIXES, _convert_heic_to_jpeg
from .progress import ProgressWriter


PROMPT = """\
An existing blog post body is shown below. It contains [PHOTO: filename | alt text]
markers embedded among the paragraphs. The photos are being replaced with a new set.

YOUR ONLY JOB: replace the [PHOTO: ...] marker lines with new ones for the new photos.

Rules:
- Do NOT change any prose. Not one word, comma, or paragraph break.
- Look at each new photo. Write an alt text for each: 15 to 25 words covering who,
  what, where, lighting and gestures, useful for a reader who cannot see the image.
{naming_rules}- NAME PEOPLE BY NAME, never by appearance or gender. Not "A male
  performer", not "A woman in a striped top", not "A bearded performer".
- NO INFERRED INNER STATES. Describe what the camera recorded, not what somebody
  felt or who an expression was aimed at. Banned: "in intense concentration",
  "with focused expression", "grinning toward the audience".
- VARY THE OPENING. Do not start more than two markers the same way.
- Use this exact format, on its own line between paragraphs:
    [PHOTO: filename.jpg | alt text description]
  where "filename.jpg" is the base filename only, no directory path.
- If the new photo count matches the old marker count: replace each marker 1-for-1
  in the same positions.
- If the counts differ: redistribute the markers at paragraph breaks, spread evenly
  through the post — not clustered at start or end.

{keep_rules}New photos ({photo_count} total):
{photo_list}

Current body (preserve ALL prose verbatim — only the [PHOTO: ...] lines change):
{body}

Return JSON ONLY (no markdown fences, no commentary):
{{
  "body": "<updated body, newlines escaped as \\n>",
  "photo_count": {photo_count}
}}
"""


def _ask(*, say, body: str, naming_rules: str,
          retained: list[str], send: list[tuple[str, str]],
          whole_rewrite: bool) -> dict:
    """One call, carrying only the photographs that have to be described.

    `retained` names the markers the model must reproduce exactly. They are
    named rather than trusted: the splice puts them back afterwards either way,
    and telling the model reduces the chance it renumbers everything around
    them, which is what makes the splice reconcilable at all.
    """
    keep_rules = ""
    if retained:
        keep_rules = (
            "- These markers are FIXED POINTS. Reproduce each one EXACTLY as it "
            "appears in the body below, character for character, in the same "
            "position:\n"
            + "".join(f"    {name}\n" for name in retained)
            + f"- Only the {len(send)} marker(s) for the new photos below may "
              "change. The marker count and their positions stay as they are.\n")

    labels = [name for name, _staged in send]
    prompt = PROMPT.format(
        photo_count=len(send),
        photo_list="\n".join(f"- {n}" for n in labels),
        body=body,
        naming_rules=naming_rules,
        keep_rules=keep_rules,
    )
    say.step("Blog: rewriting the photo markers"
             if whole_rewrite else "Blog: describing the new photographs")
    data = run_json_prompt(
        prompt,
        timeout=300,
        image_paths=[staged for _name, staged in send],
        image_labels=labels,
        step="swap_blog_photos",
    )
    if not isinstance(data, dict):
        raise ClaudeError(f"Expected JSON object, got {type(data).__name__}")
    return data


def swap_blog_photos(*, body: str, photo_paths: list[str | Path],
                     program: dict | None = None, venue: str = "",
                     venue_context: str = "", org: str = "",
                     photo_stamps_in: dict[str, list[int]] | None = None,
                     progress: ProgressWriter | None = None) -> dict:
    """Replace [PHOTO: ...] markers in body with markers for new photos.

    All prose is preserved verbatim. Only the marker lines change.

    `program`, `venue`, `venue_context` and `org` carry the alt text naming
    rules into the prompt, let the deterministic checks run on the way out, and
    give the damage gate the names a rewrite is not allowed to lose (#201,
    #1129).

    **Only the photographs that CHANGED are re-described (#1131).** This path
    used to send every photo and rewrite every marker, and said so in this
    docstring: "the one most likely to break the alt text rules". Swapping one
    photo of seven regenerated six good alt texts and re-uploaded six
    photographs for nothing, each one a fresh chance to break a rule Dan had
    already fixed by hand.

    `photo_stamps_in` is what the incoming body's alt text was written against.
    A photograph the body already names, with a recorded stamp, whose file still
    matches it, keeps its marker verbatim and is never sent. Absent on every
    post written before #1130, which is a first run: nothing is retained and the
    swap costs what it always did.

    `progress` is where this run says what it is doing (#1128). This is an
    image-carrying call at a 300 second timeout and the app drew a bare
    "Updating photos..." spinner for the whole of it, which looks identical
    whether the call is running, hung or dead. The standing rule is that no
    such action ships without working / still alive / failed being told apart,
    and this milestone adds up to seven more calls to this path.
    """
    say = (progress or ProgressWriter(None))
    if not photo_paths:
        raise ValueError("No photo paths provided")
    if not body.strip():
        raise ValueError("No blog body provided")

    with tempfile.TemporaryDirectory(prefix="postroll-blog-swap-") as tmp:
        tmp_path = Path(tmp)
        resolved: list[str] = []
        for i, p in enumerate(photo_paths):
            path = Path(p).expanduser().resolve()
            if not path.exists():
                raise FileNotFoundError(f"Photo not found: {path}")
            if path.suffix.lower() in HEIC_SUFFIXES:
                staged = _convert_heic_to_jpeg(path, tmp_path, prefix=f"{i:03d}_")
            else:
                staged = tmp_path / f"{i:03d}_{path.name}"
                shutil.copy2(path, staged)
            resolved.append(str(staged))

        # Show clean filenames (without the 000_ staging prefix) in the
        # prompt so markers use the original name. The same clean names go
        # in as image_labels so each attached image is preceded by a
        # `Photo N: filename.jpg` block, anchoring the file to image
        # correspondence instead of leaving Claude to correlate by order.
        photo_filenames = [
            Path(p).name.split('_', 1)[1] if '_' in Path(p).name else Path(p).name
            for p in resolved
        ]
        # Refused here, before a single paid call, because a collision makes the
        # repairer attach the wrong photograph (#1130).
        refuse_colliding_filenames(photo_filenames, [str(p) for p in photo_paths])

        names = [str(p.get("name", "")).strip()
                 for p in (program or {}).get("performers") or []
                 if str(p.get("name", "")).strip()]
        naming_rules = ""
        if venue.strip():
            naming_rules += f"- NAME THE VENUE in every marker: {venue.strip()}.\n"
        if names:
            naming_rules += ("- NAME THE PERFORMER in every marker. The people on "
                             "this bill are: " + ", ".join(names) + ".\n")

        # --- which photographs actually changed (#1131) -------------------
        #
        # This path sent EVERY photo and told the model to rewrite EVERY
        # marker. Its own docstring admitted it. Swap one photo of seven and
        # six good alt texts were regenerated and six photographs re-uploaded
        # for nothing, each one a fresh chance to break a rule Dan had already
        # fixed by hand.
        #
        # Retained means: the incoming body already names this photograph, AND
        # a stamp was recorded for it, AND the file on disk still matches that
        # stamp. Three reasons for "not retained", never two, because a first
        # run and a broken path decoder must not read the same (L11, L289).
        in_the_body = {_fold_filename(name)
                       for name, _alt in _PHOTO_MARKER.findall(body)}
        retained: list[str] = []
        new_photos: list[tuple[str, str]] = []
        for name, staged, source in zip(photo_filenames, resolved, photo_paths):
            key = _fold_filename(name)
            state = (retention_for(name, str(source), photo_stamps_in)
                     if key in in_the_body else Retention.NEW_NO_STAMP)
            if key in in_the_body and state is Retention.RETAINED:
                retained.append(name)
                continue
            # NEW_UNREADABLE cannot occur here: the staging loop above refuses
            # a photograph that is not on disk before anything is sent, so an
            # unreadable file is a hard FileNotFoundError rather than a
            # retention state. The distinction is real where a path is READ
            # without being staged, which is the repair pass.
            new_photos.append((name, staged))

        print(f"[swap_blog_photos] {len(retained)} photograph(s) retained, "
              f"{len(new_photos)} to describe", flush=True, file=sys.stderr)

        # Nothing to ask. The app can and does re-run a swap, and one where
        # every photograph is retained has no question for a model.
        if not new_photos:
            data = {"body": body, "photo_count": len(resolved)}
        else:
            data = _ask(
                say=say, body=body, naming_rules=naming_rules,
                retained=retained, send=new_photos,
                whole_rewrite=not retained)

        # --- put the retained markers back, verbatim ----------------------
        produced = data.get("body", body)
        fell_back = False
        if retained:
            try:
                produced, drift = splice_retained_markers(
                    body, produced, set(retained))
            except ValueError as e:
                print(f"[swap_blog_photos] {e} Falling back to the whole "
                      f"rewrite.", flush=True, file=sys.stderr)
                fell_back = True
            else:
                if drift:
                    # The splice destroys the evidence it was needed: an
                    # obedient model and one that rewrote every retained marker
                    # produce a byte identical body afterwards (L340).
                    print(f"[swap_blog_photos] RESTORED {drift} retained "
                          f"marker(s) the model rewrote despite being told to "
                          f"reproduce them exactly",
                          flush=True, file=sys.stderr)

                reasons = blog_repair_damage(
                    body, produced, program=program, venue=venue,
                    venue_context=venue_context, org=org,
                    photo_filenames=photo_filenames,
                    touched=Touched(markers=frozenset(
                        _fold_filename(n) for n, _ in new_photos)
                        | (in_the_body - {_fold_filename(n) for n in retained})))
                if reasons:
                    for reason in reasons:
                        print(f"[swap_blog_photos] REFUSED: {reason}",
                              flush=True, file=sys.stderr)
                    fell_back = True

        if fell_back:
            # A cost regression, never a correctness one, and announced because
            # it is a failure of this app's own machinery rather than a finding
            # about the post. Keeping the good state until the replacement is
            # verified (L5).
            print(f"[swap_blog_photos] falling back to rewriting every marker, "
                  f"which costs {len(resolved)} photographs instead of "
                  f"{len(new_photos)}", flush=True, file=sys.stderr)
            data = _ask(say=say, body=body, naming_rules=naming_rules,
                        retained=[], send=list(zip(photo_filenames, resolved)),
                        whole_rewrite=True)

            # The fallback is today's behaviour and today's behaviour ships
            # whatever comes back, so the gate does not REFUSE here: refusing
            # would leave Dan with the photographs he asked to replace and no
            # way forward, which is worse than the thing being refused (L109).
            #
            # It still REPORTS. The whole-rewrite path has never had anything
            # checking that its own "Do NOT change any prose" instruction was
            # obeyed, and a rewrite that quietly rewrote the post is worth
            # saying out loud even when nothing can be done about it here.
            for reason in blog_repair_damage(
                    body, data.get("body", body), program=program, venue=venue,
                    venue_context=venue_context, org=org,
                    photo_filenames=photo_filenames,
                    touched=Touched(markers=frozenset(
                        _fold_filename(n) for n in photo_filenames) | in_the_body)):
                print(f"[swap_blog_photos] the whole rewrite also: {reason}",
                      flush=True, file=sys.stderr)
        else:
            data = dict(data, body=produced)

        # The finalisation tail runs INSIDE the staging block (#1128), for
        # the reason generate_blog.py states at the same point: the alt text
        # repair is a rewrite with the photograph attached, and the block's
        # exit used to delete every staged copy before the checks ran.

        say.step("Blog: running the checks")

        # Same deterministic dash strip its two sibling paths apply on the way out
        # (generate_blog.py, revise_blog.py). Without it a post whose photos were
        # swapped could ship an em dash into published copy (#203).
        final_body = strip_em_dashes(data.get("body", body).strip())

        # A near-miss filename is repaired rather than reported (#962). This path
        # rewrites EVERY marker in the post, so it is the one most able to break
        # the filename rule, and it was the one that could not see it: the real
        # names were resolved a few lines above and none of them reached the check.
        final_body, repairs = repair_marker_filenames(final_body, photo_filenames)
        for was, now in repairs:
            print(f"[swap_blog_photos] REPAIRED marker filename: {was!r} -> {now!r}",
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
        final_body, moved = repair_marker_placement(final_body)
        for name, why in moved:
            print(f"[swap_blog_photos] MOVED marker {name!r} ({why})",
                  flush=True, file=sys.stderr)

        # The swap stages every photograph, so rule 4 licenses the same repair
        # generation gets (#1133). Without this the swap emitted a bad alt text
        # and every finding read as NEVER ATTEMPTED, which renders exactly like
        # today's findings and is the one thing rule 2 forbids.
        repair = repair_alt_text(
            final_body, program=program, venue=venue,
            photo_paths=dict(zip(photo_filenames, resolved)),
            runner=run_json_prompt, say=say,
            log=RepairLog(event=venue or "", script="swap_blog_photos"))
        final_body = repair.body
        for attempt in repair.attempts:
            print(f"[swap_blog_photos] REPAIR {attempt['outcome']}: "
                  f"{attempt['marker']} ({', '.join(attempt['codes'])})",
                  flush=True, file=sys.stderr)

        # The same deterministic checks the generate and revise paths run (#201).
        # The rest are reported, never rewritten: alt text cannot be corrected
        # without seeing the photograph.
        findings = check_blog(final_body, program=program, venue=venue,
                              photo_filenames=photo_filenames)
        for f in findings:
            print(f"[swap_blog_photos] CHECK {f.code}: {f.message} ({f.detail})",
                  flush=True, file=sys.stderr)

        # Which photographs this post actually PLACED, and the stamp each
        # carried when its alt text was written (#1130). See generate_blog for
        # what the key is for; the swap is the path that READS it, so it has to
        # write a fresh one or the next swap has no record to compare against.
        placed = filenames_used_by(final_body, photo_filenames)
        stamps = photo_stamps(placed, [
            str(photo_paths[photo_filenames.index(name)]) for name in placed])

        say.finish()
        return {
            "body":        final_body,
            "photo_count": len(photo_paths),
            "findings": [finding_entry(f, repair=repair.repair_for(f))
                         for f in findings],
            # The exact text those findings were measured against, so an edited
            # draft stops showing findings about the body before the edit. The
            # caption paths have emitted their sibling `findings_caption` since
            # #201; this one was named in the comment there and never sent, so
            # the blog panel could not go stale on any post ever generated
            # (#974).
            "findings_body": final_body,
            "photo_stamps": stamps,
            "repair_pass": {
                "ran": repair.ran,
                "selected": len(repair.selected),
                "attempted": len(repair.attempts),
                "ended_early": bool(repair.remaining <= 0),
            },
        }


def main() -> int:
    parser = argparse.ArgumentParser(description="Replace blog photo markers")
    parser.add_argument("--manifest", required=True, help="JSON manifest with body + photo_paths")
    parser.add_argument("--output",   required=True, help="Where to write result JSON")
    parser.add_argument("--progress", help="Path to write step progress JSON")
    args = parser.parse_args()

    m = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    try:
        result = swap_blog_photos(
            body=m["body"],
            photo_paths=m["photo_paths"],
            program=m.get("program"),
            venue=m.get("venue", ""),
            venue_context=m.get("venue_context", "") or "",
            org=m.get("org", "") or "",
            # What the alt text in the incoming body was written against
            # (#1131). Absent on every post written before #1130, which is a
            # first run: nothing is retained and the swap costs what it always
            # did.
            photo_stamps_in=m.get("photo_stamps") or {},
            progress=ProgressWriter(args.progress),
        )
    except (ClaudeError, FileNotFoundError, ValueError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    Path(args.output).write_text(
        json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
