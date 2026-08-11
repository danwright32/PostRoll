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


def test_a_changed_layout_constant_moves_the_fingerprint(tmp_path, monkeypatch):
    # The guard seen failing (L1). The morph reel's own module is rewritten with
    # one number changed, and the fingerprint has to notice.
    source = MEDIA_DIR / "generate_reel_morph.py"
    original = source.read_text(encoding="utf-8")
    before = fp.fingerprint("reel_morph")

    numbers = re.findall(r"^[A-Z_]+ = (\d+)$", original, flags=re.MULTILINE)
    assert numbers, "no module level numeric constant to perturb"

    changed = re.sub(r"^([A-Z_]+) = (\d+)$",
                     lambda m: f"{m.group(1)} = {int(m.group(2)) + 1}",
                     original, count=1, flags=re.MULTILINE)
    try:
        source.write_text(changed, encoding="utf-8")
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
