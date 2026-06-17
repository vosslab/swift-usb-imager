#!/usr/bin/env bash
# build_bundle.sh -- assemble USBImagerApp.app from SwiftPM release output.
#
# Run this BEFORE sign_app.sh.
# Does NOT sign anything. Output directory: dist/USBImagerApp.app
#
# Usage: bash scripts/build_bundle.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Configuration -- update once bundle IDs are finalized
# ---------------------------------------------------------------------------
APP_NAME="USBImagerApp"
HELPER_NAME="PrivilegedHelper"
HELPER_LABEL="com.nsh.usbimager.helper"              # TODO: confirm bundle ID
LAUNCHD_PLIST_NAME="${HELPER_LABEL}.plist"

DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
HELPER_DAEMON_DIR="${CONTENTS}/Library/LaunchDaemons"
RESOURCES_DIR="${CONTENTS}/Resources"

SWIFTPM_BIN="$(swift build -c release --arch arm64 --show-bin-path 2>/dev/null)"

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
echo "[build_bundle] Building release binaries (arm64)..."
swift build -c release --arch arm64 \
    --product "${APP_NAME}" \
    --product "${HELPER_NAME}"

# ---------------------------------------------------------------------------
# Assemble bundle
# ---------------------------------------------------------------------------
echo "[build_bundle] Assembling ${APP_BUNDLE} ..."
rm -rf "${APP_BUNDLE}"
mkdir -p "${MACOS_DIR}" "${HELPER_DAEMON_DIR}" "${RESOURCES_DIR}"

# Main executable
cp "${SWIFTPM_BIN}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

# Helper executable (sits alongside its launchd plist)
cp "${SWIFTPM_BIN}/${HELPER_NAME}" "${HELPER_DAEMON_DIR}/${HELPER_LABEL}"

# Plists (must be committed to Resources/ at repo root before this runs)
# TODO: commit Resources/Info.plist to the repo
cp "${REPO_ROOT}/Resources/Info.plist"      "${CONTENTS}/Info.plist"

# TODO: commit Resources/com.nsh.usbimager.helper.plist to the repo
cp "${REPO_ROOT}/Resources/${LAUNCHD_PLIST_NAME}" \
   "${HELPER_DAEMON_DIR}/${LAUNCHD_PLIST_NAME}"

# App icon (optional; skip if not present)
if [ -f "${REPO_ROOT}/Resources/AppIcon.icns" ]; then
    cp "${REPO_ROOT}/Resources/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

echo "[build_bundle] Bundle assembled at: ${APP_BUNDLE}"
echo "[build_bundle] Next step: bash scripts/sign_app.sh"
