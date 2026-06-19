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

All 325 unit tests should pass. Tests cover DiskModel, FlashEngine, Verifier, KeychainStore,
HelperProtocol, AppUI, USBImagerCore, and USBImagerCLI modules.

## Run

```bash
.build/arm64-apple-macosx/debug/USBImagerApp
```

The UI launches and is navigable through source selection and target selection.
The flash step requires a signed, installed privileged helper; see [SIGNING.md](SIGNING.md).

The GUI no longer parses launch flags. Source preselection is handled via the custom URL
scheme `usbimager://open?source=<percent-encoded file URL>&autoExitAfter=N`, which is issued
by the `usbimager open` CLI subcommand (see below).

`capture_screenshot.sh` at the repo root runs `swift run USBImagerShots`, which renders the
four panels offscreen via `ImageRenderer` with `NSApplication` activation policy `.prohibited`
(no window, no focus stolen). It writes `screenshots/main_window.png` (idle, step 1) and
`screenshots/step2_target.png` (preselected source advancing to step 2), and exits non-zero if
the step-2 state was not reached.

## Command-line interface (usbimager)

`usbimager` is a headless CLI entry point built as the `USBImagerCLI` target. It provides four
subcommands that reach the app's core logic through the `USBImagerCore` seam without importing
SwiftUI or AppKit.

```bash
.build/arm64-apple-macosx/debug/usbimager --help
```

### Subcommands

**`usbimager list`**

Print safe removable target disks. Outputs one line per eligible disk.

```bash
usbimager list
```

**`usbimager verify <image> [--sha512 <hex> | --sums <file>]`**

Hash the image file with SHA-512 and print the digest. When a comparison target is provided,
also prints whether it matched.

```bash
usbimager verify debian.iso
usbimager verify debian.iso --sha512 <128-hex-char digest>
usbimager verify debian.iso --sums SHA512SUMS
```

**`usbimager flash --source <iso> --target <bsd> [--verify]`**

Headless flash via the privileged helper. Prints one progress line per sample.
`--verify` performs a device read-back after the write and compares the SHA-512.

```bash
usbimager flash --source debian.iso --target disk4
usbimager flash --source debian.iso --target disk4 --verify
```

Requires the privileged helper to be installed and approved; see [SIGNING.md](SIGNING.md).
A missing or unapproved helper surfaces as a connection failure during the flash run
(exit 4). Exit 3 is emitted only when the engine factory cannot construct the connection
(for example, a malformed designated requirement).

**`usbimager open --source <iso> [--auto-exit N]`**

Launch or focus the GUI and preselect the source via the URL-scheme handoff. The command
validates the source file, builds a percent-encoded `usbimager://open` URL, locates
`USBImagerApp.app` relative to the CLI executable, and delivers the URL via `/usr/bin/open`.
`--auto-exit N` rides in the URL payload so the GUI self-terminates cleanly after N seconds.

```bash
usbimager open --source debian.iso
usbimager open --source debian.iso --auto-exit 5
```

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Verification mismatch |
| 2 | Bad input or usage error |
| 3 | Engine factory could not construct the helper connection |
| 4 | Flash failed mid-write (includes helper unavailable / connection failure) |
| 5 | Cancelled |
| 6 | GUI app not locatable (`open` subcommand only) |

## Targets

| Target | Type | Description |
| --- | --- | --- |
| DiskModel | Library | Enumerates and filters removable block devices |
| HelperProtocol | Library | Shared XPC contract between app and helper |
| Verifier | Library | SHA-512 streaming verification |
| KeychainStore | Library | Trusted checksum cache in the system Keychain |
| FlashEngine | Library | Actor-based flash orchestration over XPC |
| USBImagerCore | Library | Core workflow seam shared by GUI and CLI |
| AppUI | Library | SwiftUI panels and AppViewModel state machine (depends on USBImagerCore) |
| USBImagerApp | Executable | App entry point |
| PrivilegedHelper | Executable | Root LaunchDaemon for raw device writes |
| USBImagerCLI | Executable | `usbimager` CLI entry point |
| USBImagerShots | Executable | Offscreen screenshot render harness |
