/// OpenCommand.swift - the `usbimager open` subcommand.
///
/// Launches or focuses the GUI app and preselects a source image through the
/// URL-scheme handoff mechanism: a `usbimager://` URL issued via the `open`
/// command-line tool (spawned as a child Process). The CLI percent-encodes and
/// validates the source before building the URL; a bad or missing source exits 2
/// and never touches the GUI. An optional `--auto-exit N` encodes
/// `autoExitAfter=N` into the payload so the GUI schedules its own clean
/// termination.
///
/// Using `Process` + `/usr/bin/open` (rather than `NSWorkspace.shared.open`)
/// keeps AppKit out of the CLI target, consistent with the "No SwiftUI/AppKit"
/// boundary (the CLI depends on USBImagerCore + ArgumentParser only).
///
/// The launch is the only side effect. On success the CLI exits 0. If the app
/// bundle cannot be located, exit 6.
///
/// This subcommand performs no flashing and no disk writes; it is kept
/// conceptually separate from `flash`.

import ArgumentParser
import Foundation
import USBImagerCore

// MARK: - OpenCommand

/// `usbimager open --source <iso> [--auto-exit N]`.
struct OpenCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Launch the GUI app with a source image preselected (no flashing)."
    )

    /// The image to preselect in the GUI.
    @Option(name: .long, help: "Path to the image file to preselect in the GUI.")
    var source: String

    /// Seconds after which the GUI cleanly self-terminates (automation/screenshots).
    @Option(name: .customLong("auto-exit"), help: "Seconds after which the GUI self-terminates.")
    var autoExit: Double?

    // MARK: - Run

    /// Validate the source, build the handoff URL, locate the app, and issue
    /// the URL via `/usr/bin/open`. Exits 2 for a bad/missing source; exits 6
    /// if the bundle is not found; exits 0 on success.
    func run() throws {
        let services = Usbimager.services()

        // 1. Validate the source is a readable file (exit 2 on failure).
        let sourceURL = URL(fileURLWithPath: source)
        do {
            _ = try services.imageSource.byteLength(of: sourceURL)
        } catch let coreError as CoreError {
            Usbimager.fail(coreError)
        } catch {
            Usbimager.fail(CoreError.badInput(message: "Cannot read source: \(error.localizedDescription)"))
        }

        // 2. Build the percent-encoded handoff URL.
        let handoffURL = OpenCommand.buildHandoffURL(sourcePath: source, autoExit: autoExit)

        // 3. Locate the app bundle (exit 6 if absent).
        let appBundleURL = try OpenCommand.locateAppBundle()
        _ = appBundleURL  // bundle is found; URL routing depends on prior registration

        // 4. Deliver the handoff URL via /usr/bin/open. This keeps AppKit out of
        // the CLI target (no NSWorkspace). The `open` tool routes the URL to the
        // registered handler -- the GUI bundle registered via a prior `open <bundle>.app`.
        try OpenCommand.issueURL(handoffURL)

        // Success: handoff issued.
        Usbimager.exit(with: .success)
    }
}

// MARK: - URL construction (testable, no side effects)

extension OpenCommand {

    /// Build the `usbimager://` handoff URL for a given source path.
    ///
    /// Encoding contract:
    ///   - Convert the path to a `file:` URL with `URL(fileURLWithPath:)`.
    ///   - Percent-encode the absolute URL string with `.urlQueryAllowed`.
    ///   - Append `autoExitAfter=N` when `autoExit` is provided.
    ///
    /// - Parameters:
    ///   - sourcePath: absolute or relative path to the image file.
    ///   - autoExit: optional seconds for the GUI to self-terminate.
    /// - Returns: the fully-formed `usbimager://open?...` URL.
    static func buildHandoffURL(sourcePath: String, autoExit: Double?) -> URL {
        let fileURL = URL(fileURLWithPath: sourcePath)
        // Percent-encode the file: URL string so query parsing on the receiving
        // side treats it as a single opaque value. Alphanumerics and unreserved
        // chars (- _ . ~) are left unencoded; everything else (including ':'
        // and '/') is percent-encoded. This matches what URLComponents.queryItems
        // decodes back to the original file: URL string via URL(string:).
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedSource = fileURL.absoluteString
            .addingPercentEncoding(withAllowedCharacters: unreserved) ?? fileURL.absoluteString

        var urlString = "usbimager://open?source=\(encodedSource)"
        if let n = autoExit {
            urlString += "&autoExitAfter=\(n)"
        }

        // Force-unwrap is safe: the string is well-formed by construction.
        return URL(string: urlString)!
    }

    /// Locate the `USBImagerApp.app` bundle assembled by `build_debug.sh`.
    ///
    /// Checks the repo-root-relative path: the bundle lives at
    /// `<repo-root>/USBImagerApp.app`. Derives the repo root by walking up
    /// four directory levels from the CLI executable
    /// (`.build/<arch>/<config>/usbimager`).
    ///
    /// - Returns: file URL pointing to the `.app` bundle directory.
    /// - Throws: `CoreError.appNotFound` (exit 6) when the bundle is absent.
    static func locateAppBundle() throws -> URL {
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
        // Walk up from .build/<arch>/<config>/usbimager -> four levels -> repo root.
        let repoRoot = execURL
            .deletingLastPathComponent()   // <config>/
            .deletingLastPathComponent()   // <arch>/
            .deletingLastPathComponent()   // .build/
            .deletingLastPathComponent()   // repo root

        let bundleURL = repoRoot.appendingPathComponent("USBImagerApp.app")

        // Confirm the bundle directory exists.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: bundleURL.path, isDirectory: &isDir)
        guard exists && isDir.boolValue else {
            throw CoreError.appNotFound(
                message: "USBImagerApp.app not found at \(bundleURL.path). Run build_debug.sh first."
            )
        }
        return bundleURL
    }

    /// Deliver a URL to the system via `/usr/bin/open`.
    ///
    /// Spawns `/usr/bin/open <url-string>` as a child process and waits for it
    /// to complete. `open` exits 0 on success; a non-zero exit maps to
    /// `CoreError.appNotFound` (exit 6) because the most likely cause is a
    /// routing failure (bundle not registered with LaunchServices).
    ///
    /// - Parameter url: the URL to deliver.
    /// - Throws: `CoreError.appNotFound` when `open` exits non-zero.
    static func issueURL(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CoreError.appNotFound(
                message: "/usr/bin/open exited \(process.terminationStatus) for URL \(url). "
                    + "Ensure the app bundle is registered (run: open USBImagerApp.app) first."
            )
        }
    }
}
