# TODO.md

Remaining work before swift-usb-imager can flash a real disk. The library
modules, SwiftUI app, and `usbimager` CLI build and pass the test suite
(357 tests), and both front ends are usable up to the flash step. Flashing is
not yet operational. Items are grouped by theme, most-blocking first.

For phasing and the critical-path gate, see [ROADMAP.md](ROADMAP.md).

## Critical: the flash path cannot run yet

- Wire the privileged write path. Today a flash attempt fails at connection
  time (CLI exit 4, flash failed): the Mach service `com.nsh.usbimager.helper`
  is never registered. See
  [active_plans/audits/wp_helper_path_findings.md](active_plans/audits/wp_helper_path_findings.md).
- Add the XPC daemon executable target. `PrivilegedHelper` is a library with no
  `main.swift` and no `NSXPCListener`; add a thin daemon target that vends
  `HelperService.production(requirement:)` over a listener on
  `com.nsh.usbimager.helper`.
- Enforce the helper peer identity app-side. Remove the
  `_ = peerRequirement` discard in `Sources/FlashEngine/HelperConnection.swift`
  and pin the connection via `setCodeSigningRequirement`.
- Thread the live audit token into the helper's `authorize(auditToken:)`. The
  token-less `authorize()` calls fail closed under the production pinning gate.
- Add SMAppService install + teardown: `SMPrivilegedExecutables` in the app
  Info.plist, the bundled launchd plist, `SMAppService.daemon(...).register()`,
  and an `applicationWillTerminate` `unregister()` so nothing privileged
  outlives the app. Follow [SIGNING.md](SIGNING.md) as the source of truth.
- Developer ID signing of the app and helper (required before any privileged
  run). See [SIGNING.md](SIGNING.md).

## Critical: the privilege model is undecided (hardware gate)

- The raw-disk-write authorization model is NOT decided. The verdict is PENDING
  a hardware run. See
  [active_plans/decisions/raw_disk_write_model.md](active_plans/decisions/raw_disk_write_model.md).
- Run the hardware lane on a real Apple Silicon Mac with a sacrificial USB and a
  Developer ID identity. Procedure:
  [active_plans/decisions/authopen_hardware_runbook.md](active_plans/decisions/authopen_hardware_runbook.md).
  - B1: authopen raw-device write across the three launch contexts (Xcode,
    Terminal, installed signed app).
  - B2 (decisive): Full Disk Access attribution in the installed signed app --
    does one app-level FDA grant authorize the authopen child's raw write.
  - B3: unmount viability + the open exclusivity matrix.
- After the verdict: implement the chosen backend behind the swappable
  `RawDiskWriteAuthorization` / `AuthorizedRawDiskTarget` boundary (see
  [active_plans/decisions/rawdiskopener_design.md](active_plans/decisions/rawdiskopener_design.md)),
  then wire the byte-streaming write loop to the passed fd.

## UI and code quality (no hardware needed)

- Keyboard-accessible Button disk rows in the Target panel.
- Complete the keyboard tab order across panels.
- Replace remaining `print()` with `os.Logger` in the app lifecycle.
- Treat a hash mismatch as a failure state in the UI flow.
- Keep the semantic glass tint in place.
- Tame the glass backdrop and shadows.
- Source drag-and-drop plus a clickable source field.
- Empty-state and safety hints in the layout.
- Live checksum validation feedback as the user enters a digest.
- Replace the remaining unsafe `UTType` force-unwrap with a graceful fallback.

## Review follow-ups (six-pass audit)

- Test fragility cleanup: drop assertions on exact user-facing strings, remove
  redundant raw exit-code assertions, fix a tautological assertion, remove a
  `try!` in a fixture, and address silently-skipped DiskArbitration-dependent
  tests.
- Strip residual planning tags from a couple of code comments (TargetPanel,
  StyleHelpers).

## Distribution decision (owner: user)

- Decide direct-download Developer ID app (authopen is a candidate backend) vs
  Mac App Store (raw disk writing plus privilege escalation is likely not
  viable there). This is a distinct distribution decision, separate from the
  authopen-vs-SMAppService technical choice.
