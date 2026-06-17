## 2026-06-17

### Additions and New Features

- Added `Sources/AppUI/ByteFormatting.swift` with a single shared
  `formatBytes<Integer: BinaryInteger>(_:)` decimal-SI byte formatter for the AppUI
  module, consolidating three byte-identical copies into one helper (see Fixes).
- Added `AppViewModel.setOfficialChecksumFile(at:)` to `Sources/AppUI/AppViewModel.swift`:
  reads the SHA512SUMS file body in the view model so a read failure surfaces as
  `checksumInputError` ("Could not read the checksum file.") with `expectedDigest` left
  nil, then delegates to the existing `setOfficialChecksum(.sha512SumsFile(body:))`
  parse/match path. Added one `tests/AppUITests/AppViewModelTests.swift` test asserting a
  nonexistent checksum-file URL sets `checksumInputError` and leaves `expectedDigest` nil.
- Added nine `FlashState.currentStep` tests covering all enum cases (idle->1,
  sourceSelected->2, targetSelected->3, confirming->3, flashing->3, verifying->4,
  succeeded->4, failed->4, cancelled->4) to `tests/AppUITests/AppViewModelTests.swift`.

### Behavior or Interface Changes

- `Sources/USBImagerApp/USBImagerApp.swift`: removed the `AppDelegate`
  (`@NSApplicationDelegateAdaptor`) AppKit window-creation workaround and standardized the
  debug source flag on the equals form (`--source=PATH`). The delegate was a locale-fragile
  symptom patch for the space-form `--source PATH` hang (AppKit routed the trailing path
  through `application(_:openFiles:)` and suppressed the WindowGroup window, so the delegate
  force-triggered SwiftUI's "New Window" command). Since `--source`/`--auto-exit` are
  debug/testing conveniences for a GUI-first app, the durable fix is the `=` form, which
  swift-argument-parser consumes before AppKit sees it. Idle launch creates its window
  normally via SwiftUI, as before the delegate existed. Updated the file-header and
  `LaunchOptions` doc/help to document `--source=PATH` and note the flags are debug-only.
  `capture_screenshot.sh` now uses `--source=~/Downloads/...`. Verified: `./build_debug.sh`
  -> `Build complete!` (no new warnings); `swift test` -> 213 tests in 48 suites passed;
  equals-form watchdog (`--auto-exit=3 --source=...`) and idle watchdog (`--auto-exit=3`)
  both create a window and auto-exit (process gone, no window-fix diagnostics);
  `capture_screenshot.sh` writes non-empty `screenshots/main_window.png` and
  `screenshots/step2_target.png`.

- `Sources/AppUI/TargetPanel.swift`: the SHA512SUMS `.fileImporter` success handler now
  calls `vm.setOfficialChecksumFile(at: url)` instead of reading the file with
  `try? String(contentsOf:) ?? ""`, so a failed read is reported to the user rather than
  silently passed on as an empty body (fix the design, not the symptom).

- `docs/USAGE.md`: updated unit-test count from 191 to 203; added `--source PATH`,
  `--auto-exit SECONDS`, and `-h`/`--help` launch-flag documentation; added note about
  `capture_screenshot.sh` and `screenshots/main_window.png`.
- `docs/INSTALL.md`: replaced the "no additional Swift dependencies" line with accurate
  statement that SwiftPM resolves `swift-argument-parser` (1.3.0+) on first build.
- `docs/CODE_ARCHITECTURE.md`: updated `USBImagerApp` module-table row to name `AppEntry`,
  `LaunchOptions`, and `AppDelegate`; added external `ArgumentParser` edge in dependency graph.
- `README.md`: updated test count from 191 to 203.
- `Sources/AppUI/RootView.swift`: renamed private computed property `targetDivider` to
  `panelDivider` (it sits between all four panels, not just source/target); updated three use sites.
- `Sources/USBImagerApp/USBImagerApp.swift`: rewrote `AppDelegate` doc comment to clarify that
  only the space-form `--source PATH` triggers the AppKit openFiles hang (not `--source=PATH`);
  rewrote `findNewWindowMenuItem` comment to match what the code actually does (scans all top-level
  menus, not just File menu); rewrote `applicationShouldOpenUntitledFile` comment to not
  misattribute window creation (actual window creation is in `ensureWindowVisible()`).

### Fixes and Maintenance

- `Sources/AppUI/StyleHelpers.swift`: removed dead `PanelMetrics.buttonCornerRadius` (zero
  references in Sources/).
- Removed three byte-identical decimal-SI byte formatters and routed all call sites through the
  new shared `formatBytes(_:)`: the free `formatBytes(_ Int)` in `StyleHelpers.swift`,
  `FlashProgressSnapshot.formatBytes(_ UInt64)` in `FlashState.swift` (now used by
  `speedLabel`/`transferLabel`), and `AppViewModel.formatDiskSize(_ Int)` (now used by
  `displayName(for:)`). Output is byte-for-byte unchanged; existing label and disk-size tests
  still pass.
- `Sources/AppUI/FlashPanel.swift`: removed dead `isEnabled` computed property (zero references);
  fixed cancel handler to bind `_` for the sourceURL pattern value instead of `let sourceURL`
  with a discarded `_ = sourceURL` line.
- `Sources/AppUI/VerifyPanel.swift`: removed dead `isEnabled` computed property (zero references).
- `Sources/AppUI/AppViewModel.swift`: fixed `startFlash()` to bind `_` for targetInfo in the
  `.confirming` pattern match instead of `let targetInfo` with a discarded `_ = targetInfo` line.
- `docs/CHANGELOG.md`: appended parenthetical to the 2026-06-16 `--auto-exit` bullet noting
  the default and optional-value form were later changed (see 2026-06-17 entry).

- Added the `swift-argument-parser` package dependency (1.3.0+) to the `USBImagerApp` executable
  target in `Package.swift`.

### Behavior or Interface Changes

- Refactored launch-argument parsing from a hand-rolled parser to Apple's swift-argument-parser.
  `AppEntry.main()` now parses a `LaunchOptions: ParsableArguments` (optional `--source`, optional
  `--auto-exit`) via `parseOrExit()`, which supplies `--help` and validation. The app stays
  GUI-first (no required args). `--auto-exit` now REQUIRES a value (`--auto-exit=5` or
  `--auto-exit 5`); bare `--auto-exit` is no longer accepted. `capture_screenshot.sh` updated to
  `--auto-exit=5`.

### Fixes and Maintenance

- Simplified `capture_screenshot.sh` to a local-only developer helper: replaced
  `killall USBImagerApp` with `pkill USBImagerApp`, removed `swift build --show-bin-path`
  (used literal relative path `.build/arm64-apple-macosx/debug/USBImagerApp` instead),
  removed `git rev-parse --show-toplevel` (hard-coded local repo path), and removed `nohup`.
  Script now runs without triggering manual command-approval prompts.

- Fixed a `--source PATH` (space-form) startup hang in `Sources/USBImagerApp/USBImagerApp.swift`:
  a trailing path argument made AppKit route the path through `application(_:openFiles:)` so
  SwiftUI created zero WindowGroup windows, and RootView's `.task` blocks (the `--source`
  preselect and `--auto-exit` timer) never ran. An `NSApplicationDelegate` (attached via
  `@NSApplicationDelegateAdaptor`) now detects the no-window case after launch and triggers
  SwiftUI's "New Window" command so the window appears; the idle launch path is unchanged.
  Verified by a process-liveness watchdog (space-form `--source --auto-exit=3` exits in ~3s;
  idle exits) plus log lines. Verification: `swift build` -> `Build complete!`; `swift test` ->
  203 tests in 47 suites passed.

