"""CI must not pay twice for a commit, or rebuild what it already built (#430).

The merge cycle was 11 to 13 minutes on an app-code pull request, and most of it
was overhead rather than tests: every macOS run compiled the app from scratch,
every Linux run re-downloaded the same wheels and the same ffmpeg packages, and
pushing a fix to a pull request left the superseded run billing to completion at
the 10x private-repo multiplier.

Each of those is now closed by a piece of configuration, which is exactly the
kind of thing that gets silently reverted in a merge conflict or dropped while
editing something nearby. So each one is asserted, with the reason it exists, and
every one of them is registered in `tests/fixtures/guard_mutations/` so it
has been seen to go red (L1).

These read the workflows as text rather than parsing YAML, for the reason
`test_ci_gates.py` gives: a YAML parser is not worth a runtime dependency for
this. Comment lines are stripped first, because a check that can be satisfied by
the prose explaining a setting is indistinguishable from one that works (L103),
and every setting here is explained in a comment directly above it.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
MACOS = WORKFLOWS / "swift.yml"
LINUX = WORKFLOWS / "tests.yml"


def _settings(path: Path) -> str:
    """The workflow with whole-line comments removed.

    Only whole-line comments: nothing here puts a trailing comment after a
    value, and stripping from the first `#` on any line would cut into the shell
    snippets, which legitimately contain one.
    """
    return "\n".join(
        line for line in path.read_text(encoding="utf-8").splitlines()
        if not line.strip().startswith("#")
    )


@pytest.fixture
def macos() -> str:
    return _settings(MACOS)


@pytest.fixture
def linux() -> str:
    return _settings(LINUX)


def _concurrency(settings: str) -> str:
    assert "\nconcurrency:" in settings, (
        "this workflow has no concurrency block, so pushing a fix to a pull "
        "request leaves the superseded run billing to completion")
    block = settings.split("\nconcurrency:", 1)[1]
    # Ends at the next top-level key.
    return block.split("\njobs:", 1)[0]


# ── not paying for a commit nobody will merge ────────────────────────────────


@pytest.mark.parametrize("name", ["macos", "linux"])
def test_a_superseded_pull_request_run_is_cancelled(name, request):
    block = _concurrency(request.getfixturevalue(name))

    assert "cancel-in-progress:" in block
    assert "pull_request" in block, (
        "cancellation has to be conditioned on the event, or it applies to "
        "pushes to main as well")


@pytest.mark.parametrize("name", ["macos", "linux"])
def test_a_push_to_main_is_never_cancelled(name, request):
    """main is the branch every merge is verified on. A cancelled run there
    leaves main unverified while reporting nothing in particular."""
    block = _concurrency(request.getfixturevalue(name))
    condition = re.search(r"cancel-in-progress:\s*(.+)", block)
    assert condition, block

    value = condition.group(1).strip()
    assert value != "true", (
        "cancel-in-progress: true cancels a push to main as soon as the next "
        "one lands, which is how a merge ends up unverified")
    assert "pull_request" in value, (
        f"cancel-in-progress is {value!r}, which does not say it only applies "
        "to pull requests")


@pytest.mark.parametrize("name", ["macos", "linux"])
def test_consecutive_merges_do_not_queue_behind_one_another(name, request):
    """The group is per pull request, or per commit for a push.

    Keying it on the ref would put every pair of back-to-back merges into one
    group, and because cancellation is off for pushes they would run one after
    the other instead of at the same time. That is a real cost: it is the same
    nine macOS minutes, just later.
    """
    block = _concurrency(request.getfixturevalue(name))
    group = re.search(r"group:\s*(.+)", block)
    assert group, block

    value = group.group(1)
    assert "github.sha" in value, (
        f"the concurrency group is {value!r}. A push to main needs a group of "
        "its own, or consecutive merges serialise")
    assert "pull_request" in value, (
        f"the concurrency group is {value!r}. Two commits on one pull request "
        "have to share a group, or the superseded run is never cancelled")


# ── not compiling the app from scratch every run ─────────────────────────────


def test_the_build_cache_key_carries_the_toolchain(macos):
    """CI runs an older Xcode than the dev machine.

    Modules built by one toolchain are not valid input for another, so a key
    without the version restores a cache that is worse than no cache: a build
    that fails for a reason unrelated to the change (#412).
    """
    assert "xcodebuild -version" in macos, (
        "nothing reads the toolchain version, so the build cache key cannot "
        "be carrying it")

    key = re.search(r'echo "key=(.+?)" >>', macos)
    assert key, "no build-cache key is computed"
    assert "prefix" in key.group(1), (
        f"the cache key is {key.group(1)!r}, which does not include the "
        "toolchain-derived prefix")


def test_ci_compiles_the_app_and_not_only_the_test_target(macos):
    """The app has to be built by something before main (L3, L88).

    The PostRollTests scheme compiles a hand-listed subset of Sources, so the
    views were in no CI job at all: a missing brace in InsightsOverviewView sat
    on main with every check green and the app could not be built. This job is
    the only one with an Xcode in it, so it is the one that has to notice.
    """
    # Every xcodebuild invocation, as (scheme, action) pairs.
    runs = re.findall(r"-scheme\s+(\S+)(.*?)(?=-scheme|\Z)", macos, re.S)
    assert runs, "no xcodebuild invocations in the macOS workflow at all"

    app_builds = [
        scheme for scheme, rest in runs
        if scheme == "PostRoll" and re.search(r"^\s+build\s*$", rest, re.M)
    ]
    assert app_builds, (
        "no CI step builds the PostRoll app scheme, so nothing compiles the "
        f"view layer before it reaches main. Schemes run: {[s for s, _ in runs]}")


def test_the_swift_tests_build_into_the_folder_that_is_cached(macos):
    """Built is not wired (L3).

    A cache that is restored and saved while xcodebuild writes somewhere else
    is pure cost: it uploads a folder nothing reads, and the job stays as slow
    as it was while looking like it was fixed.
    """
    cached = re.search(r"path:\s*(\S*derived-data\S*)", macos)
    assert cached, "no derived-data folder is cached"

    # EVERY invocation, not the first one. This read `re.search` until #485,
    # which only ever looked at the app build, so dropping the flag from the
    # test step left the guard green: it was checking one call and reporting on
    # all of them. An invocation without the flag does not fail or warn, it
    # quietly builds into the shared default and the cached folder stays cold.
    calls = [c for c in re.findall(r"xcodebuild(?:.*\\\n)*.*", macos)
             if "-scheme" in c]  # `xcodebuild -version` asks a question, it builds nothing
    assert len(calls) >= 2, f"the scan found {len(calls)} invocations, so it proves little"

    for call in calls:
        built_into = re.search(r"-derivedDataPath\s+(\S+)", call)
        first_line = call.splitlines()[0].strip()
        assert built_into, (
            f"this xcodebuild is not given -derivedDataPath, so it writes to the "
            f"shared default and the cached folder stays empty: {first_line}")
        assert cached.group(1).rstrip("/") == built_into.group(1).rstrip("/"), (
            f"the cache holds {cached.group(1)} but this xcodebuild builds into "
            f"{built_into.group(1)}, so the cache is never read: {first_line}")


def test_the_restore_and_the_save_spell_the_key_one_way(macos):
    """Two literal keys drift, and the failure is silent: the save writes one
    key while the restore looks for another, so it is a cold build every time
    with a green cache step above it (L41)."""
    keys = re.findall(r"^\s*key:\s*(.+)$", macos, re.MULTILINE)
    computed = [k for k in keys if "steps.cache-key.outputs.key" in k]

    assert len(computed) >= 2, (
        f"expected the restore and the save to share one computed key, found "
        f"{keys}")


def test_the_build_cache_is_measured_against_a_cap_before_it_is_uploaded(macos):
    """An unbounded upload is the same defect as overture#2585, one layer up.

    GitHub evicts a repo's oldest entries once it holds 10 GB, so a folder that
    grows without limit here would quietly push out the pip and ffmpeg caches
    and slow down the very runs this was added to speed up.
    """
    assert "Index.noindex" in macos, (
        "the editor's symbol index is the bulk of the folder and nothing on a "
        "runner reads it; it has to be pruned before the upload")

    save = macos.split("Save the build cache", 1)
    assert len(save) == 2, "no step saves the build cache"
    condition = save[1].split("\n\n", 1)[0]
    assert "over-cap" in condition, (
        "the save is not conditioned on the measured size, so a folder over "
        "the cap is uploaded anyway and the measurement is decoration")


# ── not re-downloading the same packages every run ───────────────────────────


def test_the_python_workflow_caches_its_wheels(linux):
    """Every leg, not just whichever one appears first.

    This read `re.search` until the Mac leg arrived in #510 and made two, at
    which point dropping the setting from one of them left the guard green on
    the other's. The same shape as the derivedDataPath guard above: a check
    written when there was one of something, still reporting on all of them
    once there are two.
    """
    setups = re.findall(r"uses:\s*actions/setup-python.*?(?=\n      - |\Z)", linux, re.S)
    assert len(setups) >= 2, (
        f"found {len(setups)} Python setups, so this proves less than it claims")

    missing = [i for i, block in enumerate(setups) if not re.search(r"cache:\s*pip", block)]
    assert not missing, (
        f"setup-python block(s) {missing} do not cache pip, so those legs "
        "re-download the same pinned wheels on every run")


def test_the_ffmpeg_package_cache_key_carries_the_runner_image(linux):
    """Package versions belong to the image.

    Without the image in the key, an image bump would try to install last
    month's packages against this month's libraries, which is a failure in the
    one step whose whole job is to make sure ffmpeg is present.
    """
    key = re.search(r"key:\s*(ffmpeg.*)", linux)
    assert key, "the ffmpeg packages are not cached under a key of their own"
    assert "ImageOS" in key.group(1), (
        f"the ffmpeg cache key is {key.group(1)!r}, which does not name the "
        "runner image the packages came from")


def test_a_cold_or_refused_package_cache_still_installs_ffmpeg(linux):
    """The fallback is what makes the cache safe rather than load-bearing.

    A miss, or a cached set dpkg refuses, has to end in the same clean install
    this step did before there was a cache. The worst case is then today's
    speed, not a job that fails for want of a cache.
    """
    step = linux.split("name: Install ffmpeg", 1)
    assert len(step) == 2, "the ffmpeg install step has been renamed or removed"
    body = step[1].split("- name:", 1)[0]

    # Both halves, because either one alone can be satisfied while the fallback
    # does nothing: a defined-but-never-called installer reads as a fallback, and
    # a branch that calls something reads as one whatever that something does.
    installer = re.search(r"install_from_apt\(\)\s*\{(.*?)\n          \}", body, re.S)
    assert installer, (
        "no install_from_apt helper in this step, so there is nothing for the "
        "failure branch to fall back to")
    assert "apt-get install -y ffmpeg" in installer.group(1), (
        f"install_from_apt does not install ffmpeg: {installer.group(1)!r}")

    refused = re.search(r"dpkg -i.{0,200}", body, re.S)
    assert refused and "install_from_apt" in refused.group(0), (
        "nothing happens when dpkg refuses the cached packages, so a stale "
        "cache leaves the job with no ffmpeg and only the verification step "
        f"below to notice: {refused.group(0) if refused else body!r}")


def test_the_ffmpeg_install_is_still_verified_after_it_runs(linux):
    """The guard on a bad restore, and on a silent skip.

    A test that skips for want of ffmpeg is indistinguishable from one that
    passed, which is the whole reason ffmpeg is installed explicitly (#106).
    """
    install = linux.find("name: Install ffmpeg")
    confirm = linux.find("Confirm ffmpeg is actually here")

    assert confirm != -1, (
        "nothing checks ffmpeg is present after the install, so a restored "
        "cache that installed nothing would only surface as skipped tests")
    assert confirm > install, (
        "the verification runs before the install, so it cannot be checking "
        "what the install produced")
