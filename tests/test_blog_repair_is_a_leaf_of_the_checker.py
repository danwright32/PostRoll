"""#1133/#1134: the checker never reaches the repairer.

Several test files import `check_blog` directly. A `check_blog(repair=True)`
flag, or any import from `blog_quality` into `blog_repair`'s direction, would
put a model call one import away from all of them, and a suite able to make one
is a suite that spends money (L2).

The dependency runs one way only: `blog_repair` imports `blog_quality`, never
the reverse.
"""

from __future__ import annotations

import ast
from pathlib import Path

AI_DIR = Path(__file__).resolve().parent.parent / "postroll" / "ai"


def _reachable(start: str) -> set[str]:
    """Every module inside postroll.ai reachable from `start`, transitively."""
    seen: set[str] = set()
    queue = [start]
    while queue:
        name = queue.pop()
        if name in seen:
            continue
        seen.add(name)
        path = AI_DIR / f"{name}.py"
        if not path.is_file():
            continue
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            if isinstance(node, ast.ImportFrom) and node.level and node.module:
                queue.append(node.module.split(".")[0])
    return seen


def test_the_checker_cannot_reach_the_repairer():
    assert "blog_repair" not in _reachable("blog_quality"), (
        "blog_quality reaches blog_repair, so importing check_blog imports a "
        "model runner, and every test file that does is one call away from "
        "spending money")


def test_the_checker_cannot_reach_a_model_runner_at_all():
    reached = _reachable("blog_quality")
    assert "claude_client" not in reached, sorted(reached)


def test_the_repairer_DOES_reach_the_checker():
    """The control. If the direction were simply broken, both tests above would
    pass while nothing worked (L159)."""
    assert "blog_quality" in _reachable("blog_repair")
    assert "claude_client" in _reachable("blog_repair")


def test_the_damage_gate_cannot_reach_a_model_runner():
    """A gate that could call a model is a gate nobody can trust to be cheap,
    deterministic, or available."""
    reached = _reachable("blog_repair_damage")
    assert "claude_client" not in reached, sorted(reached)
