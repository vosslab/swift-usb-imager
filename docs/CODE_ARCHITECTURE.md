# Code architecture

Swift USB Imager is a native macOS SwiftUI application (macOS 26 / Tahoe) that
writes disk images to removable USB media using a two-process privilege-separation
design. The unprivileged app and the root-level helper communicate through a
named Mach service (NSXPCConnection); image bytes never travel over XPC.

The GUI (`USBImagerApp`) is the primary product. A thin terminal CLI (`usbimager`,
product `USBImagerCLI`) provides the same four-step workflow headlessly through
`USBImagerCore`, the shared GUI-independent seam.

---

## Layered design

```
+---------------------------------------------------------------+
|  USBImagerApp  (@main struct USBImagerApp: App)               |
|  SwiftUI: SourcePanel  TargetPanel  FlashPanel  VerifyPanel   |
|  AppViewModel @Observable @MainActor state machine            |
|  URL-scheme handoff (usbimager://open?...) + AutoExitCoordinator|
+---------------------------------------------------------------+
           |                              |
           v                             |
   USBImagerCore (Library)               |
   ChecksumService  ImageSourceService   |
   DiskTargetService  FlashOrchestrationService
   XPCFlashEngineFactory                 |
   CoreError / CoreExitCode              |
   FlashProgressData                     |
           |                             |
   DiskModel    Verifier    KeychainStore  FlashEngine
                                         |
                              HelperProtocol (shared XPC contract)
                                         |
                              XPC / NSXPCConnection
                              (Mach service: com.nsh.usbimager.helper)
                                         |
+---------------------------------------------------------------+
|  PrivilegedHelper  -- root LaunchDaemon (SMAppService)        |
|  HelperService (NSObject, HelperXPCProtocol)                  |
|  HelperSafety -> Unmount -> WriteJob -> VerifyJob             |
+---------------------------------------------------------------+

+---------------------------------------------------------------+
|  USBImagerCLI (executable "usbimager")                        |
|  Subcommands: list / verify / flash / open                    |
|  Depends on USBImagerCore + ArgumentParser only               |
+---------------------------------------------------------------+

+---------------------------------------------------------------+
|  USBImagerShots (executable)                                  |
|  Offscreen ImageRenderer screenshot harness                   |
|  Depends on AppUI + USBImagerCore + DiskModel                 |
+---------------------------------------------------------------+
```

Elevation model: the helper is installed once via SMAppService. Per-job
authorization is stubbed today; the signing milestone wires SecCode peer
pinning and an AuthorizationRef right before any destructive action.

---

## Four-step data flow

```
Step 1 - Select source
  User picks .iso/.img via fileImporter (GUI) or supplies --source PATH (CLI)
  AppViewModel stats the file -> sourceImageBytes
  DiskEnumerator refreshes the live disk list
  DiskSafety filters to validTargets (removable, external, < 450 GB, ...)

Step 2 - Select target
  User picks from availableTargets (safe disks only)
  User optionally pastes a SHA-512 hex or loads a SHA512SUMS file
  ChecksumFile or validatePastedHex parses -> expectedDigest
  KeychainStore is queried for a prior trusted hit

Step 3 - Flash
  AppViewModel (GUI) / FlashCommand (CLI) calls FlashOrchestrationService.flash()
  FlashOrchestrationService calls FlashEngine.flash(source:target:advisorySHA512:)
  FlashEngine builds FlashRequest (paths only, no image bytes)
  XPC: HelperService.flash(requestData:progress:result:)
  Helper:
    1. HelperAuthorization.authorize()  (stub -> allow)
    2. HelperSafety.validatedTarget()   (independent re-check, ground-truth size)
    3. Unmount.unmountWholeDisk()       (diskutil unmountDisk force)
    4. WriteJob.run()                   (O_RDWR|O_SYNC|O_EXCL|F_NOCACHE,
                                         block-aligned chunks, SHA-512 of bytes written)
    5. VerifyJob.run()                  (re-open O_RDONLY|F_NOCACHE, read back,
                                         SHA-512 of image-length bytes)
    6. digest compare; eject on success
  FlashProgress events streamed back; FlashEngine yields them on progressStream

Step 4 - Verify result
  FlashResult.deviceSHA512 compared to expectedDigest (official) or Keychain cache
  ChecksumMatchOutcome: officialMatch | officialMismatch | trustedCacheHit | noOfficialChecksum
  On officialMatch: KeychainStore.save() caches the trusted checksum
  VerifyPanel shows device SHA-512 (selectable text) + match badge; "Start over" resets
```