## 2026-06-16

### Behavior or Interface Changes

- `Sources/AppUI/StyleHelpers.swift`: redesigned the active-panel focus to a
  Liquid-Glass-native treatment. The focused card uses brighter `.regular.interactive()` glass,
  a thin white edge highlight, a soft blurred white glow, a whisper of accent-colored shadow,
  and a strong black drop shadow with ~1.025 lift; unfocused panels recede (opacity 0.74, reduced
  saturation, slight negative brightness, small grounding shadow). Replaces the earlier hard white
  inset frame so the active step reads as a lit glass card lifted toward the user, not a bordered
  box. Per-step accent (purple/blue/teal/green) stays in the panel icon and step badge.
  `PanelMetrics.cardCornerRadius` changed from 20 to 22.

- `build_debug.sh` and `build_release.sh`: replaced fragile `find -perm +0111`
  scan with a direct check for the known product binary `USBImagerApp` in the
  SwiftPM bin path. Both scripts now print `Executable: <full path>` after a
  successful build instead of the false "library-only package" message.

- `Sources/PrivilegedHelper/HelperService.swift`: introduced `TokenRegistry`
  actor to own the per-job `cancelTokens` dictionary. Removed the `NSLock` +
  mutable dictionary from `HelperService` and changed the conformance from
  `@unchecked Sendable` to plain `Sendable`. The synchronous `cancel(jobIDData:)`
  @objc method uses a fire-and-forget `Task { await registry.token(for:) }` to
  retrieve the token before calling `cancel()`, which is sound because
  `CancellationToken.cancel()` is already thread-safe and XPC cancel is
  best-effort. The `verify` method was also migrated from a raw `workQueue.async`
  block to a `Task + withCheckedContinuation` pattern to permit the actor `await`.
  No external behaviour or cancellation contract changed.

