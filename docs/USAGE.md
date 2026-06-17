# USAGE.md

How to build, test, and run swift-usb-imager.

## Build

```bash
./build_debug.sh      # debug build (fast, symbols included)
./build_release.sh    # optimized release build
```

## Test

```bash
swift test
```

All 203 unit tests should pass. Tests cover DiskModel, FlashEngine, Verifier, KeychainStore, HelperProtocol, and AppUI modules.

## Run

```bash
.build/arm64-apple-macosx/debug/USBImagerApp
```

The UI launches and is navigable through source selection and target selection.
The flash step requires a signed, installed privileged helper; see [SIGNING.md](SIGNING.md).

Launch flags:

- `--source PATH` - pre-select a source image at launch; opens on step 2.
- `--auto-exit SECONDS` - quit automatically after N seconds; requires a value
  (`--auto-exit=5` or `--auto-exit 5`).
- `-h` / `--help` - print usage and exit without launching the GUI.

`capture_screenshot.sh` at the repo root builds, launches, and screenshots the app
in one step. The resulting screenshot is saved to `screenshots/main_window.png`.

## Targets

| Target | Type | Description |
| --- | --- | --- |
| DiskModel | Library | Enumerates and filters removable block devices |
| HelperProtocol | Library | Shared XPC contract between app and helper |
| Verifier | Library | SHA-512 streaming verification |
| KeychainStore | Library | Trusted checksum cache in the system Keychain |
| FlashEngine | Library | Actor-based flash orchestration over XPC |
| AppUI | Library | SwiftUI panels and AppViewModel state machine |
| USBImagerApp | Executable | App entry point |
| PrivilegedHelper | Executable | Root LaunchDaemon for raw device writes |
