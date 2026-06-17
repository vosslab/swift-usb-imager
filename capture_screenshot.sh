#!/bin/sh
#
# capture_screenshot.sh - LOCAL developer helper for app screenshots.
#
# Intentionally local-only: relies on the easy-screenshot tool at
# ~/nsh/easy-screenshot/run.sh and on the fixed local repo path below.
#
# Builds the debug app, launches it twice, and screenshots each run:
# first idle (main window), then with a preselected source image (step 2,
# target selection). Both launches use --auto-exit so the app quits on its
# own. Output PNGs land in the repo's screenshots/ directory with stable names.

cd /Users/vosslab/nsh/swift-usb-imager

# Build the debug binary.
./build_debug.sh

mkdir -p screenshots

# Idle launch: capture the main window.
.build/arm64-apple-macosx/debug/USBImagerApp --auto-exit=5 &
sleep 2
~/nsh/easy-screenshot/run.sh --application USBImagerApp -f screenshots/main_window.png
sleep 5

pkill USBImagerApp
sleep 1

# Preselected-source launch: capture step 2 (target selection).
.build/arm64-apple-macosx/debug/USBImagerApp --auto-exit=5 --source=~/Downloads/debian-13.5.0-amd64-DVD-1.iso &
sleep 2
~/nsh/easy-screenshot/run.sh --application USBImagerApp -f screenshots/step2_target.png

pkill USBImagerApp
