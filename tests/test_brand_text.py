"""#165: the org/venue detail lines are decided once, for every template.

The rule is small: when the organisation is the same as the event name, the org
is already the big script title, so repeating it underneath is noise and it is
dropped. Three templates each carried their own copy of that rule and a fourth
group of four carried none at all, so the same show rendered three different
ways depending on which asset you looked at:

* `generate_collage.plate_detail_line` and `generate_before_after.
  header_detail_lines` dropped the org whenever it matched.
* `generate_reel_morph.draw_branded_chrome` dropped it only when a venue was
  also present, so an event with no venue printed its own title twice.
* the slider, scroll, screen and story templates rendered `[org, venue]`
  straight, so every one of them printed the title twice.

These tests pin the rule and then pin the consolidation: the last one derives
the list of templates that render org and venue FROM THE SOURCE rather than
from a list written here, because a hand-maintained list would exempt the next
template somebody adds, which is the one the guard exists for.
"""

from __future__ import annotations

import re
from pathlib import Path

from postroll.media.brand_text import detail_lines


REPO_ROOT = Path(__file__).resolve().parent.parent
MEDIA = REPO_ROOT / "postroll" / "media"


def test_drops_the_org_when_it_repeats_the_event_name():
    assert detail_lines("Home'r Bust!", "Home'r Bust!", "David Geffen Hall Lobby") \
        == ["David Geffen Hall Lobby"]


def test_drops_the_org_even_when_there_is_no_venue():
    # The morph reel's copy of the rule required a venue before it would drop a
    # duplicate org, so a venue-less event printed its own title twice.
    assert detail_lines("Home'r Bust!", "Home'r Bust!", "") == []


def test_keeps_both_when_the_org_is_a_different_name():
    assert detail_lines("Perpetual Light", "DCINY", "Carnegie Hall") \
        == ["DCINY", "Carnegie Hall"]


def test_ignores_case_and_surrounding_space_when_matching():
    assert detail_lines("Home'r Bust!", " home'r bust! ", "Weill") == ["Weill"]


def test_handles_each_piece_going_missing():
    assert detail_lines("A", "", "Carnegie") == ["Carnegie"]
    assert detail_lines("A", "DCINY", "") == ["DCINY"]
    assert detail_lines("A", "", "") == []
    assert detail_lines("", "", "") == []


def test_strips_surrounding_space_from_what_it_returns():
    assert detail_lines("A", "  DCINY  ", "  Carnegie  ") == ["DCINY", "Carnegie"]


def _templates_rendering_org_and_venue() -> list[Path]:
    """Every media module that renders an org and a venue, read from the source.

    Derived rather than listed, so a template added tomorrow is covered by the
    guard below on the day it lands instead of on the day somebody remembers to
    add it here.
    """
    found = []
    for path in sorted(MEDIA.glob("*.py")):
        if path.name in {"brand_text.py", "design_tokens.py", "__init__.py"}:
            continue
        source = path.read_text()
        if re.search(r"\borg\b", source) and re.search(r"\bvenue\b", source):
            found.append(path)
    assert len(found) >= 7, (
        f"only found {len(found)} templates rendering org and venue, which "
        "means the scan stopped matching and the guard below is vacuous"
    )
    return found


def test_every_template_routes_its_detail_lines_through_the_helper():
    missing = [
        p.name for p in _templates_rendering_org_and_venue()
        if "brand_text import detail_lines" not in p.read_text()
    ]
    assert not missing, (
        "these templates render an org and a venue without the shared rule, so "
        "an event whose org matches its name prints the title twice: "
        f"{missing}"
    )


def test_no_template_pairs_org_and_venue_by_hand():
    offenders = [
        p.name for p in _templates_rendering_org_and_venue()
        if re.search(r"\[\s*org\s*,\s*venue\s*\]", p.read_text())
    ]
    assert not offenders, (
        "these templates build their detail lines from a raw [org, venue] "
        f"pair, bypassing the collapse rule: {offenders}"
    )
