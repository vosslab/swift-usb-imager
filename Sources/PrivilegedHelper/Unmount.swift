/// Unmount.swift -- detach every volume on the target whole disk before writing.
///
/// A raw write to `/dev/rdiskN` requires `O_EXCL`, which the kernel denies while
/// any volume on that disk is mounted. The helper therefore unmounts the WHOLE
/// disk first. `diskutil unmountDisk force /dev/diskN` tears down every mounted
/// volume on the unit in one call and is the documented, supported way to do
/// this; wrapping the CLI keeps the helper free of private DiskArbitration
/// unmount-callback plumbing for this milestone (the DADiskUnmount path can
/// replace the Process call later without changing this function's contract).
///
/// Hard refusal: the helper NEVER unmounts a disk that has a volume mounted at
/// "/" (the live system root). That guard is independent of `DiskSafety` and is
/// the last line of defense against detaching the running system.

import Foundation
import DiskModel

// MARK: - Unmount

/// Namespace for the whole-disk unmount step. No instances are created.
public enum Unmount {

    /// Path to the system `diskutil` tool. Absolute and fixed; the helper runs
    /// in a controlled root context where this is the canonical location.
    public static let diskutilPath = "/usr/sbin/diskutil"

    /// Unmount every volume on the whole disk described by `descriptor`.
    ///
    /// Refuses outright when any of the disk's mount points is "/", then runs
    /// `diskutil unmountDisk force` on the device path. A non-zero exit status
    /// is a hard error; the caller must not proceed to open the raw device.
    ///
    /// - Parameters:
    ///   - descriptor: The live whole-disk descriptor (already safety-checked).
    ///   - runner: Injectable process runner. Defaults to the real `diskutil`
    ///     invocation; tests pass a closure returning a synthetic result.
    /// - Throws: `HelperError.refusedRootMount` if a volume is mounted at "/",
    ///   or `HelperError.unmountFailed` when `diskutil` reports failure.
    public static func unmountWholeDisk(
        _ descriptor: DiskDescriptor,
        runner: (String, [String]) -> ProcessRunResult = Unmount.runProcess
    ) throws {
        // Last-line guard: never detach the live system root, regardless of what
        // DiskSafety said upstream.
        if descriptor.mountPoints.contains("/") {
            throw HelperError.refusedRootMount(bsdName: descriptor.bsdName)
        }

        // `unmountDisk` operates on the whole-disk node and tears down every
        // volume; `force` proceeds even when a volume is busy.
        let arguments = ["unmountDisk", "force", descriptor.devicePath]
        let result = runner(diskutilPath, arguments)
        guard result.exitCode == 0 else {
            let detail = "diskutil exit " + String(result.exitCode)
                + ": " + result.combinedOutput
            throw HelperError.unmountFailed(detail: detail)
        }
    }

    /// Result of running an external process: exit code plus merged output.
    public struct ProcessRunResult: Sendable, Equatable {

        /// The process exit status (0 means success).
        public let exitCode: Int32

        /// Merged stdout + stderr, trimmed, for inclusion in error messages.
        public let combinedOutput: String

        public init(exitCode: Int32, combinedOutput: String) {
            self.exitCode = exitCode
            self.combinedOutput = combinedOutput
        }
    }

    /// Run `executablePath` with `arguments`, capturing merged stdout/stderr.
    ///
    /// This is the real runner used in production. It is separated from
    /// `unmountWholeDisk` so the unmount decision (root-mount refusal, exit-code
    /// handling) can be unit-tested with a synthetic runner.
    ///
    /// - Parameters:
    ///   - executablePath: Absolute path to the executable.
    ///   - arguments: Argument vector (without the executable itself).
    /// - Returns: The exit code and combined output.
    public static func runProcess(
        _ executablePath: String,
        _ arguments: [String]
    ) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        // Merge stdout and stderr into one pipe so error detail is captured.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            // The process could not be launched at all; surface that as a
            // non-zero result rather than throwing, so callers handle one shape.
            let result = ProcessRunResult(
                exitCode: -1,
                combinedOutput: "launch failed: " + String(describing: error)
            )
            return result
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = ProcessRunResult(
            exitCode: process.terminationStatus,
            combinedOutput: trimmed
        )
        return result
    }

    /// Eject the whole disk after a successful write so the user can pull it.
    ///
    /// Eject failure is non-fatal to the WRITE outcome -- the bytes are already
    /// on the device -- so this returns a flag instead of throwing. The caller
    /// may log a failed eject but still report success.
    ///
    /// - Parameters:
    ///   - descriptor: The whole-disk descriptor to eject.
    ///   - runner: Injectable process runner (see `unmountWholeDisk`).
    /// - Returns: `true` when `diskutil eject` reported success.
    @discardableResult
    public static func eject(
        _ descriptor: DiskDescriptor,
        runner: (String, [String]) -> ProcessRunResult = Unmount.runProcess
    ) -> Bool {
        let arguments = ["eject", descriptor.devicePath]
        let result = runner(diskutilPath, arguments)
        let ok = (result.exitCode == 0)
        return ok
    }
}
