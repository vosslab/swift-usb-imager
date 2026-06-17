# Code architecture

Swift USB Imager is a native macOS SwiftUI application (macOS 26 / Tahoe) that
writes disk images to removable USB media using a two-process privilege-separation
design. The unprivileged app and the root-level helper communicate through a
named Mach service (NSXPCConnection); image bytes never travel over XPC.

---

## Layered design

```
+----------------------------------------------------------+
|  USBImagerApp  (AppUI + @main)  -- unprivileged app      |
|  AppViewModel  @Observable @MainActor state machine      |
|  SwiftUI: SourcePanel  TargetPanel  FlashPanel  VerifyPanel |
+----------------------------------------------------------+
                      |
         DiskModel    |    KeychainStore    Verifier
         (enumerate   |    (trusted         (SHA-512
          + filter)   |     checksum cache)  streaming)
                      |
            FlashEngine (actor)
            HelperProtocol (shared XPC contract, JSON-Data)
                      |
              XPC / NSXPCConnection
              (named Mach service)
                      |
+----------------------------------------------------------+
|  PrivilegedHelper  -- root LaunchDaemon (SMAppService)   |
|  HelperService (NSObject, HelperXPCProtocol)             |
|  auth stub -> HelperSafety -> Unmount -> WriteJob -> VerifyJob |
+----------------------------------------------------------+
```

Elevation model: the helper is installed once via SMAppService. Per-job
authorization is stubbed today; the signing milestone wires SecCode peer
pinning and an AuthorizationRef right before any destructive action.

---

## Four-step data flow

```
Step 1 - Select source
  User picks .iso/.img via fileImporter
  AppViewModel stats the file -> sourceImageBytes
  DiskEnumerator refreshes the live disk list
  DiskSafety filters to validTargets (removable, external, < 450 GB, ...)

Step 2 - Select target
  User picks from availableTargets (safe disks only)
  User optionally pastes a SHA-512 hex or loads a SHA512SUMS file
  ChecksumFile or validatePastedHex parses -> expectedDigest
  KeychainStore is queried for a prior trusted hit

Step 3 - Flash
  AppViewModel calls FlashEngine.flash(source:target:advisorySHA512:)
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

| Module | Process | Role |
| --- | --- | --- |
| DiskModel | App | DiskArbitration/IOKit enumeration; DiskDescriptor value type; DiskSafety predicates (8 RejectionReasons, 450 GB cap); DiskEnumerator AsyncStream of disk events; DiskIdentity BSD-name helpers |
| HelperProtocol | Both | Shared XPC @objc protocol (HelperXPCProtocol); Codable control-plane types (FlashRequest, FlashProgress, FlashResult, JobID, SourceAccess, FlashOutcome); JSON-Data marshalling helpers; CodeSigningRequirement |
| Verifier | Both | CryptoKit SHA-512 streaming (SHA512Hasher, SHA512Digest); one-shot sha512(of:); ChecksumFile SHA512SUMS parser; validatePastedHex; MatchResult; ChecksumFileError |
| KeychainStore | App | Trusted-checksum cache backed by Keychain Services; KeychainBackend protocol for DI; InMemoryKeychainBackend for tests; TrustedChecksum (sha512 + imageByteLength match key) |
| FlashEngine | App | FlashEngine actor; HelperConnection protocol + XPCHelperConnection; FlashEngineError; AsyncStream<FlashProgress> relay; cancel forwarding |
| AppUI | App | AppViewModel @Observable @MainActor state machine; FlashState enum (9 cases); FlashProgressSnapshot; ChecksumMatchOutcome; OfficialChecksumSource; four SwiftUI panels (SourcePanel, TargetPanel, FlashPanel, VerifyPanel); RootView GlassEffectContainer; StyleHelpers (Liquid Glass modifiers, layout constants) |
| USBImagerApp | App | `AppEntry` (@main, parses launch args via swift-argument-parser); `LaunchOptions` (ParsableArguments: --source, --auto-exit); `AppDelegate` (AppKit startup-window fix for --source PATH space-form hang); wires production XPCHelperConnection + AppViewModel |
| PrivilegedHelper | Helper | HelperService NSObject (HelperXPCProtocol); HelperAuthorization (pluggable, stub today); HelperSafety independent re-check; Unmount (diskutil + eject); WriteJob (raw block-aligned write, F_NOCACHE, DKIOCGETBLOCKSIZE); VerifyJob (read-back SHA-512); CancellationToken; BlockMath; HelperErrors |

---

## Dependency graph

```
USBImagerApp -> AppUI -> FlashEngine -> HelperProtocol
                      -> DiskModel
                      -> Verifier
                      -> KeychainStore -> Verifier
             -> ArgumentParser (swift-argument-parser, external)

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

## What is not yet wired

- SMAppService registration and the root LaunchDaemon plist.
- Real SecCode + AuthorizationRef peer pinning in HelperAuthorization.
- Mach service name and code-signing requirement constants (placeholders in USBImagerApp).
- File-descriptor and staged-copy SourceAccess variants (SourceAccess enum shape is final; only .absolutePath executes today).
