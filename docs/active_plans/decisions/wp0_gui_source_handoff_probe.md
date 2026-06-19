# WP-0 GUI source-handoff probe findings

Working note for milestone M0 of the CLI-split plan. Selects exactly one GUI
source-handoff mechanism and records the contract WP-2b and WP-3e implement.
The probe code is throwaway; M2 reimplements the chosen path cleanly.

## Rejected validation method: repeated foreground launches

The M0 probe found the correct GUI source-handoff mechanism (see below), but its
validation method was rejected and must not be repeated.

- The probe launched the live foreground GUI repeatedly to run reliability passes.
  This stole window focus on a machine the user was actively using -- roughly two
  dozen pop-ups. That level of disruption is unacceptable, not a minor annoyance.
- Marking the probe task completed did not stop the agent process. It continued
  launching GUI windows after its answer was final.
- Rule going forward: no autonomous or automated step may launch a visible
  foreground GUI window. Routine validation is headless or offscreen: `swift test`,
  an offscreen `ImageRenderer`-based render harness for screenshots (WP-4b in the
  plan), and log/state assertions prove
  behavior without stealing focus. At most ONE visible GUI launch is allowed -- a
  final smoke test the human explicitly approves and runs. Agents hand it over as a
  copy-pasteable command and never run it themselves.
- Cross-reference: the plan's Fixed-constraints section ("Fixed (validation stays
  headless)") and WP-4b's `ImageRenderer`-based offscreen render harness both
  encode this rule.

The mechanism findings below (URL scheme, packaged `.app`, LaunchServices
registration, encoding/validation contract, the two log signals, auto-exit gating
fix) stand. Only the validation method is rejected.

## Selected mechanism

Custom URL scheme via SwiftUI `onOpenURL`:
`usbimager://open?source=<percent-encoded file URL>&autoExitAfter=<N>`.

The scheme carries query parameters, so it delivers the structured payload the
plan requires (a `source` plus an optional `autoExitAfterSeconds`) that bare
open-file delivery cannot. No fallback carrier was needed: the URL scheme
reached the dev bundle and delivered the payload once the artifact was a
packaged `.app` bundle registered with LaunchServices via a prior
`open <bundle>.app` (see "Artifact" and "LaunchServices registration" below).

## Exact artifact under test

The mechanism works only against a packaged `.app` bundle, not the bare
executable that `swift build` emits today.

- Current build output is a raw Mach-O executable at
  `.build/arm64-apple-macosx/debug/USBImagerApp`. A bare executable carries no
  `Info.plist`, so it has no `CFBundleURLTypes` and `open "usbimager://..."`
  cannot route to it.
- The probe built a minimal SwiftUI app (`HandoffSpike`), copied its executable
  into a hand-assembled bundle (`HandoffSpike.app/Contents/MacOS/HandoffSpike`),
  and added an `Info.plist` registering the `usbimager` scheme. `open` of the
  bundle launched it and `open` of the URL routed to it.

Consequence for later lanes: WP-2b/WP-4b must build and launch a `.app` bundle,
not the bare binary. The dev workflow needs a packaging step (assemble
`USBImagerApp.app` with an `Info.plist`) before the URL scheme can be exercised;
`build_debug.sh` and `capture_screenshot.sh` currently launch the bare binary
and will need that bundle step.

## LaunchServices registration (key finding, corrected)

The reliable registration step is `open <bundle>.app`: the first `open` of the
bundle teaches LaunchServices about its `CFBundleURLTypes` implicitly, after
which `open "usbimager://..."` routes to that bundle. This works for a bundle
under `/tmp` -- an earlier claim that LaunchServices refuses `/tmp` bundles was
wrong (see below). No `lsregister` and no code signing were required for the
local dev flow.

Required order (proven against the bundle at `/tmp/handoff_spike/HandoffSpike.app`):

1. `open /tmp/handoff_spike/HandoffSpike.app` -- registers the scheme + launches
   once; the window appears (`window: visible (RootView.onAppear)`).
2. `open "usbimager://open?source=<encoded>&autoExitAfter=4"` -- exit 0; the URL
   routes to the running bundle, which logs `received URL`, `preselected ...,
   step 2`, then schedules and fires the clean auto-exit quit.

Correction note: an initial probe attempt saw `open "usbimager://..."` fail with
`kLSApplicationNotFoundErr` (-10814) and `open -b <bundleid>` fail with
`LSCopyApplicationURLsForBundleIdentifier() failed`. That was a first-attempt
registration timing/ordering artifact -- the URL was issued before LaunchServices
finished indexing a freshly-copied bundle, with a competing second bundle copy in
play. Re-running the clean two-step `open <bundle>` then `open <url>` flow against
the `/tmp` bundle alone routed correctly (exit 0) and completed the full handoff.
The dev `.app` bundle does NOT have to live outside `/tmp`; the requirement is the
prior `open <bundle>` registration step, not the bundle's location.

Residual caution: if implicit `open`-based registration ever proves unreliable on
a given machine, the documented fallback is an explicit `lsregister -f <bundle>`
that the human runs (the permissions hook blocks the absolute `lsregister` binary
path for the agent). That explicit registration would then be a one-time
prerequisite for WP-2b/WP-4b. It was not needed here.

## CFBundleURLTypes / Info.plist registration

The bundle `Info.plist` needs this block to claim the scheme:

```xml
<key>CFBundleURLTypes</key>
<array>
	<dict>
		<key>CFBundleURLName</key>
		<string>com.nsh.usbimager.url</string>
		<key>CFBundleURLSchemes</key>
		<array>
			<string>usbimager</string>
		</array>
	</dict>
</array>
```