---

## Security posture

XPC carries control data only (job IDs, progress fractions, result digests).
The image file path is sent to the helper; the helper opens the file itself as
root. Gigabytes of image bytes never cross the XPC transport.

The helper re-derives every safety value from ground truth:
- Image length: stat(2) on the opened file (not advisorySizeBytes from the request).
- Safety check: HelperSafety calls DiskSafety.rejectionReasons independently, so
  a compromised app cannot bypass the size/system/TimeMachine exclusions.
- Digest: VerifyJob re-reads the device after the write; the returned
  deviceSHA512 is not the source digest forwarded from the app.

Keychain (KeychainStore) stores user-approved SHA-512 digests so re-flashing
the same image auto-matches without re-prompting. Elevation state is never stored
in the Keychain.

The authorization gate (HelperAuthorization) is a pluggable decision point.
The current stub allows all callers; the signing milestone replaces it with
SecCode peer pinning (CodeSigningRequirement) and an AuthorizationRef right.

---

## Module table

| Module | Product kind | Process | Role |
| --- | --- | --- | --- |
| DiskModel | Library | App | DiskArbitration/IOKit enumeration; DiskDescriptor value type; DiskSafety predicates (8 RejectionReasons, 450 GB cap); DiskEnumerator AsyncStream of disk events; DiskIdentity BSD-name helpers |
| HelperProtocol | Library | Both | Shared XPC @objc protocol (HelperXPCProtocol); Codable control-plane types (FlashRequest, FlashProgress, FlashResult, JobID, SourceAccess, FlashOutcome); JSON-Data marshalling helpers; CodeSigningRequirement |
| Verifier | Library | Both | CryptoKit SHA-512 streaming (SHA512Hasher, SHA512Digest); one-shot sha512(of:); ChecksumFile SHA512SUMS parser; validatePastedHex; MatchResult; ChecksumFileError |
| KeychainStore | Library | App | Trusted-checksum cache backed by Keychain Services; KeychainBackend protocol for DI; InMemoryKeychainBackend for tests; TrustedChecksum (sha512 + imageByteLength match key) |
| FlashEngine | Library | App | FlashEngine actor; HelperConnection protocol + XPCHelperConnection; FlashEngineError; AsyncStream<FlashProgress> relay; cancel forwarding |
| USBImagerCore | Library | App/CLI | GUI-independent workflow seam. Service protocols: ChecksumService, ImageSourceService, DiskTargetService, FlashOrchestrationService. FlashEngineFactory / XPCFlashEngineFactory. CoreError / CoreExitCode. FlashProgressData. Helper identity constants (Mach service name + designated requirement). No SwiftUI/AppKit. Depends on DiskModel, Verifier, FlashEngine, KeychainStore, HelperProtocol. |
| AppUI | Library | App | AppViewModel @Observable @MainActor state machine; FlashState enum (9 cases); FlashProgressSnapshot; four SwiftUI panels (SourcePanel, TargetPanel, FlashPanel, VerifyPanel); RootView GlassEffectContainer; StyleHelpers (Liquid Glass modifiers, documentationRender flag, layout constants). Depends on USBImagerCore. |
| USBImagerApp | Executable | App | `@main struct USBImagerApp: App`; constructs AppViewModel wired to production XPC helper; receives source handoff via `.onOpenURL` (URL scheme `usbimager://open?source=...&autoExitAfter=N`); `decodeHandoff` decodes and validates; `AutoExitCoordinator` gates the clean-quit timer on both source-preselected and window-visible; Info.plist declares CFBundleURLTypes; bundle assembled by `build_debug.sh`. |
| PrivilegedHelper | Library | Helper | HelperService NSObject (HelperXPCProtocol); HelperAuthorization (pluggable, stub today); HelperSafety independent re-check; Unmount (diskutil + eject); WriteJob (raw block-aligned write, F_NOCACHE, DKIOCGETBLOCKSIZE); VerifyJob (read-back SHA-512); CancellationToken; BlockMath; HelperErrors |
| USBImagerCLI | Executable ("usbimager") | App | Thin terminal CLI. Subcommands: `list`, `verify`, `flash`, `open`. CoreServices injectable seam (test override via `Usbimager.servicesOverride`). Shared exit path maps CoreError -> CoreExitCode -> process status. Depends on USBImagerCore + ArgumentParser only; no direct FlashEngine/DiskModel/AppUI imports. |
| USBImagerShots | Executable | App | Offscreen screenshot render harness. Builds AppViewModel with injected fake services; renders RootView to PNG via ImageRenderer with `documentationRender = true` (solid card, no Liquid Glass); sets `NSApplication.activationPolicy(.prohibited)` (no visible window). Depends on AppUI, USBImagerCore, DiskModel. |
| AuthopenProbeCore | Library | n/a (spike) | NON-PRODUCTION research spike. Pure (hardware-free) authopen preflight decision logic; fixture-tested by AuthopenProbeCoreTests. Not imported by any app/CLI/helper target. See the spike callout below. |
| authopen_fd_probe | Executable | n/a (spike) | NON-PRODUCTION research spike under `tools/authopen_fd_probe/`. Standalone SCM_RIGHTS fd-passing harness (`selftest` mode); depends only on AuthopenProbeCore. Not wired into the flash path. |

