"""#294: a template cannot change without its design version being reconciled.

`MEDIA_DESIGN_VERSIONS` is bumped by hand, and nothing checked that a bump
happened when a template actually changed. A redesign shipping with the version
untouched records the new design under the old number, badges no day, and leaves
every cached asset rendering the old look, with the guard green the whole time.

`postroll/media/design_fingerprint.py` hashes what decides how each template
renders: the code of the modules that draw it, and the values of the design
tokens those modules read. The committed values below are the contract. When one
moves, the change either altered what gets rendered, in which case bump
`MEDIA_DESIGN_VERSIONS[template]` and update the fingerprint here, or it did not,
in which case update the fingerprint alone and say why in the commit.

Nothing can decide that question automatically. This forces it to be asked, at
the moment of the change, by the person who knows the answer.
"""

from __future__ import annotations

import ast
import json
import re
from pathlib import Path

import pytest

from postroll.media import design_fingerprint as fp
from postroll.media import design_tokens as tokens


REPO_ROOT = Path(__file__).resolve().parent.parent
RECORD = Path(__file__).resolve().parent / "fixtures" / "media_design_fingerprints.json"
MEDIA_DIR = REPO_ROOT / "postroll" / "media"


@pytest.fixture(scope="module")
def recorded() -> dict[str, dict]:
    return json.loads(RECORD.read_text(encoding="utf-8"))


# ── the registry covers both directions ──────────────────────────────────────


def test_every_versioned_template_names_the_module_that_draws_it():
    missing = sorted(set(tokens.MEDIA_DESIGN_VERSIONS) - set(fp.TEMPLATE_MODULES))

    assert not missing, (
        "these templates carry a design version but nothing says which module "
        f"renders them, so no change to them can be detected: {missing}")


def test_every_renderer_module_is_claimed_by_a_template():
    # The other direction, which is the one a hand kept registry gets wrong: a
    # new renderer nobody added is exempt from the very check meant to cover it
    # (L96), and the check reports green while blind.
    claimed = {dotted for mods in fp.TEMPLATE_MODULES.values() for dotted in mods}
    on_disk = {
        f"postroll.media.{p.stem}" for p in MEDIA_DIR.glob("*.py")
        if p.stem.startswith(("generate_", "render_"))
    }
    unclaimed = sorted(on_disk - claimed)

    assert not unclaimed, (
        "these modules render something and no template's design version covers "
        f"them: {unclaimed}. Add them to TEMPLATE_MODULES, against the template "
        "whose asset they draw.")


def test_the_module_scan_actually_finds_the_renderers():
    # Guards the derivation above. A glob that matched nothing would make the
    # test before this one pass with total confidence (L98).
    found = [p.stem for p in MEDIA_DIR.glob("*.py")
             if p.stem.startswith(("generate_", "render_"))]

    assert len(found) >= 8, found


def test_every_template_has_a_recorded_fingerprint(recorded):
    missing = sorted(set(fp.TEMPLATE_MODULES) - set(recorded))

    assert not missing, f"no recorded fingerprint for: {missing}"


# ── the contract ─────────────────────────────────────────────────────────────


@pytest.mark.parametrize("template", sorted(fp.TEMPLATE_MODULES))
def test_the_template_still_renders_the_design_its_version_claims(template, recorded):
    entry = recorded[template]
    current = fp.fingerprint(template)

    assert current == entry["fingerprint"], (
        f"the {template} template changed. Decide which it was:\n"
        f"  it renders differently now, so bump "
        f"MEDIA_DESIGN_VERSIONS['{template}'] in postroll/media/design_tokens.py "
        f"from {tokens.MEDIA_DESIGN_VERSIONS[template]} to "
        f"{tokens.MEDIA_DESIGN_VERSIONS[template] + 1}, mirror it in "
        f"PostRollApp/Sources/DesignTokens.swift, and record the new fingerprint;\n"
        f"  or it renders identically, so record the new fingerprint alone and "
        f"say why in the commit.\n"
        f"  New fingerprint: {current}\n"
        f"  Recorded in {RECORD.relative_to(REPO_ROOT)}")


