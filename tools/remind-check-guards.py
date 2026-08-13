#!/usr/bin/env python3
"""Remind about `make check-guards` when a push changes a guard test (#422).

A guard is only real once it has been seen to fail, and the moment to see it
is the push that adds or changes one. This is a Claude Code PreToolUse(Bash)
hook, wired in this repo's own .claude/settings.json so it fires only here.
It watches a `git push` for two shapes of change arriving WITHOUT a matching
change to tests/fixtures/guard_mutations.json:

* a change to a test file the registry names (a Swift file holding a
  registered class, or a pytest guard file, #425), and
* a test file in either language that reads app source, workflow, or module
  text, which is a source-scanning guard whether or not anyone registered
  it yet.

ADVISORY, never blocking: the mutation check rewrites working tree files and
pays a Swift build per entry, so it cannot run inside the push itself. The
hook emits one line of additionalContext and always exits 0.

Fails QUIET, matching the other advisories: a broken reminder must add
nothing rather than nag, so silence never means "checked and clean", only
"nothing to say". Deliberately self-contained: the push detection twins
~/.claude/hooks/lib/push-scope.sh, because a file committed to this repo
cannot depend on one machine's private config, and the twin is pinned by
tests/test_check_guards_reminder.py.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

REGISTRY = Path("tests/fixtures/guard_mutations.json")
TESTS_DIR = Path("PostRollApp/Tests")
PY_TESTS_DIR = Path("tests")
# What a source-scanning Swift test looks like: it builds a path into the app
# sources to read them as text. Both existing guard files do exactly this.
SOURCE_SCAN = re.compile(r'appendingPathComponent\(\s*"Sources')
# And the Python equivalent (#425): a test that reads the workflows, the app
# sources, or live module source as text. Deliberately a little broad, since
# over-matching costs one advisory line while under-matching is silence.
PY_SOURCE_SCAN = re.compile(
    r'\.github/workflows|PostRollApp/Sources|"PostRollApp"|inspect\.getsource')


def is_git_push(command: str) -> bool:
    """A push judged by the leading tokens of each shell segment, never by
    substring, so a command merely mentioning a push cannot fire this."""
    for segment in re.split(r"&&|\|\||;|\|", command):
        tokens = segment.split()
        i = 0
        while i < len(tokens) and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[i]):
            i += 1
        if i < len(tokens) and tokens[i].rsplit("/", 1)[-1] == "rtk":
            i += 1
        if i >= len(tokens) or tokens[i].rsplit("/", 1)[-1] != "git":
            continue
        i += 1
        while i < len(tokens):
            tok = tokens[i]
            if tok in ("-C", "-c", "--git-dir", "--work-tree", "--namespace",
                       "--exec-path"):
                i += 2
            elif tok.startswith("-") or re.match(r"^[A-Za-z_]\w*=", tok):
                i += 1
            elif tok == "push":
                return True
            else:
                break
    return False


def chains_a_commit(command: str) -> bool:
    return bool(re.search(r"(^|[\s;&|])(\S*/)?(rtk\s+)?git(\s+\S+)*\s+commit(\s|$)",
                          command))


def git_lines(repo: Path, *args: str) -> list[str]:
    completed = subprocess.run(["git", *args], cwd=repo, capture_output=True,
                               text=True, timeout=20)
    if completed.returncode != 0:
        return []
    return [line for line in completed.stdout.splitlines() if line.strip()]


def changed_files(repo: Path, include_pending: bool) -> list[str]:
    base = None
    for candidate in ("@{upstream}", "origin/main", "origin/master"):
        merge_base = git_lines(repo, "merge-base", candidate, "HEAD")
        if merge_base:
            base = merge_base[0]
            break
    changed = git_lines(repo, "diff", "--name-only", f"{base}..HEAD") if base else []
    if include_pending:
        # status --porcelain lines carry a two-column state prefix and a space.
        changed += [line[3:] for line in git_lines(repo, "status", "--porcelain")]
    return sorted(set(changed))


def registered_guards(repo: Path) -> tuple[list[str], set[str]]:
    """The registry's Swift class names and its pytest guard files."""
    try:
        data = json.loads((repo / REGISTRY).read_text())
    except (OSError, ValueError):
        return [], set()
    classes: list[str] = []
    pytest_files: set[str] = set()
    for entry in data.get("entries", []):
        test = entry.get("test", "")
        parts = test.split("/")
        if test.startswith("PostRollTests/") and len(parts) == 3:
            classes.append(parts[1])
        elif test.startswith("tests/") and "::" in test:
            pytest_files.add(test.split("::")[0])
    return classes, pytest_files


def watched_changes(repo: Path, changed: list[str]) -> list[str]:
    classes, pytest_files = registered_guards(repo)
    watched = []
    for path in changed:
        swift = path.startswith(str(TESTS_DIR)) and path.endswith(".swift")
        python = (path.startswith(str(PY_TESTS_DIR))
                  and Path(path).name.startswith("test_")
                  and path.endswith(".py"))
        if not (swift or python):
            continue
        if path in pytest_files:
            watched.append(path)
            continue
        full = repo / path
        try:
            text = full.read_text()
        except OSError:
            continue  # deleted in this push; nothing to remind about
        if (SOURCE_SCAN if swift else PY_SOURCE_SCAN).search(text):
            watched.append(path)
            continue
        if swift and any(re.search(rf"\bclass {re.escape(name)}\b", text)
                         for name in classes):
            watched.append(path)
    return watched


def reminder(payload_text: str) -> str | None:
    try:
        payload = json.loads(payload_text)
        command = payload["tool_input"]["command"]
        cwd = Path(payload.get("cwd", "."))
    except (ValueError, KeyError, TypeError):
        return None
    if not is_git_push(command):
        return None
    if not (cwd / REGISTRY).is_file():
        return None

    changed = changed_files(cwd, include_pending=chains_a_commit(command))
    if str(REGISTRY) in changed:
        return None
    watched = watched_changes(cwd, changed)
    if not watched:
        return None
    names = ", ".join(Path(p).name for p in watched)
    return (f"This push changes guard tests ({names}) without touching "
            f"tests/fixtures/guard_mutations.json. If a guard was added or "
            f"changed, record or refresh its mutation entry and run "
            f"`venv/bin/python tools/check_guards.py --changed` (scoped to "
            f"this diff; `make check-guards` is the full sweep) so the guard "
            f"is seen to fail (#416, #422, #426).")


def main() -> int:
    try:
        note = reminder(sys.stdin.read())
    except Exception:  # noqa: BLE001  advisory: a broken reminder adds nothing
        return 0
    if note:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": note,
        }}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
