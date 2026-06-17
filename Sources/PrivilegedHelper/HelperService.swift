/// HelperService.swift -- the XPC-facing object that runs the flash pipeline.
///
/// `HelperService` conforms to `HelperXPCProtocol`: it decodes the JSON `Data`
/// control payloads, runs the full privileged pipeline -- authorization gate,
/// independent safety re-check, whole-disk unmount, raw block-aligned write,
/// read-back verify -- and encodes `FlashProgress`/`FlashResult` back to the
/// caller. It is the single place that stitches the focused helpers together.
///
/// Cancellation contract (load-bearing): on cancel the service NEVER reports
/// `.success`. It tears down nothing it did not create, leaves the drive
/// UNMOUNTED (the write path already unmounted it; the service does not re-mount
/// or eject on cancel), and returns `FlashResult` with `outcome == .cancelled`
/// and no `deviceSHA512`. A verification mismatch or any thrown `HelperError`
/// returns `.failed` with a human-readable `errorMessage`.
///
/// Threading: `@objc` XPC methods may be invoked on arbitrary queues. Per-job
/// cancel tokens are held in a lock-guarded dictionary so `cancel(jobIDData:)`
/// from one queue can signal a worker running on another. The heavy write/verify
/// runs on a background queue so the XPC reply thread is not blocked.

import Foundation
import HelperProtocol
import Verifier
import DiskModel

// MARK: - Sendable closure box

/// Wraps a non-`Sendable` XPC reply/progress closure so it can cross onto the
/// helper's background work queue.
///
/// `NSXPCConnection` reply and progress blocks are documented as safe to invoke
/// from an arbitrary queue, so moving one to the work queue is sound; the
/// compiler cannot prove that, hence `@unchecked Sendable`. Centralizing the
/// override here keeps the unchecked annotation in one auditable spot instead of
/// scattered across the dispatch sites.
private struct DataSink: @unchecked Sendable {

    /// The wrapped JSON-`Data` sink (progress or result/reply callback).
    let send: (Data) -> Void

    init(_ send: @escaping (Data) -> Void) {
        self.send = send
    }
}

/// Wraps a non-`Sendable` `FlashProgress` reporter so it can cross from the
/// async pipeline onto the blocking work queue. The wrapped closure ultimately
/// forwards to an XPC progress block, which is safe to call from any queue.
private struct ProgressSink: @unchecked Sendable {

    /// The wrapped progress reporter.
    let report: (FlashProgress) -> Void

    init(_ report: @escaping (FlashProgress) -> Void) {
        self.report = report
    }
}

// MARK: - TokenRegistry actor

/// Compiler-enforced isolation for per-job cancel tokens.
///
/// `HelperService` cannot itself be an actor (it must be `@objc`/`NSObject` for
/// `NSXPCConnection`), so this actor encapsulates the only mutable shared state --
/// the live cancel tokens keyed by job id.  Every read and write goes through the
/// actor, eliminating the manual `NSLock` and the `@unchecked Sendable` override
/// on `HelperService`.
///
/// The synchronous `cancel(jobIDData:)` XPC method retrieves the token via a
/// fire-and-forget `Task { await registry.token(for:) }`, which is sound because
/// `CancellationToken.cancel()` is thread-safe on its own and the XPC cancel
/// contract is best-effort (the authoritative result always arrives via the
/// flash/verify reply).
private actor TokenRegistry {

    /// Live cancel tokens keyed by job raw-value.
    private var tokens: [String: CancellationToken] = [:]

    /// Register a new token for `jobID` and return it.
    func register(jobID: JobID, token: CancellationToken) {
        tokens[jobID.rawValue] = token
    }

    /// Return the live token for `jobID`, or `nil` when the job is gone.
    func token(for jobID: JobID) -> CancellationToken? {
        return tokens[jobID.rawValue]
    }

    /// Drop the token once the job reaches a terminal state.
    func unregister(jobID: JobID) {
        tokens[jobID.rawValue] = nil
    }
}

// MARK: - HelperService

/// Concrete privileged-helper service vended over `NSXPCConnection`.
///
/// Subclasses `NSObject` because `HelperXPCProtocol` is an `@objc` protocol and
/// `NSXPCConnection` requires an Objective-C-visible exported object.
public final class HelperService: NSObject, HelperXPCProtocol, Sendable {

    /// Authorization gate run before any destructive work. Defaults to the
    /// development allow-all stub; the signing milestone injects a real gate.
    private let authorization: HelperAuthorization

