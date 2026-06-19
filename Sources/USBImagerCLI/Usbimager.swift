/// Usbimager.swift - the `usbimager` terminal executable root command.
///
/// This is the thin, secondary CLI front end for the macOS USB imager. The
/// SwiftUI app (`USBImagerApp`) stays the primary product; this binary is a
/// developer/automation entry point. It parses arguments with
/// `swift-argument-parser`, validates input, calls `USBImagerCore`, and exits
/// with the fixed status codes from the plan's `## CLI contract`.
///
/// This file wires the structure the subcommands fill in:
///   - a `ParsableCommand` root that registers all four subcommands, and
///   - the single shared exit path that turns a `CoreError` / `CoreExitCode`
///     into the process exit status (so no subcommand invents its own numbers),
///   - the injectable core-service seam (`CoreServices`) the subcommands reach
///     `USBImagerCore` through, defaulting to the real services and overridable
///     with a fake in tests.
///
/// The subcommand bodies (`list`, `verify`, `flash`, `open`) each live in their
/// own file under `Subcommands/`; see `ListCommand`, `VerifyCommand`,
/// `FlashCommand`, and `OpenCommand`.
///
/// Boundary (from the plan): this target depends on `USBImagerCore` and
/// `ArgumentParser` only. It reaches disk/verify/flash behavior through
/// `USBImagerCore`; the GUI library and the workflow libraries
/// (`DiskModel`/`Verifier`/`FlashEngine`/`KeychainStore`) stay reachable only
/// via `USBImagerCore`. No SwiftUI/AppKit.

import ArgumentParser
import Foundation
import USBImagerCore

// MARK: - CoreServices (injectable seam)

/// The bundle of `USBImagerCore` services a subcommand needs.
///
/// This is the test-injection seam the plan asks for: each subcommand reaches
/// core through this value instead of constructing services inline, so a test
/// can run a subcommand against fakes by setting `Usbimager.servicesOverride`.
///
/// `diskTarget` is optional because its real backing (`DefaultDiskTargetService`)
/// is failable -- a disk enumerator may be unavailable. A subcommand that needs
/// disk enumeration treats a `nil` here as `CoreError.badInput` and exits 2 via
/// the shared exit path; subcommands that do not touch disks ignore it.
public struct CoreServices: Sendable {

    /// Parse/validate checksums, match by filename, compare digests, Keychain cache.
    public let checksum: any ChecksumService

    /// Stat an image file for its byte length.
    public let imageSource: any ImageSourceService

    /// Enumerate disks and filter to safe write targets. `nil` when no enumerator
    /// is available (the real backing service is failable).
    public let diskTarget: (any DiskTargetService)?

    /// Drive a flash session and return a typed result.
    public let flashOrchestration: any FlashOrchestrationService

    /// Create a services bundle from explicit members.
    ///
    /// Tests use this to inject fakes; production uses `CoreServices.live()`.
    public init(
        checksum: any ChecksumService,
        imageSource: any ImageSourceService,
        diskTarget: (any DiskTargetService)?,
        flashOrchestration: any FlashOrchestrationService
    ) {
        self.checksum = checksum
        self.imageSource = imageSource
        self.diskTarget = diskTarget
        self.flashOrchestration = flashOrchestration
    }

    /// The real, production-wired services.
    ///
    /// The checksum and image-source services are pure wrappers and always
    /// construct. `DefaultDiskTargetService` is failable (it needs a live disk
    /// enumerator); when it cannot be built `diskTarget` is `nil` and a
    /// disk-touching subcommand reports `CoreError.badInput`.
    ///
    /// The flash orchestration service is built over `flashEngineFactory`. The
    /// default is the real `XPCFlashEngineFactory`, so `flash` is
    /// functional once the privileged helper is installed and approved. A missing
    /// or unapproved helper surfaces as a clear typed error and a non-zero exit
    /// (never a crash, never a hang): the orchestration service maps the helper's
    /// connection failure to its typed result. Tests pass an explicit fake factory
    /// (for example `HelperUnavailableEngineFactory`) to exercise the no-helper
    /// path deterministically.
    ///
    /// - Parameter flashEngineFactory: the factory the flash service obtains an
    ///   engine from. Defaults to the real XPC-backed factory.
    /// - Returns: the live services bundle.
    public static func live(
        flashEngineFactory: any FlashEngineFactory = XPCFlashEngineFactory()
    ) -> CoreServices {
        let services = CoreServices(
            checksum: DefaultChecksumService(),
            imageSource: DefaultImageSourceService(),
            diskTarget: DefaultDiskTargetService(),
            flashOrchestration: DefaultFlashOrchestrationService(engineFactory: flashEngineFactory)
        )
        return services
    }
}

