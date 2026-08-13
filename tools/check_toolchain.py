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


def main(argv: list[str]) -> int:
    banner = subprocess.run(
        ["xcodebuild", "-version"], capture_output=True, text=True, check=True
    ).stdout
    result = verdict(local=parse_version(banner), ci=recorded_ci_version())
    print(f"{result.outcome.value}: {result.detail}")
    return 0 if result.ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
