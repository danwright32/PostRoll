"""Four user-scope plugins stay disabled for this repo (#499).

TWO DIFFERENT REASONS, kept apart on purpose. Vercel was measured doing
something; the other three were not, and a docstring implying otherwise would
be a fabricated finding that no one could tell from a real one.

REASON ONE, measured cost. `vercel-plugin@vercel-vercel-plugin` is enabled at
USER scope in
`~/.claude/settings.json`, so its hooks fire in every project on this Mac
regardless of what the project is. Measured on 2026-08-13: its `SessionStart`
hooks inject 53.2KB of Vercel product documentation plus a CLI upgrade nag, and
its `UserPromptSubmit` hook matches the prompt against Vercel skills by lexical
recall and injects lines reading `You must run the Skill(ai-sdk)` under a
heading reading `MANDATORY: Your training data for these libraries is OUTDATED
and UNRELIABLE`. None of it is true here: PostRoll is a native Swift app plus a
Python render pipeline, with no Vercel, no Next.js and no deployment anywhere in
the tree.

REASON TWO, off topic surface area, and it is NOT the Vercel finding.
`cloudflare@cloudflare`, `figma@claude-plugins-official` and
`stripe@claude-plugins-official` are also enabled at user scope, but none of
them was measured injecting anything, because none of them can: read on
2026-08-13 from their installed copies under `~/.claude/plugins/cache/`, all
three declare NO `hooks` key in their `plugin.json` and ship no `hooks/`
directory, so nothing of theirs runs at session start or on a prompt. They are
disabled here purely because they are irrelevant to a native Swift app with a
Python render pipeline (no Cloudflare, no Figma, no Stripe, no payments and no
web frontend anywhere in the tree) and because what they DO cost is listing
size: 13 skill and command entries from Cloudflare, 14 from Figma, and 10 from
Stripe including one agent, plus seven MCP servers between them, all offered as
choices in every session here. That is a smaller and duller cost than Vercel's,
and it is stated as the smaller one deliberately.

Claude Code's settings precedence is user < project < local < flag < policy, so
a single `false` at project level overrides the user-scope `true` for this repo
only, leaving each plugin live for the projects that do use it.

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

# The exact `name@marketplace` ids, read on 2026-08-13 from the enabledPlugins
# keys of ~/.claude/settings.json and confirmed against `claude plugin list
# --json`. Never spelled from the plugin's display name: an id Claude Code does
# not recognise is accepted in silence and disables nothing, which is the one
# failure this file cannot see, because the entry would still read as correct.
OFF_TOPIC_PLUGINS = (
    "cloudflare@cloudflare",
    "figma@claude-plugins-official",
    "stripe@claude-plugins-official",
)

# Both are load bearing here and must NEVER join the list above. swift-lsp is
# how this repo's Swift half gets a language server, and superpowers carries the
# TDD and verification skills Dan's global rules require every session to use.
LOAD_BEARING_PLUGINS = (
    "superpowers@superpowers-dev",
    "swift-lsp@claude-plugins-official",
)


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


@pytest.mark.parametrize("plugin", OFF_TOPIC_PLUGINS,
                         ids=lambda plugin: plugin.split("@")[0])
def test_the_off_topic_plugins_are_disabled_for_this_repo(
        tracked: dict, plugin: str):
    """These three run no hooks, so unlike Vercel there is nothing to measure.
    They are off because they are irrelevant to a Swift and Python app and
    because their skills, agent and MCP servers pad every session's listing.

    Parametrised one per plugin rather than looped inside one test, so a single
    missing entry names itself in the failure instead of the first assertion
    hiding the state of the other two."""
    plugins = tracked.get("enabledPlugins", {})
    assert plugin in plugins, (
        f"{plugin} is not named in .claude/settings.json, so the user-scope "
        "enable wins and its skills, commands and MCP servers are offered in "
        "every session in this repo (#499)")
    # `is False`, not falsy, for the same reason as the Vercel entry: the value
    # Claude Code acts on is the JSON boolean.
    assert plugins[plugin] is False, (
        f"{plugin} is set to {plugins[plugin]!r} rather than false, which "
        "leaves it enabled here (#499)")


@pytest.mark.parametrize("plugin", LOAD_BEARING_PLUGINS,
                         ids=lambda plugin: plugin.split("@")[0])
def test_the_load_bearing_plugins_are_not_disabled_here(
        tracked: dict, plugin: str):
    """The failure mode of a disable sweep is one plugin too many, and this
    file is the obvious place to add the next one. A wrongly disabled
    superpowers or swift-lsp is silent in exactly the way the others are:
    nothing errors, the skills and the language server simply stop being
    offered, and the session reads as normal Claude Code."""
    plugins = tracked.get("enabledPlugins", {})
    assert plugins.get(plugin, True) is not False, (
        f"{plugin} is disabled in .claude/settings.json. It is load bearing "
        "for this repo: swift-lsp is the Swift language server and superpowers "
        "carries the TDD and verification skills every session is required to "
        "use (#499)")


def test_the_disables_live_in_the_tracked_settings_file(tracked: dict):
    """They have to reach every clone and every agent worktree without anyone
    running anything, which only the tracked file does."""
    assert _is_tracked(".claude/settings.json"), (
        ".claude/settings.json is not tracked, so the disables reach only "
        "this checkout (#499)")
    for plugin in (VERCEL_PLUGIN, *OFF_TOPIC_PLUGINS):
        assert plugin in tracked.get("enabledPlugins", {}), (
            f"the disable for {plugin} is not in the tracked settings file")
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
