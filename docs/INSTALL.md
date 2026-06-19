# INSTALL.md

Prerequisites and build setup for swift-usb-imager.

## Version

Current release: **26.06.0** (CalVer 0Y.0M.PATCH). The canonical version is in the repo-root
[VERSION](../VERSION) file; `usbimager --version` and the app Info.plist match it.

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26 with the macOS 26 SDK (provides Swift 6.2 and SwiftPM 6.2)
- Apple Silicon Mac (arm64)
- SwiftPM resolves one package dependency (`swift-argument-parser` 1.3.0+) on first
  build; internet access is required for that initial resolution

## Build

```bash
./build_debug.sh      # debug build
./build_release.sh    # release build
```

## Test

```bash
swift test
```

## Signing (optional)

Flashing to raw devices requires a signed and installed privileged helper.
See [SIGNING.md](SIGNING.md) for the full runbook.