### Additions and New Features

- Added a `--auto-exit[=SECONDS]` launch flag (also `--auto-exit SECONDS`; default 30s) to
  `Sources/USBImagerApp/USBImagerApp.swift`; the app quits itself after the delay via a `.task`
  calling `NSApplication.shared.terminate(nil)`. Useful for non-interactive screenshot automation.
  (Note: the default 30s and optional-value form were later changed; bare `--auto-exit` now
  requires a value -- see the 2026-06-17 entry.)
- Added `-h`/`--help` usage output: a new `@main enum AppEntry` prints usage and exits before
  launching the GUI; `USBImagerApp` is now a plain `App` whose synthesized entry runs on normal
  launch. Verified: `swift build` -> `Build complete!`; `swift test` -> 203 tests in 47 suites
  passed.

- Added `docs/SIGNING.md`: full runbook for Developer ID signing, SMAppService
  privileged helper embedding, designated requirement pinning, entitlements,
  bundle layout, and the notarize+staple flow. All identity-dependent steps
  are marked TODO.
- Added `scripts/build_bundle.sh`: skeleton that builds SwiftPM release
  binaries (arm64) and assembles the `dist/USBImagerApp.app` bundle directory,
  including the helper executable under `Contents/Library/LaunchDaemons/`.
- Added `scripts/sign_app.sh`: skeleton that signs the helper, then the app
  executable, then the outer bundle in correct order using `codesign
  --options runtime`; identity is a TODO placeholder.
- Added `scripts/notarize.sh`: skeleton that zips the signed bundle, submits
  to `notarytool`, waits for acceptance, staples the ticket, and validates
  via `spctl`; keychain profile is a TODO placeholder.

- Added `Sources/USBImagerApp/USBImagerApp.swift`: `@main struct USBImagerApp: App` entry
  point. Constructs `AppViewModel` via the production convenience init wired to
  `XPCHelperConnection(machServiceName:peerRequirement:)` using placeholder constants
  `"com.nsh.usbimager.helper"` (Mach service name) and an `anchor apple generic` designated
  requirement. Presents `RootView(vm:)` inside a `WindowGroup` with `.windowResizability(.contentMinSize)`.
  TODO comments call out the two placeholder values to replace during the signing phase.
- Extended `Package.swift` with `.executableTarget(name: "USBImagerApp", ...)` depending on
  `["AppUI", "FlashEngine", "DiskModel", "KeychainStore"]` and a matching
  `.executable(name: "USBImagerApp", ...)` product. All existing targets unchanged.
  `swift build` reports `Build complete!` in 0.62 s.

