"""The caption review screen holds the screen, not a dozen cards with it (#741).

`CaptionReviewView.swift` was about 6,000 lines and carried a dozen private
view structs beside the screen itself: the Instagram mockup, the media strip,
the clip editor, the collage thumbnail, the reel strip, the cover slot, the
inline photo assignment and more.

It mattered for testing rather than for tidiness. A view that is private to
that file cannot be hosted by a rendering check, so #732 had to widen
`FridayClipEditor` to internal purely so a test could render it. The next card
that needs measuring hits the same wall, and "make it internal" is a visibility
change made for the wrong reason each time.

These hold the split in place. Written as a rule rather than left to habit,
because a file grows a card at a time and no single addition looks like the
moment it stopped being one screen (L30).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from tests.source_text import swift_code_only

REPO = Path(__file__).resolve().parent.parent
VIEWS = REPO / "PostRollApp" / "Sources" / "Views"
SCREEN = VIEWS / "CaptionReviewView.swift"
CARDS = VIEWS / "CaptionReview"

# A declaration at column zero: the whole file's contents, as opposed to a
# member of something.
TOP_LEVEL = re.compile(
    r"(?m)^(private )?(struct|enum|final class|class|func|extension)\s+([A-Za-z_][A-Za-z0-9_]*)")


def declarations(path: Path) -> list[tuple[str, str]]:
    """(visibility, name) for every top-level declaration in `path`."""
    text = swift_code_only(path.read_text(encoding="utf-8"))
    return [("private" if m.group(1) else "internal", m.group(3))
            for m in TOP_LEVEL.finditer(text)]


def card_files() -> list[Path]:
    files = sorted(CARDS.glob("*.swift"))
    assert files, (
        f"nothing under {CARDS.relative_to(REPO)}, so the caption review "
        "screen's cards are back in one file")
    return files


def test_the_screen_file_holds_only_the_screen():
    names = [name for _, name in declarations(SCREEN)]
    assert names == ["CaptionReviewView"], (
        f"{SCREEN.name} declares {names}. Everything except the screen itself "
        f"belongs in {CARDS.relative_to(REPO)}, one file per card: a card that "
        "lives here is private to a 6,000 line file, so a rendering check "
        "cannot host it and the only way to measure one is to widen its "
        "visibility for the wrong reason (#732, #741).")


@pytest.mark.parametrize("path", card_files(), ids=lambda p: p.name)
def test_no_card_is_private_to_its_own_file(path: Path):
    hidden = [name for visibility, name in declarations(path)
              if visibility == "private"]
    assert not hidden, (
        f"{path.name} declares {hidden} as private to the file. A card in its "
        "own file has nothing to hide from: private here buys no encapsulation "
        "and costs a rendering check the ability to host it, which is the wall "
        "this split exists to take down.")


def test_the_screen_is_no_longer_one_of_the_biggest_files():
    # A number rather than a feeling, and a ceiling rather than the current
    # value, so an ordinary edit does not fail it and a card moving back in
    # does. Measured after the split: 1,648 lines.
    lines = len(SCREEN.read_text(encoding="utf-8").splitlines())
    assert lines <= 2_500, (
        f"{SCREEN.name} is back to {lines} lines. It was 5,999 before the "
        "split and every entry in the guard registry that perturbs it "
        "recompiles the whole file (#742).")


# ---------------------------------------------------------------------------
# The controls
# ---------------------------------------------------------------------------


def test_the_scan_can_still_see_a_private_declaration(tmp_path: Path):
    """A scan that had stopped matching would report every file clean (L98)."""
    offender = tmp_path / "Offender.swift"
    offender.write_text("import SwiftUI\n\nprivate struct Card: View {}\n",
                        encoding="utf-8")
    assert declarations(offender) == [("private", "Card")]


def test_the_scan_reads_an_internal_declaration_as_internal(tmp_path: Path):
    # The other direction: a rule that called everything private would fail
    # every file it is meant to pass (L104).
    fine = tmp_path / "Fine.swift"
    fine.write_text("import SwiftUI\n\nstruct Card: View {}\n", encoding="utf-8")
    assert declarations(fine) == [("internal", "Card")]


def test_a_nested_declaration_is_not_a_top_level_one(tmp_path: Path):
    # A card may still keep its own private helper INSIDE it, which is what
    # `private` is for. Only column zero is the file's contents.
    nested = tmp_path / "Nested.swift"
    nested.write_text(
        "import SwiftUI\n\nstruct Card: View {\n    private struct Row {}\n}\n",
        encoding="utf-8")
    assert declarations(nested) == [("internal", "Card")]
