"""#1128 (Phase 0a): the finding vocabulary lives in a leaf module.

`Finding` and `finding_entry` were defined in `blog_quality.py`, which is the
whole blog checker: 540 lines, every rule, and after this milestone a module
one import away from a model call. Three caption modules imported the pair out
of it purely for the vocabulary, so the caption paths dragged the entire blog
checker in behind two dataclass fields and a dict builder.

Not `findings.py`. `postroll/ai/analyze_posts.py` already defines a DIFFERENT
`finding_entry(raw: dict)` for `insight_finding`, with its own contract entry.
A generically named module holding a same-named function with different
behaviour is L263 exactly: the shared name is read as evidence of shared
behaviour and the two are never compared. The module is named for what it
holds.

The leaf property is the point and it is asserted rather than remembered: the
moment `blog_findings` imports anything from `postroll.ai`, importing the
vocabulary costs whatever that import costs, and the reason the caption modules
were repointed is gone.
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
AI_DIR = REPO_ROOT / "postroll" / "ai"
FINDINGS = AI_DIR / "blog_findings.py"

#: The modules repointed by Phase 0a. They want the vocabulary, never the checks.
CAPTION_MODULES = (
    AI_DIR / "caption_credits.py",
    AI_DIR / "revise_caption.py",
    AI_DIR / "generate_captions.py",
)


def _tree(path: Path) -> ast.Module:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def _imported_modules(path: Path) -> set[str]:
    """Every module this file imports, relative ones resolved to a bare name."""
    names: set[str] = set()
    for node in ast.walk(_tree(path)):
        if isinstance(node, ast.ImportFrom):
            if node.level:
                # A relative import inside postroll/ai resolves within it.
                names.add((node.module or "").split(".")[0] or "postroll.ai")
            elif node.module:
                names.add(node.module)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
    return names


def test_the_findings_module_exists_where_the_contract_points():
    assert FINDINGS.is_file(), (
        "postroll/ai/blog_findings.py is missing. The bridge payload contract's "
        "blog_finding entry points its python side at this file."
    )


def test_the_findings_module_imports_nothing_from_the_ai_package():
    """A leaf. This is the whole reason the caption modules were repointed."""
    reached = {
        name for name in _imported_modules(FINDINGS)
        if name.startswith("postroll") or name in {
            p.stem for p in AI_DIR.glob("*.py")
        }
    }
    assert not reached, (
        f"blog_findings imports {sorted(reached)} from inside the package. It is "
        "the shared vocabulary, so importing it must cost nothing; a caption "
        "module reaching it would pull that import in behind three fields."
    )


@pytest.mark.parametrize("path", CAPTION_MODULES, ids=lambda p: p.name)
def test_no_caption_module_imports_the_blog_checker(path: Path):
    assert "blog_quality" not in _imported_modules(path), (
        f"{path.name} imports blog_quality. It wants Finding/finding_entry, "
        "which now live in blog_findings; importing the checker for them pulls "
        "in every blog rule and, after this milestone, a module one import away "
        "from a model call."
    )


def test_the_vocabulary_is_defined_there_not_re_exported_from_elsewhere():
    """The contract resolves `finding_entry` to a FunctionDef in this file.

    `tests/bridge_payload_keys.py` raises LookupError when no FunctionDef of the
    named function is in the pointed-at module, and a re-export is an ImportFrom.
    So the definition has to be here, not the other way round.
    """
    tree = _tree(FINDINGS)
    functions = {n.name for n in tree.body if isinstance(n, ast.FunctionDef)}
    classes = {n.name for n in tree.body if isinstance(n, ast.ClassDef)}
    assert "finding_entry" in functions, (
        "finding_entry must be DEFINED in blog_findings.py; the payload contract "
        "resolves it here and a re-export is not a FunctionDef."
    )
    assert "Finding" in classes


def test_the_checker_still_re_exports_the_vocabulary():
    """So the eight test files importing check_blog and Finding are untouched."""
    from postroll.ai import blog_findings, blog_quality

    assert blog_quality.Finding is blog_findings.Finding
    assert blog_quality.finding_entry is blog_findings.finding_entry
