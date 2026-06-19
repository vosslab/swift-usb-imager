/// CoreError - the typed error surface for the GUI-independent workflow, plus
/// the CLI exit-code mapping fixed by the plan's `## CLI contract`.
///
/// `CoreError` is the single place the workflow expresses what went wrong in a
/// way both front ends can act on. The CLI maps a `CoreError` to a process exit
/// code via `CoreExitCode`; the GUI maps the same value to UI state. Neither
/// front end invents its own error taxonomy.
///
/// The exit-code values are frozen here so every subcommand maps to one shared
/// table instead of choosing its own numbers. The table mirrors the plan:
///
///   | Code | Meaning                                   |
///   | ---- | ----------------------------------------- |
///   | 0    | Success                                   |
///   | 1    | Verification mismatch                     |
///   | 2    | Bad input / usage                         |
///   | 3    | Privileged helper unavailable/not approved|
///   | 4    | Flash failed mid-write                     |
///   | 5    | Operation cancelled                       |
///   | 6    | GUI app binary/bundle not locatable        |
///
/// ArgumentParser's own usage errors exit with its standard code; this table
/// covers post-parse behavior only.

import FlashEngine
import Foundation

// MARK: - CoreExitCode

/// The fixed process exit codes from the plan's CLI contract.
///
/// `rawValue` is the actual exit status. The CLI uses these directly; the GUI
/// ignores them. Adding or renumbering a case is a contract change and must go
/// back to the plan first.
public enum CoreExitCode: Int32, Sendable, CaseIterable {

    /// Success: digest matched, list printed, flash completed, or GUI launched.
    case success = 0

    /// Verification mismatch: a computed digest did not equal the expected one.
    case verificationMismatch = 1

    /// Bad input or usage: unreadable file, malformed hex, or unknown target.
    case badInput = 2

    /// The privileged helper is unavailable or has not been approved.
    case helperUnavailable = 3

    /// The flash failed mid-write (I/O or device error).
    case flashFailed = 4

    /// The operation was cancelled.
    case cancelled = 5

    /// The GUI app binary or bundle could not be located (for `open`).
    case appNotFound = 6
}

// MARK: - CoreError

/// Typed errors surfaced by the `USBImagerCore` workflow services.
///
/// Each case carries enough context for a front end to present it, and maps to
/// exactly one `CoreExitCode` via `exitCode`. The associated `message` strings
/// are developer/user-facing explanations, not localized UI copy; a front end
/// may present them directly or substitute its own wording.
public enum CoreError: Error, Equatable, Sendable {

    /// Input the caller supplied is unusable: an unreadable or missing source
    /// file, a malformed pasted hex digest, an unparsable `SHA512SUMS` body, or
    /// a target BSD name that does not resolve to a safe disk.
    /// Maps to `CoreExitCode.badInput` (2).
    case badInput(message: String)

    /// A verification compared a computed digest to an expected digest and they
    /// differed. Maps to `CoreExitCode.verificationMismatch` (1).
    case verificationMismatch(expected: String, actual: String)

    /// The privileged helper could not be reached or is not approved, so a
    /// flash cannot proceed. Maps to `CoreExitCode.helperUnavailable` (3).
    case helperUnavailable(message: String)

    /// The flash failed while writing (helper-reported failure, I/O, or device
    /// error). `message` is the helper-supplied detail when present.
    /// Maps to `CoreExitCode.flashFailed` (4).
    case flashFailed(message: String)

    /// The operation was cancelled before completion.
    /// Maps to `CoreExitCode.cancelled` (5).
    case cancelled

    /// The GUI app binary or bundle could not be located when launching it.
    /// Maps to `CoreExitCode.appNotFound` (6). Used by the CLI `open` path.
    case appNotFound(message: String)

    // MARK: - Exit-code mapping

    /// The fixed CLI exit code for this error, per the plan's CLI contract.
    ///
    /// The CLI calls this to choose its process exit status. The mapping is
    /// total: every case has exactly one code.
    public var exitCode: CoreExitCode {
        switch self {
        case .badInput:
            return .badInput
        case .verificationMismatch:
            return .verificationMismatch
        case .helperUnavailable:
            return .helperUnavailable
        case .flashFailed:
            return .flashFailed
        case .cancelled:
            return .cancelled
        case .appNotFound:
            return .appNotFound
        }
    }
}

// MARK: - FlashEngineError message mapping

/// Maps a `FlashEngineError` to a user-facing message string.
///
/// Maps a `FlashEngineError` to a user-facing message string.
///
/// Lives in core (not in a front end) so the GUI and CLI show the same wording
/// for the same engine failure. The function is pure and synchronous: given an
/// engine error it returns a message with no I/O and no side effects.
///
///
/// - Parameter error: the `FlashEngineError` thrown by `FlashEngine.flash`.
/// - Returns: a user-facing message describing the failure.
public func userMessage(for error: FlashEngineError) -> String {
    // Every `FlashEngineError` case routes to one user-facing message so the
    // GUI and CLI present identical wording for the same engine failure.
    // Pure function: an error in, a string out, no I/O.
    switch error {
    case .connectionFailed(let detail):
        // The XPC channel to the helper dropped mid-job (a clean no-helper
        // start-up failure is reported by the factory as `.helperUnavailable`,
        // not here). Surface the channel detail so the user can tell a crash
        // apart from a deliberate denial.
        return "Lost the connection to the privileged helper during the flash: \(detail)"
    case .decodeFailed(let detail):
        // The helper answered, but its reply could not be parsed -- a version
        // or protocol skew between app and helper.
        return "The privileged helper sent a response this app could not understand: \(detail)"
    case .encodeFailed(let detail):
        // The request could not be serialized before it ever reached the
        // helper; this is an app-side packaging fault, not a device problem.
        return "The flash request could not be prepared to send to the helper: \(detail)"
    case .helperReportedFailure(let message):
        // The helper ran and explicitly failed (I/O or device error). Prefer
        // its own detail; fall back to a generic line when it sent none.
        return message ?? "The privileged helper reported that the flash failed."
    case .cancelled:
        // The user (or caller) cancelled before the write completed.
        return "The flash was cancelled before it finished."
    case .jobIDMismatch(let expected, let received):
        // A progress/result update carried the wrong job id: a protocol
        // confusion that should never happen in a correct helper.
        return "Internal error: the helper replied about a different job"
            + " (expected \(expected), received \(received))."
    }
}
