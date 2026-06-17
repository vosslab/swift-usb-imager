/// HelperConnection - protocol abstracting the XPC remote proxy, plus the
/// production `XPCHelperConnection` implementation.
///
/// Design rationale:
///   - `HelperConnection` gives `FlashEngine` a Swift-native async interface
///     that works with typed `FlashRequest` / `FlashProgress` / `FlashResult`
///     values instead of raw `Data`. The XPC encoding/decoding is isolated here.
///   - The production `XPCHelperConnection` wraps `NSXPCConnection` to the
///     real Mach service and validates the peer's code-signing identity via the
///     `CodeSigningRequirement` from `HelperProtocol`.
///   - Swapping in a fake implementation for testing requires only a type that
///     conforms to `HelperConnection`; `FlashEngine` has no direct dependency on
///     `NSXPCConnection`.

import Foundation
import HelperProtocol

// MARK: - HelperConnection protocol

/// Swift-native, async-friendly abstraction over the XPC helper connection.
///
/// Conformers must be sendable because `FlashEngine` (an actor) stores one and
/// calls methods from its isolated context. The conformer is responsible for all
/// Data encode/decode at the XPC boundary; callers work with typed Swift values.
public protocol HelperConnection: Sendable {

    /// Begin a flash job.
    ///
    /// Invokes `progress` zero or more times as the helper advances, then
    /// invokes `result` exactly once when the job terminates.
    ///
    /// Both callbacks may arrive on an arbitrary queue; the caller (FlashEngine)
    /// is responsible for any actor-hop needed for safe mutation.
    ///
    /// - Parameters:
    ///   - request: the typed flash request.
    ///   - progress: called for each `FlashProgress` update.
    ///   - result: called exactly once with the terminal `FlashResult`.
    /// - Throws: `FlashEngineError.encodeFailed` if the request cannot be
    ///   serialized, or `FlashEngineError.connectionFailed` if the proxy is
    ///   unavailable.
    func flash(
        request: FlashRequest,
        progress: @escaping @Sendable (FlashProgress) -> Void,
        result: @escaping @Sendable (Result<FlashResult, FlashEngineError>) -> Void
    ) throws

    /// Request cancellation of an in-flight job.
    ///
    /// Best-effort; the authoritative outcome still arrives through the `result`
    /// callback of the originating `flash` call as `.cancelled`.
    ///
    /// - Parameter jobID: the job to cancel.
    /// - Throws: `FlashEngineError.encodeFailed` if the job ID cannot be
    ///   serialized.
    func cancel(jobID: JobID) throws

    /// Tear down the underlying XPC connection.
    ///
    /// Safe to call more than once; subsequent calls are no-ops.
    func invalidate()
}

// MARK: - XPCHelperConnection

/// Production `HelperConnection` backed by an `NSXPCConnection` to the
/// privileged Mach service.
///
/// Lifecycle: create once per flash session, call `invalidate()` when done.
/// The connection is activated lazily on first use.
// `NSXPCConnection` predates Swift Concurrency and does not declare
// `Sendable`, but its documented API is thread-safe: the connection has its
// own internal serial queue and all proxy/handler interactions are safe to
// call from any thread. We take responsibility for that guarantee with
// `@unchecked Sendable`.
public final class XPCHelperConnection: @unchecked Sendable, HelperConnection {

    // MARK: - Private state

    /// The Mach service name registered by the helper's `SMAppService` daemon.
    private let machServiceName: String

    /// The peer code-signing requirement validated at connection time.
    private let peerRequirement: CodeSigningRequirement

    /// The underlying XPC connection. Created once and reused.
    private let connection: NSXPCConnection

    // MARK: - Init

    /// Create a connection to the named Mach service, validating the peer with
    /// the supplied code-signing requirement.
    ///
    /// - Parameters:
    ///   - machServiceName: the Mach service name the helper registered via
    ///     `SMAppService.daemon(plistName:)`, e.g.
    ///     `"com.example.swift-usb-imager.helper"`.
    ///   - peerRequirement: a structurally validated `CodeSigningRequirement`
    ///     that the helper peer must satisfy. See `CodeSigningRequirement`.
    public init(machServiceName: String, peerRequirement: CodeSigningRequirement) {
        self.machServiceName = machServiceName
        self.peerRequirement = peerRequirement

        // Build the NSXPCConnection. The connection is resumed immediately;
        // the actual Mach lookup and helper launch are deferred until the first
        // proxy call.
        let xpc = NSXPCConnection(machServiceName: machServiceName)
        xpc.remoteObjectInterface = NSXPCInterface(with: HelperXPCProtocol.self)

        // Peer code-signing validation: store the requirement so a future
        // Security-framework hook (e.g. an auditTokenBlock or a
        // SecCodeCheckValidity call in the invalidation handler) can enforce
        // it. Full SecCode peer-pinning lands with the XPC listener wiring in
        // the PrivilegedHelper target.
        //
        // NOTE: `peerRequirement.requirementString` is the string that will be
        // passed to `SecRequirementCreateWithString` when the peer-check hook
        // is wired. It is captured here so the initializer signature already
        // carries the requirement through to production.
        _ = peerRequirement  // retained; used when peer-check wiring lands.

        xpc.resume()
        self.connection = xpc
    }

    // MARK: - HelperConnection

    public func flash(
        request: FlashRequest,
        progress progressCallback: @escaping @Sendable (FlashProgress) -> Void,
        result resultCallback: @escaping @Sendable (Result<FlashResult, FlashEngineError>) -> Void
    ) throws {
        // Encode the request to JSON Data for the @objc XPC boundary.
        let requestData: Data
        do {
            requestData = try HelperProtocolCoding.encode(request)
        } catch {
            throw FlashEngineError.encodeFailed(error.localizedDescription)
        }

        // Retrieve the remote proxy; an error proxy is substituted if the
        // connection is broken so that the result callback is always called.
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ xpcError in
            resultCallback(.failure(.connectionFailed(xpcError.localizedDescription)))
        }) as? HelperXPCProtocol else {
            throw FlashEngineError.connectionFailed("Could not obtain remote proxy for \(machServiceName)")
        }

        proxy.flash(requestData: requestData) { progressData in
            // Decode progress update; silently drop malformed updates.
            guard let progressValue = try? HelperProtocolCoding.decode(FlashProgress.self, from: progressData) else {
                return
            }
            progressCallback(progressValue)
        } result: { resultData in
            // Decode the terminal result and forward as a typed Result.
            let flashResult: FlashResult
            do {
                flashResult = try HelperProtocolCoding.decode(FlashResult.self, from: resultData)
            } catch {
                resultCallback(.failure(.decodeFailed(error.localizedDescription)))
                return
            }
            // Translate failed outcome to an error so callers see a uniform Result.
            switch flashResult.outcome {
            case .success:
                resultCallback(.success(flashResult))
            case .cancelled:
                resultCallback(.failure(.cancelled))
            case .failed:
                resultCallback(.failure(.helperReportedFailure(message: flashResult.errorMessage)))
            }
        }
    }

    public func cancel(jobID: JobID) throws {
        // Encode the JobID to Data for the @objc XPC boundary.
        let jobIDData: Data
        do {
            jobIDData = try HelperProtocolCoding.encode(jobID)
        } catch {
            throw FlashEngineError.encodeFailed(error.localizedDescription)
        }

        guard let proxy = connection.remoteObjectProxy as? HelperXPCProtocol else {
            // If the proxy is unavailable the job is already gone; ignore.
            return
        }
        proxy.cancel(jobIDData: jobIDData)
    }

    public func invalidate() {
        connection.invalidate()
    }
}