- Added five SwiftUI view files under `Sources/AppUI/` implementing the four-panel
  Etcher-style USB imager UI, verified with `swift build`:
  - `Sources/AppUI/StyleHelpers.swift`: `PanelMetrics` layout constants, `PanelCardModifier`
    applying `glassEffect(in: .rect(cornerRadius:))` as `.panelCard()`, `PanelHeader` numbered
    step badge, `StatusBadge` colored pill, and `formatBytes(_:)` helper.
  - `Sources/AppUI/RootView.swift`: `RootView` wraps four panels in a `GlassEffectContainer`
    (shared Liquid Glass backdrop) with a resizable `HStack` at min 880x420 pt.
  - `Sources/AppUI/SourcePanel.swift`: `.fileImporter` for `.iso`/`.img` files; calls
    `selectSource(_:)` inside a `Task`; displays filename + size once selected.
  - `Sources/AppUI/TargetPanel.swift`: lists only `availableTargets`; tap to call
    `selectTarget(_:)`; refresh button calls `refreshTargets()`; collapsible checksum
    section for pasted hex and SHA512SUMS file loading via `setOfficialChecksum(_:)`;
    shows `checksumInputError` and accepted-checksum indicator.
  - `Sources/AppUI/FlashPanel.swift`: primary Flash button calls `requestConfirmation()`;
    a SwiftUI `confirmationDialog` (destructive button) names the exact target as
    `<displayName> (<rawDevicePath>)` and on confirm calls `startFlash()` inside a `Task`;
    progress ring with fraction, phase label, speed, transfer, and Cancel -> `cancel()`.
  - `Sources/AppUI/VerifyPanel.swift`: three terminal states as first-class panels:
    `.succeeded` shows device SHA-512 (text-selectable) + `ChecksumMatchOutcome` badge;
    `.failed` shows error message; `.cancelled` shows not-verified + re-flash hint.
    All terminal states have a "Start over" button calling `reset()`.
  - Liquid Glass API: `GlassEffectContainer { }` for shared backdrop; per-panel cards use
    `.glassEffect(in: .rect(cornerRadius: 20))` via the `panelCard()` modifier.

- `Sources/AppUI/FlashState.swift` and `Sources/AppUI/AppViewModel.swift` -
  implemented the four-panel `@Observable @MainActor` view-model layer:
  - `FlashState` enum: `idle`, `sourceSelected(url:)`, `targetSelected(sourceURL:target:)`,
    `confirming(sourceURL:target:)`, `flashing(snapshot:)`, `verifying(snapshot:)`,
    `succeeded(deviceSHA512:matchOutcome:)`, `failed(message:)`, `cancelled`.
    Convenience predicates `canSelectSource`, `isActive`, `isTerminal`.
  - `FlashProgressSnapshot`: pre-formatted progress struct (`fraction`, `phaseLabel`,
    `speedLabel` in MB/s, `transferLabel` in GB/MB/KB/B). Speed derived from elapsed
    wall-clock time since phase start; phase transitions reset the clock. Static factory
    `make(from:phaseStart:now:)` keeps all math out of the view layer.
  - `ChecksumMatchOutcome` enum: `officialMatch`, `officialMismatch`, `trustedCacheHit`,
    `noOfficialChecksum`. Priority: official checksum -> Keychain cache -> no checksum.
  - `OfficialChecksumSource` enum: `pastedHex(hexString:)`, `sha512SumsFile(body:)`.
  - `TargetInfo`: lightweight `(disk, displayName)` bundle carried through confirming states.
  - `AppViewModel`: injected dependencies (`makeEngine: @Sendable () -> FlashEngine`,
    `KeychainStore`, `DiskEnumerator?`). Convenience init wires production types.
    Public API: `selectSource(_:)`, `refreshTargets()`, `selectTarget(_:)`,
    `setOfficialChecksum(_:)`, `clearOfficialChecksum()`, `requestConfirmation()`,
    `startFlash()`, `cancel()`, `reset()`. Live disk-event loop via `DiskEnumerator.events()`;
    auto-deselects target on disk-disappear. On success: compares `deviceSHA512` to
    `expectedDigest` then Keychain cache; saves to Keychain on `officialMatch`. All
    `FlashEngineError` cases mapped to readable messages. No success claim on cancel/failure.
  - `@ObservationIgnored nonisolated(unsafe)` applied to `diskEventTask` so `deinit`
    can cancel the long-running event-loop task without a MainActor hop.
  - `swift build` outcome: `Build complete! (0.53s)`.

