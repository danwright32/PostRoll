"""#1470: no workflow runs on an image or an action that moves on its own.

`ubuntu-latest` moves to Ubuntu 26 beginning 2026-10-19 (actions/runner-images
#14748), and six workflows used it unpinned. An image change can move Python,
ffmpeg or another tool and turn the Linux jobs red, or change their behaviour
quietly, on a day nobody here chose. The macOS image and Xcode were already
pinned for the same reason (#792, #1226), so the Linux label is pinned too and
moved on a chosen day.

The second half is the actions still on Node 20, which GitHub has deprecated:
`actions/upload-artifact@v4` and `actions/cache@v4`, both of which have Node 24
majors (upload-artifact v6 and later, cache v5 and later).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = sorted((REPO_ROOT / ".github" / "workflows").glob("*.yml"))

#: The first major of each action that runs on Node 24, from each action's
#: release notes, read 2026-10-03.
NODE_24_FROM = {
    "actions/checkout": 5,
    "actions/setup-python": 6,
    "actions/upload-artifact": 6,
    "actions/download-artifact": 6,
    "actions/cache": 5,
}


def _lines(path: Path) -> list[str]:
    return [line.split("#", 1)[0] for line in path.read_text().splitlines()]


def test_there_are_workflows_to_check():
    assert len(WORKFLOWS) >= 6, [w.name for w in WORKFLOWS]


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_every_runner_label_is_pinned(path: Path):
    moving = [line.strip() for line in _lines(path)
              if re.search(r"runs-on:\s*\S*-latest\b", line)]
    assert not moving, (
        f"{path.name} runs on a label that moves on its own: {moving}. Pin a "
        "version (ubuntu-24.04, macos-26) and move it on a chosen day")


@pytest.mark.parametrize("path", WORKFLOWS, ids=lambda p: p.name)
def test_no_action_is_on_a_node_20_major(path: Path):
    old = []
    for line in _lines(path):
        match = re.search(r"uses:\s*([\w-]+/[\w-]+)@v(\d+)", line)
        if match and match.group(1) in NODE_24_FROM:
            if int(match.group(2)) < NODE_24_FROM[match.group(1)]:
                old.append(f"{match.group(1)}@v{match.group(2)}")
    assert not old, (
        f"{path.name} uses actions still on Node 20, which GitHub has "
        f"deprecated: {old}")


def test_the_scan_would_see_a_moving_label_and_an_old_action(tmp_path):
    """The checks above judge by pattern, so they are seen to fire once."""
    sample = tmp_path / "x.yml"
    sample.write_text("jobs:\n  a:\n    runs-on: ubuntu-latest\n"
                      "    steps:\n      - uses: actions/cache@v4\n")
    with pytest.raises(AssertionError, match="ubuntu-latest"):
        test_every_runner_label_is_pinned(sample)
    with pytest.raises(AssertionError, match="actions/cache@v4"):
        test_no_action_is_on_a_node_20_major(sample)
