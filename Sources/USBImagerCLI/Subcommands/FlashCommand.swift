/// FlashCommand.swift - the `usbimager flash` subcommand.
///
/// Drives the core flash service directly with no GUI: resolve the target via the
/// core disk service, validate the source, call `FlashOrchestrationService.flash`,
/// print one concise progress line per sample, and exit with a documented code.
///
/// Boundaries (from the plan):
///   - Contains no write/unmount/disk-safety logic of its own; every step
///     delegates to `USBImagerCore`. The CLI target imports only `USBImagerCore`
///     and `ArgumentParser` -- the XPC/`FlashEngine` details live in core (the
///     real engine factory is `USBImagerCore.XPCFlashEngineFactory`, selected by
///     `CoreServices.live()`).
///   - Never launches the GUI; `open` is the only GUI-launching subcommand.
///
/// Exit codes (the frozen `## CLI contract` mapping, applied via the shared exit
/// path so this command invents no numbers):
///   - 0  success (write completed; with `--verify`, read-back matched too)
///   - 1  verification mismatch (`--verify` read-back digest != source digest)
///   - 2  bad input (unreadable source, or unknown target BSD name)
///   - 3  privileged helper unavailable / not approved
///   - 4  flash failed mid-write (I/O or device error)
///   - 5  operation cancelled
///
/// Helper-absent path: when the helper cannot be reached the orchestration
/// service returns `.failure(.helperUnavailable)`, which maps to exit 3 with a
/// clear message -- no crash, no hang. A real flash requires the helper installed
/// plus a scratch USB device and is a documented manual run, not a unit test.

import ArgumentParser
import Dispatch
import Foundation
import USBImagerCore

// MARK: - FlashCommand

/// `usbimager flash --source <iso> --target <bsd> [--verify]`.
struct FlashCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "flash",
        abstract: "Write an image to a USB disk through the privileged helper (no GUI)."
    )

    /// The image to write. ArgumentParser accepts both `--source PATH` and
    /// `--source=PATH`; there is no AppKit in a CLI process to intercept the path.
    @Option(name: .long, help: "Path to the image file to write.")
    var source: String

    /// The BSD name of the target disk (for example disk4).
    @Option(name: .long, help: "BSD name of the target disk (for example disk4).")
    var target: String

    /// Read back and verify the written device after the flash.
    @Flag(name: .long, help: "Read back and verify the written device after flashing.")
    var verify: Bool = false

    // MARK: - Run

    /// Resolve the target, validate the source, run the flash, and exit with a
    /// documented code. All work delegates to `USBImagerCore`.
    ///
    /// The resolve/validate/orchestrate work is factored into `performFlash`, which
    /// returns a typed outcome without terminating the process; `run()` only routes
    /// that outcome to the shared exit path (success prints the digest and exits 0,
    /// a failure hands its `CoreError` to `Usbimager.fail`). Keeping the exit out of
    /// `performFlash` is what lets the delegation tests drive the full path against
    /// fakes and assert the exit-code mapping without killing the test process.
    func run() throws {
        let services = Usbimager.services()
        let outcome = FlashCommand.performFlash(
            sourcePath: source,
            targetBSDName: target,
            verifyReadBack: verify,
            services: services,
            progress: { sample in
                // Progress callbacks may arrive on any task; printing is safe and the
                // line is intentionally concise for human and log consumers.
                print(FlashCommand.progressLine(for: sample))
            }
        )

        switch outcome {
        case .success(let deviceSHA512):
            print("Flash complete. Device SHA-512: \(deviceSHA512)")
            Usbimager.exit(with: .success)
        case .failure(let error):
            Usbimager.fail(error)
        }
    }
}

// MARK: - Flash orchestration (testable, no process exit)

extension FlashCommand {