- `Sources/PrivilegedHelper/` - implemented the helper-side privileged flash
  pipeline (compilable; running as root needs signing/SMAppService later). Split
  into focused files:
  - `HelperErrors.swift`: `HelperError` typed enum (`targetRejected`,
    `targetNotResolvable`, `sourceUnavailable`, `deviceOpenFailed`, `ioFailed`,
    `unmountFailed`, `refusedRootMount`, `verificationMismatch`, `notAuthorized`)
    with single-line `message` strings for `FlashResult.errorMessage`.
  - `BlockMath.swift`: pure block-alignment math (`roundUp(_:toMultipleOf:)`,
    `nextReadLength`, `paddedLength`, `defaultChunkBytes` 8 MiB, `fallbackBlockSize`
    512). Side-effect-free for unit testing.
  - `CancellationToken.swift`: lock-guarded one-way cooperative cancel flag
    (`@unchecked Sendable`), checked at every chunk boundary.
  - `HelperSafety.swift`: `validatedTarget(...)` re-resolves the target BSD name to
    a live `DiskDescriptor` (via a one-shot `DiskEnumerator` snapshot) and re-runs
    `DiskSafety.rejectionReasons` independently of the app, using the GROUND-TRUTH
    image length derived from the opened source, not `advisorySizeBytes`. Resolver
    is injectable for tests.
  - `Unmount.swift`: `unmountWholeDisk(...)` wraps `diskutil unmountDisk force`
    via `Process`, hard-refusing any disk with a volume mounted at "/"; `eject(...)`
    on success (non-fatal); injectable runner.
  - `WriteJob.swift`: opens source `O_RDONLY`, opens raw target
    `O_RDWR|O_SYNC|O_EXCL`, sets `F_NOCACHE`, queries block size via
    `DKIOCGETBLOCKSIZE` ioctl (encoded inline, 512 fallback), writes block-aligned
    chunks (final chunk zero-padded up to a block boundary), reports `FlashProgress`
    (`.writing`), honors the cancel token, and streams a SHA-512 of exactly the real
    image bytes via `Verifier`.
  - `VerifyJob.swift`: re-opens the raw device `O_RDONLY` with `F_NOCACHE`, reads
    exactly image-length bytes, streams a read-back SHA-512.
  - `HelperAuthorization.swift`: STUB authorization gate (`allowAll` default,
    `deny(reason:)`, `pinning(requirement:)`) shaped for the later SecCode +
    AuthorizationRef wiring; no Security-framework calls yet.
  - `HelperService.swift`: `NSObject` conforming to `HelperXPCProtocol`; decodes the
    JSON `Data` payloads, runs auth-stub -> safety re-check -> unmount -> write ->
    read-back verify -> digest compare -> eject, encodes `FlashProgress`/`FlashResult`
    back. On cancel: no success claim, drive left unmounted, result `.cancelled`.
    Per-job cancel tokens in a lock-guarded map; heavy work on a background queue
    with non-Sendable XPC closures boxed via `DataSink` (`@unchecked Sendable`).
  - `swift build` outcome: `Build complete! (0.10s)`.

- `Sources/FlashEngine/` - implemented app-side XPC orchestration (three files):
  - `FlashEngineError.swift`: typed error enum (`connectionFailed`, `decodeFailed`,
    `encodeFailed`, `helperReportedFailure`, `cancelled`, `jobIDMismatch`); conforms
    to `Error`, `Equatable`, `Sendable`.
  - `HelperConnection.swift`: `HelperConnection` protocol abstracting the XPC remote
    proxy with Swift-typed async-friendly methods (`flash`, `cancel`, `invalidate`);
    production `XPCHelperConnection` (`@unchecked Sendable` final class) wrapping
    `NSXPCConnection` to a named Mach service, storing a `CodeSigningRequirement` for
    future peer-pinning wiring.
  - `FlashEngine.swift`: `FlashEngine` actor - `flash(source:target:advisorySHA512:)`
    builds a `FlashRequest` (sourceAccess `.absolutePath`, targetBSDName from
    `DiskDescriptor.bsdName`), submits via `HelperConnection`, bridges callbacks into
    `async/await` via `withCheckedThrowingContinuation`, relays `FlashProgress` to a
    public `AsyncStream<FlashProgress>`; `cancel()` forwards to the active `JobID`.
    Image bytes never enter the engine.
  - `swift build` outcome: `Build complete! (0.33s)`.

- Package.swift: added three new library targets (`FlashEngine`, `PrivilegedHelper`,
  `AppUI`) with dependency wiring and matching products. Placeholder source files
  created at `Sources/FlashEngine/FlashEngine.swift`,
  `Sources/PrivilegedHelper/PrivilegedHelper.swift`, and
  `Sources/AppUI/AppUI.swift`. `swift build` stays green (Build complete! 0.66s).
  Stale comment about Xcode-only targets removed from Package.swift header.