    /// BSD name of the disk the source image was read from, when known, for the
    /// source-overlap safety rule. `nil` when the source is a plain file with no
    /// backing disk. Injected by the host; not part of the wire request today.
    private let sourceBackingBSDName: String?

    /// Background queue for the heavy write/verify so XPC threads stay responsive.
    private let workQueue = DispatchQueue(
        label: "com.swiftusbimager.helper.work",
        qos: .userInitiated
    )

    /// Actor that owns the per-job cancel tokens; replaces the former NSLock +
    /// mutable dictionary so the compiler enforces isolation.
    private let tokenRegistry = TokenRegistry()

    /// Create a service with an authorization gate and optional source backing.
    ///
    /// - Parameters:
    ///   - authorization: The pre-write gate (default: development allow-all).
    ///   - sourceBackingBSDName: BSD name of the source's backing disk, or `nil`.
    public init(
        authorization: HelperAuthorization = .allowAll,
        sourceBackingBSDName: String? = nil
    ) {
        self.authorization = authorization
        self.sourceBackingBSDName = sourceBackingBSDName
        super.init()
    }

    /// Build the PRODUCTION service: a pinned-requirement authorization gate that
    /// admits only the genuine app. The XPC listener wiring must use this factory
    /// (never the `allowAll` default) so a real `SecCode` peer check guards every
    /// request once the helper is signed and installed.
    ///
    /// - Parameters:
    ///   - requirement: The pinned designated requirement for the connecting app.
    ///   - sourceBackingBSDName: BSD name of the source's backing disk, or `nil`.
    /// - Returns: A service whose gate evaluates the peer's `SecCode`.
    public static func production(
        requirement: CodeSigningRequirement,
        sourceBackingBSDName: String? = nil
    ) -> HelperService {
        let gate = HelperAuthorization.pinning(requirement: requirement)
        let service = HelperService(
            authorization: gate,
            sourceBackingBSDName: sourceBackingBSDName
        )
        return service
    }

    // MARK: - HelperXPCProtocol: flash

    public func flash(
        requestData: Data,
        progress: @escaping (Data) -> Void,
        result: @escaping (Data) -> Void
    ) {
        // Decode the control payload first; the authoritative job identity comes
        // FROM the request (the app assigned it), so the helper echoes that exact
        // id in every progress/result event. A decode failure cannot recover the
        // app's id, so it reports under a freshly generated one.
        let request: FlashRequest
        do {
            request = try HelperProtocolCoding.decode(FlashRequest.self, from: requestData)
        } catch {
            let failure = FlashResult(
                jobID: JobID.generate(),
                outcome: .failed,
                deviceSHA512: nil,
                errorMessage: "Could not decode FlashRequest: "
                    + String(describing: error)
            )
            emit(terminal: failure, to: result)
            return
        }

        // The job id travels in the request; use it for cancellation bookkeeping
        // and for every emitted event so the app can correlate them.
        let jobID = request.jobID

        // Box the non-Sendable XPC closures so they can cross onto the work queue.
        let progressSink = DataSink(progress)
        let resultSink = DataSink(result)

        // The async safety re-check awaits a live DiskArbitration snapshot, so the
        // pipeline is async. Run it in a detached Task off the XPC thread; the
        // heavy blocking write/verify is hopped onto `workQueue` inside.
        // Register a cancel token inside the Task before any work so an early
        // cancel is honored; the actor await is cheap.
        Task { [weak self] in
            guard let self else { return }
            let token = await self.registerToken(for: jobID)
            let finalResult = await self.runFlashPipeline(
                jobID: jobID,
                request: request,
                token: token,
                progress: progressSink.send
            )
            await self.unregisterToken(for: jobID)
            self.emit(terminal: finalResult, to: resultSink.send)
        }
    }

