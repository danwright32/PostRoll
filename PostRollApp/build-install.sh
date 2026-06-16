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
BUILD_DIR="$(pwd)/build"

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

echo "==> Installed: ${DEST}"

if [[ "${1:-}" == "--launch" ]]; then
  echo "==> Launching"
  open "${DEST}"
fi
