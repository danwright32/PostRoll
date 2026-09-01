#!/usr/bin/env python3
"""What the damage gate's retention floor is calibrated against (#1129, #1137).

Check 5 of `blog_repair_damage` refuses a rewritten alt text that kept too
little of what the original said about the photograph. That threshold is
MEASURED, not chosen: one sitting inside the dense middle of the real
distribution turns the check into noise, because a small uniform shift carries
dozens of items across at once (L172).

The corpus is every known-good alt text correction this repo can reach:

  * 14 from `tests/fixtures/blog_corrections/{bludline,one_man_odyssey}.json`,
    paired draft to corrected by folded filename;
  * every differing pair in the stored events, generated_body against body.

Both are Dan's own work, so the floor has to pass all of them. Run it rather
than trusting the number written beside the constant, because the second half of
the corpus grows every time he finishes a post (L316, L61):

    venv/bin/python tools/measure_alt_text_retention.py

It also re-measures check 7, the capitalised-name refusal, THROUGH THE COMMITTED
PREDICATE rather than through a query written beside it, which is what #1137
was filed for: the plan quoted a rate its own specification does not produce.

Reading on 2026-08-31, over 55 corrections: retention share min 0.18, p05 0.29,
median 0.52, max 0.96; the fewest content words any of them keeps is 4; and 0 of
55 are refused by either check.

The share is reported because it is what the plan asked for, and it is NOT what
the floor rests on. Measured, a husk written to pass every other check scores
0.18, which is exactly Dan's tightest correction. The absolute count is what
separates them, and the constant's own comment records that.
"""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from postroll.ai.blog_quality import _fold_filename, _markers  # noqa: E402
from postroll.ai.blog_repair_damage import (  # noqa: E402
    _RETENTION_FLOOR, _RETENTION_LONG_ENOUGH, _RETENTION_MIN_KEPT,
    _RETENTION_MIN_WORDS, _identity_tokens, _introduced_names,
    _retained_share)
from postroll.data_root import data_root  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent


def corrections() -> list[dict]:
    """Every draft-to-corrected alt text pair, with the context it was made in."""
    out: list[dict] = []
    fixtures = REPO_ROOT / "tests" / "fixtures" / "blog_corrections"
    for name in ("bludline", "one_man_odyssey"):
        data = json.loads((fixtures / f"{name}.json").read_text(encoding="utf-8"))
        draft = {_fold_filename(k): v for k, v in _markers(data["draft"])}
        for marker, alt in _markers(data["corrected"]):
            key = _fold_filename(marker)
            if key in draft and draft[key].strip() != alt.strip():
                out.append({"source": name, "before": draft[key], "after": alt,
                            "prior_body": data["draft"],
                            "known": _identity_tokens(data["program"],
                                                      data["venue"], marker)})

    store = Path(data_root()) / "events.json"
    if not store.exists():
        print(f"no stored events at {store}: the fixture half of the corpus is "
              "all that was measured", file=sys.stderr)
        return out

    for event in json.loads(store.read_text(encoding="utf-8")):
        blog = (event.get("weekResult") or {}).get("blog") or {}
        generated, final = blog.get("generated_body"), blog.get("body")
        if not generated or not final:
            continue
        was = {_fold_filename(k): v for k, v in _markers(generated)}
        known = _identity_tokens(event.get("ocrResult"), event.get("venue"),
                                 event.get("venueContext"), event.get("org"),
                                 event.get("name"), event.get("blogPhotoPaths"))
        for marker, alt in _markers(final):
            key = _fold_filename(marker)
            if key in was and was[key].strip() != alt.strip():
                out.append({"source": event.get("name", "?"), "before": was[key],
                            "after": alt, "prior_body": generated,
                            "known": known | _identity_tokens(marker)})
    return out


def main() -> int:
    corpus = corrections()
    if not corpus:
        # An empty corpus is not a clean one (L98).
        print("no corrections found, so nothing was measured", file=sys.stderr)
        return 1

    shares, kepts, totals, refused = [], [], [], []
    for pair in corpus:
        share, kept, total = _retained_share(pair["before"], pair["after"],
                                             drop=pair["known"])
        if not total:
            continue
        shares.append(share)
        kepts.append(kept)
        totals.append(total)
        if total >= _RETENTION_MIN_WORDS and (
                share < _RETENTION_FLOOR
                or (total >= _RETENTION_LONG_ENOUGH
                    and kept < _RETENTION_MIN_KEPT)):
            refused.append((pair["source"], share, kept, total))
    shares.sort()

    print(f"{len(corpus)} known-good corrections "
          f"({sum(1 for c in corpus if c['source'] in ('bludline', 'one_man_odyssey'))} "
          "from the fixtures)")
    print(f"retention SHARE: min {shares[0]:.2f}, p05 "
          f"{shares[max(0, int(len(shares) * 0.05))]:.2f}, median "
          f"{statistics.median(shares):.2f}, max {shares[-1]:.2f}")
    # The dimension the floor actually uses. The share cannot separate a husk
    # from a real rewrite at any threshold; this is what does.
    print(f"content words KEPT: min {min(kepts)} (the floor refuses below "
          f"{_RETENTION_MIN_KEPT}), over originals of min {min(totals)} words")
    print(f"check 5 (a gutted rewrite) refuses {len(refused)} of {len(corpus)}")
    for source, share, kept, total in refused:
        print(f"  {source}: {share:.2f}, kept {kept} of {total}")

    names = [(pair["source"], hits) for pair in corpus
             if (hits := _introduced_names(
                 pair["before"], pair["after"],
                 known=pair["known"] | _identity_tokens(pair["prior_body"])))]
    print(f"check 7 (an unaccountable capitalised name) fires on "
          f"{len(names)} of {len(corpus)}")
    for source, hits in names:
        print(f"  {source}: {hits}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