    /// Execute the safety -> unmount -> write -> verify pipeline and return the
    /// terminal `FlashResult`. All thrown errors collapse into a `.failed` or
    /// `.cancelled` result here; this function never throws.
    private func runFlashPipeline(
        jobID: JobID,
        request: FlashRequest,
        token: CancellationToken,
        progress: @escaping (Data) -> Void
    ) async -> FlashResult {
        // Progress callback that encodes and forwards over XPC.
        let report: (FlashProgress) -> Void = { [weak self] update in
            self?.emit(update, to: progress)
        }

        do {
            // 1. Authorization gate. The pinned gate evaluates the peer's SecCode;
            //    the in-process path here has no peer token, so the live SecCode
            //    check is reached once the XPC listener supplies the audit token.
            try authorization.authorize()

            // 2. Resolve the source path (only .absolutePath is wired now) and
            //    derive the GROUND-TRUTH image length from the opened file.
            let sourcePath = try resolveSourcePath(request.sourceAccess)
            let imageLength = try groundTruthImageLength(sourcePath: sourcePath)

            // Guard the UInt64 -> Int narrowing used by the safety check. On a
            // 32-bit host (or a future port) an image larger than Int.max would
            // silently truncate and under-count required space; refuse instead.
            guard imageLength <= UInt64(Int.max) else {
                throw HelperError.imageTooLarge(byteCount: imageLength)
            }

            // 3. Independent safety re-check against live device state, using the
            //    ground-truth length -- not request.advisorySizeBytes. Prefer the
            //    helper's own injected source backing when set; otherwise fall back
            //    to the app-supplied hint carried in the request.
            let sourceBacking = self.sourceBackingBSDName ?? request.sourceBackingBSDName
            let descriptor = try await HelperSafety.validatedTarget(
                targetBSDName: request.targetBSDName,
                imageSizeBytes: Int(imageLength),
                sourceBackingBSDName: sourceBacking
            )

            // Early cancel checkpoint before any destructive action.
            if token.isCancelled {
                return Self.cancelledResult(jobID: jobID)
            }

            // 4-8. Unmount, raw write, read-back verify, eject. These are heavy
            //       BLOCKING POSIX calls; run them on the dedicated work queue so
            //       no cooperative-pool thread is parked on synchronous I/O.
            let success = try await runDestructiveStages(
                jobID: jobID,
                sourcePath: sourcePath,
                descriptor: descriptor,
                imageLength: imageLength,
                token: token,
                report: report
            )
            return success
        } catch is CancellationError {
            // Cooperative cancel observed in a loop. Drive stays unmounted.
            return Self.cancelledResult(jobID: jobID)
        } catch let helperError as HelperError {
            let failure = FlashResult(
                jobID: jobID,
                outcome: .failed,
                deviceSHA512: nil,
                errorMessage: helperError.message
            )
            return failure
        } catch {
            let failure = FlashResult(
                jobID: jobID,
                outcome: .failed,
                deviceSHA512: nil,
                errorMessage: String(describing: error)
            )
            return failure
        }
    }

    /// Run the BLOCKING destructive sequence (unmount -> write -> verify ->
    /// eject) on the dedicated work queue and bridge its result back into async.
    ///
    /// Returns a `.success` result on a verified write, a `.cancelled` result
    /// when the token is flipped at a phase boundary, and rethrows any
    /// `HelperError` (open/IO/verify mismatch) so the caller maps it to `.failed`.
    private func runDestructiveStages(
        jobID: JobID,
        sourcePath: String,
        descriptor: DiskDescriptor,
        imageLength: UInt64,
        token: CancellationToken,
        report: @escaping (FlashProgress) -> Void
    ) async throws -> FlashResult {
        // The report closure crosses onto the work queue; the XPC progress block
        // it wraps is documented safe to call from an arbitrary queue.
        let reportSink = ProgressSink(report)
        let result: Result<FlashResult, Error> = await withCheckedContinuation { continuation in
            self.workQueue.async {
                let outcome = Self.performDestructiveStages(
                    jobID: jobID,
                    sourcePath: sourcePath,
                    descriptor: descriptor,
                    imageLength: imageLength,
                    token: token,
                    report: reportSink.report
                )
                continuation.resume(returning: outcome)
            }
        }
        switch result {
        case .success(let flashResult):
            return flashResult
        case .failure(let error):
            throw error
        }
    }

