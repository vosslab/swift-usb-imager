/// HelperProtocol: shared XPC contract between the unprivileged app and the
/// privileged SMAppService root LaunchDaemon helper, communicated over an
/// `NSXPCConnection`.
///
/// Design summary (the load-bearing contract for M2):
///
///   - XPC carries CONTROL data ONLY: a job request, progress callbacks, a
///     cancel signal, and a final result. Image bytes NEVER travel over XPC.
///     The helper opens the source file itself (by absolute path now, by a
///     transferred file descriptor or a staged copy later) and streams those
///     bytes straight to the target device. This keeps the XPC message size
///     tiny and avoids copying gigabytes of disk image through the kernel XPC
///     transport.
///
///   - The advisory size and advisory SHA-512 in `FlashRequest` are HINTS for
///     the UI (progress bar denominator, early "this looks wrong" checks).
///     They are NOT trusted for safety. The helper re-derives ground truth:
///     it stats the real source file for the true byte count and re-hashes the
///     bytes it actually wrote to the device. `FlashResult.deviceSHA512` is the
///     digest the helper computed by reading the target back, not the advisory.
///
/// Marshalling across the @objc boundary
/// -------------------------------------
/// `NSXPCConnection` can only ship Objective-C / `NSSecureCoding` values across
/// the wire. Our request/progress/result models are Swift `Codable` value types.
/// Rather than hand-write `NSSecureCoding` for each one, every Codable payload
/// is encoded to JSON `Data` by the sender and decoded from `Data` by the
/// receiver. `Data` is a first-class `NSSecureCoding` type, so the @objc method
/// signatures below traffic only in `Data` and `String`.
///
/// Rationale for JSON `Data` over hand-rolled `NSSecureCoding`:
///   - Single source of truth: the `Codable` conformance defines the wire shape
///     for both XPC and any on-disk persistence (e.g. KeychainStore), so the two
///     can never drift.
///   - Forward compatibility: adding an optional Codable field does not require
///     touching the @objc protocol, only the struct.
///   - Auditability: a JSON blob is trivially inspectable in logs and tests.
/// The cost is one encode/decode per message; control messages are small and
/// infrequent, so this is negligible compared to the multi-gigabyte write.
///
/// Encoding helpers (`HelperProtocolCoding`) are provided so both peers use the
/// exact same encoder/decoder configuration. See `HelperProtocolCoding`.

import Foundation

// MARK: - XPC protocol

/// The @objc protocol vended by the privileged helper over `NSXPCConnection`.
///
/// All structured payloads cross the boundary as JSON-encoded `Data` (see the
/// file header). Callers encode a `FlashRequest`/`VerifyRequest` with
/// `HelperProtocolCoding.encode(_:)` before invoking, and decode reply `Data`
/// with `HelperProtocolCoding.decode(_:from:)`.
///
/// Reply blocks are used (not `async`) because `NSXPCConnection` proxies deliver
/// results through completion handlers. `flash` reports incremental progress by
/// invoking `progress` zero or more times, then `result` exactly once.
@objc public protocol HelperXPCProtocol {

    /// Begin flashing the source described by `request` to its target device.
    ///
    /// - Parameters:
    ///   - requestData: JSON-encoded `FlashRequest`.
    ///   - progress: invoked zero or more times with JSON-encoded `FlashProgress`
    ///     as the helper advances through phases. May be called on an arbitrary
    ///     queue; the caller is responsible for hopping to the main queue for UI.
    ///   - result: invoked exactly once with JSON-encoded `FlashResult` when the
    ///     job terminates (success, failure, or cancellation).
    func flash(requestData: Data,
               progress: @escaping (Data) -> Void,
               result: @escaping (Data) -> Void)

    /// Verify a device or source by re-hashing it, without writing.
    ///
    /// - Parameters:
    ///   - requestData: JSON-encoded `FlashRequest` (the same descriptor; the
    ///     helper uses `sourceAccess`/`targetBSDName` to locate what to hash).
    ///   - reply: invoked once with JSON-encoded `FlashResult` whose
    ///     `deviceSHA512` carries the helper-computed digest.
    func verify(requestData: Data,
                reply: @escaping (Data) -> Void)

    /// Request cancellation of an in-flight job.
    ///
    /// - Parameter jobIDData: JSON-encoded `JobID`. Cancellation is best-effort;
    ///   the authoritative outcome still arrives via the `flash` `result` block
    ///   as `.cancelled`.
    func cancel(jobIDData: Data)
}

// MARK: - Codable marshalling helpers

/// Shared encode/decode configuration so both XPC peers agree on the wire shape.
///
/// Both the app and the helper MUST use these functions; constructing ad-hoc
/// `JSONEncoder`/`JSONDecoder` instances risks divergent settings.
public enum HelperProtocolCoding {

    /// Encode any Codable control payload to JSON `Data` for an XPC message.
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        // Stable key order keeps logged/captured messages diff-friendly.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return data
    }

    /// Decode a Codable control payload from JSON `Data` received over XPC.
    public static func decode<Value: Decodable>(_ type: Value.Type,
                                                from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        let value = try decoder.decode(type, from: data)
        return value
    }
}
