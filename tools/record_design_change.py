"""Record a deliberate design change, in the one order that works (#786).

Changing what a template renders takes several steps and they only work in one
order:

  1. bump `MEDIA_DESIGN_VERSIONS` in `postroll/media/design_tokens.py`,
  2. mirror it into `PostRollApp/Sources/DesignTokens.swift`,
  3. regenerate `tests/fixtures/design_stamp.json` from the writer,
  4. re-record the reference frames with `POSTROLL_UPDATE_GOLDENS=1`,
  5. LOOK at them,
  6. commit them,
  7. run `tools/record_design_fingerprints.py`.

Get the order wrong and the tools refuse, correctly, but each refusal costs a
re-run of a suite that takes minutes. On 2026-08-20 this was done five times
across #753 and #756 and the order was wrong twice: once recording fingerprints
before the goldens were committed, once re-recording goldens while the version
was still unbumped.

The refusals stay. What this adds is doing the steps in the right order in the
first place, and refusing BEFORE the render rather than after it. Steps 1 and 2
are decisions and stay with the person; this checks they have been made, then
runs 3 and 4, then stops at 5 and hands back the frames to look at. Steps 6 and 7
stay separate on purpose: `record_design_fingerprints.py` declining to vouch for
reference frames with uncommitted changes is the guard that makes the whole
sequence mean anything, since a frame regenerated in this working tree was
produced by the very code being recorded.

It refuses, by name, in every case where going on would be wrong:

  * a template whose fingerprint moved and whose version did not, which is the
    other door (`make record-fingerprints`) rather than this one;
  * a tree whose reference frames are already modified, because the list this
    hands back could then be anything;
  * a run after which no frame changed at all, which means the templates render
    exactly as before, so this was not a design change.

    venv/bin/python tools/record_design_change.py    # or: make record-design-change
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

from postroll.media import design_fingerprint as fp  # noqa: E402
from postroll.media import design_stamp  # noqa: E402
from postroll.media import design_tokens as tokens  # noqa: E402

#: Repo-relative, so the whole tool can be pointed at a copy of the tree.
GOLDEN_DIR = "tests/fixtures/goldens"
STAMP_PATH = "tests/fixtures/design_stamp.json"
RECORD_PATH = "tests/fixtures/media_design_fingerprints.json"

#: The file that photographs every template. One node file rather than a list of
#: node ids: this re-records everything that moved, and a list would be a
#: registry deciding which templates are allowed to be re-recorded (L96).
GOLDEN_TESTS = "tests/test_golden_frames.py"


class Refused(RuntimeError):
    """This is not a tree the sequence can be run in, and why."""


@dataclass(frozen=True)
class Outcome:
    """What the run produced, and what the person has to do with it."""

    #: Repo-relative paths of the reference frames that moved.
    changed: list[str]
    #: What to print, including the remaining steps.
    report: str


def unbumped_templates(current: dict[str, str], record: dict[str, dict],
                       versions: dict[str, int]) -> list[str]:
    """Templates whose fingerprint moved while their version stayed put.

    The precondition for this whole sequence. A design change bumps a version;
    a change that moves the source without moving a pixel does not, and that is
    a different tool. Deciding which is the question the fingerprint guard
    exists to force, so this reports rather than chooses.

    A template the record has never heard of counts as unbumped. It has no
    recorded version to have been bumped FROM, and reading an absent entry as
    agreement would wave through the one case with no history at all (L98).
    """
    unbumped = []
    for template in sorted(current):
        entry = record.get(template)
        if entry is None:
            unbumped.append(template)
            continue
        if (entry.get("fingerprint") != current[template]
                and entry.get("version") == versions.get(template)):
            unbumped.append(template)
    return unbumped


def _git(repo_root: Path, *arguments: str) -> str:
    finished = subprocess.run(["git", "-C", str(repo_root), *arguments],
                              capture_output=True, text=True)
    if finished.returncode != 0:
        raise Refused(
            f"git {' '.join(arguments)} failed in {repo_root}: "
            f"{finished.stderr.strip()}")
    return finished.stdout


def changed_goldens(repo_root: Path) -> list[str]:
    """Reference frames git reports as modified, added or removed."""
    lines = _git(repo_root, "status", "--porcelain", "--", GOLDEN_DIR).splitlines()
    # The path is everything after the two status columns and a space. Split on
    # the first space rather than on whitespace: a rename is `A -> B`, and a
    # filename could hold a space.
    return sorted(line[3:].strip().strip('"') for line in lines if line.strip())


def write_stamp(repo_root: Path) -> None:
    """Regenerate the shared design stamp fixture from the writer itself.

    Through `write_design_stamp` rather than by composing the JSON here, because
    it is the one file both languages read and a second writer is one they can
    disagree over (L41). It writes into a temporary folder and the result is
    copied, since the writer names the file inside a day folder.
    """
    with tempfile.TemporaryDirectory() as folder:
        day = Path(folder)
        design_stamp.write_design_stamp(day, tokens.MEDIA_DESIGN_VERSIONS.keys())
        produced = design_stamp.design_stamp_path(day).read_text(encoding="utf-8")
    (repo_root / STAMP_PATH).write_text(produced, encoding="utf-8")


def rerecord_goldens(repo_root: Path, environment: dict[str, str]) -> None:
    """Run the reference frames with the re-record flag set.

    A non-zero exit is NOT a refusal here. Under `POSTROLL_UPDATE_GOLDENS` every
    frame check re-records and skips, so what can still fail is the other
    assertions in that file, and those failing is exactly the news this sequence
    exists to surface. It is reported with its output rather than swallowed.
    """
    finished = subprocess.run(
        [sys.executable, "-m", "pytest", GOLDEN_TESTS, "-q"],
        cwd=repo_root, env=environment, capture_output=True, text=True)
    if finished.returncode != 0:
        raise Refused(
            "the reference-frame run failed, so the frames it left behind are "
            "of a broken render and must not be committed:\n"
            + "\n".join(finished.stdout.splitlines()[-20:]))


def prepare(repo_root: Path, *, unbumped: list[str] | None = None,
            stamp=write_stamp, runner=rerecord_goldens) -> Outcome:
    """Steps 3 and 4, in order, having checked 1 and 2 were done.

    `unbumped` is passed in rather than computed here so the check can be driven
    against a tree that is not this checkout, which is what the tests do. The
    caller below computes it from the real fingerprints.
    """
    unbumped = [] if unbumped is None else unbumped
    if unbumped:
        raise Refused(
            "these templates render differently and their version has not "
            f"moved: {', '.join(unbumped)}.\n"
            "  If the rendering really did change, bump "
            "MEDIA_DESIGN_VERSIONS in postroll/media/design_tokens.py and "
            "mirror it in PostRollApp/Sources/DesignTokens.swift, then run this "
            "again.\n"
            "  If it renders identically and only the source moved, this is the "
            "wrong door: use `make record-fingerprints`, which records the "
            "fingerprint alone.\n"
            "  Refusing here rather than after the render, which takes minutes.")

    already = changed_goldens(repo_root)
    if already:
        raise Refused(
            f"these reference frames are already modified: {', '.join(already)}.\n"
            "  This hands back the frames that changed so they can be looked at, "
            "and taken in a tree where some were already modified that list is "
            "whatever was lying around plus whatever this produced, with no way "
            "to tell them apart.\n"
            "  Commit or discard them first.")

    stamp(repo_root)
    runner(repo_root, dict(os.environ, POSTROLL_UPDATE_GOLDENS="1"))

    changed = changed_goldens(repo_root)
    if not changed:
        raise Refused(
            "no reference frame changed, so every template renders exactly as it "
            "did and this was not a design change.\n"
            "  A version bump badges every asset already made as out of date, "
            "which is the wrong thing to do to assets that still look current.\n"
            "  Put the version back and use `make record-fingerprints`, which "
            "records the moved source alone.")

    listing = "\n".join(f"    {path}" for path in changed)
    report = (
        f"Re-recorded {STAMP_PATH} and {len(changed)} reference frame(s).\n\n"
        f"{listing}\n\n"
        "Now, in this order:\n"
        "  1. LOOK at those frames. The re-record flag is the one way a broken\n"
        "     frame becomes the expectation, so nothing downstream can catch it.\n"
        "  2. Commit them, along with the version bump and the stamp.\n"
        "  3. Run `make record-fingerprints`, which refuses to vouch for a frame\n"
        "     with uncommitted changes, so it has to be step 3 and not step 2.\n")
    return Outcome(changed=changed, report=report)


def main(argv: list[str] | None = None) -> int:
    record_path = REPO_ROOT / RECORD_PATH
    record = json.loads(record_path.read_text(encoding="utf-8")) if record_path.exists() else {}
    unbumped = unbumped_templates(current=fp.fingerprints(),
                                  record=record,
                                  versions=tokens.MEDIA_DESIGN_VERSIONS)
    try:
        outcome = prepare(REPO_ROOT, unbumped=unbumped)
    except Refused as refusal:
        print(f"refusing: {refusal}", file=sys.stderr)
        return 1
    print(outcome.report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
