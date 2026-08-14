#!/usr/bin/env bash
set -euo pipefail

# Build PostRoll in Release configuration and install to /Applications.
# Usage: ./build-install.sh [--launch]

cd "$(dirname "$0")"

PROJECT="PostRoll.xcodeproj"
SCHEME="PostRoll"
CONFIG="Release"
APP_NAME="PostRoll.app"
DEST="/Applications/${APP_NAME}"
# One cache location for every build this repo runs, shared with the
# Makefile so the two cannot drift, and outside the iCloud-synced checkout
# (#485).
CACHE_PATH_FILE="$(pwd)/derived-data-path.sh"
if [[ ! -f "${CACHE_PATH_FILE}" ]]; then
  echo "Error: ${CACHE_PATH_FILE} is missing. It holds the one build cache" >&2
  echo "       location this script and the Makefile share, so without it there" >&2
  echo "       is nowhere agreed to build into." >&2
  exit 1
fi
. "${CACHE_PATH_FILE}"
BUILD_DIR="${POSTROLL_DERIVED_DATA}"

# Nothing ran the tests before a build reached /Applications, so a red suite
# could be installed and used without anyone noticing (#98). The gate lives
# here rather than only in the Makefile because the `postroll` alias calls this
# script directly and would otherwise skip it entirely.
#
# SKIP_INSTALL_TESTS=1 ./build-install.sh installs a known-red build on purpose.
if [[ "${SKIP_INSTALL_TESTS:-0}" == "1" ]]; then
  echo "==> Skipping tests (SKIP_INSTALL_TESTS=1)"
else
  echo "==> Running the Swift tests before installing"
  # The output is kept so a permissions refusal can be told apart from a real
  # red suite (#271). The repo lives under ~/Documents, which macOS protects,
  # so the test process needs Documents access to read its own fixtures; when
  # that is refused, several fixture-reading suites fail at once and the output
  # reads as broken tests. A gate that fails for reasons unrelated to the code
  # teaches the operator to bypass it every time, and a gate that is always
  # bypassed is the same as no gate.
  # An explicit XXXXXX template. The short `-t NAME` form of mktemp is
  # BSD-only, GNU mktemp refuses it, and it broke every Linux CI run while
  # working perfectly on this Mac.
  SWIFT_LOG="$(mktemp "${TMPDIR:-/tmp}/postroll-swift-tests.XXXXXX")"
  # Same cache as the build below. Without -derivedDataPath this step minted
  # a SECOND full cache under Xcode's default location, on every install,
  # that nothing here ever reclaimed (#485).
  if xcodebuild -project "${PROJECT}" -scheme PostRollTests \
       -derivedDataPath "${BUILD_DIR}" -destination 'platform=macOS' test \
       > "${SWIFT_LOG}" 2>&1; then
    (command -v xcbeautify >/dev/null && xcbeautify < "${SWIFT_LOG}" || cat "${SWIFT_LOG}")
    rm -f "${SWIFT_LOG}"
  else
    (command -v xcbeautify >/dev/null && xcbeautify < "${SWIFT_LOG}" || cat "${SWIFT_LOG}")
    if grep -qE "PERMISSIONS, not a test failure|Operation not permitted" "${SWIFT_LOG}"; then
      echo >&2
      echo "Error: the Swift suite could not READ ITS OWN FIXTURES. This is a macOS" >&2
      echo "       permissions problem, not a code failure: the repo is under" >&2
      echo "       ~/Documents, which is protected, and the test runner was refused" >&2
      echo "       access. Grant Xcode and the test runner access under System" >&2
      echo "       Settings > Privacy & Security > Files and Folders, then re-run." >&2
      echo "       Nothing about the code was exercised either way, so bypassing" >&2
      echo "       once with SKIP_INSTALL_TESTS=1 is safe FOR THIS CAUSE ONLY." >&2
    fi
    rm -f "${SWIFT_LOG}"
    exit 1
  fi

  echo "==> Running the Python tests before installing"
  REPO_ROOT="$(cd .. && pwd)"
  if [[ -x "${REPO_ROOT}/venv/bin/python" ]]; then
    # Is the green suite above worth anything? If this Mac's Xcode has moved
    # ahead of the one CI is pinned to, it can pass on code the runner cannot
    # compile, and only a push would say so (#528). Cheap, and it refuses
    # rather than warns, because a warning printed above three minutes of test
    # output is a warning nobody reads.
    echo "==> Checking this Mac's compiler against CI's"
    "${REPO_ROOT}/venv/bin/python" "${REPO_ROOT}/tools/check_toolchain.py"

    # The FAST subset, not the whole suite (#432, approved 2026-08-13).
    #
    # The four files that render real reels are most of the suite's runtime and
    # this gate is paid on every install, several times an evening. They still run
    # on every pull request and on every push to main, so a regression they catch
    # still blocks the merge; what this gives up is that an install can briefly
    # precede those checks. That is a deliberate relaxation of the full-suite gate
    # chosen in #98, not an oversight.
    #
    # Honest figure: this saves about two minutes per install, not the eight the
    # issue was written with. #497 made the full suite one parallel pass, which
    # took it from 9m53s to about 3m30s before this change was made.
    #
    # Through the Makefile target rather than a second copy of the pytest command
    # (#430). This script used to spell the invocation itself, so the day the run
    # changed shape the install gate would have kept running the old command and
    # nobody would have seen the difference.
    make -C "${REPO_ROOT}" test-python-fast
  else
    # A missing venv is not a pass. Refuse rather than install a bundle whose
    # entire generation pipeline went unchecked.
    echo "Error: ${REPO_ROOT}/venv/bin/python not found, so the Python suite" >&2
    echo "       could not run. Create the venv, or re-run with" >&2
    echo "       SKIP_INSTALL_TESTS=1 to install without it." >&2
    exit 1
  fi
