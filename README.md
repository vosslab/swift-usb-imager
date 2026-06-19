# swift-usb-imager

SwiftUI app for Apple Silicon Mac that flashes ISO and IMG disk images to USB drives and SD cards with SHA-512 verification. Targets macOS 26 Tahoe with the native Liquid Glass design language. Also ships a thin usbimager terminal CLI for scripted or automated flashing workflows.

## Status

Version 26.06.0. Early development. Core library modules, UI, and CLI compile and pass 325 tests. Signing and privileged helper installation are pending; the GUI and CLI are fully usable up to the flash step.

## Quick start

Prerequisites: macOS 26 (Tahoe), Xcode 26, Apple Silicon Mac. See [docs/INSTALL.md](docs/INSTALL.md).

```bash
git clone https://github.com/vosslab/swift-usb-imager.git
cd swift-usb-imager
./build_debug.sh
swift test
.build/arm64-apple-macosx/debug/USBImagerApp
```

Note: flashing requires a signed, installed privileged helper (see [docs/SIGNING.md](docs/SIGNING.md)). The GUI launches and is navigable without it. For CLI usage (list/verify/flash/open subcommands) see [docs/USAGE.md](docs/USAGE.md).

## Documentation

- [docs/CODE_ARCHITECTURE.md](docs/CODE_ARCHITECTURE.md): layered design, XPC privilege-separation model, and data flow
- [docs/FILE_STRUCTURE.md](docs/FILE_STRUCTURE.md): directory map and where to add new work
- [docs/SIGNING.md](docs/SIGNING.md): Developer ID signing, notarization, and privileged helper installation
- [docs/INSTALL.md](docs/INSTALL.md): prerequisites and build commands
- [docs/USAGE.md](docs/USAGE.md): build, test, and run commands
- [docs/CHANGELOG.md](docs/CHANGELOG.md): chronological record of changes