    /// Pure blocking body of the destructive stages. Runs entirely on the work
    /// queue; never touches actor state, so it is a static function.
    private static func performDestructiveStages(
        jobID: JobID,
        sourcePath: String,
        descriptor: DiskDescriptor,
        imageLength: UInt64,
        token: CancellationToken,
        report: @escaping (FlashProgress) -> Void
    ) -> Result<FlashResult, Error> {
        do {
            // 4. Unmount every volume on the whole disk (phase: .unmounting).
            report(FlashProgress(
                jobID: jobID,
                bytesDone: 0,
                totalBytes: imageLength,
                phase: .unmounting
            ))
            try Unmount.unmountWholeDisk(descriptor)

            if token.isCancelled {
                // Drive is left unmounted; no success claim.
                return .success(cancelledResult(jobID: jobID))
            }

            // 5. Raw, block-aligned write streaming a SHA-512 of the image bytes.
            let writeJob = WriteJob()
            let writtenDigest = try writeJob.run(
                sourcePath: sourcePath,
                rawDevicePath: descriptor.rawDevicePath,
                jobID: jobID,
                cancelToken: token,
                progress: report
            )

            // 6. Read the device back and re-hash exactly the image length.
            let verifyJob = VerifyJob()
            let readBackDigest = try verifyJob.run(
                rawDevicePath: descriptor.rawDevicePath,
                imageLength: imageLength,
                jobID: jobID,
                cancelToken: token,
                progress: report
            )

            // 7. Compare digests; a mismatch is a hard failure.
            guard writtenDigest == readBackDigest else {
                throw HelperError.verificationMismatch(
                    written: writtenDigest.hexString,
                    readBack: readBackDigest.hexString
                )
            }

            // 8. Success: eject so the user can safely remove the media.
            Unmount.eject(descriptor)
            report(FlashProgress(
                jobID: jobID,
                bytesDone: imageLength,
                totalBytes: imageLength,
                phase: .done
            ))
            let success = FlashResult(
                jobID: jobID,
                outcome: .success,
                deviceSHA512: readBackDigest.hexString,
                errorMessage: nil
            )
            return .success(success)
        } catch is CancellationError {
            // Cooperative cancel observed in a loop. Drive stays unmounted.
            return .success(cancelledResult(jobID: jobID))
        } catch {
            // HelperError and any other error flow back so the async caller maps
            // it to a .failed result with the right message.
            return .failure(error)
        }
    }

    // MARK: - HelperXPCProtocol: verify

