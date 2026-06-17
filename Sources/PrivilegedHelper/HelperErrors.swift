/// HelperErrors.swift -- typed errors raised by the privileged helper pipeline.
///
/// Every stage of the helper (safety re-check, unmount, raw write, read-back
/// verify) raises a `HelperError` rather than an untyped `NSError` or a bare
/// POSIX `errno`. `HelperService` maps these onto a `FlashResult` with
/// `outcome == .failed` and a human-readable `errorMessage`, so the failure
/// reason survives the trip back across XPC.
///
/// Design note: the helper deliberately fails loudly. A rejected target, an
/// unmount that cannot guarantee a clean device, a short write, or a read-back
/// digest mismatch are all hard errors -- never silently downgraded to a
/// best-effort success. This matches "fix the design, not the symptom": the
/// caller sees the real reason instead of a masked one.

import Foundation
import DiskModel

// MARK: - HelperError

/// A typed failure from any stage of the privileged flash pipeline.
public enum HelperError: Error, Equatable, Sendable {

    /// The independent safety re-check rejected the target. The associated
    /// reasons are the exact `DiskSafety` rejection reasons; the helper never
    /// writes when this is non-empty.
    case targetRejected(reasons: [RejectionReason])

    /// The target BSD name could not be resolved to a whole-disk descriptor
    /// (the device is gone, is a slice, or DiskArbitration declined it).
    case targetNotResolvable(bsdName: String)

    /// The source could not be opened or stat'd (path missing, permission
    /// denied, or an unsupported `SourceAccess` case for this milestone).
    case sourceUnavailable(detail: String)

    /// The source image byte count exceeds what the size path can represent as
    /// an `Int` on this host (would silently truncate). `byteCount` carries the
    /// true `UInt64` length so the failure message is exact.
    case imageTooLarge(byteCount: UInt64)

    /// The raw target device could not be opened with the required flags.
    /// `errnoValue` carries the POSIX error for diagnosis.
    case deviceOpenFailed(path: String, errnoValue: Int32)

    /// A POSIX read or write call failed mid-stream. `errnoValue` carries the
    /// POSIX error; `bytesSoFar` records progress at the point of failure.
    case ioFailed(detail: String, errnoValue: Int32, bytesSoFar: UInt64)

    /// Unmounting the target's volumes failed, so the device is not safe to
    /// write. `detail` carries the underlying tool output or reason.
    case unmountFailed(detail: String)

    /// Refused to operate on a disk that has a volume mounted at "/" (the live
    /// system root). This is a last-line guard independent of `DiskSafety`.
    case refusedRootMount(bsdName: String)

    /// The read-back digest did not match the digest computed while writing.
    /// Both hex strings are carried so the caller can log the divergence.
    case verificationMismatch(written: String, readBack: String)

    /// The authorization / code-signing check rejected the caller. This case
    /// is reserved for the real `SecCode` enforcement wired during signing;
    /// today it is only raised by the explicit stub when configured to deny.
    case notAuthorized(detail: String)
}

// MARK: - Human-readable messages

extension HelperError {

    /// A single-line, user-facing description suitable for `FlashResult`.
    public var message: String {
        switch self {
        case .targetRejected(let reasons):
            let names = reasons.map { $0.rawValue }.joined(separator: ", ")
            let text = "Target rejected by safety re-check: " + names
            return text
        case .targetNotResolvable(let bsdName):
            let text = "Could not resolve target device: " + bsdName
            return text
        case .sourceUnavailable(let detail):
            let text = "Source unavailable: " + detail
            return text
        case .imageTooLarge(let byteCount):
            let text = "Source image is too large to process on this host: "
                + String(byteCount) + " bytes"
            return text
        case .deviceOpenFailed(let path, let errnoValue):
            let posix = String(cString: strerror(errnoValue))
            let text = "Could not open device " + path + ": " + posix
            return text
        case .ioFailed(let detail, let errnoValue, let bytesSoFar):
            let posix = String(cString: strerror(errnoValue))
            let text = "I/O failed after " + String(bytesSoFar)
                + " bytes (" + detail + "): " + posix
            return text
        case .unmountFailed(let detail):
            let text = "Unmount failed: " + detail
            return text
        case .refusedRootMount(let bsdName):
            let text = "Refused: " + bsdName + " has a volume mounted at /"
            return text
        case .verificationMismatch(let written, let readBack):
            let text = "Read-back verification mismatch: wrote "
                + written + " but device reads " + readBack
            return text
        case .notAuthorized(let detail):
            let text = "Not authorized: " + detail
            return text
        }
    }
}