// MARK: - Usbimager (root command)

/// The `usbimager` root command.
///
/// Registers the four subcommands and owns the shared service seam plus the
/// shared exit path. Running `usbimager` with no subcommand prints help (via
/// `subcommands` with no default), and `usbimager --help` /
/// `usbimager <sub> --help` print usage.
@main
struct Usbimager: ParsableCommand {

    /// Command metadata and the registered subcommands.
    ///
    /// `version` is the CLI version string. It is kept in sync with the repo
    /// `VERSION` file and the app Info.plist; `--version` reports this value.
    static let configuration = CommandConfiguration(
        commandName: "usbimager",
        abstract: "Flash and verify USB images from the terminal (thin CLI over USBImagerCore).",
        version: "26.06.0",
        subcommands: [
            ListCommand.self,
            VerifyCommand.self,
            FlashCommand.self,
            OpenCommand.self,
        ]
    )

    // MARK: - Injectable service seam

    /// Test override for the core services bundle.
    ///
    /// `nil` in production, where `services()` builds `CoreServices.live()`. A
    /// test sets this to a fake bundle so a subcommand runs against fakes; the
    /// per-subcommand delegation tests rely on this. The property is
    /// `nonisolated(unsafe)` because ArgumentParser drives the command tree on a
    /// single thread and tests set it before invoking a subcommand.
    nonisolated(unsafe) static var servicesOverride: CoreServices?

    /// The core services a subcommand should use.
    ///
    /// Returns the test override when set, otherwise the live production bundle.
    /// Subcommands call this rather than constructing services inline.
    ///
    /// - Returns: the resolved `CoreServices`.
    static func services() -> CoreServices {
        if let override = servicesOverride {
            return override
        }
        let live = CoreServices.live()
        return live
    }

    // MARK: - Shared exit path

    /// Exit the process with the status for a `CoreExitCode`.
    ///
    /// This is the single place a `CoreExitCode` becomes a process exit status,
    /// so every subcommand maps to one shared table. It calls `Foundation.exit`
    /// with the code's raw value and never returns.
    ///
    /// - Parameter code: the exit code to terminate with.
    static func exit(with code: CoreExitCode) -> Never {
        Foundation.exit(code.rawValue)
    }

    /// Print a `CoreError` to stderr and exit with its mapped status.
    ///
    /// The shared failure path: a subcommand that catches a `CoreError` hands it
    /// here, and the error's `exitCode` (the frozen contract mapping) becomes the
    /// process status. The message goes to stderr so stdout stays machine-clean.
    ///
    /// - Parameter error: the typed core error to report and exit on.
    static func fail(_ error: CoreError) -> Never {
        FileHandle.standardError.write(Data((errorMessage(for: error) + "\n").utf8))
        exit(with: error.exitCode)
    }

    /// A user-facing one-line message for a `CoreError`.
    ///
    /// Kept in one place so every subcommand reports the same wording for the
    /// same error.
    ///
    /// - Parameter error: the error to describe.
    /// - Returns: a single-line message.
    static func errorMessage(for error: CoreError) -> String {
        switch error {
        case .badInput(let message):
            return "Bad input: \(message)"
        case .verificationMismatch(let expected, let actual):
            return "Verification mismatch: expected \(expected), computed \(actual)."
        case .helperUnavailable(let message):
            return "Privileged helper unavailable: \(message)"
        case .flashFailed(let message):
            return "Flash failed: \(message)"
        case .cancelled:
            return "The operation was cancelled."
        case .appNotFound(let message):
            return "Could not locate the GUI app: \(message)"
        }
    }
}
