/// ListCommand.swift - the `usbimager list` subcommand.
///
/// Prints one row per safe target disk (bsd name, size, bus, display name) via
/// the core disk service. When no safe targets exist, prints a clear line and
/// exits 0 (that is a normal, not an error, condition). When the disk service is
/// unavailable (no DiskArbitration session), exits 2 via the shared error path.
///
/// Disk-safety filtering stays entirely in `DiskModel`; this command only calls
/// `snapshotDisks()` + `validTargets(from:imageSizeBytes:sourceBackingBSDName:)`.

import ArgumentParser
import Foundation
import USBImagerCore

/// `usbimager list` -- print the safe target disks.
struct ListCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List USB disks that are safe to flash to."
    )

    // MARK: - Run

    /// Enumerate safe target disks and print one row each.
    ///
    /// Resolves core services through the injectable seam so tests can inject a
    /// recording fake. When `diskTarget` is nil (no DiskArbitration session),
    /// treats it as a bad-environment failure and exits 2.
    func run() throws {
        let services = Usbimager.services()

        // A nil diskTarget means no enumerator/session is available -- bad environment.
        guard let diskService = services.diskTarget else {
            Usbimager.fail(.badInput(message: "No disk enumeration session available (sandboxed or permission denied)."))
        }

        // Drive the async disk snapshot from the synchronous ArgumentParser run() hook.
        // `swift run` / the CLI entry point does not supply a top-level async context,
        // so we block on a Task that hops to the DiskEnumerator actor.
        let snapshot = runBlocking { await diskService.snapshotDisks() }

        // Filter to safe write targets. Pass imageSizeBytes: 0 (no image loaded)
        // and sourceBackingBSDName: nil (no source path) so the safety filter
        // eliminates unsafe disks without imposing a size floor.
        let targets = diskService.validTargets(
            from: snapshot,
            imageSizeBytes: 0,
            sourceBackingBSDName: nil
        )

        // Normal case: no removable target disks present.
        if targets.isEmpty {
            print("No removable target disks found.")
            return
        }

        // Print one row per target: "bsdName  bus  sizeString  displayName"
        // The display name already includes bsdName, bus, and size in a readable
        // format ("disk4  (USB, 32.0 GB)"). We print it as-is so both human and
        // script consumers get the same line.
        for disk in targets {
            let name = diskService.displayName(for: disk)
            print(name)
        }
    }
}

// MARK: - runBlocking helper

/// Block the calling thread until `body` completes and return its result.
///
/// `ListCommand.run()` is synchronous (ArgumentParser's `run()` is not `async`).
/// The core snapshot is `async` because it hops to the `DiskEnumerator` actor.
/// This helper bridges the boundary with the minimum overhead: spin up a detached
/// task, wait on a semaphore, and forward the result.
///
/// Scope: private to this file; only `ListCommand.run()` calls it.
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
