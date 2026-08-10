"""#99: the PRD's status must not describe a system that does not exist.

The audit that raised #99 found the PRD listing direct-API or Metricool
publishing, a built-in scheduling calendar, and a collaborator suggestion engine
as core goals, while a grep for any of it across the codebase returned only
brand-voice prose. The whole remaining roadmap lived in a static document and
had no representation in the backlog.

What actually happens is that PostRoll exports a folder and Dan uploads it to
Metricool by hand. These tests hold the document to that, in both directions:
the PRD may not imply publishing is built while no publishing exists, and if
publishing is ever built the PRD stops being allowed to say it is not.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
PRD = REPO_ROOT / "postroll-prd.md"

#: The names a real publishing implementation would have. Matched against code
#: only, never prose: the brand voice and caption docs mention these platforms
#: constantly and always will.
PUBLISHING_SYMBOLS = re.compile(
    r"\b(schedule_post|publish_post|graph_api|instagram_api|metricool_client|"
    r"collaborator_invite|bluesky_client|tiktok_upload)\b", re.IGNORECASE)


def _code_files() -> list[Path]:
    found = [
        p for p in (REPO_ROOT / "postroll").rglob("*.py")
        if "__pycache__" not in p.parts
    ]
    found += list((REPO_ROOT / "PostRollApp" / "Sources").rglob("*.swift"))
    assert len(found) > 20, "found almost no source; this scan would pass vacuously"
    return found


@pytest.fixture
def prd() -> str:
    return PRD.read_text()


def publishing_is_built() -> list[str]:
    return [
        f"{p.relative_to(REPO_ROOT)}: {m.group(0)}"
        for p in _code_files()
        for m in [PUBLISHING_SYMBOLS.search(p.read_text())] if m
    ]


def test_the_status_says_what_actually_happens_today(prd):
    # Whoever reads this document first should learn how posting works before
    # they read four sections of an automation design that was not taken.
    header = prd.split("## 1. Overview")[0].lower()
    assert "metricool" in header and "hand" in header, (
        "the PRD status does not say that assets are exported and uploaded by "
        "hand, which is the only way anything reaches a platform today")


def test_the_publishing_design_is_marked_as_not_taken(prd):
    section = prd.split("### 7.1")[1].split("### 7.2")[0].lower()
    assert "superseded" in section, (
        "section 7.1 still reads as a live binary decision. It was decided the "
        "other way, and a reader cannot tell a plan from a record without that")


def test_the_open_questions_say_nobody_is_researching_them(prd):
    section = prd.split("## 9. Open Questions")[1][:800].lower()
    assert "not currently" in section, (
        "section 9 reads as live research. Twenty-nine open questions with no "
        "owner is what made the roadmap invisible in the first place")


def test_the_prd_and_the_code_cannot_disagree_about_publishing():
    # The check that survives this change. If publishing is ever built, the
    # assertions above become lies and this is what says so, rather than the
    # document quietly describing a system that has since appeared.
    built = publishing_is_built()
    prd_text = PRD.read_text().lower()
    claims_not_started = "not started" in prd_text.split("## 1. Overview")[0]

    if built:
        assert not claims_not_started, (
            f"publishing code now exists ({built[:3]}), so the PRD status "
            f"saying it is not started is out of date. Update it in the same "
            f"change that built it.")
    else:
        assert claims_not_started, (
            "no publishing implementation exists, so the PRD must say so")
