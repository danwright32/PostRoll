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

# Strip quarantine so Gatekeeper doesn't nag on first launch.
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true

# Ad-hoc re-sign so the bundle identity is stable across rebuilds
# (helps TCC/Full Disk Access grants persist).
codesign --force --deep --sign - "${DEST}" >/dev/null 2>&1 || true

echo "==> Installed: ${DEST}"

if [[ "${1:-}" == "--launch" ]]; then
  echo "==> Launching"
  open "${DEST}"
fi
