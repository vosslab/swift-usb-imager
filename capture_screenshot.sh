#!/bin/sh
#
# capture_screenshot.sh - deterministic, non-intrusive app screenshots.
#
# Renders the SwiftUI panel state to PNG files OFFSCREEN via the USBImagerShots
# harness and exits. It never opens a visible window and never steals focus, so
# it is safe to run on a machine in active use. This replaces the previous flow
# of launching the live foreground GUI twice and killing it with pkill, which
# was rejected as disruptive (see
# docs/active_plans/decisions/wp0_gui_source_handoff_probe.md).
#
# Output PNGs land in screenshots/ with stable names:
#   screenshots/main_window.png  - idle main window (step 1)
#   screenshots/step2_target.png - preselected source advancing to step 2
#
# The harness asserts the view-model state reached step 2 before writing
# step2_target.png and exits non-zero otherwise, so a blank PNG never passes.
#
# To run the live GUI as an opt-in human smoke test instead (NOT the screenshot
# path), use: usbimager open --source <iso> --auto-exit N

cd /Users/vosslab/nsh/swift-usb-imager

# Render both screenshots offscreen; `swift run` builds the harness as needed.
# The harness writes screenshots/main_window.png and screenshots/step2_target.png
# and exits non-zero if the step-2 render state did not advance.
swift run USBImagerShots
