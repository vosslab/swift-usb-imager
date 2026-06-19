#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building (debug)..."
swift build "$@"
echo "Debug build complete"

BIN_PATH=$(swift build --show-bin-path)
echo "Build output: $BIN_PATH"

# Check for the known executable product by name
EXEC_PATH="$BIN_PATH/USBImagerApp"
if [ -f "$EXEC_PATH" ] && [ -x "$EXEC_PATH" ]; then
	echo "Executable: $EXEC_PATH"
else
	echo "No executable product yet (library-only package)"
	echo "Build complete!"
	exit 0
fi

# Assemble a real USBImagerApp.app bundle in the repo working tree.
#
# The custom usbimager:// URL scheme (the M0-selected GUI source handoff) reaches
# the app only through a packaged .app bundle whose Info.plist declares
# CFBundleURLTypes; the bare swift-build executable carries no Info.plist. The
# bundle lives at a stable repo path (not /tmp) so LaunchServices can route the
# scheme to the dev artifact. This is a build step only; it does not launch.
APP_BUNDLE="$SCRIPT_DIR/USBImagerApp.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_PLIST_SRC="$SCRIPT_DIR/Sources/USBImagerApp/Info.plist"

echo "Assembling app bundle: $APP_BUNDLE"
mkdir -p "$APP_MACOS"
cp "$EXEC_PATH" "$APP_MACOS/USBImagerApp"
cp "$APP_PLIST_SRC" "$APP_BUNDLE/Contents/Info.plist"
echo "App bundle: $APP_BUNDLE"

echo "Build complete!"
