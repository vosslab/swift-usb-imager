# Sources

SwiftPM library modules live here. Each subdirectory is one package target.

## SwiftPM targets (this directory)

| Directory | Target | Status |
| --- | --- | --- |
| `Sources/DiskModel/` | `DiskModel` | Scaffold; real implementation in WS-1b + WS-1c |
| `Sources/HelperProtocol/` | `HelperProtocol` | Scaffold; real implementation in WS-2b |
| `Sources/Verifier/` | `Verifier` | Scaffold; real implementation in WS-3a + WS-3c |
| `Sources/KeychainStore/` | `KeychainStore` | Scaffold; real implementation in WS-3c |

## Xcode-only targets (not here yet)

Two additional components are planned as Xcode targets, not SwiftPM targets.
They depend on signing, entitlements, and embedded-binary rules that Xcode
manages. Do NOT add them as SwiftPM targets.

- `AppUI/` - SwiftUI four-panel flash flow (WS-4a/WS-4b). Depends on all four
  library modules above plus `FlashEngine` (app-side XPC orchestration).
- `PrivilegedHelper/` - SMAppService LaunchDaemon root helper (WS-2a/WS-2c).
  Signed separately with a matching Developer ID identity; never sandboxed;
  communicates with the app over NSXPCConnection using `HelperProtocol`.

Both directories will be created when their Xcode target work begins (M2 for
`PrivilegedHelper/`, M4 for `AppUI/`).
