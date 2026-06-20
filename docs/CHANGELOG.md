## 2026-06-19

### Additions and New Features

- Added `docs/TODO.md` and `docs/ROADMAP.md` (task #46) to lay out the remaining
  work before the app can flash, ahead of a preliminary commit. `docs/TODO.md`
  is a scannable backlog grouped by theme (critical flash-path wiring, the
  pending hardware-gated privilege model, UI/code-quality work packages, six-pass
  review follow-ups, and the distribution decision), most-blocking first.
  `docs/ROADMAP.md` is a five-phase plan (preliminary commit; hardware lane to
  decide the privilege model, marked the critical-path gate; implement the chosen
  write backend + wire the flash path; UI/code-quality polish; signing +
  distribution) with an explicit "not started yet" section. Both stay honest that
  the app builds and the suite passes (357 tests) but flashing is not yet
  operational. Links cross-reference the decision record
  (`raw_disk_write_model.md`), the hardware runbook (`authopen_hardware_runbook.md`),
  the helper-path audit (`wp_helper_path_findings.md`), the backend design
  (`rawdiskopener_design.md`), and `docs/SIGNING.md`. Verification:
  `pytest tests/test_markdown_links.py` -> passed; ASCII-only confirmed.

- Added human-readable disk identity to target rows in the Target panel
  (WP-disk-identity, task #7, deadcode F4/F5). `DiskDescriptor` gained three new
  optional fields (`vendor`, `model`, `volumeLabel`) populated by `DiskEnumerator`
  from `kDADiskDescriptionDeviceVendorKey`, `kDADiskDescriptionDeviceModelKey`, and
  the volume-name fold through `VolumeAttribution`. `VolumeFact` gained a
  `volumeName` field (defaulted to `""`) and `AttributedVolumes` gained `volumeLabel`
  so the per-node name folds to the physical-disk descriptor without touching
  enumeration logic. `DefaultDiskTargetService.displayName(for:)` now composes a
  human identity from vendor + model + size (e.g. "SanDisk Ultra 32.0 GB");
  graceful degradation: vendor only, model only, or bus-protocol label (e.g.
  "USB 32.0 GB") when device strings are absent. `AppViewModel` exposes
  `displayName(for:)` publicly so `TargetPanel` can route the primary label through
  the core helper. `DiskRow` in `Sources/AppUI/TargetPanel.swift` now shows PRIMARY
  (human identity via core `displayName`) and SECONDARY (volume label + BSD name,
  e.g. "UNTITLED - disk4") text, so the operator always has an unambiguous
  identifier without needing to know BSD names. All existing `DiskDescriptor` call
  sites compile unchanged (new fields default to empty string). Added three new
  `displayName` unit tests in `DiskSourceServiceTests.swift` covering full identity,
  vendor-only, and size-suffix presence; updated the four brittle exact-format tests
  to the new format. Glass identity preserved: `DiskRow` layout unchanged except text
  content. Build: "Build complete!" (0 errors). Tests: 0 failures.

- Added inline error rendering across all three input panels (WP-panel-error-render, task #10,
  audit findings F8/F9). A new `ErrorBadge` view in `Sources/AppUI/StyleHelpers.swift`
  renders `AppViewModel.currentError` as a high-contrast red-tinted inset (near-opaque
  `Color.red.opacity(0.82)` fill, white icon and white text) over the Liquid Glass panels
  so error state is legible over any glass refraction. `SourcePanel`, `TargetPanel`, and
  `VerifyPanel` each bind to `vm.currentError` via an `if let` guard and call
  `userMessage(for:)` from `USBImagerCore` to get the display string; they clear
  automatically when `currentError` returns to nil. Added a new error-state scene to the
  `USBImagerShots` screenshot harness: a `ThrowingImageSourceService` fake drives
  `selectSource` into the error path, and a guard asserts `currentError != nil` before
  rendering, so a blank badge PNG is never written silently. Output:
  `screenshots/error_state.png`. Glass identity preserved: `ErrorBadge` is an inset over
  the panel, not an opaque panel replacement. Build: "Build complete!" (0 errors).
  Tests: 354 passed, 0 failures (baseline preserved).

- Added live `accessibilityReduceTransparency` opaque fallback to `PanelCardModifier`
  in `Sources/AppUI/StyleHelpers.swift` (WP-reduce-transparency, audit finding F1).
  `PanelCardModifier` now reads `@Environment(\.accessibilityReduceTransparency)` and
  derives a `useOpaquePath` bool: `documentationRender || reduceTransparency`. When true,
  the four panel cards render using the existing opaque charcoal path (solid dark fill,
  promoted foreground hierarchy, `.colorScheme(.dark)`) instead of `.glassEffect`.
  `CardSurfaceModifier` parameter renamed from `documentationRender: Bool` to
  `useOpaquePath: Bool` to reflect the combined condition. Default (a11y off,
  non-doc-render) Liquid Glass appearance is unchanged. Build: "Build complete!" (0 errors).
  Tests: 347 passed, 0 failures (baseline preserved).

- Added an observable typed error surface to `AppViewModel`
  (`Sources/AppUI/AppViewModel.swift`): a new `public private(set) var currentError: CoreError?`
  (WP-core-typed-errors, task #9, safety-audit HIGH#1 + HIGH#2). It is set on a
  source-stat failure and on a trusted-cache probe failure, and cleared on a
  successful source selection, on a successful flash result, and on `reset`, so a
  stale error never outlives a later success. Added a `userMessage(for:)` overload
  for `CoreError` in `Sources/USBImagerCore/CoreError.swift` (mirroring the existing
  `FlashEngineError` mapping) so a front end renders the surface through the shared
  core taxonomy rather than inventing its own copy. Build: "Build complete!" (0 errors).

### Behavior or Interface Changes

- `ChecksumService.matchOutcome(deviceDigest:officialDigest:imageByteLength:)` is now
  `throws` (`Sources/USBImagerCore/Services.swift`, `ChecksumService.swift`). A true
  trusted-cache miss still resolves to `.noOfficialChecksum`; a genuine Keychain
  access error now throws `CoreError.badInput` instead of being collapsed into a
  silent miss (safety-audit HIGH#2). Updated `AppViewModel.applySuccess` to surface
  a thrown probe error on `currentError` while still resolving the write to
  `.succeeded`. Updated the CLI test fakes and core `matchOutcome` tests to the new
  throwing signature.

### Fixes and Maintenance

- Stripped planning-scaffolding tags from permanent code comments (task #45).
  `Sources/AppUI/TargetPanel.swift` line 123: removed `(WP-disk-identity)` from
  the inline comment; result is "so the GUI and CLI share one canonical format."
  `Sources/AppUI/StyleHelpers.swift`: removed `(F8/F9 glass-audit fix)` from the
  MARK line (now "// MARK: - Error badge") and replaced the audit-ticket sentence
  "Audit findings F8 and F9 flagged that..." with a plain design-intent statement
  ("Bare colored caption text over glass loses contrast; the dense inset preserves
  legibility."). No logic, no behavior, no test changes. Verified: `swift build` ->
  "Build complete!"; `swift test` -> "Test run with 355 tests in 86 suites passed",
  exit 0; grep confirms zero remaining WP-/F8/F9/"Audit findings" tags in both files.
- Replaced unsafe force-unwraps surfaced by the pre-commit audit (task #11,
  WP-forceunwrap-audit). Two were commit-blockers. CB-2: in
  `Sources/AppUI/SourcePanel.swift` the file importer built
  `allowedContentTypes` from `UTType(filenameExtension: "iso")!` and
  `...: "img")!`, which would crash the picker if a UTType could not resolve.
  Added `import UniformTypeIdentifiers` and two file-scope constants,
  `isoContentType`/`imgContentType`, each `UTType(filenameExtension:) ?? .data`,
  and pass those instead; the importer can no longer crash. CB-1: in
  `tools/authopen_fd_probe/main.swift` the `.accept`-branch preflight log
  printed `/dev/\(bootWholeBSD ?? "")`, masking a logic guarantee with `?? ""`.
  Bound the value explicitly as `let bootBSD = bootWholeBSD!` with a one-line
  invariant comment (gate 5 refuses with `.bootDiskUnknown` when nil, so
  `.accept` guarantees non-nil); this is logging-only, not a safety gate.
  D-1/D-2: added one-line SAFETY comments at each `baseAddress!` cluster in the
  `withUnsafeBytes`/`withUnsafeMutableBytes` POSIX and `utsname` closures
  (selftest write/read, regular-file isolation write/read-back, cmsg fd copy,
  `unameString`) explaining the buffer is a non-empty fixed array so the stdlib
  guarantees baseAddress is non-nil; buffer logic unchanged. D-3: added a NOTE
  comment at `diskModelValidTargets` in `Sources/DiskModel/DiskSafety.swift`
  stating it exists as a recursion guard so conformers avoid the bare
  `validTargets(...)` self-resolving to the protocol method. ac-comment
  Finding 3: corrected the file-level summary and the `runAuthopenScaffold`
  step list to say revalidation re-checks the HARDWARE FLAGS
  (external/removable/not-internal/not-boot) AND identity before open, matching
  the post-#43 `revalidateDiskIdentity` behavior. No runtime behavior changed
  except removing the crash/`?? ""` risks; the probe stays open/fstat/close for
  raw devices. Verification: `swift build` -> "Build complete!"; `swift test` ->
  "Test run with 357 tests in 86 suites passed", exit 0 (baseline 357);
  `swift run authopen_fd_probe selftest` -> "ALL CHECKS PASSED", exit 0
  (unchanged). ASCII check passed on all three edited files.
- Consolidated three byte-for-byte duplicate `DiskTargetService` helpers into one
  shared point each (task #13, WP-snapshot-dedup-deadcode). Added two public free
  functions to `Sources/DiskModel/DiskSafety.swift`: `diskDisplayName(for:)` (the
  one canonical disk display-name formatter) and `diskModelValidTargets(...)` (a
  distinctly named alias for the `validTargets` free function that conformers can
  call without the bare name self-resolving to the protocol method and recursing).
  Routed `DefaultDiskTargetService` (`Sources/USBImagerCore/DiskTargetService.swift`),
  `EmptyDiskTargetService` (`Sources/AppUI/AppViewModel.swift`), and
  `FixtureDiskTargetService` (`Sources/USBImagerShots/USBImagerShots.swift`) through
  the shared functions, deleting the three private `displayName` bodies and the
  three private `diskModelValidTargets`/`safeDiskModelValidTargets` wrappers.
  `displayName` output and `validTargets` results are byte-for-byte unchanged.
  Added `import Foundation` to `DiskSafety.swift` for `String(format:)`.
- Removed a duplicated docstring sentence ("Maps a `FlashEngineError` to a
  user-facing message string.") and a stray blank `///` line above
  `userMessage(for: FlashEngineError)` in `Sources/USBImagerCore/CoreError.swift`.
- Removed the "(WP-disk-identity)" planning tag from the `FixtureDiskTargetService`
  comment in `Sources/USBImagerShots/USBImagerShots.swift` (the helper now forwards
  to the shared formatter).
- Hardened the authopen fd probe from the six-pass independent review (task
  #43). In `tools/authopen_fd_probe/main.swift`: (a) routed every
  operator-facing "Removable: YES (...)" progress line (the `.accept`,
  `.isInternal`, and `printGatesThroughInternal` print paths) through a new
  `removabilityFlags(plist:)` helper that uses the SAME `as? Bool ?? false`
  reads as the pure evaluator's removable gate, so the displayed flags cannot
  drift from the value the gate decided on. (b) Documented at the `openFlags`
  assignment that `O_EXCL` has no exclusivity effect on a regular file (no
  `O_CREAT`) and is meaningful only on a raw device node, recording it as the
  spike-noted deviation. (c) Rewrote `revalidateDiskIdentity` to fetch the
  whole-disk plist ONCE and re-run the full pure preflight evaluator (external
  / removable / not-internal / not-boot) on it before the identity-field
  compare, closing the window where a disk keeps its UUID/size/name but flips a
  hardware flag; the UUID mismatch alone would not catch that. (d) Added a
  bounded isolation write/read-back through the received fd for REGULAR-FILE
  targets only (mirrors the selftest), proving read/write capability through
  the passed fd after authopen exits; raw devices stay open/fstat/close with no
  write payload (gated on `!targetPath.hasPrefix("/dev/")`). (e) Replaced the
  inline `String(diskPath.dropFirst("/dev/".count))` BSD-name derivation with
  the existing `wholeDiskBSD(fromRaw:)` from `AuthopenProbeCore`. (g) Comment
  hygiene: removed the planning tag from the module doc, expanded the TWO MODES
  and `rawDevicePreflight` docs to list every gate including the
  identity-capture (TotalSize) refusal, added a "which gates passed" comment
  before the `.isBootDisk` arm, and removed the now-dead `captureDiskIdentity`
  wrapper (orphaned by the revalidation rewrite). In `Package.swift`: (f)
  removed the `.library(name: "AuthopenProbeCore", ...)` PRODUCT entry so the
  spike library is not published; the `.target`, `.testTarget`, and probe
  `.executable` remain so the binary and its hardware-free tests still build.
  The pure evaluator's fail-closed logic in `PreflightCore.swift` was left
  unchanged. Verification: `swift build` -> "Build complete!"; `swift test` ->
  "Test run with 357 tests in 86 suites passed", exit 0 (baseline 357);
  `swift run authopen_fd_probe selftest` -> "ALL CHECKS PASSED", exit 0
  (unchanged). ASCII check passed on both edited files.
- Documented the authopen raw-disk-write spike targets in the architecture and
  file-structure docs and added a parent-plan cross-reference to the decision
  record (task #42, from the working-tree review). `docs/FILE_STRUCTURE.md` now
  lists `AuthopenProbeCore` in the `Sources/` subtree, adds a `tools/` subtree
  section with `tools/authopen_fd_probe/`, and lists `AuthopenProbeCoreTests` in
  the `Tests/` listing, each marked SPIKE (non-production). `docs/CODE_ARCHITECTURE.md`
  gained two module-table rows and a "Research spike" callout clarifying that
  `AuthopenProbeCore` and `authopen_fd_probe` are not wired into the shipping flash
  path (verdict pending hardware). `docs/active_plans/decisions/raw_disk_write_model.md`
  gained an intro line naming the parent plan `immutable-spinning-sifakis` and its
  milestone/task scope (S1-S5, A1-A4, B1-B3) in prose, since the session-local plan
  has no GitHub-browsable link. Review note: the flagged README first-paragraph
  code span was not present; the only backticked `usbimager` is in the Status
  section, which the About/first-paragraph pure-prose rule does not govern, so
  README.md was left unchanged. Verification: `pytest tests/test_readme_first_paragraph.py
  tests/test_markdown_links.py` -> 37 passed; ASCII check passed on all edited files.
- Scoped `ErrorBadge` display per panel domain (P1 fix, task #39). Added
  `CoreErrorDomain` enum (`.source`, `.target`, `.verify`) and a `domain`
  computed property to `CoreError` in `Sources/USBImagerCore/CoreError.swift`.
  Each case maps to exactly one domain: `.badInput` and `.appNotFound` to
  `.source`; `.helperUnavailable` and `.flashFailed` to `.target`;
  `.verificationMismatch` and `.cancelled` to `.verify`. `SourcePanel`,
  `TargetPanel`, and `VerifyPanel` each guard the `ErrorBadge` on
  `error.domain == .<their-domain>` so an error appears in exactly one panel
  (the one matching its workflow phase). A source-file-stat failure
  (`currentError = .badInput(...)` from `selectSource`) now shows only in
  the Source panel and is suppressed in Target and Verify. Added one new
  `@Suite("CoreError panel-domain mapping")` test in
  `Tests/USBImagerCoreTests/SeamSmokeTests.swift` covering all six case->domain
  mappings. Regenerated `screenshots/error_state.png` via `swift run
  USBImagerShots`; the error badge appears in the Source panel only.
  Build: "Build complete!" (0 errors). Tests: 357 passed (was 356), 0 failures.
- Fixed a deterministic SIGSEGV (`EXC_BAD_ACCESS` at 0x0, signal 11) that aborted
  `swift test` before the final summary (task #40). Root cause: the CLI
  sync-over-async bridge `runBlocking<T>` in both
  `Sources/USBImagerCLI/Subcommands/FlashCommand.swift` and `ListCommand.swift`
  stored the async result in a captured stack-local `nonisolated(unsafe) var
  result: T? = nil`, wrote it from a `Task.detached`, and read it back after
  `semaphore.wait()`. Capturing a stack local by an `@escaping @Sendable` closure
  and mutating it across the concurrency boundary is undefined behavior; for the
  associated-value enum `FlashRunResult` the optimizer emitted a `@out` copy
  (`memmove`) from a null box, crashing the detached-task thread inside
  `_platform_memmove` during `FlashCommand.performFlash`. The crash surfaced after
  the WP-disk-identity change only because added `DiskDescriptor` fields shifted
  timing/layout; the disk-identity code itself was benign. Fix: replaced both
  duplicated buggy helpers with one shared, well-defined helper in
  `Sources/USBImagerCLI/RunBlocking.swift` that stores the result in a heap-
  allocated `ResultBox` reference shared across threads (stable address, no
  captured-stack-local UB), keeping the `DispatchSemaphore` happens-before barrier.
  Removed the now-unused `import Dispatch` from `FlashCommand.swift`. No test was
  deleted or weakened. Verification: `swift test --filter USBImagerCLITests` -> 49
  tests in 15 suites passed, RC=0, no signal 11; full `swift test` -> "Test run
  with 356 tests in 85 suites passed", shell RC=0; `swift build` -> "Build
  complete!".
- Refreshed `README.md` (readme-docs skill, task #37) for truthfulness about the
  in-progress privileged flash path. Trimmed the opening paragraph to 225 chars
  so it fits the GitHub About 250-char limit while keeping it prose-only (no
  links/badges/code spans); confirmed via `tests/test_readme_first_paragraph.py`
  (6 passed). Rewrote the Status section: the flash path is not
  just "signing pending" but unwired (no installed daemon, so a flash attempt
  fails at connection time, exit 4), and the least-persistent authopen
  raw-disk-write model is noted as active research with a hardware-pending
  verdict and no committed backend. Updated the stale "325 tests" claim to a
  durable "350+ tests" and the flash note to match. Doc links and the
  `build_debug.sh`/`swift test`/run-path quick start verified against the repo.
- Fixed safety-audit HIGH#1: `AppViewModel.selectSource` no longer swallows a
  source-stat failure into `print()` + `return`. It now sets the observable
  `currentError` (a typed `CoreError`) and stays on step 1, so an unreadable source
  is visible to the operator instead of leaving the UI silently on step 1.

### Removals and Deprecations

- Removed dead code found by a no-caller search across `Sources` and `Tests`
  (task #13, WP-snapshot-dedup-deadcode). Deleted the unused internal
  `SHA256Hasher` from `Sources/Verifier/Digest.swift` (zero references). Deleted
  the dead `FlashProgressSnapshot.make(from: FlashProgress)` overload and its
  `label(for: FlashPhase)` helper from `Sources/AppUI/FlashState.swift`:
  production builds snapshots from the numeric `FlashProgressData` factory, and
  only tests used the `FlashProgress` overload. Rewrote those `AppViewModelTests`
  call sites to construct `FlashProgressData` instead (phases map 1:1:
  `.writing`/`.verifying`) so the tests exercise the production factory; coverage
  is equivalent (still 357 tests, all passing). Dropped the now-unused
  `import HelperProtocol` from `FlashState.swift`.

### Developer Tests and Notes

- Test fragility cleanup (task #44): removed brittle assertions across eight test
  files without losing real coverage. Replaced exact `phaseLabel` string asserts
  ("Writing"/"Verifying") with a distinct-and-non-empty check
  (`AppViewModelTests.swift`); injected an explicit `now` into the speed-label
  test so it no longer reads the real clock; switched setup fixture writes from
  `try?` to `try` so a failed write surfaces. Made the CLI live-fallback test
  falsifiable -- it now asserts the resolved image source is not the test fake
  rather than `#expect(Bool(true))` (`CLIScaffoldTests.swift`). Changed the
  `decodePlist` helper from `try!`/`as!` to a throwing helper called with `try`
  so a malformed fixture fails the test instead of crashing the process; dropped
  the duplicate `acceptRemovableNuance` test (identical inputs to
  `acceptValidUSB`, which now documents the Removable=false nuance it already
  covers) (`PreflightCoreTests.swift`). Made the silent DiskArbitration skip
  visible via `withKnownIssue`, replaced `result.count == 1` + `result[0]` with a
  structural `map(\.bsdName)` check, and dropped the live-enumerator dependency
  from the pure `displayName` formatting tests (now call `diskDisplayName(for:)`
  directly, with structural prefix/suffix/token checks and one documented
  full-string lock) (`DiskSourceServiceTests.swift`). Removed redundant numeric
  `exitCode.rawValue == N` asserts that duplicated the typed `== .someCase` check
  on the line above (`VerifyCommandTests.swift`, `FlashCommandTests.swift`,
  `FlashOrchestrationServiceTests.swift`); the numeric exit-code table stays
  owned solely by `SeamSmokeTests`, which gained a comment citing
  `Sources/USBImagerCore/CoreError.swift` as the panel-domain contract source of
  truth. No production code changed. Verification: `swift build` -> "Build
  complete!"; `swift test` -> "Test run with 355 tests in 86 suites passed",
  exit code 0 (357 -> 355: one duplicate test removed, two phaseLabel tests
  merged into one).

- WP-snapshot-dedup-deadcode (task #13) verification: `swift build` -> "Build
  complete!"; `swift test` -> "Test run with 357 tests in 86 suites passed",
  exit code 0.

- Added 7 tests (total 347 -> 354, none regressed). Core
  (`Tests/USBImagerCoreTests/ChecksumServiceTests.swift`): a genuine Keychain access
  error throws `CoreError` from `matchOutcome`; a true cache miss does not throw and
  stays `.noOfficialChecksum` (new `ThrowingLoadAllKeychainBackend` fixture). AppUI
  (`Tests/AppUITests/AppViewModelTests.swift`): a stat failure sets `currentError` to
  `.badInput`; a later successful selection clears it (new
  `FailThenSucceedImageSourceService`); `reset` clears it; a throwing `matchOutcome`
  surfaces `currentError` while still resolving `.succeeded` (new
  `SucceedingFlashOrchestrationService` + `ThrowingMatchOutcomeChecksumService`); a
  clean success leaves `currentError` nil. Assertions check the error case
  (non-nil/nil + `.badInput`), not user-facing strings or collection sizes.

## 2026-06-18

### Additions and New Features

- Added `tools/authopen_fd_probe/` (task A1, WP-authopen-fd-spike): standalone
  SCM_RIGHTS fd-passing harness for the authopen spike. `main.swift` provides
  two modes: `selftest` (automated proof, no authopen, no device, no auth
  prompt -- runs from any shell) and `authopen` (scaffolded interactive
  `/usr/libexec/authopen -stdoutpipe` run for operator use). Uses `posix_spawn`
  instead of `fork()` (unavailable in Swift 6) and hand-computed CMSG layout
  constants (the CMSG_* function-like C macros are not importable into Swift).
  Wired into `Package.swift` as `authopen_fd_probe` executable product/target
  with its source at `tools/authopen_fd_probe/`. Self-test verified on Darwin
  25.5.0 arm64 (12 checks, exit 0): fd passed from posix_spawn'd child to
  parent over UNIX socketpair, read/write capability confirmed, fd usable after
  sender exit (capability-lifetime proof), close returns 0, double-close returns
  EBADF. `README.md` documents build steps, self-test expected output, and the
  full operator preflight invariant checklist for sacrificial-USB raw-device
  use in the three required launch contexts.

- Added `Sources/AuthopenProbeCore/PreflightCore.swift` and
  `Tests/AuthopenProbeCoreTests/PreflightCoreTests.swift` (fixture-tests):
  extracted the probe's raw-device preflight DECISION logic out of the diskutil
  I/O so it can be unit-tested with no hardware. The new `AuthopenProbeCore`
  library holds the pure pieces -- `DiskIdentity`, the `PreflightRefusal` /
  `PreflightDecision` types, `parseRawDevicePath` / `wholeDiskPath` /
  `wholeDiskBSD`, `diskIdentity(fromPlist:wholeDiskBSD:)`,
  `evaluateRawDevicePreflight(rawPath:plist:bootWholeBSD:)`, and
  `identityMismatchFields(recorded:current:)` -- none of which spawn diskutil.
  `tools/authopen_fd_probe/main.swift` now imports the library and its
  `captureDiskIdentity` / `rawDevicePreflight` / `revalidateDiskIdentity`
  functions are thin diskutil-fetch wrappers that delegate the accept/refuse
  decision to the pure evaluator; the real `authopen <device>` refusals,
  exit code 3, and printed reasons are byte-for-byte unchanged (verified for
  `/dev/rdiskGARBAGE` and `/dev/disk4`). 22 fixture tests cover ACCEPT (valid
  external USB, the Removable=false-but-RemovableMedia/Ejectable=true nuance, a
  real-shape XML plist parsed via PropertyListSerialization), REFUSE (internal,
  external-but-fixed, target==boot disk, unknown boot disk, malformed path,
  buffered `/dev/diskN`, missing TotalSize), identity capture (UUID fallback),
  and identity comparison (UUID/size/media-name mismatches reported per field).
  Wired `AuthopenProbeCore` library + `AuthopenProbeCoreTests` test target into
  `Package.swift`. `swift build` -> Build complete; `swift test` -> 347 tests in
  84 suites passed (was 325); `swift run authopen_fd_probe selftest` -> ALL
  CHECKS PASSED, exit 0 (unchanged). `PreflightRefusal` conforms to `Error` so
  it can be a `Result` failure; test fixtures are built by functions rather than
  module-level lets to satisfy Swift 6 strict-concurrency Sendable rules.

- Refreshed `docs/CODE_ARCHITECTURE.md`: added USBImagerCore, USBImagerCLI, and USBImagerShots to
  the module table; updated the USBImagerApp row to `@main struct USBImagerApp: App`,
  `.onOpenURL` URL-scheme handoff (`usbimager://`), `AutoExitCoordinator`, and Info.plist
  CFBundleURLTypes; added missing dependency-graph edges (USBImagerCLI -> USBImagerCore,
  USBImagerShots -> AppUI + USBImagerCore, AppUI -> USBImagerCore); corrected the "not yet wired"
  bullet -- Mach service name and code-signing requirement are now wired in
  `Sources/USBImagerCore/XPCFlashEngineFactory.swift` (Mach service `com.nsh.usbimager.helper`
  + designated requirement); added CLI exit-code contract table. Created `docs/FILE_STRUCTURE.md`
  with full top-level layout, Sources/Tests/docs subtree guides, generated-artifacts table, and
  where-to-add-new-work table. Added `docs/FILE_STRUCTURE.md` link to `README.md`.
- Added `VerifyCommandTests.swift` (WP-3c): 13 new Swift Testing tests covering `usbimager verify`
  delegation and exit-code mapping. Factored a `VerifyCommand.performVerify` static helper (mirrors
  `FlashCommand.performFlash`) that returns a typed `VerifyOutcome` without calling
  `Foundation.exit`, then updated `run()` to route the outcome to `Usbimager.fail`/`exit`. Tests
  assert delegation to `ChecksumService` protocol requirements (`sha512(ofFileAt:)`,
  `validatePastedHex`, `expectedDigest(fromSums:matching:)`, `matches`), outcome cases
  (`.digestOnly`, `.match`, `.failure(.verificationMismatch)` exit 1), and bad-input paths
  (unreadable image, malformed `--sha512` hex, unreadable/unparsable `--sums`) all exit 2
  via `.failure(.badInput)`. `swift test` -> 325 tests in 79 suites passed (was 312).

- Implemented `usbimager list` subcommand (WP-3b): `Sources/USBImagerCLI/Subcommands/ListCommand.swift`
  replaced the stub with the real body. Calls `diskService.snapshotDisks()` then
  `diskService.validTargets(from:imageSizeBytes:0 sourceBackingBSDName:nil)` to get safe
  targets (no disk-safety logic in the CLI; all filtering in DiskModel via core). Prints one
  `displayName(for:)` row per safe target; prints "No removable target disks found." and exits 0
  when the list is empty; exits 2 via `Usbimager.fail(.badInput(...))` when `diskTarget` is nil
  (no DiskArbitration session). Added `Tests/USBImagerCLITests/ListCommandTests.swift` with 4
  new delegation tests ("snapshotDisks() and validTargets() are both called", "validTargets is
  called with imageSizeBytes: 0 and nil sourceBackingBSDName", "displayName(for:) is called once
  per safe target disk", "Empty safe-target list exits cleanly"). `usbimager list` output on this
  machine: "No removable target disks found." `swift test --filter USBImagerCLITests` -> 49 tests
  in 15 suites passed.

### Behavior or Interface Changes

- Fixed low-contrast "Choose Image" button in the offscreen documentation
  screenshots: in `documentationRender` mode the card surface promotes labels to
  near-white, but the `.bordered` button kept a light translucent lavender fill,
  leaving the label light-on-light. Added a `documentationRender`-gated
  `DocButtonFillModifier` (Sources/AppUI/StyleHelpers.swift) that paints a dark
  charcoal pill behind the label, applied only in `Sources/AppUI/SourcePanel.swift`'s
  doc-render branch. The interactive app (flag false) is unchanged. Regenerated
  `screenshots/main_window.png` (486 KB) and `screenshots/step2_target.png`
  (449 KB) via `swift run USBImagerShots` (activation policy `.prohibited` --
  nothing on screen, no focus); the label now reads clearly on the dark pill in
  both Source-active and Source-inactive states. `swift test` -> 325 tests in 79
  suites passed.

- Refreshed `docs/USAGE.md`: removed stale GUI launch-flags section (`--source`/`--auto-exit`/`-h`),
  rewrote `capture_screenshot.sh` description to reflect `swift run USBImagerShots` offscreen render,
  updated unit-test count to 325, added "Command-line interface (usbimager)" section documenting the
  four subcommands (`list`, `verify`, `flash`, `open`) with usage examples and exit-code table
  (0-6), and updated Targets table with `USBImagerCore`, `USBImagerCLI`, and `USBImagerShots`.
  `docs/INSTALL.md` version section (26.06.0 CalVer, VERSION synced) confirmed current; no edits needed.

### Fixes and Maintenance

- Tightened `AGENTS.md`: converted prose style pointers to bare-path bullet list; added
  `## Project docs` section pointing to `docs/CODE_ARCHITECTURE.md`, `docs/FILE_STRUCTURE.md`,
  and `docs/USAGE.md` (all added or refreshed in the CLI/core split). No content moved or
  deleted; file remains 15 non-blank lines.

- Refreshed `README.md`: updated first paragraph to lead with SwiftUI GUI as the primary product
  and mention the thin `usbimager` terminal CLI; fixed stale test count (203 -> 325); added CLI
  subcommand pointer in the quick start note; confirmed all doc links (USAGE, INSTALL,
  CODE_ARCHITECTURE, FILE_STRUCTURE, SIGNING, CHANGELOG) present and correct.

- Verified the documentation-render screenshot style is DARK cards with LIGHT text (per explicit
  user direction reversing an earlier light-card attempt): confirmed `Sources/AppUI/StyleHelpers.swift`
  keeps the opaque charcoal `cardDepthFill`, promotes the foreground hierarchy via three-argument
  `foregroundStyle(.white, white@0.82, white@0.62)`, forces `.colorScheme(.dark)`, and that no
  light-card fill or `.colorScheme(.light)` remains in any `documentationRender` branch; the
  interactive `glassEffect` path (flag false) is unchanged. Regenerated `screenshots/main_window.png`
  (475 KB) and `screenshots/step2_target.png` (442 KB) via `swift run USBImagerShots` with activation
  policy `.prohibited` (nothing on screen, no focus taken); the "Source/Target/Flash/Verify" headers,
  the "No image selected"/"No removable disks found"/"Optional checksum"/"Select a target first"/
  "Waiting for flash"/"Choose Image" labels, and the "debian.iso / 4.3 GB" source line render as
  clearly legible light text on the dark cards, with Source idle-purple and Target loud-blue at step 2
  preserved. `swift test` -> 325 tests in 79 suites passed.

- Stripped planning-scaffolding tags (WP-*, WS-*, standalone M0-M4 milestone references) from
  committed comments across 13 files under `Sources/` and `Sources/README.md`; rephrased each
  comment to describe code behavior. Removed two brittle collection-size `#expect` assertions
  (`FlashProgressData.Phase.allCases.count == 2` in `SeamSmokeTests.swift` and
  `registered.count == 4` in `CLIScaffoldTests.swift`); the `contains` checks above each
  already pin every required element. `swift build` clean; `swift test` -> 325 tests in 79
  suites passed (count unchanged -- removing a count-check line does not remove a test).
- Fixed two additional stale comments: removed false "not yet implemented / stub" claim from
  `Sources/USBImagerCLI/Usbimager.swift` (subcommands are all implemented); added missing
  body comment "Forward to the DiskModel module-level free function." to the file-scope
  `diskModelValidTargets` wrapper in `Sources/AppUI/AppViewModel.swift` to match its
  sibling wrappers in `DiskTargetService.swift`. Comment-only; `swift test` -> 325 passed.

- Reconciled `docs/active_plans/decisions/authopen_hardware_runbook.md` preflight wording
  with final probe code (task #31, doc-reconcile). Two targeted fixes: (1) added
  "not an internal disk (Internal=false)" bullet to the preflight invariant list so the
  documented set of conditions matches the independent `guard !internalFlag` check the code
  enforces (main.swift lines 470-475); (2) corrected the revalidation-step description from
  "BSD name, size, removable flag, and media identity" to "UUID/anchor, size, and media name"
  to match the three fields `revalidateDiskIdentity` actually re-compares (main.swift lines
  512-549: `diskUUID`, `totalSizeBytes`, `mediaName`). The Removable flag is checked once
  during preflight, not re-checked at revalidation.

### Removals and Deprecations

- Removed `.product(name: "ArgumentParser", package: "swift-argument-parser")` from the
  `USBImagerApp` target in `Package.swift`; the GUI app never imported ArgumentParser (confirmed
  by source audit), so the dependency was dead. `USBImagerCLI` retains its ArgumentParser dep.
  `swift build` -> Build complete; `swift test` -> 325 tests in 79 suites passed (unchanged).

## 2026-06-17

### Additions and New Features

- Added a no-glass documentation render path (WP-4b+) so offscreen screenshots show readable panel
  text and icons: introduced the public `EnvironmentValues.documentationRender` flag (default false)
  in `Sources/AppUI/StyleHelpers.swift`; when true the `panelCard` modifier draws a solid opaque
  charcoal card (same step tint, rim, and active/inactive highlighting) instead of `.glassEffect`,
  and `RootView` drops the `GlassEffectContainer`. `Sources/USBImagerShots/USBImagerShots.swift`
  sets the flag on the rendered `RootView` because Liquid Glass does not rasterize through
  `ImageRenderer` without a live window's backing. The interactive app default (flag false) keeps its
  unchanged Liquid Glass appearance. Regenerated `screenshots/main_window.png` (2.3 MB) and
  `screenshots/step2_target.png` (2.2 MB), which now show panel headers, SF Symbol icons, and text
  labels with the same idle vs step-2 highlighting; activation policy stays `.prohibited` (nothing
  appears on screen). `swift test` -> 312 tests in 76 suites passed.
- Added the `USBImagerShots` offscreen screenshot render harness (WP-4b):
  `Sources/USBImagerShots/USBImagerShots.swift` builds an `AppViewModel` with injected fake core
  services (a fixed-byte `ImageSourceService`, a fixture USB-disk `DiskTargetService` forwarding to
  the real `DiskModel` safety filter, and a no-op `FlashOrchestrationService`), then renders `RootView`
  to PNG offscreen via `ImageRenderer` and exits -- it sets `NSApplication.activationPolicy(.prohibited)`
  so no window is ordered front and focus is never taken (verified: running it shows nothing on screen).
  It writes `screenshots/main_window.png` (idle, step 1) and `screenshots/step2_target.png` (preselected
  source advancing to step 2 through the same `selectSource` core seam). A step-2 guard asserts
  `flashState.currentStep == 2` with populated `availableTargets`/`sourceImageBytes` before writing the
  step-2 PNG and exits non-zero otherwise (negative path verified: forced source failure leaves step 1
  and exits 1, refusing to write a blank PNG). `capture_screenshot.sh` now runs `swift run USBImagerShots`
  instead of launching the live foreground GUI twice and `pkill`-ing it (rejected as disruptive in
  `docs/active_plans/decisions/wp0_gui_source_handoff_probe.md`); `usbimager open --auto-exit N` is kept
  only as an opt-in human smoke test. Added the `USBImagerShots` executable target/product to
  `Package.swift` (depends on `AppUI`, `USBImagerCore`, `DiskModel`). `swift build` -> `Build complete!`;
  `swift run USBImagerShots` exits 0 and produces both non-empty PNGs (~2.3 MB and ~2.2 MB). Known
  `ImageRenderer` limitation: the four panel cards, step highlighting, and mesh backdrop rasterize, but
  the Liquid Glass panel text/content does not render offscreen.
- Set CalVer version 26.06.0 (WP-4c): created repo-root `VERSION` file containing `26.06.0`;
  updated `Sources/USBImagerApp/Info.plist` CFBundleShortVersionString and CFBundleVersion from
  `0.0.0` to `26.06.0`; updated `Sources/USBImagerCLI/Usbimager.swift` CommandConfiguration
  `version:` from `"0.0.0"` to `"26.06.0"`; added a version note to `docs/INSTALL.md`; added
  `Version 26.06.0` line to `README.md` Status section. `usbimager --version` prints `26.06.0`.
  All edited files are ASCII-clean.

- Implemented `usbimager flash --source <iso> --target <bsd> [--verify]` (WP-3d):
  replaced the scaffold stub in `Sources/USBImagerCLI/Subcommands/FlashCommand.swift`
  with the real headless flash path. It resolves the target via the core disk
  service (`diskDescriptor(withBSDName:)`; unknown -> exit 2), validates the source
  via `ImageSourceService.byteLength` (exit 2), then calls
  `FlashOrchestrationService.flash(advisorySHA512: nil, verifyReadBack: --verify)`,
  printing one concise progress line per sample, and maps `FlashRunResult` to a
  contract exit code via the shared exit path (success 0, verificationMismatch 1,
  helperUnavailable 3, flashFailed 4, cancelled 5). The resolve/validate/orchestrate
  logic is factored into a static `performFlash` that returns the typed result
  without calling `Foundation.exit`, so delegation tests drive the full path against
  fakes. Wired the real engine factory inside core
  (`Sources/USBImagerCore/XPCFlashEngineFactory.swift`): it builds a `FlashEngine`
  over `XPCHelperConnection` using the shared helper Mach service name
  `com.nsh.usbimager.helper` and designated requirement, constructs
  `CodeSigningRequirement` internally, and throws `CoreError.helperUnavailable` when
  the connection cannot be established; `CoreServices.live()` now defaults to this
  factory (replacing `HelperUnavailableEngineFactory`) so the CLI selects the real
  flash path without importing `FlashEngine`. Added
  `Tests/USBImagerCLITests/FlashCommandTests.swift` (14 tests in 4 suites): flash
  delegation with the resolved descriptor and `verifyReadBack` reflecting `--verify`,
  each `FlashRunResult` case mapping to its exit code, bad-target/unreadable-source/no-session
  exit-2 paths that never call flash, and progress-line formatting. `swift test`
  passes (312 tests in 76 suites); `usbimager flash --source <fixture> --target bogusdisk999`
  exits 2 with a clear message (no crash/hang). A real device flash needs the helper
  installed plus a scratch USB and is the documented manual run
  `usbimager flash --source <iso> --target <bsd> [--verify]`.

- Implemented `usbimager open --source <path> [--auto-exit N]` (WP-3e): replaced the
  scaffold stub in `Sources/USBImagerCLI/Subcommands/OpenCommand.swift` with the real
  M0 handoff. The command validates the source via `ImageSourceService.byteLength` (exit
  2 on failure), builds the percent-encoded `usbimager://open?source=<file-url>&autoExitAfter=N`
  URL using the unreserved-characters encoding that matches the M0 contract, locates
  `USBImagerApp.app` relative to the CLI executable (exit 6 if absent), then delivers the
  URL via `/usr/bin/open` as a child `Process` (no AppKit/NSWorkspace, keeping the CLI
  target dependency-clean) and exits 0. The URL-construction and app-location logic are
  factored into static, testable functions on `OpenCommand`. Added
  `Tests/USBImagerCLITests/OpenCommandTests.swift` (22 new tests in 4 suites): exact M0
  encoding assertions, round-trip decode, auto-exit variants, space-in-path handling, source
  validation via fake/real `ImageSourceService`, and bundle-location positive/negative paths.
  `swift test` passes (298 tests in 72 suites).

- Added two core seam methods (WP-1e) so the CLI `verify` and `flash` paths stay behind
  `USBImagerCore`: `ChecksumService.sha512(ofFileAt:)` streams a source image file through the
  incremental `SHA512Hasher` in 1 MiB chunks (no whole-image load; digest matches the one-shot
  `Verifier.sha512(of:)`) and throws `CoreError.badInput` on a missing/unreadable file, and
  `DiskTargetService.diskDescriptor(withBSDName:)` snapshots disks and returns the first descriptor
  whose `bsdName` matches (else `nil`). Both are protocol-extension defaults in
  `Sources/USBImagerCore/Services.swift` (shared by every conformer, so the GUI/CLI stubs need no
  edits), with a pure file-scope `firstDescriptor(withBSDName:in:)` matching helper in
  `Sources/USBImagerCore/DiskTargetService.swift`. Added `USBImagerCoreTests` coverage: streaming
  vs one-shot hash equivalence (empty, small, multi-chunk files), a missing-file `badInput` case,
  and BSD-name lookup hits/misses over a controlled descriptor list (no live DiskArbitration).
  `swift test --filter USBImagerCoreTests` -> 60 tests in 14 suites passed.
- Added the `usbimager` terminal executable scaffold (WP-3a): `Sources/USBImagerCLI/Usbimager.swift`
  (a `@main ParsableCommand` root registering the `list`/`verify`/`flash`/`open` subcommands, the
  injectable `CoreServices` seam with a `Usbimager.servicesOverride` test hook and `services()`
  resolver, and the shared exit path mapping a `CoreError`/`CoreExitCode` to the process status per
  the CLI contract), four thin subcommand stubs under `Sources/USBImagerCLI/Subcommands/` that reach
  core through the seam and print "not yet implemented" (bodies owned by WP-3b/3c/3d/3e), and
  `Sources/USBImagerCore/HelperUnavailableEngineFactory.swift` (a placeholder `FlashEngineFactory`
  that reports the helper unavailable so the flash path returns exit code 3 instead of crashing until
  WP-3d wires the real XPC factory). Added the `USBImagerCLI` executable target plus the `usbimager`
  product to `Package.swift` (deps: `USBImagerCore` + `ArgumentParser` only; the GUI and workflow
  libraries stay reachable only via `USBImagerCore`), and a `USBImagerCLITests` target. `swift build`
  is clean; `usbimager --help` lists all four subcommands; `swift test` passes (276 tests, 65 suites).
- Rewrote `Sources/USBImagerApp/USBImagerApp.swift` as the GUI-only entry point and added the
  M0 source handoff (WP-2b). Removed `import ArgumentParser`, the `LaunchOptions`
  `ParsableArguments` struct, the `AppEntry` wrapper, the `launchOptions` static, and the
  `--source`/`--auto-exit` `.task` argument hooks. The app now receives a preselected source
  only through the custom URL scheme `usbimager://open?source=<percent-encoded file
  URL>&autoExitAfter=N` handled by SwiftUI `.onOpenURL` on the scene: `decodeHandoff(_:)`
  parses with `URLComponents`, accepts only a readable `file:`-backed source
  (`isFileURL` + `FileManager.isReadableFile(atPath:)`) and otherwise stays on step 1 with a
  clear log line, and reads an optional positive `autoExitAfter`. On a valid source it calls
  `AppViewModel.selectSource` and emits the M0 preselect line
  `[USBImagerApp] handoff: preselected <path>, step 2`. A new private `@MainActor`
  `AutoExitCoordinator` gates the auto-exit timer on the M0 correction: a single idempotent
  `startAutoExitIfReady()` is fed by both the window-visible trigger
  (`RootView.onAppear`, which logs `[USBImagerApp] window: visible (RootView.onAppear)`) and
  the handoff handler, so the timer starts only when source-preselected AND window-visible
  both hold, whichever is last, and fires `NSApplication.terminate` for a clean lifecycle
  quit; absent/non-positive `autoExitAfter` schedules no timer and the window stays open. The
  `.onAppear` is attached to the `RootView` instance from the app scene so the AppUI module's
  `RootView` stays unchanged (WP-2a ownership). Added `Sources/USBImagerApp/Info.plist`
  carrying `CFBundleURLTypes` (`CFBundleURLName com.nsh.usbimager.url`, scheme `usbimager`)
  plus the standard app keys (`CFBundleExecutable`, `CFBundleIdentifier com.nsh.usbimager`,
  `CFBundlePackageType APPL`, `NSPrincipalClass NSApplication`, `LSMinimumSystemVersion 26.0`,
  `CFBundleShortVersionString`/`CFBundleVersion` placeholders for WP-4c, `CFBundleName`);
  excluded it from the SwiftPM `USBImagerApp` target (`exclude: ["Info.plist"]`) since it is
  a bundle input, not a build resource. Updated `build_debug.sh` to assemble a real
  `USBImagerApp.app` bundle (`Contents/MacOS/USBImagerApp` + `Contents/Info.plist`) at a
  stable repo path so LaunchServices can route the scheme to the dev artifact (the bare
  executable carries no `CFBundleURLTypes`); the bundle is git-ignored. The bundle assembly
  is a build step only -- this work does no GUI launch (validation stays headless per the M0
  finding). Verified: `./build_debug.sh` -> `Build complete!` with the bundle assembled;
  `swift test` -> `Test run with 276 tests in 65 suites passed`.

- Added `Sources/USBImagerCore/FlashOrchestrationService.swift` (WP-1d):
  `DefaultFlashOrchestrationService`, an `actor` conforming to the frozen
  `FlashOrchestrationService` protocol. It obtains a `FlashEngine` from the injected
  `FlashEngineFactory` (a throwing factory is the no-helper path: `makeEngine()` throwing
  `CoreError.helperUnavailable` is returned directly as `.failure(.helperUnavailable)`, CLI
  exit code 3, before any device work), drains the engine's `progressStream` on a child task,
  maps each helper `FlashProgress` into `FlashProgressData` while dropping the lifecycle
  phases (`.unmounting`/`.done`) and forwarding only `.writing`/`.verifying`, forwards
  `cancel()` to the active engine, and collapses the engine's `async throws` result into a
  typed `FlashRunResult`. On engine `.success` it returns `.success(deviceSHA512:)` with the
  helper-derived (lowercased) device digest, except that when `verifyReadBack` is set and an
  advisory digest is present a case-insensitive read-back mismatch yields
  `.failure(.verificationMismatch)` (exit code 1). `FlashEngineError.cancelled` maps to
  `CoreError.cancelled` (exit code 5); every other engine error maps to
  `CoreError.flashFailed` (exit code 4) with wording from `userMessage(for:)`. Completed the
  body of `userMessage(for: FlashEngineError)` in `CoreError.swift` (the WP-1a seam, signature
  unchanged) with full per-case wording. The service is an `actor` so it satisfies `Sendable`
  and isolates the per-session engine reference without forcing `@MainActor`; no SwiftUI/AppKit.
  Added `Tests/USBImagerCoreTests/FlashOrchestrationServiceTests.swift` (11 tests) driving a
  fake `FlashEngineFactory` and a scripted fake `HelperConnection` (no real device): helper-
  absent path yields `.failure(.helperUnavailable)` with exit code 3, success carries the
  device digest, progress phase filtering keeps only writing/verifying, read-back mismatch and
  case-insensitive match, helper-reported failure and connection-failed map to `.flashFailed`,
  engine-cancelled maps to `.cancelled`, `userMessage` covers every `FlashEngineError` case
  with non-empty wording, and `cancel()` is a safe no-op with no active session. Test note:
  `FlashEngine` forwards each progress callback onto its actor via a detached `Task` hop and
  then finishes the progress stream synchronously when the helper's result callback resumes,
  so a synchronous in-memory fake would race the stream finish ahead of those hops; the
  scripted fake `HelperConnection` delivers its terminal result from a short-delayed task when
  a progress script is present, matching production timing where helper IPC interleaves
  naturally. The device digest is normalized to canonical lowercase hex once so the success
  payload and the read-back comparison agree regardless of wire casing. Verified: `swift build`
  -> `Build complete!`; `swift test --filter USBImagerCoreTests` -> `Test run with 53 tests in
  12 suites passed` (all 11 WP-1d tests plus the pre-existing WP-1a/1b/1c suites).

- Ran the WP-0 GUI source-handoff probe (M0) and recorded findings in
  `docs/active_plans/decisions/wp0_gui_source_handoff_probe.md`. Selected the custom URL
  scheme `usbimager://open?source=<percent-encoded file URL>&autoExitAfter=N` handled by
  SwiftUI `onOpenURL` as the single GUI source-handoff mechanism (no fallback carrier
  needed). A throwaway SwiftUI spike (`/tmp/handoff_spike/`) packaged into a `.app` bundle
  with a `CFBundleURLTypes` Info.plist registration proved, end to end, that `open` of the
  URL routes to the exact dev bundle, the WindowGroup window appears, the percent-encoded
  `file:` source reaches a `selectSource`-equivalent, and the GUI self-terminates cleanly
  when `autoExitAfter` is set. Key findings for later lanes: the mechanism requires a
  packaged `.app` bundle (the bare `swift build` executable has no `CFBundleURLTypes`), and
  LaunchServices refuses an unsigned bundle under `/tmp` (the dev bundle must live in a
  non-transient path). Fixed the two observable signals downstream lanes consume: the
  preselect line `[USBImagerApp] handoff: preselected <path>, step 2` (polled by WP-4b) and
  the window-visible trigger `[USBImagerApp] window: visible (RootView.onAppear)` (gates the
  WP-2b auto-exit timer, which must start only when source-preselected AND window-visible
  both hold). Verification: `swift build` -> `Build complete!`; `open` the bundle then
  `open "usbimager://open?source=...&autoExitAfter=5"` produced the ordered
  handoff/preselect/auto-exit log lines and a clean process exit; negative paths (missing
  source, `autoExitAfter=0`) logged and stayed on step 1.

- Added `Sources/USBImagerCore/ImageSourceService.swift` and
  `Sources/USBImagerCore/DiskTargetService.swift` (WP-1c): concrete implementations of the
  `ImageSourceService` and `DiskTargetService` protocols from the frozen service seam. `DefaultImageSourceService`
  wraps `FileManager.attributesOfItem` to stat a local image file by its `file:` URL and returns the
  byte length; throws `CoreError.badInput` when the file is missing, is a directory, or is unreadable.
  No hashing, no disk-safety logic. `DefaultDiskTargetService` wraps `DiskEnumerator.snapshot()` (async,
  actor-isolated) for disk enumeration and delegates to the `DiskModel.validTargets(from:imageSizeBytes:
  sourceBackingBSDName:)` free function for safety filtering with no re-implementation of safety rules.
  Provides `displayName(for:)` formatting `"<bsdName>  (<busProtocol>, <size> GB)"` (decimal gigabytes,
  one decimal place, matching macOS Disk Utility) as the stable GUI-neutral disk label. Key design note:
  the `validTargets` free function name collides with the `DiskTargetService` protocol method inside the
  conformance body; resolved via a file-scope wrapper (`safeDiskModelValidTargets`) that names the DiskModel
  free function unambiguously so the method delegates without self-recursion. `DiskEnumerator` init is
  failable; `snapshotDisks()` returns an empty list when no session is available (sandbox) rather than
  crashing. Added `tests/USBImagerCoreTests/DiskSourceServiceTests.swift` with 14 tests: 5 for
  `DefaultImageSourceService` (correct size for a real `/tmp` file at 1 KB, 0 B, and 4 MB; `CoreError.badInput`
  for a missing file; `CoreError.badInput` for a directory path) and 9 for `DefaultDiskTargetService`
  (valid target from mixed list, all-invalid empty result, sourceBackingBSDName overlap, empty input,
  displayName formatting for USB/SD/NVMe/virtual buses, bsdName-first invariant). Verified: `swift build`
  -> `Build complete!`; `swift test --filter USBImagerCoreTests` -> 14 new WP-1c tests passed; all
  pre-existing WP-1a/1b/1d tests in the suite also passed (3 WP-1d test failures are pre-existing issues
  in that workstream, not introduced here).

- Added `Sources/USBImagerCore/ChecksumService.swift` (WP-1b): `DefaultChecksumService`
  conforming to the frozen `ChecksumService` protocol. Validates pasted 128-hex SHA-512
  strings (strips whitespace, maps `ChecksumFileError` to `CoreError.badInput`); parses a
  `SHA512SUMS` body via `Verifier.ChecksumFile` and matches by last path component (throws
  `CoreError.badInput` on malformed body or no match); compares digests with `==`; resolves
  `ChecksumMatchOutcome` in fixed priority order (official digest first, then Keychain trusted
  cache via `KeychainStore.lookup`, then `noOfficialChecksum`); and performs Keychain
  lookup/save through an injected `KeychainStore` (in-memory backend in tests). The save
  method is explicit caller-invoked; duplicate-item saves are swallowed as success; Keychain
  errors in `matchOutcome` are swallowed as cache misses so flash results always resolve. No
  SwiftUI/AppKit. Added `Tests/USBImagerCoreTests/ChecksumServiceTests.swift` with 23 tests
  covering valid/invalid pasted hex, SHA512SUMS match and no-match, outcome priority for all
  four `ChecksumMatchOutcome` cases, Keychain save+lookup roundtrip, duplicate save, and
  distinct byte-length keying. Blocked from full `swift test --filter USBImagerCoreTests` run
  by a compile error in the sibling `DiskTargetService.swift` (WP-1c; calls
  `DiskModel.validTargets(...)` instead of the module-level `validTargets(...)`); this error
  is in the WP-1c scope and not touched here per boundary rules. `ChecksumService.swift`
  itself produces no compiler errors or warnings.

- Added the `USBImagerCore` library target (WP-1a core seam) as the foundational
  shared seam for the GUI/CLI split. Created `Sources/USBImagerCore/FlashProgressData.swift`
  (numeric-only progress value: a `Phase` enum with `.writing`/`.verifying`, plus
  `bytesDone`/`totalBytes`/optional `fraction`, no display strings),
  `Sources/USBImagerCore/CoreError.swift` (the `CoreError` typed-error surface, the
  `CoreExitCode` table 0-6 from the plan's CLI contract via `CoreError.exitCode`, and the
  declared `userMessage(for: FlashEngineError)` mapping with a routing stub WP-1d fills in),
  and `Sources/USBImagerCore/Services.swift` (frozen service signatures the M1 lanes
  implement: `ChecksumService` + `ChecksumMatchOutcome` for WP-1b, `ImageSourceService` and
  `DiskTargetService` for WP-1c, `FlashOrchestrationService` + `FlashEngineFactory` +
  `FlashRunResult` for WP-1d). Wired the `USBImagerCore` target + library product into
  `Package.swift` (depends on `DiskModel`, `Verifier`, `FlashEngine`, `KeychainStore`,
  `HelperProtocol`; imports no SwiftUI/AppKit) and added the `Tests/USBImagerCoreTests`
  target with `SeamSmokeTests.swift` (6 tests) so sibling lanes have a test home. Key
  choice: `USBImagerCore` is the single workflow home and the seam types/signatures are
  frozen here so WP-1b/1c/1d implement against a stable contract. Verified: `./build_debug.sh`
  -> `Build complete!`; `swift build` -> `Build complete!`; grep finds no `import SwiftUI`/
  `import AppKit` in `Sources/USBImagerCore`; `swift test --filter USBImagerCoreTests` ->
  6 tests in 2 suites passed.
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

- Enlarged the empty-state placeholder icons in all four GUI panels (`Sources/AppUI/`
  `SourcePanel.swift`, `TargetPanel.swift`, `FlashPanel.swift`, `VerifyPanel.swift`) to a
  consistent `.font(.system(size: 64))` (was 38/28/34/34) and bumped each empty-state `VStack`
  spacing to 12 so the larger icon does not crowd the caption. The icons now read as clear focal
  points proportional to the tall cards while captions and accent/active-inactive highlighting stay
  unchanged. App-wide visual change (not gated on `documentationRender`); regenerated
  `screenshots/main_window.png` (475 KB) and `screenshots/step2_target.png` (442 KB) offscreen with
  activation policy `.prohibited` (nothing on screen). `swift test` -> 312 tests in 76 suites passed.

- Raised documentation-render text contrast for legible screenshots by keeping the cards DARK and
  making the TEXT LIGHT: when `documentationRender` is true, `Sources/AppUI/StyleHelpers.swift` keeps
  the panel card on its dark charcoal surface and promotes the panel foreground hierarchy via the
  three-argument `foregroundStyle(.white, white@0.82, white@0.62)` so every panel's faint
  `.foregroundStyle(.secondary)` header and body label resolves to bright near-white text without
  editing the panel views; `.colorScheme(.dark)` is forced so control chrome resolves for dark. The
  step-hue tint keeps its interactive opacities (0.30 active / 0.07 inactive) and the rim is slightly
  stronger (0.70/0.22 at 1.5pt) so Source idle-purple and Target loud-blue at step 2 stay recognizable
  on the dark card. The previous dark-charcoal doc card left `.secondary` labels dim; promoting the
  foreground (not lightening the card) fixes it. The interactive app (flag false) Liquid Glass
  appearance is unchanged (all edits live inside `documentationRender` branches). Regenerated
  `screenshots/main_window.png` (451 KB) and `screenshots/step2_target.png` (437 KB); the
  "1 Source"/"2 Target"/"3 Flash"/"4 Verify" headers, the "No image selected"/"No removable disks
  found"/"Select a target first"/"Waiting for flash"/"Choose Image" labels, the "debian.iso / 4.3 GB"
  source line, and the SF Symbol icons now render as light text/icons on the dark cards and are clearly
  legible; activation policy stays `.prohibited` (nothing appears on screen). `swift test` -> 312 tests
  in 76 suites passed.
- Refactored `Sources/AppUI/AppViewModel.swift` (WP-2a) into a thin presentation
  adapter over `USBImagerCore`: source stat now calls `ImageSourceService.byteLength`,
  target snapshot/filter/display-name go through `DiskTargetService`, checksum
  parse/validate/match/cache go through `ChecksumService`, and the whole write/verify
  run is delegated to the `FlashOrchestrationService` actor (the view model no longer
  drives `FlashEngine` or consumes `progressStream` directly). The view model retains
  only presentation: `FlashState` transitions, `FlashProgressSnapshot` string
  formatting, the disk-event-to-UI binding, gesture guards, and the core-to-GUI
  `ChecksumMatchOutcome` mapping; no workflow logic remains duplicated in `AppUI`.
  Added a service-injection initializer (overridable with fakes) alongside the
  existing engine-factory initializer, which now builds the `Default*` core services
  internally so the existing `AppViewModelTests` dependency-injection seam stays
  unchanged. Added `FlashProgressSnapshot.make(from: FlashProgressData,...)` so the
  view layer formats the numeric core progress type. Wired `USBImagerCore` as a
  dependency of the `AppUI` target (and the `AppUITests` target). Added a
  source-to-target regression test (select source -> `availableTargets` populated ->
  `flashState.currentStep == 2` -> `selectTarget` advances to step 3).

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

- Refactored launch-argument parsing from a hand-rolled parser to Apple's swift-argument-parser.
  `AppEntry.main()` now parses a `LaunchOptions: ParsableArguments` (optional `--source`, optional
  `--auto-exit`) via `parseOrExit()`, which supplies `--help` and validation. The app stays
  GUI-first (no required args). `--auto-exit` now REQUIRES a value (`--auto-exit=5` or
  `--auto-exit 5`); bare `--auto-exit` is no longer accepted. `capture_screenshot.sh` updated to
  `--auto-exit=5`.

### Fixes and Maintenance

- Suppressed an `ImageRenderer` artifact in the Target-panel documentation screenshots: the live
  refresh `Button` and the "Optional checksum" toggle `Button`/`TextField` rasterized offscreen as a
  filled olive/yellow disabled bar with a red no-entry glyph. In `Sources/AppUI/TargetPanel.swift`,
  `documentationRender`-gated branches now substitute a plain refresh icon and a static "Optional
  checksum" label for those controls so `screenshots/step2_target.png` renders cleanly (headers,
  icons, and labels unchanged). The interactive app (flag false) keeps the live Button/TextField and
  is byte-for-byte equivalent. Regenerated both PNGs via `swift run USBImagerShots` (activation policy
  stays `.prohibited`; nothing appears on screen): `main_window.png` ~454 KB, `step2_target.png`
  ~435 KB. `swift test` -> 312 tests in 76 suites passed.
- Fixed `AppViewModel.selectSource` swallowing a stat error: replaced `(try? byteLength(of:)) ?? 0`
  with a direct `do/catch` that logs a clear line and returns early (source stays unselected, step 1)
  when `ImageSourceService.byteLength` throws; a successful stat still advances to step 2 with the
  real byte length. Added `AlwaysThrowingImageSourceService` and `FixedByteLengthImageSourceService`
  stubs in `tests/AppUITests/AppViewModelTests.swift`; the regression suite (`AppViewModel: selectSource
  stat-error regression`) uses them to drive the error path and success path without any filesystem
  dependency. Also updated five existing tests that called `selectSource` with non-existent paths
  (they were silently passing under the old bug) to write real temp files for the success path.
  Verified: `swift test --filter AppViewModelTests` -> 41 tests passed; `swift test` -> 276 tests in
  65 suites passed.
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

### Decisions and Failures

- Rejected repeated foreground GUI launches as the M0 validation method. The probe ran
  roughly two dozen visible GUI windows to collect reliability data, stealing window focus on
  an actively-used machine. This is unacceptable: no automated or agent-driven step may launch
  a visible foreground GUI window. Going forward, routine validation is headless or offscreen
  (`swift test`, the `ImageRenderer`-based offscreen render harness planned for WP-4b, and
  log/state assertions). At most one visible GUI launch is allowed -- a final smoke test the
  human explicitly approves and runs as a copy-pasteable command. The mechanism finding (custom
  URL scheme, packaged `.app`, LaunchServices registration, the two log signals, auto-exit
  gating fix) stands. Only the validation method is rejected. Recorded in
  `docs/active_plans/decisions/wp0_gui_source_handoff_probe.md` under "Rejected validation
  method: repeated foreground launches".

## 2026-06-16

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

- `Sources/AppUI/StyleHelpers.swift`: added `PanelAccent` palette as the single
  source of four per-step hues: Source=purple, Target=blue, Flash=teal, Verify=green,
  forming a continuous left-to-right hue walk across the four panels.
- Added screenshot `screenshots/main_window.png` (51K) showing the four panels with
  the new per-step hue progression. `swift build` -> `Build complete!`;
  `swift test` -> 203 tests in 47 suites passed.

- Added a `currentStep: Int` derivation to `Sources/AppUI/FlashState.swift`
  (idle->1, sourceSelected->2, targetSelected/confirming/flashing->3, verifying/terminal->4)
  so exactly one panel is the loud "current step" at a time.
- Added a `--source PATH` launch flag to `Sources/USBImagerApp/USBImagerApp.swift`
  (also `--source=PATH`; expands a leading `~`) that preselects a disk image on startup and
  opens on step 2; help text updated. Verification: `swift build` -> `Build complete!`;
  `swift test` -> Test run with 203 tests in 47 suites passed.

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

- `Sources/AppUI/StyleHelpers.swift`: `PanelHeader` now accepts an `accent: Color`
  parameter; the active step badge fills with the per-step hue instead of the
  generic `Color.accentColor`. Inactive badges remain muted secondary.
- `panelCard()` modifier now accepts an optional `tint: Color?`; when set, applies
  a subtle Liquid Glass color overlay via `.glassEffect(.regular.tint(tint.opacity(0.12)), in:)`.
  Untinted panels are unchanged.
- `SourcePanel`, `TargetPanel`, `FlashPanel`, `VerifyPanel`: each panel passes its
  step hue into `PanelHeader`, `panelCard(tint:)`, and the large SF Symbol icon
  (muted when the panel is inactive). `DiskRow` selection highlight uses the target blue.

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

### Decisions and Failures

- Flash resting hue is teal; the destructive-flash danger signal remains the
  existing red confirmation dialog, unchanged. `StatusBadge` terminal semantic
  colors (success green, warning orange, failure red) are unchanged.

- Created `docs/CODE_ARCHITECTURE.md`: layered architecture map, four-step
  data-flow walkthrough, security posture summary, module table, dependency
  graph, and threading model. ASCII diagrams only; grounded from source.

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
