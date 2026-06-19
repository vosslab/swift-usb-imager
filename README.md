# swift-usb-imager

SwiftUI USB and SD card imager for Apple Silicon Macs that flashes ISO and IMG disk images with SHA-512 verification. Built for macOS 26 Tahoe with native Liquid Glass styling, plus a thin usbimager CLI for scripted flashing.


## Status

Version 26.06.0. Early development. The library modules, SwiftUI app, and `usbimager` CLI compile and pass the test suite (350+ tests), and the GUI and CLI are fully usable up to the flash step. The privileged write path is still in progress: there is no installed daemon yet, so a flash attempt fails at connection time. Bringing it up requires the XPC daemon wiring plus Developer ID signing and SMAppService installation (see [docs/SIGNING.md](docs/SIGNING.md)). In parallel, a least-persistent authopen-based raw-disk-write model is under active research; its verdict is pending a hardware run, and no production flash code commits to a backend yet.

## Quick start

Prerequisites: macOS 26 (Tahoe), Xcode 26, Apple Silicon Mac. See [docs/INSTALL.md](docs/INSTALL.md).

```bash
git clone https://github.com/vosslab/swift-usb-imager.git
cd swift-usb-imager
./build_debug.sh
swift test
.build/arm64-apple-macosx/debug/USBImagerApp
```

Note: flashing is not yet operational; it needs the privileged write path completed and a signed, installed helper (see [docs/SIGNING.md](docs/SIGNING.md)). The GUI launches and is navigable without it. For CLI usage (`list`, `verify`, `flash`, `open` subcommands) see [docs/USAGE.md](docs/USAGE.md).

## Documentation

- [docs/CODE_ARCHITECTURE.md](docs/CODE_ARCHITECTURE.md): layered design, XPC privilege-separation model, and data flow
- [docs/FILE_STRUCTURE.md](docs/FILE_STRUCTURE.md): directory map and where to add new work
- [docs/SIGNING.md](docs/SIGNING.md): Developer ID signing, notarization, and privileged helper installation
- [docs/INSTALL.md](docs/INSTALL.md): prerequisites and build commands
- [docs/USAGE.md](docs/USAGE.md): build, test, and run commands
- [docs/CHANGELOG.md](docs/CHANGELOG.md): chronological record of changes