---

## Dependency graph

```
USBImagerApp -> AppUI -> USBImagerCore -> FlashEngine -> HelperProtocol
                                      -> DiskModel
                                      -> Verifier
                                      -> KeychainStore -> Verifier
                      -> FlashEngine (direct, for XPCHelperConnection)
                      -> DiskModel   (direct)
                      -> KeychainStore (direct)
             -> ArgumentParser (swift-argument-parser, external)

USBImagerCLI -> USBImagerCore
             -> ArgumentParser

USBImagerShots -> AppUI
              -> USBImagerCore
              -> DiskModel

PrivilegedHelper -> HelperProtocol
                 -> DiskModel
                 -> Verifier

HelperProtocol  (no repo-local deps)
DiskModel       (no repo-local deps)
Verifier        (no repo-local deps)
KeychainStore -> Verifier
```

---

## Threading model

- AppViewModel: @MainActor; all observable state on the main thread.
- FlashEngine: Swift actor; XPC callbacks hop in via Task { await }.
- HelperService: NSObject (no actor isolation); per-job work dispatched to a
  background DispatchQueue; cancel tokens guarded by NSLock.
- DiskEnumerator: AsyncStream<DiskEvent> bridged from DiskArbitration callbacks.

---

## CLI exit-code contract

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Verification mismatch |
| 2 | Bad input / usage |
| 3 | Privileged helper unavailable or not approved |
| 4 | Flash failed mid-write |
| 5 | Operation cancelled |
| 6 | GUI app binary/bundle not locatable (open subcommand) |

The mapping is frozen in `CoreExitCode` (Sources/USBImagerCore/CoreError.swift);
no subcommand invents its own numbers.

---

## What is not yet wired

- SMAppService registration and the root LaunchDaemon plist.
- Real SecCode + AuthorizationRef peer pinning in HelperAuthorization (stub allows all callers).
- File-descriptor and staged-copy SourceAccess variants (SourceAccess enum shape is final;
  only .absolutePath executes today).

---

## Research spike: authopen raw-disk-write investigation (NON-PRODUCTION)

`AuthopenProbeCore` (library) and `authopen_fd_probe` (executable, under
`tools/authopen_fd_probe/`), plus their `AuthopenProbeCoreTests` target, are
research/spike targets for the authopen raw-disk-write investigation. They are
NOT part of the shipping flash path: no production target imports them, and the
flash data flow above does not touch them.

The spike evaluates a least-persistent privileged backend (authopen over
SCM_RIGHTS) for opening one `/dev/rdiskN` for writing, as an alternative to the
SMAppService LaunchDaemon. `AuthopenProbeCore` holds the pure, hardware-free
preflight decision logic so its accept/refuse behavior can be unit-tested against
saved fixtures with no real USB. The verdict is PENDING a hardware run; until then
no production code commits to a backend. See the decision record at
[active_plans/decisions/raw_disk_write_model.md](active_plans/decisions/raw_disk_write_model.md).
