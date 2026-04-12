"""
PostRoll — AI Tells Loader

Fetches the comprehensive AI writing signals list from Wikipedia and
caches it per project. Every blog and caption generation injects the
cached list as a hard constraint so drafts arrive cleaner.

Per project (one event = one project), the list is fetched ONCE from
Wikipedia and cached in the project's working directory. Subsequent
writes within the project read from the cache. The cache expires after
CACHE_MAX_AGE_DAYS so the list stays current.

Source: https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing

Usage:
    from postroll.ai.ai_tells import get_ai_tells_list
    text = get_ai_tells_list(Path("output/event-slug/ai_tells.md"))
"""

from __future__ import annotations

import time
from pathlib import Path

from .claude_client import run_prompt, ClaudeError


WIKIPEDIA_URL = "https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing"
CACHE_MAX_AGE_DAYS = 30


FETCH_PROMPT = f"""\
Use the WebFetch tool to fetch this URL:
{WIKIPEDIA_URL}

Extract every specific pattern, phrase, word, and structural habit listed
on that page as a sign of AI writing. Organize the output as a clean
markdown document with these sections:

- Vocabulary and word choice (specific words to avoid)
- Sentence and paragraph patterns (negative parallelism, rule of three, etc.)
- Avoidance of basic copulas ("serves as" instead of "is", etc.)
- Significance and meaning-making patterns (vague claims, gestural phrases)
- Structural habits (challenges-and-future-prospects template, etc.)
- Formatting habits (em dash overuse, title case, etc.)
- Communication and tone habits (collaborative tone, knowledge-cutoff
  disclaimers, etc.)

For each item, give the specific pattern with a short example or rule.
Capture EVERYTHING the page lists — don't summarize aggressively. The
output is going to be injected into writing prompts as a blacklist, so
completeness matters.

Return ONLY the markdown document. No preamble, no commentary, no
explanation about what you fetched.
"""


def _is_cache_fresh(cache_path: Path) -> bool:
    """True if the cache exists and is younger than CACHE_MAX_AGE_DAYS."""
    if not cache_path.exists():
        return False
    age_seconds = time.time() - cache_path.stat().st_mtime
    age_days = age_seconds / 86400
    return age_days < CACHE_MAX_AGE_DAYS


def get_ai_tells_list(cache_path: str | Path) -> str:
    """Return the AI tells list, fetching from Wikipedia if needed.

    If the cache file at `cache_path` exists and is fresh (<30 days old),
    its contents are returned. Otherwise, Claude is invoked with
    WebFetch to pull the latest Wikipedia signals page, extract a
    comprehensive list, write it to the cache, and return it.

    Raises ClaudeError if the fetch fails.
    """
    path = Path(cache_path).expanduser().resolve()

    if _is_cache_fresh(path):
        return path.read_text(encoding="utf-8")

    # Cache miss or stale — fetch fresh from Wikipedia via Claude
    text = run_prompt(
        FETCH_PROMPT,
        timeout=300,
        allowed_tools=["WebFetch"],
    )

    if not text.strip():
        raise ClaudeError("AI tells fetch returned empty content")

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text + "\n", encoding="utf-8")
    return text


def format_for_prompt(ai_tells_text: str) -> str:
    """Wrap the AI tells list in a section header for prompt injection."""
    return (
        "---\n\n"
        "## AI WRITING TELLS TO AVOID (live from Wikipedia)\n\n"
        "The following patterns are AI writing tells. After drafting your\n"
        "output, review it against EVERY item below and revise to remove\n"
        "any matches. The cleaned version is what you return — never the\n"
        "first draft.\n\n"
        f"{ai_tells_text}\n\n"
        "---\n"
    )
