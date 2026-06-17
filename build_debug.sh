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
fi