@pytest.mark.parametrize("template", sorted(fp.TEMPLATE_MODULES))
def test_the_recorded_version_is_the_version_that_ships(template, recorded):
    # The half that makes a bump land here too. Without it the fingerprint could
    # be updated on its own forever and the record would stop describing which
    # design it was taken at.
    assert recorded[template]["version"] == tokens.MEDIA_DESIGN_VERSIONS[template], (
        f"{template} ships version {tokens.MEDIA_DESIGN_VERSIONS[template]} and "
        f"the record says {recorded[template]['version']}. Update "
        f"{RECORD.relative_to(REPO_ROOT)} in the same change as the bump.")


# ── the fingerprint measures what it claims to measure ───────────────────────


def _module_level_ints(path: Path) -> dict[str, int]:
    """Every plain integer constant a module declares at the top level."""
    found: dict[str, int] = {}
    for node in ast.parse(path.read_text(encoding="utf-8")).body:
        if not (isinstance(node, ast.Assign) and len(node.targets) == 1):
            continue
        target, value = node.targets[0], node.value
        if (isinstance(target, ast.Name) and isinstance(value, ast.Constant)
                and isinstance(value.value, int) and not isinstance(value.value, bool)):
            found[target.id] = value.value
    return found


def _perturb(source: Path, name: str) -> str:
    """`source` rewritten with `name`'s value incremented by one.

    Raises rather than returning the file unchanged when the constant is not
    there. A substitution that matches nothing returns the original text and
    reports success, so the caller would fingerprint an untouched file and read
    the resulting non-change as a finding (L100).
    """
    changed, count = re.subn(
        rf"^{name} = (\d+)", lambda m: f"{name} = {int(m.group(1)) + 1}",
        source.read_text(encoding="utf-8"), count=1, flags=re.MULTILINE)
    if count != 1:
        raise AssertionError(
            f"{name} is not a module level integer in {source.name} any more, "
            f"so nothing was perturbed and the guard would have measured "
            f"an unchanged file")
    return changed


#: The constant the layout guard perturbs, named rather than taken as whichever
#: happens to come first in the file (#333). This guard used to rewrite the
#: FIRST module level number in `generate_reel_morph.py`. #164 moved the plate's
#: geometry out into `program_plate.py`, which left the frame rate as the first
#: such number, and the guard kept passing while no layout constant anywhere was
#: being exercised. A guard that passes for a reason unrelated to its purpose is
#: worse than an absent one, because its name is taken as coverage.
PLATE_GEOMETRY_CONSTANT = "PRINT_Y"


def test_the_guard_perturbs_a_constant_the_plate_really_lays_out_with():
    # Stops the subject drifting again. The plate module holds nothing but the
    # composition's geometry, so being a module level integer HERE is what makes
    # a constant a layout constant, and the frame rate could never qualify.
    plate = MEDIA_DIR / "program_plate.py"
    geometry = _module_level_ints(plate)

    assert PLATE_GEOMETRY_CONSTANT in geometry, (
        f"{PLATE_GEOMETRY_CONSTANT} is no longer a module level integer in "
        f"{plate.name}. The layout guard below perturbs it by name; point it at "
        f"one of {sorted(geometry)} rather than letting it choose whichever "
        f"number comes first, which is how it ended up on the frame rate (#333).")


