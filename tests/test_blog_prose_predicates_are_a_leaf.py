"""#1129: the prose predicates are reachable without importing a model runner.

`_prose_indices_with_second_person`, `_prose_indices_without_contractions` and
`_block_holds_marker` are pure text over a body. They lived in
`generate_blog.py`, which imports `run_json_prompt`, so any module wanting to
ask those questions had to import a model runner to do it.

The damage gate has to ask all three: it refuses a repair that reintroduces
second person or a contraction free paragraph (those fixes run once, at
generation, and never again, so anything a repair puts back ships), and it
refuses a repair touching a paragraph that holds an inline marker, for the
reason #998 recorded. The gate is pure text with no model call and no import
that can reach one, so it must not import `generate_blog`.

Reusing the predicates rather than copying them is the whole point (L263): two
same-named functions on either side of a boundary are never compared and can
implement different rules indefinitely, while every caller on each side reads
as correct in isolation.
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
AI_DIR = REPO_ROOT / "postroll" / "ai"
PROSE = AI_DIR / "blog_prose.py"


def _imported(path: Path) -> set[str]:
    names: set[str] = set()
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            names.add((node.module or "").split(".")[0] if not node.level
                      else (node.module or "").split(".")[0])
        elif isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
    return {n for n in names if n}


def test_the_prose_module_exists():
    assert PROSE.is_file()


def test_the_prose_module_cannot_reach_a_model_runner():
    local = {p.stem for p in AI_DIR.glob("*.py")}
    reached = {n for n in _imported(PROSE) if n in local or n.startswith("postroll")}
    assert not reached, (
        f"blog_prose imports {sorted(reached)}. It is pure text over a body and "
        "the damage gate reads it; anything it imports, the gate imports too.")


def test_generate_blog_uses_the_moved_predicates_rather_than_its_own():
    """One definition, not two that read the same and drift (L263)."""
    from postroll.ai import blog_prose, generate_blog

    assert generate_blog._prose_indices_with_second_person is \
        blog_prose.prose_indices_with_second_person
    assert generate_blog._prose_indices_without_contractions is \
        blog_prose.prose_indices_without_contractions
    assert generate_blog._block_holds_marker is blog_prose.block_holds_marker


@pytest.mark.parametrize("body,expected", [
    ("You should see it.\n\nA closing line.", [0]),
    # The closing call to action is allowed to address the reader.
    ("A first line.\n\nCome and see for yourself.", []),
    # Quoted speech is allowed to.
    ('He said "you had to be there".\n\nA closing line.', []),
])
def test_the_second_person_predicate_still_answers_the_same_way(body, expected):
    from postroll.ai.blog_prose import prose_indices_with_second_person

    assert prose_indices_with_second_person(body) == expected


@pytest.mark.parametrize("body,expected", [
    ("The room was full.", [0]),
    ("It's a full room.", []),
    # A marker block is not prose, so it is never an offender.
    ("[PHOTO: a.jpg | Alt]", []),
])
def test_the_contraction_predicate_still_answers_the_same_way(body, expected):
    from postroll.ai.blog_prose import prose_indices_without_contractions

    assert prose_indices_without_contractions(body) == expected


def test_the_marker_predicate_sees_an_inline_marker():
    from postroll.ai.blog_prose import block_holds_marker

    assert block_holds_marker("Some prose [PHOTO: a.jpg | Alt] and more")
    assert not block_holds_marker("Some prose with no marker at all")
