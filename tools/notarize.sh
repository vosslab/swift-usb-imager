#!/usr/bin/env bash
# notarize.sh -- submit signed .app to Apple notarization, wait, and staple.
#
# Run AFTER scripts/sign_app.sh.
#
# Prerequisites:
#   xcrun notarytool store-credentials "notarytool-profile" \
#       --apple-id "YOUR_APPLE_ID"  \   # TODO
#       --team-id  "XXXXXXXXXX"     \   # TODO
#       --password "xxxx-xxxx-xxxx-xxxx"
#
# Usage: bash scripts/notarize.sh

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
APP_NAME="USBImagerApp"
DIST_DIR="${REPO_ROOT}/dist"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"
ZIP_PATH="${DIST_DIR}/${APP_NAME}-notarize.zip"

# Keychain profile name created by notarytool store-credentials above.
# TODO: change if you used a different profile name.
NOTARYTOOL_PROFILE="notarytool-profile"

# ---------------------------------------------------------------------------
# Verify bundle exists and is signed
# ---------------------------------------------------------------------------
if [ ! -d "${APP_BUNDLE}" ]; then
    echo "[notarize] ERROR: ${APP_BUNDLE} not found. Run sign_app.sh first."
    exit 1
fi

echo "[notarize] Verifying signatures before submission..."
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

# ---------------------------------------------------------------------------
# Create a zip for submission (Apple requires a zip or dmg)
# ---------------------------------------------------------------------------
echo "[notarize] Creating submission zip: ${ZIP_PATH}"
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_BUNDLE}" "${ZIP_PATH}"

# ---------------------------------------------------------------------------
# Submit for notarization and wait for result
# ---------------------------------------------------------------------------
echo "[notarize] Submitting to Apple notarization service..."
xcrun notarytool submit "${ZIP_PATH}" \
    --keychain-profile "${NOTARYTOOL_PROFILE}" \
    --wait \
    --timeout 30m

# notarytool exits non-zero on rejection, so reaching this line means success.

# ---------------------------------------------------------------------------
# Staple the ticket to the bundle
# ---------------------------------------------------------------------------
echo "[notarize] Stapling notarization ticket to bundle..."
xcrun stapler staple "${APP_BUNDLE}"

# ---------------------------------------------------------------------------
# Final Gatekeeper verification
# ---------------------------------------------------------------------------
echo "[notarize] Final Gatekeeper check (should say 'accepted'):"
spctl --assess --type exec --verbose "${APP_BUNDLE}"

echo "[notarize] Validating stapled ticket:"
xcrun stapler validate "${APP_BUNDLE}"

# ---------------------------------------------------------------------------
# Clean up submission zip; create distributable zip with stapled ticket
# ---------------------------------------------------------------------------
rm -f "${ZIP_PATH}"
FINAL_ZIP="${DIST_DIR}/${APP_NAME}.zip"
echo "[notarize] Creating distributable zip: ${FINAL_ZIP}"
ditto -c -k --keepParent "${APP_BUNDLE}" "${FINAL_ZIP}"

echo "[notarize] Done."
echo "Distributable: ${FINAL_ZIP}"
