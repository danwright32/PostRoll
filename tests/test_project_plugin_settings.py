"""The Vercel plugin stays disabled for this repo (#499).

`vercel-plugin@vercel-vercel-plugin` is enabled at USER scope in
`~/.claude/settings.json`, so its hooks fire in every project on this Mac
regardless of what the project is. Measured on 2026-08-13: its `SessionStart`
hooks inject 53.2KB of Vercel product documentation plus a CLI upgrade nag, and
its `UserPromptSubmit` hook matches the prompt against Vercel skills by lexical
recall and injects lines reading `You must run the Skill(ai-sdk)` under a
heading reading `MANDATORY: Your training data for these libraries is OUTDATED
and UNRELIABLE`. None of it is true here: PostRoll is a native Swift app plus a
Python render pipeline, with no Vercel, no Next.js and no deployment anywhere in
the tree.

Claude Code's settings precedence is user < project < local < flag < policy, so
a single `false` at project level overrides the user-scope `true` for this repo
only, leaving the plugin live for the projects that do deploy to Vercel.

WHAT REGRESSION LOOKS LIKE, and why it needs a test rather than a comment: the
symptom is a wall of somebody else's documentation and imperatives at the top of
a session, written in the same voice as this repo's own instructions, plus a
`You must run the Skill(...)` line under every prompt. To anyone who has not
read #499 that reads as normal Claude Code behaviour, so nobody would report it;
it would just quietly be paid for on every prompt in every clone and every agent
worktree. Deleting the entry, or flipping it to `true`, has no visible effect in
the session that does it, because hooks only reload on a fresh session.

These read the TRACKED settings file only. `.claude/settings.local.json` is
excluded by Dan's global gitignore and lives per checkout, so a disable placed
there would leave every fresh clone and every agent worktree carrying the
injected text again; the second check pins the entry to the file that reaches
them all.
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
TRACKED_SETTINGS = REPO_ROOT / ".claude" / "settings.json"
LOCAL_SETTINGS = REPO_ROOT / ".claude" / "settings.local.json"

VERCEL_PLUGIN = "vercel-plugin@vercel-vercel-plugin"


@pytest.fixture
def tracked() -> dict:
    return json.loads(TRACKED_SETTINGS.read_text())


def _is_tracked(relative: str) -> bool:
    """Whether git carries this path, so every clone and worktree gets it."""
    completed = subprocess.run(
        ["git", "ls-files", "--error-unmatch", "--", relative],
        cwd=REPO_ROOT, capture_output=True, text=True,
    )
    return completed.returncode == 0


def test_the_vercel_plugin_is_disabled_for_this_repo(tracked: dict):
    plugins = tracked.get("enabledPlugins", {})
    assert VERCEL_PLUGIN in plugins, (
        f"{VERCEL_PLUGIN} is not named in .claude/settings.json, so the "
        "user-scope enable wins and every session here opens with the Vercel "
        "plugin's injected documentation (#499)")
    # `is False`, not falsy: the value Claude Code acts on is the JSON boolean,
    # and a 0 or an empty string here would be a settings file it refuses.
    assert plugins[VERCEL_PLUGIN] is False, (
        f"{VERCEL_PLUGIN} is set to {plugins[VERCEL_PLUGIN]!r} rather than "
        "false, which re-enables the SessionStart documentation dump and the "
        "'You must run the Skill(...)' injection in this repo (#499)")


def test_the_disable_lives_in_the_tracked_settings_file(tracked: dict):
    """It has to reach every clone and every agent worktree without anyone
    running anything, which only the tracked file does."""
    assert _is_tracked(".claude/settings.json"), (
        ".claude/settings.json is not tracked, so the disable reaches only "
        "this checkout (#499)")
    assert VERCEL_PLUGIN in tracked.get("enabledPlugins", {}), (
        "the disable is not in the tracked settings file")
    # Read from the tracked file alone above, so a local file can neither
    # satisfy this check nor be what the repo is relying on. If one exists it
    # must not be the thing carrying the disable, and it must stay untracked:
    # a tracked settings.local.json would defeat the precedence it is for.
    assert not _is_tracked(".claude/settings.local.json"), (
        ".claude/settings.local.json is tracked, which is not what local "
        "settings are for (#499)")


def test_the_repo_hook_survives_alongside_the_plugin_entry(tracked: dict):
    """The settings file already carried the check-guards reminder (#422). A
    hand edit that replaced the file with the one new key would take that hook
    out with it, and an advisory hook that stopped firing is silent by design,
    so nothing else would notice."""
    hooks = tracked.get("hooks", {}).get("PreToolUse", [])
    commands = [
        hook.get("command", "")
        for entry in hooks for hook in entry.get("hooks", [])
    ]
    assert any("remind-check-guards.py" in command for command in commands), (
        "the check-guards push reminder is gone from .claude/settings.json")