fi

echo "==> Building ${SCHEME} (${CONFIG})"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -derivedDataPath "${BUILD_DIR}" \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build \
  | (command -v xcbeautify >/dev/null && xcbeautify || cat)

BUILT_APP="${BUILD_DIR}/Build/Products/${CONFIG}/${APP_NAME}"
if [[ ! -d "${BUILT_APP}" ]]; then
  echo "Error: build succeeded but ${BUILT_APP} not found" >&2
  exit 1
fi

echo "==> Installing to ${DEST}"
if [[ -d "${DEST}" ]]; then
  # If the app is running, quit it first so the replace doesn't fail.
  if pgrep -xq "PostRoll"; then
    echo "    Quitting running PostRoll..."
    osascript -e 'tell application "PostRoll" to quit' || true
    sleep 1
  fi
  rm -rf "${DEST}"
fi
cp -R "${BUILT_APP}" "${DEST}"

# Clear ALL extended attributes (quarantine plus any resource-fork / Finder-info
# "detritus") so Gatekeeper doesn't nag AND codesign doesn't refuse with
# "resource fork, Finder information, or similar detritus not allowed" — which
# was silently dropping the app back to unsigned and breaking TCC persistence.
xattr -cr "${DEST}" 2>/dev/null || true

# Sign with a stable self-signed identity if one exists (run ./setup-signing.sh
# once to create it). A stable identity keeps macOS folder-permission grants
# (Downloads, etc.) from re-prompting on every rebuild. Falls back to ad-hoc.
SIGN_IDENTITY="PostRoll Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "${SIGN_IDENTITY}"; then
  # Show codesign's stderr on failure: an unsigned bundle silently breaks TCC
  # grant persistence (macOS re-prompts for Documents access on every file
  # read), so this must never fail quietly.
  if codesign --force --deep --sign "${SIGN_IDENTITY}" "${DEST}"; then
    echo "    Signed with '${SIGN_IDENTITY}' (stable identity)"
  else
    echo "    ERROR: signing with '${SIGN_IDENTITY}' failed; bundle is unsigned." >&2
    echo "    Fix the cause above (often: xattr -cr '${DEST}'), then re-run." >&2
    exit 1
  fi
else
  codesign --force --deep --sign - "${DEST}" >/dev/null 2>&1 || true
  echo "    Ad-hoc signed. Run ./setup-signing.sh once to stop repeated folder-access prompts."
fi

# Final gate: confirm the installed bundle is actually validly signed. An
# unsigned or broken signature has no stable identity for TCC to remember grants
# against, which silently reintroduces the repeated Documents-access prompts.
# This catches a silently-failed (ad-hoc or stable) signing — passing equally
# for a stable or an ad-hoc signature, failing only on a genuinely broken one.
if ! codesign --verify --deep --strict "${DEST}"; then
  echo "    ERROR: installed bundle failed signature verification (unsigned or broken)." >&2
  echo "    Run ./setup-signing.sh, ensure 'xattr -cr ${DEST}' clears detritus, then re-run." >&2
  exit 1
fi
echo "    Signature verified"

echo "==> Installed: ${DEST}"

if [[ "${1:-}" == "--launch" ]]; then
  echo "==> Launching"
  open "${DEST}"
fi