The bundle also needs the standard keys to be a launchable app:
`CFBundleExecutable`, `CFBundleIdentifier`, `CFBundlePackageType` (`APPL`),
`NSPrincipalClass` (`NSApplication`), `LSMinimumSystemVersion` (`26.0`).

## Encoding and validation contract

- The `source` is carried as a percent-encoded `file:` URL. The CLI builds it
  with `URL(fileURLWithPath:)` then percent-encodes the absolute URL string;
  the probe verified `python3` `Path(...).as_uri()` + full `quote(safe='')`
  produces a value the GUI accepts (for example
  `file%3A%2F%2F%2Ftmp%2Fhandoff_spike%2Ffixture.iso`).
- The GUI decodes with `URLComponents`, which percent-decodes query values, then
  `URL(string:)` and checks `isFileURL`. Only `file:`-backed sources are
  accepted; a non-file source is logged and ignored.
- A missing or unreadable source (checked with
  `FileManager.isReadableFile(atPath:)`) does not call `selectSource`: the GUI
  stays on step 1 and logs, with no hang or crash. Verified.
- `autoExitAfter` must parse as a positive `Double`; `0` or a non-numeric value
  is ignored (no timer scheduled). Verified with `autoExitAfter=0`.

## Two observable signals

Signal 1 (preselect, polled by WP-4b before screenshot capture). The handoff
handler emits exactly this stdout line once `selectSource` completes:

```
[USBImagerApp] handoff: preselected <path>, step 2
```

Signal 2 (window-visible trigger, used by WP-2b to gate the auto-exit timer).
`RootView`'s `.onAppear` proves the window is on screen and logs:

```
[USBImagerApp] window: visible (RootView.onAppear)
```

## Auto-exit timer gating (correction for WP-2b)

The timer must start when BOTH conditions hold, whichever completes last: the
source is preselected (`selectSource` ran) AND the window is visible
(`.onAppear` fired). The URL can arrive after the window is already on screen,
so `.onAppear` alone is not a sufficient trigger. The probe initially scheduled
only from `.onAppear`, the URL arrived later, and the timer never started.
The fix: both `.onAppear` and the `onOpenURL` handler call one idempotent
`startAutoExitIfReady()` that schedules at most once, only when source +
visibility are both satisfied. Without `autoExitAfter`, no timer is scheduled
and the window stays open. Verified end to end: timer scheduled then
`NSApplication.terminate` fired and the process exited cleanly.

## Fallback carrier

None. The URL scheme met every requirement, so no open-file fallback or
companion automation-parameter carrier (temp request file / pasteboard /
parameter-only URL) was selected.

## Verification commands and observed output

Build the spike and assemble the bundle:

- `swift build` in the spike package: `Build complete!`
- copy executable into `HandoffSpike.app/Contents/MacOS/`, add the
  `Info.plist` above.

Launch and deliver (`open <bundle>` first to register, then `open <url>`):

- `open <bundle>.app` -> window appears, logs
  `[USBImagerApp] window: visible (RootView.onAppear)`.
- `open "usbimager://open?source=file%3A%2F%2F%2Ftmp%2Fhandoff_spike%2Ffixture.iso&autoExitAfter=5"`
  -> exit 0; the running instance logs in order:

```
[USBImagerApp] handoff: received URL usbimager://open?source=...&autoExitAfter=5
[USBImagerApp] handoff: preselected /tmp/handoff_spike/fixture.iso, step 2
[USBImagerApp] auto-exit: scheduling clean quit in 5.0s
[USBImagerApp] auto-exit: terminating now (clean quit)
```

The process then exits on its own (confirmed: no matching process after ~9s).

Negative paths (missing source + `autoExitAfter=0`):

```
[USBImagerApp] handoff: source missing/unreadable: /tmp/handoff_spike/nope.iso; staying on step 1
[USBImagerApp] handoff: ignoring non-positive autoExitAfter: 0
```

No `selectSource`/preselect line, no timer, window stays open. Verified.

## Residual risks for WP-2b and WP-3e

- Packaging step required. WP-2b/WP-4b must produce and launch a real
  `USBImagerApp.app` bundle with the `CFBundleURLTypes` block; the bare
  `swift build` executable will not receive `usbimager://`. `build_debug.sh`
  and `capture_screenshot.sh` need a bundle-assembly step.
- LaunchServices registration step. Before issuing `usbimager://`, the bundle
  must be registered via a prior `open <bundle>.app` (implicit registration);
  the URL routes only after that. This works for a `/tmp` bundle -- no
  non-transient location and no code signing are required. Fallback if implicit
  registration is ever unreliable: a one-time human-run `lsregister -f <bundle>`
  (the agent's permissions hook blocks the absolute `lsregister` path).
- Stdout capture under `open`. When launched via `open`, the app's stdout is
  detached, so WP-4b cannot read the preselect line from the launching shell.
  The probe used a file sink to observe it; WP-4b needs a defined channel for
  the `[USBImagerApp]` line (launch the bundle executable with redirected
  stdout, read the unified log, or have the app also write a log file). The
  exact stdout-capture path for the screenshot script is WP-4b's to pin down.
- Timer gating ordering. WP-2b must gate the auto-exit timer on source +
  window-visible (whichever is last), not on `.onAppear` alone (see above).

## Spike location

Throwaway spike package: `/tmp/handoff_spike/` (`Package.swift`,
`Sources/HandoffSpike/HandoffSpike.swift`, hand-assembled `HandoffSpike.app`,
`fixture.iso`, `spike.log`). A copy of the bundle was placed in the repo at
`_spike_scratch/` to clear the LaunchServices `/tmp` constraint; it is
git-ignored (`.gitignore` `_spike_scratch/`) and is safe to delete.
