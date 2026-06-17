/// FlashEngineError - typed errors surfaced by FlashEngine to callers.
///
/// All decode failures and connection-level problems collapse into this enum
/// so the view model never has to reason about raw `NSError` or JSON decode
/// errors from the XPC boundary.

import Foundation

// MARK: - FlashEngineError

/// Errors thrown by `FlashEngine.flash(source:target:advisorySHA512:)`.
public enum FlashEngineError: Error, Equatable, Sendable {

    /// The XPC connection to the helper could not be established or was
    /// interrupted before the job completed.
    case connectionFailed(String)

    /// A JSON payload received from the helper could not be decoded into the
    /// expected Codable type.
    case decodeFailed(String)

    /// A JSON payload could not be encoded before sending to the helper.
    case encodeFailed(String)

    /// The helper reported a failed outcome; `message` is the helper-supplied
    /// human-readable explanation when present.
    case helperReportedFailure(message: String?)

    /// `cancel()` was called and the helper confirmed cancellation.
    case cancelled

    /// A progress or result update arrived for an unexpected `JobID`, indicating
    /// a protocol confusion between the app and helper.
    case jobIDMismatch(expected: String, received: String)
}