- `Sources/DiskModel/DiskSafety.swift`: pure predicate module over `DiskDescriptor`.
  - `RejectionReason` enum (8 cases): `.synthesizedContainer`, `.internalDisk`,
    `.carriesMacOSSystem`, `.timeMachineBackup`, `.notWritable`, `.tooSmall`,
    `.tooLarge`, `.sourceOverlap`. Conforms to `Sendable`, `Codable`, `CaseIterable`,
    `Equatable`.
  - `diskSafetyMaxSizeBytes: Int = 450_000_000_000` - documented named constant for
    the upper-bound threshold (450 GB decimal, inclusive).
  - `rejectionReasons(for:imageSizeBytes:sourceBackingBSDName:) -> [RejectionReason]`
    - evaluates all 8 rules independently, returns every reason that fires.
  - `isValidTarget(_:imageSizeBytes:sourceBackingBSDName:) -> Bool` - returns true
    iff `rejectionReasons` returns an empty array.
  - `validTargets(from:imageSizeBytes:sourceBackingBSDName:) -> [DiskDescriptor]`
    - filters a list to only the valid targets.
- `Tests/DiskModelTests/DiskSafetyTests.swift`: 35 `@Test` cases covering all
  rejection reasons (one fixture each), boundary conditions for `.tooSmall` and
  `.tooLarge` (exact threshold, one byte above/below), allowed-device fixtures for
  five standard flash media sizes (16/32/64/128/256 GB decimal), multiple-reasons
  accumulation, and a ground-truth Mac Studio `diskutil list` fixture asserting that
  `validTargets` returns an empty list for disk0/3/4/5/6/7.

- `Sources/Verifier/Digest.swift`: CryptoKit streaming SHA-512 with `SHA512Digest`
  (Codable, Equatable, Hashable, Sendable value type; init from hex; hexString output;
  constant-time-ish equality via XOR reduction) and `SHA512Hasher` (incremental
  update/finalize) plus `sha512(of:)` one-shot convenience. SHA-256 kept as
  internal-only `SHA256Hasher`; not in public MVP API.
- `Sources/Verifier/ChecksumFile.swift`: `ChecksumFile` struct parses SHA512SUMS-
  format bodies (two-space, single-space, and binary-mode ` *` separators; blank
  and `#` comment lines skipped); `validatePastedHex(_:)` validates raw 128-hex-char
  strings; `MatchResult` enum with `.hashMatch` / `.hashMismatch(expected:actual:)`;
  `ChecksumFileError` with `.invalidHexString`, `.filenameNotFound`, `.malformedLine`.
- `Tests/VerifierTests/VerifierTests.swift`: compile-time API conformance checks for
  all public types plus runtime `precondition` guards in global initializers verifying:
  NIST FIPS 180-4 SHA-512("abc") vector, tamper detection, chunked-streaming equality,
  SHA512Digest hex-init rejection, ChecksumFile parse + hashMatch result,
  validatePastedHex rejection of short/bad inputs. Runtime checks execute at test-
  binary startup (before SwiftPM-generated `main`); a failing check causes
  `swift test` to exit non-zero. Note: XCTest and swift-testing are unavailable in
  this CLT/macOS-26 environment (no such module), so the scaffold compile-time
  pattern is extended with precondition-based startup assertions.



- Created `Package.swift` at repo root with swift-tools-version 6.2 (installed
  toolchain: Swift 6.3.2). Platform set to `.macOS(.v26)` (Tahoe), available
  in PackageDescription 6.2+.
- Four SwiftPM library targets: `DiskModel` (`Sources/DiskModel/`),
  `HelperProtocol` (`Sources/HelperProtocol/`), `Verifier` (`Sources/Verifier/`),
  `KeychainStore` (`Sources/KeychainStore/`).
- Four matching test targets: `DiskModelTests`, `HelperProtocolTests`,
  `VerifierTests`, `KeychainStoreTests` (all under `Tests/<Name>/`).
- Placeholder `.swift` per source target, each exporting a `scaffoldVersion`
  constant; test files import the module and reference `scaffoldVersion` as a
  compile-time check.
- `Sources/README.md` documents SwiftPM targets and notes `AppUI/` and
  `PrivilegedHelper/` as future Xcode-only targets.
- `.gitignore` entries for Swift artifacts: `.build/`, `.swiftpm/`,
  `DerivedData/`, `*.xcodeproj/xcuserdata/`, etc.

### Behavior or Interface Changes

- `Sources/AppUI/StyleHelpers.swift`: `PanelHeader` now accepts an `accent: Color`
  parameter; the active step badge fills with the per-step hue instead of the
  generic `Color.accentColor`. Inactive badges remain muted secondary.
