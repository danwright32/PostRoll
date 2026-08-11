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

import ast

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


def code_names(source: str) -> set[str]:
    """Every identifier a module's CODE uses.

    Parsed, so a docstring or a comment mentioning something is not the module
    doing it. The scan below used to grep the raw text for the words org and
    venue, which meant prose counted as code in both directions (#315): writing
    a sentence about the detail lines in an unrelated module made the guard
    demand that module import the helper, and the same match propped up the
    vacuity floor, so prose could hold the floor while a real template quietly
    stopped matching (L96).

    String constants are excluded by construction: only names, arguments,
    keyword argument names and attributes are collected.
    """
    names: set[str] = set()
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Name):
            names.add(node.id)
        elif isinstance(node, ast.arg):
            names.add(node.arg)
        elif isinstance(node, ast.keyword) and node.arg:
            names.add(node.arg)
        elif isinstance(node, ast.Attribute):
            names.add(node.attr)
    return names


def pairs_org_and_venue_by_hand(source: str) -> bool:
    """Whether the code builds a bare [org, venue] list, bypassing the rule.

    Read off the parsed list literal rather than matched as text, for the same
    reason: a docstring showing the shape it forbids is documentation, not a
    breach of it.
    """
    for node in ast.walk(ast.parse(source)):
        if not isinstance(node, ast.List) or len(node.elts) != 2:
            continue
        first, second = node.elts
        if (isinstance(first, ast.Name) and first.id == "org"
                and isinstance(second, ast.Name) and second.id == "venue"):
            return True
    return False


def _templates_rendering_org_and_venue() -> list[Path]:
    """Every media module whose CODE handles an org and a venue.

    Derived rather than listed, so a template added tomorrow is covered by the
    guard below on the day it lands instead of on the day somebody remembers to
    add it here.
    """
    found = []
    for path in sorted(MEDIA.glob("*.py")):
        if path.name in {"brand_text.py", "design_tokens.py", "__init__.py"}:
            continue
        if {"org", "venue"} <= code_names(path.read_text()):
            found.append(path)
    assert len(found) >= 7, (
        f"only found {len(found)} templates rendering org and venue, which "
        "means the scan stopped matching and the guard below is vacuous"
    )
    return found


#: Ways a module can satisfy the rule.
#:
#: Calling the helper, or handing its org and venue to the shared program plate,
#: which calls the helper itself. The second appeared with #164: the Tuesday
#: reel now passes both through to the plate and draws no detail line of its
#: own, so demanding a direct import would force a dead one back in.
ROUTES_TO_THE_RULE = ("brand_text import detail_lines", "program_plate import")


def test_every_template_routes_its_detail_lines_through_the_helper():
    missing = [
        p.name for p in _templates_rendering_org_and_venue()
        if not any(route in p.read_text() for route in ROUTES_TO_THE_RULE)
    ]
    assert not missing, (
        "these templates render an org and a venue without the shared rule, so "
        "an event whose org matches its name prints the title twice: "
        f"{missing}"
    )


def test_no_template_pairs_org_and_venue_by_hand():
    offenders = [
        p.name for p in _templates_rendering_org_and_venue()
        if pairs_org_and_venue_by_hand(p.read_text())
    ]
    assert not offenders, (
        "these templates build their detail lines from a raw [org, venue] "
        f"pair, bypassing the collapse rule: {offenders}"
    )


# ── the scan reads code, not prose (#315) ────────────────────────────────────


def test_a_module_that_only_talks_about_org_and_venue_is_not_counted():
    # The case that actually happened: a docstring in design_stamp.py mentioning
    # "the shared org and venue detail lines" made the guard demand that a
    # bookkeeping module, which renders nothing, import the text helper. It was
    # worked around by rewording, which leaves the next person to hit the same
    # wall with no idea why.
    source = '''
"""A note about the org and venue detail lines, which this module does not draw."""
# org and venue are decided elsewhere
def unrelated():
    return "org", "venue"
'''
    assert not {"org", "venue"} <= code_names(source)


def test_a_module_that_handles_them_in_code_is_counted():
    source = "def draw(org, venue):\n    return [org, venue]\n"

    assert {"org", "venue"} <= code_names(source)


def test_a_keyword_argument_counts_as_handling_them():
    # How several of these templates actually receive the values.
    source = "render(org=event.org, venue=event.venue)\n"

    assert {"org", "venue"} <= code_names(source)


def test_a_bare_pair_in_code_is_reported():
    assert pairs_org_and_venue_by_hand("lines = [org, venue]\n")


def test_a_bare_pair_shown_in_a_docstring_is_not_reported():
    # Documentation describing the shape it forbids is documentation.
    source = '"""The old templates rendered [org, venue] straight."""\n'

    assert not pairs_org_and_venue_by_hand(source)


def test_a_pair_routed_through_the_helper_is_not_reported():
    assert not pairs_org_and_venue_by_hand("lines = detail_lines(name, org, venue)\n")
