# swift-usb-imager

Native macOS app for Apple Silicon that writes ISO and IMG disk images to USB drives and SD cards, then verifies each flash with SHA-512. Targets macOS 26 Tahoe and uses the native Liquid Glass design language.

## Status

Early development. Core library modules and UI compile and pass 203 tests. Signing and privileged helper installation are pending; the UI is fully usable up to the flash step.

## Quick start

Prerequisites: macOS 26 (Tahoe), Xcode 26, Apple Silicon Mac. See [docs/INSTALL.md](docs/INSTALL.md).

```bash
git clone https://github.com/vosslab/swift-usb-imager.git
cd swift-usb-imager
./build_debug.sh
swift test
.build/arm64-apple-macosx/debug/USBImagerApp
```

Note: flashing requires a signed, installed privileged helper (see [docs/SIGNING.md](docs/SIGNING.md)). The UI launches and is navigable without it.

## Documentation

- [docs/CODE_ARCHITECTURE.md](docs/CODE_ARCHITECTURE.md): layered design, XPC privilege-separation model, and data flow
- [docs/SIGNING.md](docs/SIGNING.md): Developer ID signing, notarization, and privileged helper installation
- [docs/INSTALL.md](docs/INSTALL.md): prerequisites and build commands
- [docs/USAGE.md](docs/USAGE.md): build, test, and run commands
- [docs/CHANGELOG.md](docs/CHANGELOG.md): chronological record of changes