- `panelCard()` modifier now accepts an optional `tint: Color?`; when set, applies
  a subtle Liquid Glass color overlay via `.glassEffect(.regular.tint(tint.opacity(0.12)), in:)`.
  Untinted panels are unchanged.
- `SourcePanel`, `TargetPanel`, `FlashPanel`, `VerifyPanel`: each panel passes its
  step hue into `PanelHeader`, `panelCard(tint:)`, and the large SF Symbol icon
  (muted when the panel is inactive). `DiskRow` selection highlight uses the target blue.

### Additions and New Features

- `Sources/AppUI/StyleHelpers.swift`: added `PanelAccent` palette as the single
  source of four per-step hues: Source=purple, Target=blue, Flash=teal, Verify=green,
  forming a continuous left-to-right hue walk across the four panels.
- Added screenshot `screenshots/main_window.png` (51K) showing the four panels with
  the new per-step hue progression. `swift build` -> `Build complete!`;
  `swift test` -> 203 tests in 47 suites passed.

### Decisions and Failures

- Flash resting hue is teal; the destructive-flash danger signal remains the
  existing red confirmation dialog, unchanged. `StatusBadge` terminal semantic
  colors (success green, warning orange, failure red) are unchanged.

- Created `docs/CODE_ARCHITECTURE.md`: layered architecture map, four-step
  data-flow walkthrough, security posture summary, module table, dependency
  graph, and threading model. ASCII diagrams only; grounded from source.

### Behavior or Interface Changes

- `FlashRequest` now carries `jobID: JobID` and `sourceBackingBSDName: String?`.
  `FlashEngine.flash` stamps its own jobID into the request so the helper echoes
  it in every `FlashProgress`/`FlashResult`; this fixes progress events being
  silently dropped by the engine's `handleProgress` guard (they could never
  match an internal-only UUID before). `HelperService` now reads both fields
  from the decoded request and reports under the app's jobID.
- `HelperSafety.validatedTarget` and `HelperSafety.liveResolve` are now `async`;
  the resolver parameter is `(String) async -> DiskDescriptor?`. Callers
  `await` them. Removed the `DispatchSemaphore`-over-`Task` bridge
  (`blockingSnapshot`) that could deadlock the cooperative pool under two
  concurrent flash calls; the snapshot is now awaited directly.
- `panelCard(...)` now takes `isActive: Bool`; the active panel card draws a 1.5pt
  ~85% white inset frame (`RoundedRectangle.strokeBorder`) so the current step stands
  out. Inactive cards draw no frame. Each panel passes its existing active/enabled
  boolean (the same one given to `PanelHeader(active:)`). Verified: `swift build` ->
  `Build complete!`; `swift test` -> Test run with 203 tests in 47 suites passed.

### Fixes and Maintenance

- C-1: `Sources/PrivilegedHelper/HelperAuthorization.swift` now implements a real
  peer check. `HelperAuthorization.pinning(requirement:)` evaluates the
  connecting peer's `SecCode` (built from its audit token via
  `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)`) against a
  `SecRequirement` (`SecRequirementCreateWithString`) using
  `SecCodeCheckValidity`. It is fail-closed: a missing token, uncompilable
  requirement, missing code reference, or any non-success `OSStatus` denies.
  Pure pieces live in a new `CodeSignatureValidator`. `HelperService.production(`
  `requirement:)` wires the pinned gate; `allowAll`/`deny` remain for tests.
- H-1: source-overlap rule can now fire. The app resolves the source image's
  backing whole-disk BSD name (new `DiskModel/SourceBacking.swift` using
  `DADiskCreateFromVolumePath` + `kDADiskDescriptionMediaBSDNameKey`) and sends
  it in the request; `HelperService` passes it to `HelperSafety`.
- M-1: `FlashEngine` builds its progress stream with
  `AsyncStream.makeStream(of:)` instead of a force-unwrapped continuation.
- M-3: `HelperService` guards `imageLength <= UInt64(Int.max)` before the
  `Int(imageLength)` narrowing and throws the new `HelperError.imageTooLarge`,
  preventing a silent truncation that would under-count required space.
- M-4: widened Time Machine detection in `DiskModel/DiskEnumerator.swift`: more
  known mount-path prefixes (`/Volumes/MobileBackups`,
  `/Volumes/Backups.backupdb`, `/System/Volumes/Data/.Snapshots`, etc.) plus a
  conservative non-browsable-local-volume signal (`volumeIsBrowsable` URL
  resource value). Note: DiskArbitration has no browsable description key, so the
  signal is read from the mount path; unknown reads default to browsable so the
  signal never over-rejects a normal external disk.
