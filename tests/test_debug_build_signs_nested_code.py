"""The checkout-recording build phase leaves a signed bundle, in Debug too (#719).

Pressing Run in Xcode could not work at all. Every Debug build of the app scheme
died in the `Record the checkout this build was made from` phase with `code
object is not signed at all`, naming signing rather than the script that caused
it.

The mechanism, measured rather than reasoned about (L177). A Debug build puts
two extra Mach-O files inside the bundle that a Release build has no trace of,
`PostRoll.debug.dylib` and `__preview.dylib`, and at the moment this phase runs
neither is signed yet. `codesign --force --sign` on the WRAPPER then refuses,
because a bundle containing unsigned nested code cannot be sealed. So the phase
failed at its sign step, not at the verification after it, and the message
quoted whichever nested file codesign reached first.

Two things about that are worth writing down, because both were assumed wrong.

The phase does NOT run after Xcode signs. The comment in `project.yml` said it
did, and that is what the re-sign was there for. On this toolchain the ordering
is the other way round in BOTH configurations: the script phase runs, then
`CodeSign` runs. So the plist edit breaks no seal. The re-sign is kept anyway,
because it is harmless under the ordering that holds now and correct under the
ordering the comment described, and because its verification is what caught
this. A signing step is not removed on the strength of one machine's ordering.

And the fix cannot enumerate the nested files by name. The issue that reported
this named `PostRoll.debug.dylib` and had no idea `__preview.dylib` existed. A
hand-kept list of what to sign is exempt from the very check meant to catch it
(L96), so the phase discovers nested code by reading what is actually in the
bundle.

These tests run the REAL script, taken out of the generated project, against a
fixture bundle shaped like a Debug build. `project.yml` is a manifest;
`PostRoll.xcodeproj` is generated from it and committed, and it is the generated
file Xcode builds (L3), so that is the copy under test and the two are held to
each other separately.
"""

from __future__ import annotations

import os
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parent.parent
APP = REPO_ROOT / "PostRollApp"
MANIFEST = APP / "project.yml"
PBXPROJ = APP / "PostRoll.xcodeproj" / "project.pbxproj"

PHASE_NAME = "Record the checkout this build was made from"


# --------------------------------------------------------------------------
# Getting at the script the build actually runs
# --------------------------------------------------------------------------


def _script_from_manifest() -> str:
    """The phase's shell body as written in `project.yml`."""
    text = MANIFEST.read_text(encoding="utf-8")
    marker = f"- name: {PHASE_NAME}\n"
    assert marker in text, (
        f"there is no build phase named {PHASE_NAME!r} in project.yml, so this "
        "test is checking nothing. If the phase was renamed, rename it here too."
    )
    rest = text.split(marker, 1)[1]
    lines = rest.split("\n")
    start = None
    for i, line in enumerate(lines):
        if line.strip() == "script: |":
            start = i
            break
        if line.strip().startswith("- name:"):
            break
    assert start is not None, (
        f"the {PHASE_NAME!r} phase has no `script: |` block in project.yml"
    )
    indent = len(lines[start]) - len(lines[start].lstrip()) + 2
    body: list[str] = []
    for line in lines[start + 1 :]:
        if line.strip() and not line.startswith(" " * indent):
            break
        body.append(line[indent:] if len(line) >= indent else "")
    return "\n".join(body).rstrip("\n") + "\n"


def _unescape_pbx(value: str) -> str:
    """Undo the pbxproj string escaping, which is C-like and shallow."""
    out: list[str] = []
    i = 0
    while i < len(value):
        ch = value[i]
        if ch == "\\" and i + 1 < len(value):
            nxt = value[i + 1]
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def _script_from_generated_project() -> str:
    """The phase's shell body as it sits in the committed `.xcodeproj`.

    This is the copy Xcode runs. A fix applied to the manifest and never
    generated is absent from every build while the manifest reads as fixed.
    """
    text = PBXPROJ.read_text(encoding="utf-8")
    scripts = re.findall(r'shellScript = "((?:[^"\\]|\\.)*)";', text)
    assert scripts, "no shellScript in the generated project at all"
    hits = [_unescape_pbx(s) for s in scripts if "POSTROLLProjectRoot" in _unescape_pbx(s)]
    assert len(hits) == 1, (
        f"expected exactly one script recording the checkout, found {len(hits)}"
    )
    return hits[0]


