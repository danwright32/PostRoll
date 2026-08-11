"""#334: the wordmark is a required asset, not a setting.

Every reel and graphic used to be handed the mark as
`LOGO_BLACK if Path(LOGO_BLACK).exists() else None`, and every generator turned
a path it could not open into no mark at all. The legibility bands are built the
same way, appended only `if logo_path`, so when there was no mark there was no
band either and nothing looked for what was missing.

The result: Dan's signature disappears from every reel going to clients and
every check stays green. It is the invisible-mark class that has shipped twice
already (white on cream), approached from the other side. Instead of the mark
being there and unreadable, it is absent and unmentioned.

The wordmark ships in this repo, so its absence is a broken install rather than
a configuration choice, and the render is refused naming the file (L67: code
that has already detected a required value is missing must block the action, not
merely label it).
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest

from postroll.media import wordmark
from postroll.media.missing_media import MissingMediaError


REPO_ROOT = Path(__file__).resolve().parent.parent

#: Where the app decides which mark a render gets. Both, because the cover
#: generator carried its own copy of the same fallback.
APP_CALL_SITES = (
    REPO_ROOT / "postroll" / "ai" / "generate_media.py",
    REPO_ROOT / "postroll" / "ai" / "generate_cover.py",
)


# ── the premise ──────────────────────────────────────────────────────────────


def test_the_wordmark_ships_in_the_repo():
    # The whole decision rests on this. If the mark were something Dan supplied
    # per event, refusing the render would be wrong.
    for path in (wordmark.BLACK, wordmark.WHITE):
        assert Path(path).exists(), (
            f"{path} is not in the repo, so treating its absence as a broken "
            f"install is no longer the right call")


# ── the shared loader ────────────────────────────────────────────────────────


def test_the_loader_names_the_file_it_could_not_find(tmp_path):
    gone = tmp_path / "logo-black.png"

    with pytest.raises(MissingMediaError) as exc:
        wordmark.load(gone, width=340)

    assert str(gone) in str(exc.value)
    assert "wordmark" in str(exc.value)


def test_the_loader_still_allows_a_render_that_asks_for_no_mark():
    # Unset is not missing. A test frame drawn with no chrome mark at all is a
    # different thing from one whose mark could not be opened.
    assert wordmark.load(None, width=340) is None
    assert wordmark.load("", width=340) is None


def test_required_refuses_an_absent_file_and_an_absent_path(tmp_path):
    with pytest.raises(MissingMediaError):
        wordmark.required(tmp_path / "logo-black.png")
    with pytest.raises(MissingMediaError):
        wordmark.required(None)

    assert wordmark.required(wordmark.BLACK) == wordmark.BLACK


# ── every generator that draws a colophon ────────────────────────────────────


def test_the_before_after_graphic_refuses_a_missing_wordmark(
    sample_photo, tmp_output, tmp_path
):
    from postroll.media.generate_before_after import generate_before_after

    gone = tmp_path / "logo-black.png"
    out = tmp_output / "ba.png"

    with pytest.raises(MissingMediaError) as exc:
        generate_before_after(
            raw_path=sample_photo, edit_path=sample_photo, output_path=str(out),
            event_name="Test", org="Org", venue="Venue", logo_path=str(gone))

    assert str(gone) in str(exc.value)
    assert not out.exists(), "an unsigned graphic here would look exactly like success"


def test_the_tuesday_reel_refuses_a_missing_wordmark(sample_photo, tmp_output, tmp_path):
    from postroll.media.generate_reel_slider import generate_reel_slider

    gone = tmp_path / "logo-black.png"
    out = tmp_output / "reel.mp4"

    with pytest.raises(MissingMediaError) as exc:
        generate_reel_slider(
            raw_path=sample_photo, edit_path=sample_photo, bw_path=sample_photo,
            # A real path so the check under test is what fails, not the audio
            # step (which would reach Jamendo).
            audio_path=str(sample_photo),
            output_path=str(out),
            event_name="Test", org="Org", venue="Venue", logo_path=str(gone))

    assert str(gone) in str(exc.value)
    assert not out.exists(), "an unsigned reel here would look exactly like success"


def test_the_collage_refuses_a_missing_wordmark(sample_photo, tmp_output, tmp_path):
    from postroll.media.generate_collage import generate_collage

    gone = tmp_path / "logo-black.png"
    out = tmp_output / "collage.png"

    with pytest.raises(MissingMediaError) as exc:
        generate_collage(
            photo_paths=[str(sample_photo)] * 3, output_path=str(out),
            event_name="Test", org="Org", venue="Venue", logo_path=str(gone))

    assert str(gone) in str(exc.value)
    assert not out.exists()


# ── the app never hands a render an absent-tolerant mark ─────────────────────


def _logo_arguments(path: Path) -> list[ast.keyword]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    return [kw for node in ast.walk(tree) if isinstance(node, ast.Call)
            for kw in node.keywords if kw.arg == "logo_path"]


def test_the_scan_finds_the_call_sites_it_is_meant_to_check():
    # A scan matching nothing would make the test below pass on an empty list,
    # and a vacuous pass is indistinguishable from real coverage (L98).
    found = sum(len(_logo_arguments(path)) for path in APP_CALL_SITES)

    assert found >= 10, (
        f"only found {found} logo_path arguments across "
        f"{[p.name for p in APP_CALL_SITES]}, so this is not checking the app")


@pytest.mark.parametrize("path", APP_CALL_SITES, ids=lambda p: p.stem)
def test_no_app_call_site_turns_a_missing_wordmark_into_no_mark(path):
    # The defect in its original form was a conditional at the call site:
    #     logo_path=LOGO_BLACK if Path(LOGO_BLACK).exists() else None
    # which converts a broken install into a silently unsigned render. Every
    # such argument now has to go through the helper that refuses instead.
    unguarded = []
    for kw in _logo_arguments(path):
        value = kw.value
        guarded = (isinstance(value, ast.Call)
                   and isinstance(value.func, ast.Name)
                   and value.func.id == "required_wordmark")
        if not guarded:
            unguarded.append(f"line {kw.value.lineno}: {ast.unparse(value)}")

    assert not unguarded, (
        f"{path.name} hands these renders a wordmark that may not be there, "
        f"instead of refusing: {unguarded}. A conditional here turns a broken "
        f"install into a reel with no signature and nothing to notice.")


# ── a mark that is drawn is a mark that is checked ───────────────────────────


@pytest.mark.parametrize("builder", ["morph_regions", "slider_regions"])
def test_a_drawn_mark_always_has_a_band_looking_for_it(builder):
    # The other half of #334: the bands were appended only `if logo_path`, so a
    # reel with no mark had no band either and nothing measured the absence.
    from postroll.media import text_regions

    build = getattr(text_regions, builder)
    regions = (build(600, wordmark.BLACK) if builder == "morph_regions"
               else build(wordmark.BLACK))
    named = [r.name for r in regions]

    assert any("wordmark" in name for name in named), (
        f"{builder} draws a colophon and no band looks for it: {named}")


@pytest.mark.parametrize("builder", ["morph_regions", "slider_regions",
                                     "scroll_moving_regions"])
def test_a_band_builder_refuses_a_wordmark_that_is_not_there(builder, tmp_path):
    # A band list built for a mark that cannot be opened would come back with
    # no colophon in it, and a missing band is indistinguishable from a mark
    # drawn perfectly to everything downstream.
    from postroll.media import text_regions

    gone = tmp_path / "logo-black.png"
    build = getattr(text_regions, builder)

    with pytest.raises(MissingMediaError) as exc:
        if builder == "morph_regions":
            build(600, str(gone))
        else:
            build(str(gone))

    assert str(gone) in str(exc.value)
