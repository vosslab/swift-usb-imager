/// USBImagerApp.swift - SwiftUI @main entry point for the macOS USB imager.
///
/// Constructs a single `AppViewModel` wired to the production XPC helper and
/// presents `RootView` inside a single resizable window.
///
/// Launch flags are parsed via Apple's swift-argument-parser (see LaunchOptions
/// below). The app is GUI-first: with no flags it launches the window normally.
/// The flags below are debug/testing conveniences (preselect a source for
/// screenshots, auto-exit for unattended runs); a GUI app never requires CLI
/// input to function.
///
/// Supported launch flags:
///   --source=PATH      Pre-select PATH as the source image on launch.
///                      If PATH does not exist the flag is ignored and the app
///                      stays on step 1. Use the equals form: a trailing
///                      space-separated path argument (--source PATH) is
///                      intercepted by AppKit's open-files handling and
///                      suppresses the WindowGroup window.
///   --auto-exit=N      Quit the app after N seconds. Requires a value
///                      (--auto-exit=N or --auto-exit N); absent = no auto-exit.
///   -h / --help        Print usage and exit without launching the GUI
///                      (supplied automatically by ArgumentParser).
///
/// TODO (signing phase):
///   - Replace `helperMachServiceName` with the final SMAppService daemon name
///     once the helper's Info.plist and launchd plist are committed.
///   - Replace `helperRequirementString` with the real Apple-signed designated
///     requirement for the privileged helper (e.g.
///     `anchor apple generic and identifier "com.nsh.usbimager.helper"`).
///   - The `CodeSigningRequirement` init throws when the string is structurally
///     invalid; `fatalError` here is intentional - a bad requirement string is a
///     programmer error that must be caught before shipping.

import AppKit
import AppUI
import ArgumentParser
import FlashEngine
import HelperProtocol
import SwiftUI

// MARK: - Constants

/// Mach service name registered by the privileged helper via SMAppService.
/// Replace with the real daemon bundle ID during the signing phase.
private let helperMachServiceName = "com.nsh.usbimager.helper"

/// Designated-requirement string used to pin the XPC peer's code-signing identity.
/// Replace with the real Apple-signed requirement during the signing phase.
private let helperRequirementString = #"identifier "com.nsh.usbimager.helper" and anchor apple generic"#

// MARK: - Argument parsing

/// Structured launch options parsed by swift-argument-parser.
///
/// Both options are optional and exist only as debug/testing conveniences: the
/// app is GUI-first, so launching with no arguments opens the window normally.
/// ArgumentParser supplies --help and clean error messages automatically via
/// parseOrExit().
///
/// Note: use the equals form for --source (--source=PATH). swift-argument-parser
/// consumes the equals form as a single token before AppKit sees it. A trailing
/// space-separated path argument (--source PATH) is instead intercepted by
/// AppKit's open-files handling and suppresses the WindowGroup window.
///
/// Note: --auto-exit requires a value (--auto-exit=N or --auto-exit N); a bare
/// --auto-exit is no longer accepted. Absent flag means no auto-exit.
struct LaunchOptions: ParsableArguments {

    /// Pre-select a source image at launch; nil when the flag is absent.
    @Option(
        name: [.customLong("source")],
        help: "Pre-select a source image (.iso/.img) at launch; opens on step 2. Use --source=PATH (equals form)."
    )
    var source: String?

    /// Seconds until auto-exit; nil when the flag is absent.
    @Option(
        name: [.customLong("auto-exit")],
        help: "Quit automatically after this many seconds (useful for testing/screenshots)."
    )
    var autoExit: Double?
}

// MARK: - AppEntry

/// @main entry point that handles --help and then hands off to SwiftUI.
///
/// Argument parsing happens here, before the GUI is constructed, so that
/// `--help` and `--source` work even in non-interactive (headless) contexts.
@main
enum AppEntry {
    static func main() {
        // parseOrExit() handles --help and argument errors, printing usage and
        // exiting with the appropriate status before the GUI is constructed.
        let opts = LaunchOptions.parseOrExit()

        // Forward the parsed struct to USBImagerApp so the SwiftUI .task
        // closures can read from it without their own arg parsing.
        USBImagerApp.launchOptions = opts

        USBImagerApp.main()
    }
}

// MARK: - App

struct USBImagerApp: App {

    // MARK: Statics set by AppEntry before SwiftUI launches

    /// Parsed launch options set once in AppEntry.main() before the GUI starts.
    /// Both fields are optional, so the default init yields nil/nil (GUI-first launch).
    /// Written once at startup; read-only afterward, so nonisolated(unsafe) is sound.
    nonisolated(unsafe) static var launchOptions = LaunchOptions()

    // MARK: State

    @State private var viewModel: AppViewModel = {
        // CodeSigningRequirement.init throws only when the string is structurally
        // malformed. fatalError is correct here - invalid requirement is a
        // programmer error that must be caught before shipping.
        let requirement: CodeSigningRequirement
        do {
            requirement = try CodeSigningRequirement(requirementString: helperRequirementString)
        } catch {
            fatalError("Invalid code-signing requirement string: \(error)")
        }
        let connection = XPCHelperConnection(
            machServiceName: helperMachServiceName,
            peerRequirement: requirement
        )
        return AppViewModel(helperConnection: connection)
    }()

    // MARK: Scene

    var body: some Scene {
        WindowGroup {
            RootView(vm: viewModel)
                // --source preselect: guard existence, log result, then preselect.
                .task {
                    guard let path = USBImagerApp.launchOptions.source else { return }
                    guard FileManager.default.fileExists(atPath: path) else {
                        print("[USBImagerApp] --source: file not found: \(path); staying on step 1")
                        return
                    }
                    print("[USBImagerApp] --source: preselecting \(path)")
                    await viewModel.selectSource(URL(fileURLWithPath: path))
                    print("[USBImagerApp] --source: source bytes \(viewModel.sourceImageBytes); now on step \(viewModel.flashState.currentStep)")
                }
                // --auto-exit: quit after the specified delay.
                .task {
                    guard let secs = USBImagerApp.launchOptions.autoExit else { return }
                    try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                    NSApplication.shared.terminate(nil)
                }
        }
        .windowResizability(.contentMinSize)
    }
}
