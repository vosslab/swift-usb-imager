#!/usr/bin/env bash
# sign_app.sh -- sign the helper, app executable, and outer .app bundle.
#
# Run AFTER scripts/build_bundle.sh.
# Run BEFORE scripts/notarize.sh.
#
# Usage: bash scripts/sign_app.sh
#
# Signing order matters:
#   1. Helper executable (deepest, signed first)
#   2. App executable
#   3. Outer .app bundle (seals _CodeSignature/CodeResources last)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# TODO: fill in your identity and Team ID before running
# ---------------------------------------------------------------------------
# Find the exact identity string with:
#   security find-identity -v -p codesigning
DEVELOPER_ID_IDENTITY="Developer ID Application: Your Name (XXXXXXXXXX)"  # TODO
TEAM_ID="XXXXXXXXXX"                                                        # TODO
HELPER_LABEL="com.nsh.usbimager.helper"                                    # TODO: confirm

# ---------------------------------------------------------------------------
# Paths (must match build_bundle.sh output)
# ---------------------------------------------------------------------------
APP_NAME="USBImagerApp"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
HELPER_EXEC="${CONTENTS}/Library/LaunchDaemons/${HELPER_LABEL}"
APP_EXEC="${CONTENTS}/MacOS/${APP_NAME}"

# Entitlements files -- commit these to Resources/ before running
# TODO: commit Resources/PrivilegedHelper.entitlements to the repo
HELPER_ENTITLEMENTS="${REPO_ROOT}/Resources/PrivilegedHelper.entitlements"
# TODO: commit Resources/USBImagerApp.entitlements to the repo
APP_ENTITLEMENTS="${REPO_ROOT}/Resources/USBImagerApp.entitlements"

# ---------------------------------------------------------------------------
# Verify bundle exists
# ---------------------------------------------------------------------------
if [ ! -d "${APP_BUNDLE}" ]; then
    echo "[sign_app] ERROR: ${APP_BUNDLE} not found. Run build_bundle.sh first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: sign the privileged helper
# ---------------------------------------------------------------------------
echo "[sign_app] Signing helper: ${HELPER_EXEC}"
codesign \
    --force \
    --timestamp \
    --options runtime \
    --entitlements "${HELPER_ENTITLEMENTS}" \
    --sign "${DEVELOPER_ID_IDENTITY}" \
    "${HELPER_EXEC}"

# ---------------------------------------------------------------------------
# Step 2: sign the app executable
# ---------------------------------------------------------------------------
echo "[sign_app] Signing app executable: ${APP_EXEC}"
codesign \
    --force \
    --timestamp \
    --options runtime \
    --entitlements "${APP_ENTITLEMENTS}" \
    --sign "${DEVELOPER_ID_IDENTITY}" \
    "${APP_EXEC}"

# ---------------------------------------------------------------------------
# Step 3: sign the outer .app bundle (seals the bundle)
# ---------------------------------------------------------------------------
echo "[sign_app] Signing bundle: ${APP_BUNDLE}"
codesign \
    --force \
    --deep \
    --timestamp \
    --options runtime \
    --entitlements "${APP_ENTITLEMENTS}" \
    --sign "${DEVELOPER_ID_IDENTITY}" \
    "${APP_BUNDLE}"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
echo "[sign_app] Verifying signatures..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

echo "[sign_app] Checking Gatekeeper assessment (will say 'rejected' pre-notarization):"
spctl --assess --type exec --verbose "${APP_BUNDLE}" || true

echo "[sign_app] Done. Next step: bash scripts/notarize.sh"
echo ""
echo "After signing, derive the designated requirements for Info.plist:"
echo "  Helper DR:  codesign -d -r - ${HELPER_EXEC}"
echo "  App DR:     codesign -d -r - ${APP_BUNDLE}"
