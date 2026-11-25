"""This repo's CLAUDE.md stays inside a token budget (#1528).

Claude Code loads CLAUDE.md, and every file it imports, into the first request
of every session, and each later request reads it again. Measured over 25
October to 25 November 2026, what an interactive session started with was
37.2% of the tokens its requests read, so a paragraph added here is paid for on
every request of every session in this repo, by the main session and by each
agent it dispatches.

The file was 2,192 characters on 2026-11-25. The budget below leaves room to
roughly double it. A rule that needs more room than that belongs in `docs/`
with a one or two line pointer here that states the rule.

Tokens are counted at 2.78 characters each, the figure measured on these rule
files, not the 3.7 often assumed for prose, which undercounts by about a
quarter.

WHAT THIS CANNOT SEE: the project memory index, which Claude Code also loads
at session start. It lives outside the repo, under the home directory, so no
test here can read it on CI.
"""

from __future__ import annotations

import re
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
RULE_FILE = REPO_ROOT / "CLAUDE.md"

# 2.78 characters a token, held as a whole number so the count is exact: as a
# float, 2,780 characters divided by 2.78 comes out a hair over 1,000 and
# rounds up to 1,001.
CHARS_PER_100_TOKENS = 278
BUDGET_TOKENS = 1_500

# An import is an at sign followed by a path, at the start of a line or after
# white space. Only a path that names a file counts, so an email address or a
# decorator quoted in prose is not mistaken for one.
IMPORT = re.compile(r"(?:^|\s)@(\S+)")
MAX_IMPORT_DEPTH = 5


def loaded_text(rule_file: Path, depth: int = 0, seen: set | None = None) -> str:
    """The text a session is sent for this rule file: its own, then the text
    of every file it imports, followed the same way."""
    seen = set() if seen is None else seen
    resolved = rule_file.resolve()
    if resolved in seen or depth > MAX_IMPORT_DEPTH:
        return ""
    seen.add(resolved)
    text = rule_file.read_text()
    parts = [text]
    for match in IMPORT.finditer(text):
        target = Path(match.group(1)).expanduser()
        if not target.is_absolute():
            target = rule_file.parent / target
        if target.is_file():
            parts.append(loaded_text(target, depth + 1, seen))
    return "".join(parts)


def tokens(text: str) -> int:
    """Rounded up, since part of a token is still a token sent."""
    return -(-len(text) * 100 // CHARS_PER_100_TOKENS)


def test_claude_md_stays_inside_its_token_budget():
    used = tokens(loaded_text(RULE_FILE))
    assert used <= BUDGET_TOKENS, (
        f"CLAUDE.md and its imports are {used:,} tokens, over the budget of "
        f"{BUDGET_TOKENS:,}. Every request of every session in this repo "
        "reads them again. Move the runbook, history or table that grew into "
        "docs/ and leave a one or two line pointer that states the rule "
        "(#1528)")


def test_an_imported_file_counts_toward_the_budget(tmp_path: Path):
    """An import is the way a rule file grows without its own size moving, so
    a count that stopped at the file itself would pass on exactly that."""
    (tmp_path / "more.md").write_text("m" * 400)
    rule_file = tmp_path / "CLAUDE.md"
    rule_file.write_text("r" * 100 + "\n@more.md\n")
    assert len(loaded_text(rule_file)) == len(rule_file.read_text()) + 400


def test_an_import_loop_is_counted_once(tmp_path: Path):
    first = tmp_path / "CLAUDE.md"
    second = tmp_path / "second.md"
    first.write_text("a" * 50 + "\n@second.md\n")
    second.write_text("b" * 70 + "\n@CLAUDE.md\n")
    assert len(loaded_text(first)) == (
        len(first.read_text()) + len(second.read_text()))


def test_a_token_is_counted_at_the_measured_rate():
    assert tokens("x" * 2_780) == 1_000
    assert tokens("x" * 2_781) == 1_001