- L-4: `HelperService` terminal results go through a new `emit(terminal:)` that
  fabricates a primitive-only `.failed` `FlashResult` if the real result fails
  to encode, so the app's continuation is never left hanging.
- Corrected NIST FIPS 180-4 SHA-512("abc") reference vector in
  `tests/VerifierTests/VerifierTests.swift`: byte 9 was `c9` (transcription
  error in the original brief and scaffold); correct value is `cc`. Verified
  independently with `printf 'abc' | openssl dgst -sha512`.

### Developer Tests and Notes

- Restored the two `FlashEngine` progress-forwarding tests (single and multiple
  events) removed when the jobID mismatch made them impossible; they now pass
  because the helper echoes the request's jobID. Added a `sourceOverlap` firing
  test to `HelperSafetyTests`, a `sourceBackingBSDName`/`jobID` round-trip to
  `HelperProtocolTests`, and `HelperAuthorizationTests` covering requirement
  construction and every fail-closed deny branch (a positive
  `SecCodeCheckValidity` pass needs a live signed peer and is deferred to the
  signing milestone). Full suite: 203 tests in 47 suites pass.
- `swift build` passes: "Build complete!"
- `swift test` passes: all four test targets compile and link; compile-time
  reference checks confirm public API contract.
- Note: swift-testing `@Test`/`@Suite` syntax requires Xcode (not available
  with Command Line Tools only). Scaffold tests use compile-time type references
  instead. Runtime test functions will be added in WS-1b, WS-1c, WS-2b, WS-3a,
  WS-3c as those modules are implemented.
- Target names and paths are a contract for parallel module workstreams. Do not
  rename targets or move source directories without updating all workstream plans.
- Added `capture_screenshot.sh` (build + launch with `--auto-exit` + easy-screenshot)
  for non-interactive UI captures. Root-level byproducts `nohup.out` and
  `USBImagerApp_*.png` are now gitignored.
- Verification: `swift build` -> `Build complete!`; `swift test` -> Test run with
  203 tests in 47 suites passed.

### Behavior or Interface Changes

- `Sources/AppUI/StyleHelpers.swift`: finalized panel cards as true system Liquid Glass.
  Each card is a plain `.glassEffect(.regular, in:)` surface (no opaque fill), so the
  window gradient backdrop shows through and the glass refracts color. Focus uses
  restrained accents only: a per-step tint overlay
  (`fill(accent.opacity(0.10)).blendMode(.plusLighter)`), a brighter white rim (0.28 vs
  0.08), a drop shadow, and a slight scale (1.02 vs 0.99). Supersedes the earlier
  same-day solid-tinted-base and hard-frame focus iterations.
  `Sources/AppUI/RootView.swift` keeps the subtle gradient background that gives the
  glass color to catch.
- `--auto-exit` default delay changed from 30s to 5s in
  `Sources/USBImagerApp/USBImagerApp.swift`; help text updated to match.
- The loud per-step highlight now tracks the current step only: completed steps subdue again
  (e.g. Source dims after an image is chosen). Each panel's card tint, header badge, and large
  icon key off `currentStep`; enable/disable interactivity is unchanged.
- Tuned the loud-active / subdued-inactive hue hierarchy in `Sources/AppUI/StyleHelpers.swift`:
  active card step-hue tint 0.30 + rim 0.60 + colored glow; inactive same-hue tint 0.07 + rim
  0.14 + deeper charcoal. Large placeholder icons follow the same hierarchy (active full hue,
  inactive 0.6) in the four panel files.

### Additions and New Features

- Added a `currentStep: Int` derivation to `Sources/AppUI/FlashState.swift`
  (idle->1, sourceSelected->2, targetSelected/confirming/flashing->3, verifying/terminal->4)
  so exactly one panel is the loud "current step" at a time.
- Added a `--source PATH` launch flag to `Sources/USBImagerApp/USBImagerApp.swift`
  (also `--source=PATH`; expands a leading `~`) that preselects a disk image on startup and
  opens on step 2; help text updated. Verification: `swift build` -> `Build complete!`;
  `swift test` -> Test run with 203 tests in 47 suites passed.