    /// Resolve the target, validate the source, and drive the core flash service,
    /// returning the typed `FlashRunResult` without terminating the process.
    ///
    /// This is the full `flash` behavior minus the final `Foundation.exit`: it
    /// resolves the BSD name through the core disk service (unknown -> a
    /// `.failure(.badInput)`), validates the source via the core image-source
    /// service (unreadable -> `.failure(.badInput)`), then calls
    /// `FlashOrchestrationService.flash` with `advisorySHA512: nil` and
    /// `verifyReadBack` taken straight from `--verify`. Every result case is the
    /// orchestration service's own typed outcome, which the caller maps to an exit
    /// code via `CoreError.exitCode` (the frozen contract mapping).
    ///
    /// - Parameters:
    ///   - sourcePath: the `--source` path to validate and flash.
    ///   - targetBSDName: the `--target` BSD name to resolve.
    ///   - verifyReadBack: whether `--verify` was set (maps to read-back verify).
    ///   - services: the resolved core services (real or injected fakes).
    ///   - progress: invoked for each numeric progress sample.
    /// - Returns: the typed `FlashRunResult`; bad input / unknown target arrive as
    ///   `.failure(.badInput)`.
    static func performFlash(
        sourcePath: String,
        targetBSDName: String,
        verifyReadBack: Bool,
        services: CoreServices,
        progress: @escaping @Sendable (FlashProgressData) -> Void
    ) -> FlashRunResult {
        // A nil diskTarget means no enumerator/session is available -- bad environment.
        guard let diskService = services.diskTarget else {
            return .failure(error: .badInput(
                message: "No disk enumeration session available (sandboxed or permission denied)."
            ))
        }

        // 1. Resolve the target BSD name to a descriptor. The async lookup hops to
        //    the DiskEnumerator actor, so block on it. An unknown name is bad input;
        //    core never writes an unsafe disk.
        guard let descriptor = runBlocking({ await diskService.diskDescriptor(withBSDName: targetBSDName) }) else {
            return .failure(error: .badInput(
                message: "Unknown target \"\(targetBSDName)\": no attached disk has that BSD name. Run `usbimager list`."
            ))
        }

        // 2. Validate the source is a readable file. This is a stat only; the helper
        //    opens the file itself and bytes never enter the CLI.
        let sourceURL = URL(fileURLWithPath: sourcePath)
        do {
            _ = try services.imageSource.byteLength(of: sourceURL)
        } catch let coreError as CoreError {
            return .failure(error: coreError)
        } catch {
            return .failure(error: .badInput(
                message: "Cannot read source \"\(sourcePath)\": \(error.localizedDescription)"
            ))
        }

        // 3. Drive the flash through core. advisorySHA512 is nil (the CLI flash path
        //    does not pre-hash the source); --verify maps directly to verifyReadBack.
        let result = runBlocking {
            await services.flashOrchestration.flash(
                source: sourceURL,
                target: descriptor,
                advisorySHA512: nil,
                verifyReadBack: verifyReadBack,
                progress: progress
            )
        }
        return result
    }
}

// MARK: - Progress formatting (testable, pure)

extension FlashCommand {

    /// Format one `FlashProgressData` sample as a concise single-line status.
    ///
    /// Shows the phase, a percentage when a fraction is known, and the byte
    /// counts. When `totalBytes` is `0` (no denominator yet) the percentage is
    /// omitted rather than printing a misleading `0%`.
    ///
    /// - Parameter sample: the numeric progress sample from core.
    /// - Returns: a single status line (no trailing newline; `print` adds one).
    static func progressLine(for sample: FlashProgressData) -> String {
        // Phase label, GUI-neutral and stable for log scraping.
        let phaseLabel: String
        switch sample.phase {
        case .writing:
            phaseLabel = "writing"
        case .verifying:
            phaseLabel = "verifying"
        }

        // Percentage only when a fraction is available (totalBytes > 0).
        let percentPart: String
        if let fraction = sample.fraction {
            let percent = Int((fraction * 100).rounded())
            percentPart = " \(percent)%"
        } else {
            percentPart = ""
        }

        let line = "[\(phaseLabel)]\(percentPart) \(sample.bytesDone)/\(sample.totalBytes) bytes"
        return line
    }
}

// MARK: - runBlocking helper

/// Block the calling thread until `body` completes and return its result.
///
/// `FlashCommand.run()` is synchronous (ArgumentParser's `run()` is not `async`).
/// The core disk lookup and flash orchestration are `async` because they hop to
/// the `DiskEnumerator` / `FlashEngine` actors. This helper bridges the boundary:
/// spin up a detached task, wait on a semaphore, and forward the result.
///
/// Scope: private to this file; only `FlashCommand.run()` calls it.
///
/// - Parameter body: the async work to block on.
/// - Returns: the value produced by `body`.
private func runBlocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    // nonisolated(unsafe) is required because the value crosses the concurrency
    // boundary via a semaphore rather than through Swift's structured concurrency.
    // The semaphore guarantees the assignment happens-before the read below.
    nonisolated(unsafe) var result: T? = nil
    Task.detached {
        result = await body()
        semaphore.signal()
    }
    semaphore.wait()
    // Force-unwrap is safe: `result` is set before `semaphore.signal()`.
    return result!
}