def test_a_changed_plate_geometry_constant_moves_both_reels():
    # The guard seen failing (L1). The plate both Tuesday reels are composed on
    # is rewritten with one geometry constant changed, and both fingerprints
    # have to notice. Both, because #164's whole point is that the two reels
    # share one composition: a change to it that moved only one of them would
    # mean the other had drifted back to its own copy.
    source = MEDIA_DIR / "program_plate.py"
    original = source.read_text(encoding="utf-8")
    before = {name: fp.fingerprint(name) for name in ("reel_morph", "reel_slider")}

    try:
        source.write_text(_perturb(source, PLATE_GEOMETRY_CONSTANT), encoding="utf-8")
        after = {name: fp.fingerprint(name) for name in before}
    finally:
        source.write_text(original, encoding="utf-8")

    unmoved = sorted(name for name in before if before[name] == after[name])
    assert not unmoved, (
        f"moving the plate's {PLATE_GEOMETRY_CONSTANT} changed how these render "
        f"and their fingerprints did not move: {unmoved}. Either the template no "
        f"longer draws on the shared plate, or its fingerprint closure has "
        f"stopped reaching program_plate.py.")

    assert {name: fp.fingerprint(name) for name in before} == before, (
        "the perturbation was not undone")


def test_a_changed_timing_constant_moves_the_reels_fingerprint():
    # The reel's own module still decides something that renders, so it keeps a
    # guard of its own. Named FPS rather than "the first number in the file", so
    # that moving code out of this module produces a failure here instead of a
    # silent change of subject.
    source = MEDIA_DIR / "generate_reel_morph.py"
    original = source.read_text(encoding="utf-8")
    before = fp.fingerprint("reel_morph")

    try:
        source.write_text(_perturb(source, "FPS"), encoding="utf-8")
        assert fp.fingerprint("reel_morph") != before
    finally:
        source.write_text(original, encoding="utf-8")

    assert fp.fingerprint("reel_morph") == before, "the perturbation was not undone"


def test_a_changed_token_moves_only_the_templates_that_read_it(monkeypatch):
    # MAT_PRINT is the single-print mat: the before/after and the morph reel use
    # it, the gallery templates do not. A check that fired on every template for
    # every token change would be one nobody reads (L36).
    readers = {name for name in fp.TEMPLATE_MODULES
               if "MAT_PRINT" in fp.referenced_tokens(fp.TEMPLATE_MODULES[name][0])}
    assert readers, "nothing reads MAT_PRINT, so this asserts nothing"

    before = fp.fingerprints()
    monkeypatch.setattr(tokens, "MAT_PRINT", tokens.MAT_PRINT + 1)
    after = fp.fingerprints()

    moved = {name for name in before if before[name] != after[name]}
    assert moved == readers, f"moved {sorted(moved)}, expected {sorted(readers)}"


def test_a_comment_or_a_docstring_is_not_a_redesign():
    # A fingerprint that moved on prose would be overridden within a week.
    source = MEDIA_DIR / "generate_reel_morph.py"
    original = source.read_text(encoding="utf-8")
    before = fp.fingerprint("reel_morph")

    try:
        source.write_text(original + "\n\n# A note about the design.\n",
                          encoding="utf-8")
        assert fp.fingerprint("reel_morph") == before
    finally:
        source.write_text(original, encoding="utf-8")


def test_a_change_to_an_imported_helper_moves_the_fingerprint():
    # The closure is transitive on purpose: the text a reel draws is measured
    # and placed by brand_text, so a change there changes what renders while the
    # reel's own module is untouched.
    helper = MEDIA_DIR / "brand_text.py"
    original = helper.read_text(encoding="utf-8")
    before = fp.fingerprint("reel_morph")

    try:
        helper.write_text(original + "\n_UNUSED_MARKER = 1\n", encoding="utf-8")
        assert fp.fingerprint("reel_morph") != before
    finally:
        helper.write_text(original, encoding="utf-8")


def test_the_version_numbers_themselves_are_not_part_of_the_fingerprint(monkeypatch):
    # Otherwise bumping a version would change the fingerprint that asked for the
    # bump, and the check could never settle.
    before = fp.fingerprints()
    monkeypatch.setattr(tokens, "MEDIA_DESIGN_VERSIONS",
                        {k: v + 1 for k, v in tokens.MEDIA_DESIGN_VERSIONS.items()})

    assert fp.fingerprints() == before