def test_the_generated_project_carries_the_same_script_as_the_manifest():
    """Held to each other, so editing one without regenerating fails here.

    Without this the manifest can carry a fix that no build has ever run, which
    is the exact way #648's first attempt looked correct while doing nothing.
    """
    assert _script_from_generated_project().strip() == _script_from_manifest().strip(), (
        "project.yml and PostRoll.xcodeproj disagree about the checkout-recording "
        "script. Run `cd PostRollApp && xcodegen generate` and commit the result: "
        "the generated project is what Xcode builds, so until then the change is "
        "in no build at all."
    )


# --------------------------------------------------------------------------
# A bundle shaped like a Debug build
# --------------------------------------------------------------------------


def _clang() -> str:
    found = shutil.which("clang")
    if not found:
        pytest.skip("no clang on PATH, so no Mach-O fixture could be built")
    return found


def _unsigned_macho(path: Path, *, dylib: bool) -> None:
    """A real, genuinely unsigned Mach-O at `path`.

    Compiled rather than copied from the system, because every system binary is
    signed and `codesign --remove-signature` refuses on some of them. The linker
    ad-hoc signs what it produces on arm64, so the signature is stripped after.
    """
    source = "int postroll_fixture(void) { return 0; }" if dylib else "int main(void) { return 0; }"
    cmd = [_clang(), "-x", "c", "-o", str(path), "-"]
    if dylib:
        cmd.insert(1, "-dynamiclib")
    subprocess.run(cmd, input=source.encode(), check=True, capture_output=True)
    subprocess.run(["codesign", "--remove-signature", str(path)], capture_output=True)
    proof = subprocess.run(["codesign", "-dv", str(path)], capture_output=True)
    assert proof.returncode != 0, (
        f"{path.name} is still signed, so a fixture meant to reproduce unsigned "
        "nested code reproduces nothing and any test using it proves nothing (L48)"
    )


def _bundle(tmp_path: Path, *, nested: bool) -> Path:
    """A `.app` shaped like a build product, with or without nested code."""
    app = tmp_path / "products" / "Fixture.app"
    macos = app / "Contents" / "MacOS"
    macos.mkdir(parents=True)
    _unsigned_macho(macos / "Fixture", dylib=False)
    if nested:
        # Both of the ones a real Debug build carries, under their real names,
        # so the fixture is the shape that actually failed rather than one
        # chosen to make the rule fire (L48).
        _unsigned_macho(macos / "Fixture.debug.dylib", dylib=True)
        _unsigned_macho(macos / "__preview.dylib", dylib=True)
    (app / "Contents" / "Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleExecutable": "Fixture",
                "CFBundleIdentifier": "com.dwphotony.Fixture",
                "CFBundleName": "Fixture",
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
            }
        )
    )
    return app


def _run_phase(tmp_path: Path, app: Path) -> subprocess.CompletedProcess:
    """Run the real build phase against `app`, as Xcode would."""
    srcroot = tmp_path / "checkout" / "PostRollApp"
    srcroot.mkdir(parents=True)
    env = {
        **os.environ,
        "SRCROOT": str(srcroot),
        "TARGET_BUILD_DIR": str(app.parent),
        "WRAPPER_NAME": app.name,
        "EXECUTABLE_PATH": f"{app.name}/Contents/MacOS/Fixture",
        "INFOPLIST_PATH": f"{app.name}/Contents/Info.plist",
        "CODE_SIGNING_ALLOWED": "YES",
        "EXPANDED_CODE_SIGN_IDENTITY": "-",
    }
    return subprocess.run(
        ["/bin/sh", "-c", _script_from_generated_project()],
        env=env,
        capture_output=True,
        text=True,
    )


