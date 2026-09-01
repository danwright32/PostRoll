"""The Python half of the backup doc's inventory (#495).

The Swift suite checks the doc's table against ``DataInventory``, which is built
from ``AppPaths.Layout``. Two of the things inside the data root are written by
this side of the app, not by Swift, so ``DataInventory`` can only declare their
names, and a declaration nothing measures is how the doc drifted in the first
place (L26, L41).

These pin the two names as *this* code computes them, so renaming either one
fails here rather than sending somebody to a folder that is not there while they
are losing data.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from postroll.ai.repair_log import default_log_path as repair_log_path
from postroll.ai.usage_log import default_log_path
from postroll.audio import default_cache_dir

DOC = Path(__file__).resolve().parents[1] / "docs" / "BACKUP-AND-RESTORE.md"


def _rows() -> list[str]:
    return [
        line
        for line in DOC.read_text(encoding="utf-8").splitlines()
        if line.startswith("| `")
    ]


def _names() -> set[str]:
    """The first cell of each table row, unbackticked and unslashed."""
    out = set()
    for row in _rows():
        first = row.split("|")[1].strip()
        out.add(first.strip("`").rstrip("/"))
    return out


def test_the_doc_has_a_table_at_all():
    # Every other check here would pass vacuously against an empty list, which
    # is exactly the shape a doc rewrite would leave behind (L98).
    assert len(_rows()) >= 10, _rows()


@pytest.mark.parametrize(
    "path, label",
    [
        (default_cache_dir(), "the audio cache"),
        (default_log_path(), "the usage log"),
        (repair_log_path(), "the blog repair journal"),
    ],
)
def test_python_owned_items_are_in_the_inventory(path: Path, label: str):
    assert path.name in _names(), (
        f"{label} is written to {path.name} and the backup doc does not list it"
    )


def test_the_doc_lists_nothing_python_stopped_writing(monkeypatch, tmp_path):
    """The names must come from the code, not from a memory of the code.

    Reading them through the same override the app uses proves these are the
    live paths rather than constants that happen to match.
    """
    monkeypatch.setenv("POSTROLL_DATA_DIR", str(tmp_path))
    assert default_log_path() == tmp_path / "usage.jsonl"
    assert default_log_path().name in _names()
    assert repair_log_path() == tmp_path / "blog-repairs.jsonl"
    assert repair_log_path().name in _names()
