# Swift deprecated and dead-code audit

Read-only sweep of all 52 files under `Sources/`. The codebase is clean of
deprecated macOS, SwiftUI, and Foundation APIs: it already uses the modern
macOS 26 surface (`@Observable`, `@MainActor`, `GlassEffectContainer`,
`.glassEffect`, `MeshGradient`, `ImageRenderer`, `AsyncStream.makeStream`,
CryptoKit, structured concurrency). No `print()`/`NSLog` exists in the GUI
runtime path except a set of diagnostic `print()` calls in the SwiftUI app,
view model, and screenshot harness that belong on `os.Logger`; the CLI
`print()` calls are intentional stdout output, not debug logging. The byte-count
formatter was already consolidated into
[Sources/AppUI/ByteFormatting.swift](../../../Sources/AppUI/ByteFormatting.swift),
but a second formatter (the decimal-GB disk display-name label) is still
copied byte-for-byte in three places. A handful of public types and methods
have no production caller (they are exercised only by tests or kept for a
documented future), and one internal type (`SHA256Hasher`) is referenced
nowhere at all. There is one stale doubled docstring and one `TODO` block.

## Findings

| ID | File | Snippet | Severity | Fix |
| --- | --- | --- | --- | --- |
| F1 | [AppViewModel.swift](../../../Sources/AppUI/AppViewModel.swift) | `print("[AppViewModel] selectSource: source missing/unreadable: ...")` | high | Route through an `os.Logger` (subsystem `com.nsh.usbimager`, category `viewmodel`). GUI runtime diagnostic, not stdout output. |
| F2 | [USBImagerApp.swift](../../../Sources/USBImagerApp/USBImagerApp.swift) | 11 `print("[USBImagerApp] ...")` calls (handoff decode, auto-exit, window-visible) | high | Replace all 11 with `os.Logger` (category `app`/`handoff`). These are GUI lifecycle diagnostics. |
| F3 | [USBImagerShots.swift](../../../Sources/USBImagerShots/USBImagerShots.swift) | `print("[USBImagerShots] idle state: ...")` etc. | low | Tool harness status lines. Prefer `os.Logger` for consistency; acceptable to leave as `FileHandle.standardError` since this is a dev tool, not the app. |
| F4 | [AppViewModel.swift](../../../Sources/AppUI/AppViewModel.swift) | `EmptyDiskTargetService.displayName(for:)` duplicates the `"%.1f GB"` disk-label formatter | high | Consolidate the disk display-name label into one shared helper. `DefaultDiskTargetService.displayName` (core) is the canonical owner; route this copy and F5 through it. Distinct from `formatBytes`; this is the decimal-GB device-row label. |
| F5 | [USBImagerShots.swift](../../../Sources/USBImagerShots/USBImagerShots.swift) | `FixtureDiskTargetService.displayName(for:)` is byte-identical to F4 and to the core formatter | high | Same consolidation target as F4: forward to the shared disk-label helper instead of re-implementing. |
| F6 | [Digest.swift](../../../Sources/Verifier/Digest.swift) | `struct SHA256Hasher { ... }` | medium | Dead: zero references in `Sources/` or `Tests/`. Header comment says it is "kept in source for future extension." Either delete it now (recover from git when needed) or add a removal-date marker; carrying unreferenced crypto code invites drift. |
| F7 | [FlashState.swift](../../../Sources/AppUI/FlashState.swift) | `FlashProgressSnapshot.make(from progress: FlashProgress, ...)` overload + `label(for phase: FlashPhase)` | medium | No production caller. Production uses only the `FlashProgressData` overload (AppViewModel.swift:604). The `FlashProgress`/`FlashPhase` overload is referenced solely by `AppViewModelTests`. Once `WP-snapshot-dedup-deadcode` removes it, drop the matching tests too, or keep it and document it as the tested public contract. |
| F8 | [ChecksumFile.swift](../../../Sources/Verifier/ChecksumFile.swift) | `enum MatchResult` and `ChecksumFile.verify(filename:computedDigest:)` | low | No production caller; production matches via `expectedDigest(for:)` through the core checksum service. Only `VerifierTests` exercises `verify`. Keep as tested public API or trim if the module surface is being narrowed. |
| F9 | [ChecksumService.swift](../../../Sources/USBImagerCore/ChecksumService.swift) | `matches(deviceDigest:expected:)`, `lookupTrustedCache(...)` | low | No production caller (production uses `matchOutcome`/`hexDigestsMatch`/`saveTrustedCache`). Test-only via `ChecksumServiceTests`. Documented protocol surface; leave unless trimming the service contract. |
| F10 | [DiskSafety.swift](../../../Sources/DiskModel/DiskSafety.swift) | `isValidTarget(_:imageSizeBytes:sourceBackingBSDName:)` | low | No production caller (production calls `validTargets`/`rejectionReasons`). Used by `DiskSafetyTests` and internally by `validTargets`. Keep; it is a thin, tested public predicate. |
| F11 | [CoreError.swift](../../../Sources/USBImagerCore/CoreError.swift) | doc line `Maps a FlashEngineError to a user-facing message string.` repeated twice, plus a stray empty `///` line | low | Delete the duplicated docstring sentence and the extra blank `///` lines above `userMessage(for:)`. Cosmetic; no behavior change. |
| F12 | [USBImagerApp.swift](../../../Sources/USBImagerApp/USBImagerApp.swift) | `/// TODO (signing phase): ...` (replace mach service name + requirement string) | low | Legitimate signing-phase placeholder, not stale. Leave in place; track under the signing milestone, not the dead-code WP. |
| F13 | [HelperConnection.swift](../../../Sources/FlashEngine/HelperConnection.swift) | `_ = peerRequirement  // retained; used when peer-check wiring lands.` | low | Intentional placeholder for the unwired peer-pinning path, documented. Not dead in the deletion sense; revisit when the SecCode peer check is wired, not now. |

## Maps to which work package

WP-logger (replace `print()` with `os.Logger`):

- F1 (AppViewModel diagnostic print)
- F2 (11 USBImagerApp lifecycle prints) -- the bulk of the package
- F3 (USBImagerShots harness prints; lower priority, dev tool)
- NOT the CLI prints (`ListCommand`, `VerifyCommand`, `FlashCommand`): those are
  the program's stdout output contract and must stay `print()`.

WP-snapshot-dedup-deadcode (dedup formatter + remove dead code):

- F4, F5 (disk display-name label duplicated 3x -> route through the core
  `displayName` helper) -- the "dedup formatter" half. Note the byte-count
  formatter is already consolidated in `ByteFormatting.swift`; this is the
  separate decimal-GB device-label formatter.
- F6 (`SHA256Hasher` truly dead -> delete or mark with removal date)
- F7 (`FlashProgressSnapshot.make(from: FlashProgress)` + `label(for: FlashPhase)`
  with no production caller) -- the "remove dead code" half.
- F11 (doubled docstring cleanup) can ride along.

Not a work-package item (leave as-is, tracked elsewhere):

- F8, F9, F10 (public, test-covered API with no current production caller --
  keep unless the module surface is deliberately narrowed)
- F12 (signing-phase TODO -> signing milestone)
- F13 (documented unwired peer-pinning placeholder -> signing milestone)

## Finding counts per severity

| Severity | Count | IDs |
| --- | --- | --- |
| blocker | 0 | -- |
| high | 4 | F1, F2, F4, F5 |
| medium | 2 | F6, F7 |
| low | 7 | F3, F8, F9, F10, F11, F12, F13 |
| total | 13 | F1 - F13 |
