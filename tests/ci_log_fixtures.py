"""The recorded CI job logs, and which pattern each one is evidence for (#1085).

`tools/check_job_durations.py` reads each job's log by regex twice over, and a
pattern that stops matching returns None or an empty set, which both tools are
built to treat as "could not measure" rather than as an error. The failure is
quiet by design at the call site and had nothing watching it upstream.

So each pattern is calibrated against a REAL recorded log, in the shape
`tools/wait_for_checks.py` is calibrated against GitHub's own reply rather than
against a reimplementation of it (L52).

`tools/record_ci_log.py` writes the logs, verbatim and gzipped, timestamps
included. The timestamps matter: they are what the worse of the two defects was
about, and a fixture with them stripped would be a fixture shaped so the rule
fires (L48).

Everything here RAISES rather than answering with an empty log, for the same
reason the patterns cannot: an empty log is one every pattern reports nothing
against, and nothing is what a broken pattern reports too.
"""

from __future__ import annotations

import gzip
import json
from functools import lru_cache
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LOGS = REPO_ROOT / "tests" / "fixtures" / "ci_logs"
MANIFEST = LOGS / "manifest.json"

#: Which recorded log is evidence for each job family's WORK pattern.
#:
#: A family missing from here is a family whose pattern nothing checks, which is
#: the state every one of them was in until now, so the test that walks
#: WORK_PATTERNS refuses on a family this does not name rather than skipping it
#: (L96, L129).
WORK_EVIDENCE = {
    "swift-unit": "swift-red",
    "python": "python-red",
    "macos": "macos-red",
    "reference-frames": "reference-frames-green",
    "changed": "guard-full",
    "full": "guard-full",
}

#: Which recorded log is evidence for each family's FAILURE pattern.
#:
#: A GREEN log is no evidence at all here: it holds no failures, so a pattern
#: that can never match reports the same empty set as one that works (L159,
#: L98). Every entry must therefore name a log whose `holds.failed_tests` is not
#: empty, which is asserted rather than assumed.
#:
#: The five pytest families share one pattern over one producer, so one real red
#: pytest log is evidence for all of them. `swift-unit` is the only distinct
#: one, and it needs a log from a run in PARALLEL mode: the serial runner printed
#: `Test Case '-[Module.Class method]' failed` and the parallel one prints
#: `Test case 'Class.method()' failed on '<worker>'`, and the suite has run in
#: parallel since #992.
FAILURE_EVIDENCE = {
    "swift-unit": "swift-red",
    "python": "python-red",
    "macos": "macos-red",
    "reference-frames": "python-red",
    "changed": "python-red",
    "full": "python-red",
}


def manifest() -> dict:
    assert MANIFEST.exists(), (
        f"{MANIFEST.relative_to(REPO_ROOT)} is missing, so no pattern below is "
        "held to anything")
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


@lru_cache(maxsize=None)
def recorded(name: str) -> str:
    """One recorded log, decompressed once per run.

    Once per run rather than once per test: the logs are about 1.2MB each and
    several tests read the same one (#1018).
    """
    path = LOGS / f"{name}.log.gz"
    assert path.exists(), (
        f"no recorded log called {name}. Record one: "
        f"tools/record_ci_log.py --job <id> --as {name}")
    text = gzip.decompress(path.read_bytes()).decode("utf-8", errors="replace")
    assert text.strip(), (
        f"the recorded log {name} is empty, and an empty log is one every "
        "pattern reports nothing against")
    return text


def holds(name: str) -> dict:
    """What a log holds, read off it by hand rather than by the code under test.

    A fixture whose expectations were produced by the pattern can only ever
    prove the pattern agrees with itself (L58, L70).
    """
    entry = manifest()["logs"].get(name)
    assert entry, f"the manifest does not describe a log called {name}"
    found = entry.get("holds") or {}
    assert found.get("work") is not None, (
        f"{name} has no recorded work count, so nothing says what the pattern "
        "reading it should answer. Fill in its `holds`, read off the log.")
    assert found.get("read_off"), (
        f"{name}'s `holds` does not say which line each number came from, so "
        "nobody after you can check it without trusting this file")
    return found