    public func verify(requestData: Data, reply: @escaping (Data) -> Void) {
        // The job id travels in the request so the reply echoes the app's id; a
        // decode failure cannot recover it, so it falls back to a fresh one.
        let request: FlashRequest
        do {
            request = try HelperProtocolCoding.decode(FlashRequest.self, from: requestData)
        } catch {
            let failure = FlashResult(
                jobID: JobID.generate(),
                outcome: .failed,
                deviceSHA512: nil,
                errorMessage: "Could not decode FlashRequest: "
                    + String(describing: error)
            )
            emit(terminal: failure, to: reply)
            return
        }

        let jobID = request.jobID
        let replySink = DataSink(reply)

        // Register the cancel token and run the blocking verify on the work queue.
        // The actor await is cheap; the blocking verify work is dispatched inside.
        Task { [weak self] in
            guard let self else { return }
            let token = await self.registerToken(for: jobID)
            let finalResult = await withCheckedContinuation { continuation in
                self.workQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume(returning: Self.cancelledResult(jobID: jobID))
                        return
                    }
                    let result = self.runVerifyOnly(
                        jobID: jobID,
                        request: request,
                        token: token
                    )
                    continuation.resume(returning: result)
                }
            }
            await self.unregisterToken(for: jobID)
            self.emit(terminal: finalResult, to: replySink.send)
        }
    }

    /// Verify a device WITHOUT writing: re-hash the target's first image-length
    /// bytes and return the digest. Used to re-check media after the fact.
    private func runVerifyOnly(
        jobID: JobID,
        request: FlashRequest,
        token: CancellationToken
    ) -> FlashResult {
        do {
            try authorization.authorize()

            // Derive the ground-truth length from the source file, mirroring the
            // flash path so the verify span matches what would be written.
            let sourcePath = try resolveSourcePath(request.sourceAccess)
            let imageLength = try groundTruthImageLength(sourcePath: sourcePath)

            // Resolve the target raw node from its BSD name (no safety mutation
            // needed for a read-only verify, but resolve to get the raw path).
            let wholeName = DiskIdentity.wholeDiskName(for: request.targetBSDName)
                ?? request.targetBSDName
            let rawPath = DiskIdentity.rawDevicePath(for: wholeName)

            let verifyJob = VerifyJob()
            let digest = try verifyJob.run(
                rawDevicePath: rawPath,
                imageLength: imageLength,
                jobID: jobID,
                cancelToken: token,
                progress: { _ in }
            )
            let success = FlashResult(
                jobID: jobID,
                outcome: .success,
                deviceSHA512: digest.hexString,
                errorMessage: nil
            )
            return success
        } catch is CancellationError {
            return Self.cancelledResult(jobID: jobID)
        } catch let helperError as HelperError {
            let failure = FlashResult(
                jobID: jobID,
                outcome: .failed,
                deviceSHA512: nil,
                errorMessage: helperError.message
            )
            return failure
        } catch {
            let failure = FlashResult(
                jobID: jobID,
                outcome: .failed,
                deviceSHA512: nil,
                errorMessage: String(describing: error)
            )
            return failure
        }
    }

    // MARK: - HelperXPCProtocol: cancel

    public func cancel(jobIDData: Data) {
        // Best-effort: decode the job id and flip its token if still live. The
        // authoritative outcome still arrives via the flash/verify reply.
        // `cancel(jobIDData:)` is a synchronous @objc method; dispatch the actor
        // lookup as a fire-and-forget Task. CancellationToken.cancel() is
        // thread-safe on its own, so calling it from the Task closure is sound.
        guard let jobID = try? HelperProtocolCoding.decode(JobID.self, from: jobIDData) else {
            return
        }
        Task { [tokenRegistry] in
            let token = await tokenRegistry.token(for: jobID)
            token?.cancel()
        }
    }

    // MARK: - Source resolution and ground truth

    /// Resolve a `SourceAccess` to an absolute source path.
    ///
    /// Only `.absolutePath` is wired this milestone; `.fileDescriptor` and
    /// `.stageCopy` are reserved and throw a clear `sourceUnavailable` so a
    /// premature use fails loudly instead of silently.
    private func resolveSourcePath(_ access: SourceAccess) throws -> String {
        switch access {
        case .absolutePath(let path):
            return path
        case .stageCopy(let path):
            // The staged copy is just a readable path; treat it as the source.
            return path
        case .fileDescriptor:
            throw HelperError.sourceUnavailable(
                detail: "fileDescriptor SourceAccess is not wired in this milestone"
            )
        }
    }

    /// Stat the source file for its byte length -- the GROUND TRUTH used for all
    /// safety and progress math, never `FlashRequest.advisorySizeBytes`.
    private func groundTruthImageLength(sourcePath: String) throws -> UInt64 {
        let fd = open(sourcePath, O_RDONLY)
        guard fd >= 0 else {
            throw HelperError.sourceUnavailable(
                detail: sourcePath + ": " + String(cString: strerror(errno))
            )
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw HelperError.sourceUnavailable(
                detail: sourcePath + ": fstat " + String(cString: strerror(errno))
            )
        }
        let length = UInt64(info.st_size)
        return length
    }

    // MARK: - Token bookkeeping

    /// Create and register a cancel token for `jobID` via the actor.
    private func registerToken(for jobID: JobID) async -> CancellationToken {
        let token = CancellationToken()
        await tokenRegistry.register(jobID: jobID, token: token)
        return token
    }

    /// Drop the cancel token for `jobID` once the job is terminal.
    private func unregisterToken(for jobID: JobID) async {
        await tokenRegistry.unregister(jobID: jobID)
    }

    // MARK: - Terminal-result and encoding helpers

    /// Build the standard cancelled result: no success, no digest, no error.
    private static func cancelledResult(jobID: JobID) -> FlashResult {
        let cancelled = FlashResult(
            jobID: jobID,
            outcome: .cancelled,
            deviceSHA512: nil,
            errorMessage: nil
        )
        return cancelled
    }

    /// Encode `value` and hand the JSON `Data` to a sink, swallowing encode
    /// errors (a control message that cannot be encoded cannot be delivered;
    /// the job's authoritative result still flows through its own path).
    ///
    /// Use this only for NON-terminal control messages (progress). For the
    /// terminal `FlashResult` use `emit(terminal:)` so the caller's continuation
    /// is never left hanging on an encode failure.
    private func emit<Value: Encodable>(_ value: Value, to sink: (Data) -> Void) {
        guard let data = try? HelperProtocolCoding.encode(value) else {
            return
        }
        sink(data)
    }

    /// Deliver a TERMINAL `FlashResult`, guaranteeing the sink always receives a
    /// terminal event. If the real result fails to encode, this fabricates a
    /// minimal `.failed` result (same jobID, primitive fields only) and encodes
    /// that instead, so the app's continuation always resumes.
    private func emit(terminal result: FlashResult, to sink: (Data) -> Void) {
        if let data = try? HelperProtocolCoding.encode(result) {
            sink(data)
            return
        }
        // The real result could not be encoded. Synthesize a fallback terminal
        // result built only from primitive, always-encodable fields so the
        // caller still receives a terminal event and does not hang.
        let fallback = FlashResult(
            jobID: result.jobID,
            outcome: .failed,
            deviceSHA512: nil,
            errorMessage: "Terminal result could not be encoded; "
                + "reporting failure so the job does not hang."
        )
        if let data = try? HelperProtocolCoding.encode(fallback) {
            sink(data)
        }
    }
}