# --------------------------------------------------------------------------
# The checks
# --------------------------------------------------------------------------


def test_a_bundle_with_nested_code_is_left_signed_and_sealed(tmp_path):
    """The Debug shape: two unsigned dylibs beside the main executable."""
    app = _bundle(tmp_path, nested=True)
    done = _run_phase(tmp_path, app)
    assert done.returncode == 0, (
        "the checkout-recording phase failed on a bundle carrying nested code, "
        "which is every Debug build, so pressing Run in Xcode cannot work.\n"
        f"stdout: {done.stdout}\nstderr: {done.stderr}"
    )
    verify = subprocess.run(
        ["codesign", "--verify", "--strict", str(app)], capture_output=True, text=True
    )
    assert verify.returncode == 0, (
        f"the phase reported success but left an unsealed bundle: {verify.stderr}"
    )


def test_every_nested_macho_is_signed_not_only_the_wrapper(tmp_path):
    """Sealing the wrapper is not signing what is inside it.

    Checked per file rather than through the wrapper's own verification, because
    `--verify --strict` on the bundle is one answer for the whole tree and this
    is the specific property that was missing.
    """
    app = _bundle(tmp_path, nested=True)
    assert _run_phase(tmp_path, app).returncode == 0
    nested = sorted((app / "Contents" / "MacOS").glob("*.dylib"))
    assert len(nested) == 2, (
        f"the fixture no longer carries the nested dylibs it exists for: {nested}"
    )
    for lib in nested:
        proof = subprocess.run(["codesign", "-dv", str(lib)], capture_output=True)
        assert proof.returncode == 0, (
            f"{lib.name} was left unsigned. A list of nested files kept by hand "
            "is exempt from this check the moment the build grows one nobody "
            "wrote down, which is how __preview.dylib was missed (L96)."
        )


def test_the_release_shape_still_works(tmp_path):
    """The control on the other side: no nested code, which is every Release
    build and the only shape that has ever worked. A fix for Debug that broke
    this would break `make build` and the installed app."""
    app = _bundle(tmp_path, nested=False)
    done = _run_phase(tmp_path, app)
    assert done.returncode == 0, (
        f"the phase failed on a Release-shaped bundle.\nstderr: {done.stderr}"
    )
    verify = subprocess.run(
        ["codesign", "--verify", "--strict", str(app)], capture_output=True, text=True
    )
    assert verify.returncode == 0, verify.stderr


def test_the_fixture_really_does_defeat_a_wrapper_only_sign(tmp_path):
    """The positive control.

    A test asserting the nested case now works is worthless unless the fixture
    could fail it, and this is the one thing that proves the fixture reproduces
    #719 rather than merely being a bundle that signs (L159, L1). This performs
    the OLD behaviour by hand, wrapper only, and requires it to be refused.
    """
    app = _bundle(tmp_path, nested=True)
    done = subprocess.run(
        ["codesign", "--force", "--sign", "-", str(app)], capture_output=True, text=True
    )
    assert done.returncode != 0, (
        "signing only the wrapper succeeded on a bundle with unsigned nested "
        "code, so this fixture does not reproduce #719 and every other test in "
        "this file is passing for a reason unrelated to the fix"
    )
    assert "not signed" in done.stderr, (
        f"the refusal was for some other reason than unsigned nested code: {done.stderr}"
    )


def test_the_phase_still_records_the_checkout(tmp_path):
    """The signing work must not have displaced what the phase is FOR."""
    app = _bundle(tmp_path, nested=True)
    assert _run_phase(tmp_path, app).returncode == 0
    data = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
    assert data.get("POSTROLLProjectRoot") == str(tmp_path / "checkout"), (
        f"the phase left POSTROLLProjectRoot as {data.get('POSTROLLProjectRoot')!r}"
    )
