# Sources

SwiftPM library modules live here. Each subdirectory is one package target.

## SwiftPM targets (this directory)

| Directory | Target | Status |
| --- | --- | --- |
| `Sources/DiskModel/` | `DiskModel` | Scaffold; disk enumeration and safety filtering |
| `Sources/HelperProtocol/` | `HelperProtocol` | Scaffold; shared XPC contract for the privileged helper |
| `Sources/Verifier/` | `Verifier` | Scaffold; SHA-512 hashing and checksum file parsing |
| `Sources/KeychainStore/` | `KeychainStore` | Scaffold; Keychain trusted-checksum cache |

## Xcode-only targets (not here yet)

Two additional components are planned as Xcode targets, not SwiftPM targets.
They depend on signing, entitlements, and embedded-binary rules that Xcode
manages. Do NOT add them as SwiftPM targets.

- `AppUI/` - SwiftUI four-panel flash flow. Depends on all four library modules
  above plus `FlashEngine` (app-side XPC orchestration).
- `PrivilegedHelper/` - SMAppService LaunchDaemon root helper. Signed separately
  with a matching Developer ID identity; never sandboxed; communicates with the
  app over NSXPCConnection using `HelperProtocol`.

Both directories will be created when their Xcode target work begins
(`PrivilegedHelper/` before `AppUI/`).
