# ROADMAP.md

Phased plan to take swift-usb-imager from "builds and tests pass, navigable up
to the flash step" to "flashes a real disk, signed and distributable." The app
builds and the suite passes (357 tests), but flashing is not yet operational.

For the flat backlog, see [TODO.md](TODO.md).

## Phase 1: preliminary commit (now)

Commit the reviewed in-progress work: the library modules, SwiftUI app, and
`usbimager` CLI; the six-pass audit fixes; and the authopen research spike
(non-production, not wired into the flash path). This phase captures honest
in-progress state. No backend is committed and flashing does not work yet.

## Phase 2: decide the privilege model (critical-path gate, human-run)

This is the decisive gate. Everything downstream depends on its outcome.

Run the hardware lane on a real Apple Silicon Mac with a sacrificial USB and a
Developer ID identity, following
[active_plans/decisions/authopen_hardware_runbook.md](active_plans/decisions/authopen_hardware_runbook.md):
B1 (authopen raw-device write across three launch contexts), B2 (the decisive
Full Disk Access attribution measurement in an installed signed app), and B3
(unmount + exclusivity matrix). The results lift the PENDING verdict in
[active_plans/decisions/raw_disk_write_model.md](active_plans/decisions/raw_disk_write_model.md)
and pick the backend: least-persistent authopen if the installed-app context
passes, otherwise the SMAppService LaunchDaemon fallback.

This phase needs hardware and a human operator; it cannot be completed from the
build alone.

## Phase 3: implement the chosen write backend and wire the flash path

After the Phase 2 verdict:

- Implement the chosen backend behind the swappable
  `RawDiskWriteAuthorization` / `AuthorizedRawDiskTarget` boundary
  ([active_plans/decisions/rawdiskopener_design.md](active_plans/decisions/rawdiskopener_design.md)),
  so the byte-streaming write loop never special-cases the backend.
- Wire the privileged flash path: add the XPC daemon target with its
  `NSXPCListener`, enforce the helper peer identity app-side, thread the live
  audit token into `authorize(auditToken:)`, and add SMAppService install +
  app-quit teardown per [SIGNING.md](SIGNING.md).
- Wire the byte-streaming write loop to the passed fd and confirm an end-to-end
  flash against a sacrificial USB.

## Phase 4: finish UI and code-quality polish

Complete the UI and code-quality work packages that need no hardware:
keyboard-accessible disk rows and tab order, `os.Logger` in the app lifecycle,
hash-mismatch failure state, glass tint/backdrop refinement, source
drag-and-drop, empty-state and safety hints, live checksum feedback, and the
remaining force-unwrap fallback. Also the review follow-ups: test fragility
cleanup and stripping residual planning tags from comments. Much of this can
proceed in parallel with Phases 2-3 since it does not depend on the backend.

## Phase 5: signing and distribution

- Developer ID sign and notarize the app and the privileged helper.
- Decide the distribution channel (owner: user): direct-download Developer ID
  app vs Mac App Store. App Store distribution likely cannot perform raw disk
  writing or privilege escalation; treat this as a distinct distribution
  decision separate from the backend choice.

## Not started yet

- No production backend is selected or implemented; the verdict is pending the
  Phase 2 hardware run.
- The XPC daemon executable target, helper peer pinning, audit-token threading,
  and SMAppService registration are not wired.
- The byte-streaming write loop is not connected to a privileged fd.
- No Developer ID signing or notarization has been done.
- The distribution channel is undecided.
