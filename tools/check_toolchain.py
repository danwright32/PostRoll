"""Keep the compiler CI uses at or ahead of the one this Mac uses (#528).

CI ran Xcode 16.4 while the dev Mac ran 26.6. The older compiler rejects code
the newer one accepts, so six CI round trips in one session were compile errors
that built clean locally: a change could look fully verified here and still be
unbuildable, and the only signal took minutes and a push to arrive.

The rule is one-directional, and that is the whole design:

  CI ahead of local    fine. It accepts everything this machine's compiler does,
                       so a green local build still means something.
  same                 fine.
  local ahead of CI    the hole. Code that compiles here can be rejected there,
                       and nothing on this machine can tell you.

`PostRollApp/.ci-xcode-version` is the one recorded version. The macOS workflow
selects that Xcode explicitly rather than taking whatever the runner image
defaults to, and this tool holds the local machine to the same number, so an
Xcode update here is loud on the next build instead of silent until a push.

    venv/bin/python tools/check_toolchain.py

Exits non-zero only for the local-ahead case. Run by `make check-toolchain` and
by build-install.sh before it installs anything.
"""

from __future__ import annotations

import enum
import platform
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
VERSION_FILE = REPO_ROOT / "PostRollApp" / ".ci-xcode-version"

Version = tuple[int, ...]


class Verdict(enum.Enum):
    MATCHED = "MATCHED"
    CI_IS_AHEAD = "CI_IS_AHEAD"
    LOCAL_IS_AHEAD = "LOCAL_IS_AHEAD"


@dataclass(frozen=True)
class Result:
    outcome: Verdict
    detail: str

    @property
    def ok(self) -> bool:
        return self.outcome is not Verdict.LOCAL_IS_AHEAD


def parse_version(text: str) -> Version:
    """The version out of an `xcodebuild -version` banner, or a raised error.

    Raises rather than returning a default. A failed parse that returns
    something comparable lands on whichever side of the threshold the default
    happens to fall on, with no error ever raised (L50).
    """
    match = re.search(r"Xcode\s+(\d+(?:\.\d+)*)", text)
    if not match:
        raise ValueError(
            "no Xcode version in this text, so there is nothing to compare:\n"
            + text.strip()
        )
    return tuple(int(part) for part in match.group(1).split("."))


def recorded_ci_version(path: Path | None = None) -> Version:
    """The Xcode version CI is pinned to."""
    source = path or VERSION_FILE
    raw = source.read_text().strip()
    if not re.fullmatch(r"\d+(?:\.\d+)*", raw):
        raise ValueError(
            f"{source} should hold nothing but a version like 26.6, and holds: {raw!r}"
        )
    return tuple(int(part) for part in raw.split("."))


def verdict(*, local: Version, ci: Version) -> Result:
    spelled_local = ".".join(str(p) for p in local)
    spelled_ci = ".".join(str(p) for p in ci)

    if local == ci:
        return Result(Verdict.MATCHED, f"Xcode {spelled_local} on both sides.")
    if local < ci:
        return Result(
            Verdict.CI_IS_AHEAD,
            f"This Mac runs Xcode {spelled_local} and CI runs {spelled_ci}. That is "
            "the safe direction: anything CI would reject is rejected here first.",
        )
    return Result(
        Verdict.LOCAL_IS_AHEAD,
        f"This Mac runs Xcode {spelled_local} and CI is pinned to {spelled_ci}, so "
        "the compiler here accepts code the one there rejects and no local build "
        "can tell you. That is #528: six CI round trips in one session were "
        "compile errors that built clean on this machine.\n\n"
        f"Fix it by raising {VERSION_FILE.relative_to(REPO_ROOT)} to {spelled_local} "
        "once the GitHub runner image carries that Xcode (check "
        "actions/runner-images), or by keeping this Mac on the recorded version.",
    )


# ── the same hazard, on the Python side (#656) ───────────────────────────────
#
# The venv was built on the Python inside Xcode.app, which meant an Xcode update
# or move would take the entire generation pipeline with it, and it held this
# Mac on 3.9 while every CI job runs 3.11. Neither was reported anywhere.
#
# Two rules, for two different failures:
#
#   base inside an app bundle   another application owns your runtime, and its
#                               update schedule is not yours.
#   local minor != CI's minor   the drift this file already guards for the
#                               compiler, in the language the pipeline runs in.

WORKFLOWS = Path(__file__).resolve().parent.parent / ".github" / "workflows"


def base_interpreter(pyvenv_cfg: str) -> str | None:
    """The interpreter a venv was built from, out of its pyvenv.cfg.

    None when the file names none, which is NOT the same as a healthy
    environment and must not be treated as one by the caller (L98).
    """
    for line in pyvenv_cfg.splitlines():
        key, _, value = line.partition("=")
        if key.strip() == "home":
            return value.strip() or None
    return None


def ci_python_version(workflows: Path | None = None) -> str:
    """The Python minor version CI installs, read from the workflows.

    Derived rather than recorded a second time here: a hand-kept copy drifts
    from what CI actually installs, and the check then compares this Mac
    against a fiction (L41).
    """
    found: set[str] = set()
    for path in sorted((workflows or WORKFLOWS).glob("*.yml")):
        found.update(re.findall(r"""python-version:\s*["']?(\d+\.\d+)""",
                                path.read_text(encoding="utf-8")))
    if not found:
        raise ValueError(
            f"no python-version pinned in any workflow under {workflows or WORKFLOWS}, "
            "so there is nothing to hold this Mac to")
    if len(found) > 1:
        raise ValueError(
            f"CI installs more than one Python minor version {sorted(found)}, so "
            "there is no single version for this Mac to match")
    return found.pop()


def python_verdict(*, local: str, ci: str, base: str | None) -> Result:
    """Whether this machine's Python is one the project can rely on."""
    if base is None:
        return Result(
            Verdict.LOCAL_IS_AHEAD,
            "the virtualenv does not say which interpreter it was built from, so "
            "nothing here can tell whether it is a safe one. Rebuild it.")

    # Checked before the version, because it is the more serious of the two: a
    # matching version inside somebody else's app is still a runtime that can
    # vanish on their schedule.
    owner = next((part for part in Path(base).parts if part.endswith(".app")), None)
    if owner:
        return Result(
            Verdict.LOCAL_IS_AHEAD,
            f"the virtualenv is built on the Python inside {owner} ({base}). That "
            "runtime belongs to another application and moves or disappears when it "
            "updates, taking generation with it. Rebuild the venv on a standalone "
            f"Python {ci}.")

    spelled_local = ".".join(local.split(".")[:2])
    if spelled_local != ci:
        return Result(
            Verdict.LOCAL_IS_AHEAD,
            f"this Mac's virtualenv runs Python {spelled_local} and CI runs {ci}. "
            "Code that passes on one can be rejected by the other, and only a push "
            f"would say so. Rebuild the venv on Python {ci}.")

    return Result(Verdict.MATCHED,
                  f"Python {ci} on both sides, from {base}.")


def main(argv: list[str]) -> int:
    banner = subprocess.run(
        ["xcodebuild", "-version"], capture_output=True, text=True, check=True
    ).stdout
    result = verdict(local=parse_version(banner), ci=recorded_ci_version())
    print(f"{result.outcome.value}: {result.detail}")

    cfg = Path(sys.prefix) / "pyvenv.cfg"
    python = python_verdict(
        local=platform.python_version(),
        ci=ci_python_version(),
        base=base_interpreter(cfg.read_text(encoding="utf-8")) if cfg.exists() else None)
    print(f"{python.outcome.value}: {python.detail}")

    return 0 if result.ok and python.ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
