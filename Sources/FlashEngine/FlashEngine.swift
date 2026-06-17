/// FlashEngine - app-side orchestrator that drives a flash job through the
/// privileged helper over XPC.
///
/// Responsibilities:
///   - Build a `FlashRequest` from a source `URL` and a `DiskDescriptor`.
///   - Submit the request via a `HelperConnection` (real XPC in production,
///     injectable fake in tests).
///   - Relay incremental `FlashProgress` updates through an `AsyncStream` that
///     the view model can subscribe to.
///   - Surface the terminal `FlashResult` as an `async throws` return value.
///   - Forward a `cancel()` call to the active job in the helper.
///
/// Image bytes never enter this layer. The helper opens the source file itself
/// and streams bytes directly to the raw device node.
///
/// Threading model: `FlashEngine` is an `actor`. All mutable state (active job
/// ID, progress continuation) is isolated to the actor's executor. The
/// `HelperConnection` callbacks arrive on arbitrary queues; they are forwarded
/// into the actor via `Task { await self.... }` hops.

import DiskModel
import Foundation
import HelperProtocol

// MARK: - FlashEngine actor

/// App-side XPC orchestrator for a single flash session.
///
/// Create one `FlashEngine` per flash operation. The engine is not reusable
/// across jobs; create a fresh instance for each new flash session.
public actor FlashEngine {

    // MARK: - Public types

    /// The live stream of progress updates for the current job.
    ///
    /// Callers iterate this stream with `for await progress in engine.progressStream { ... }`.
    /// The stream finishes when the job terminates (success, failure, or cancel).
    public let progressStream: AsyncStream<FlashProgress>

    // MARK: - Private state

    /// The abstract XPC connection used for this session.
    private let connection: HelperConnection

    /// The `AsyncStream` continuation used to yield and finish the progress stream.
    private let progressContinuation: AsyncStream<FlashProgress>.Continuation

    /// The job ID assigned to the active flash request, set when the job starts.
    private var activeJobID: JobID?

    // MARK: - Init

    /// Create a new engine.
    ///
    /// - Parameter connection: the helper connection to use. Pass an
    ///   `XPCHelperConnection` in production. Pass a fake conformer in tests.
    public init(connection: HelperConnection) {
        self.connection = connection

        // Build the progress stream and continuation together; `makeStream`
        // avoids the implicitly-unwrapped-optional dance and the force-unwrap.
        let (stream, continuation) = AsyncStream<FlashProgress>.makeStream()
        self.progressStream = stream
        self.progressContinuation = continuation
    }

    // MARK: - Public API

    /// Flash the image at `source` onto the disk described by `target`.
    ///
    /// - Parameters:
    ///   - source: URL to the disk image on the local filesystem. The URL's
    ///     `path` is sent to the helper as a `SourceAccess.absolutePath`; the
    ///     helper opens the file itself.
    ///   - target: the whole-disk descriptor of the write target. The engine
    ///     uses `target.bsdName` as the `targetBSDName` in the `FlashRequest`.
    ///   - advisorySHA512: optional expected SHA-512 of the source, lowercase
    ///     hex, for UI progress feedback only. Not a safety gate; the helper
    ///     re-hashes what it writes. Pass `nil` when no checksum is available.
    ///
    /// - Returns: the terminal `FlashResult` from the helper (outcome `.success`
    ///   only; failed and cancelled outcomes are thrown as errors).
    ///
    /// - Throws:
    ///   - `FlashEngineError.encodeFailed` - request serialization failed.
    ///   - `FlashEngineError.connectionFailed` - XPC connection error.
    ///   - `FlashEngineError.decodeFailed` - helper response could not be decoded.
    ///   - `FlashEngineError.helperReportedFailure` - helper ended with `.failed`.
    ///   - `FlashEngineError.cancelled` - `cancel()` was called before completion.
    public func flash(
        source: URL,
        target: DiskDescriptor,
        advisorySHA512: String?
    ) async throws -> FlashResult {
        // Assign a fresh job ID for this session. This SAME id travels inside the
        // FlashRequest so the helper echoes it in every FlashProgress/FlashResult;
        // that is what lets `handleProgress` match events back to this job.
        let jobID = JobID.generate()
        activeJobID = jobID

        // Resolve which whole disk the source image lives on, so the helper's
        // sourceOverlap rule can refuse a target that is the same disk. Best
        // effort: `nil` when DiskArbitration cannot describe the backing volume.
        let sourceBackingBSDName = SourceBacking.wholeDiskBSDName(forPath: source.path)

        // Build the typed request. Image bytes stay on disk; the helper opens
        // the source by its absolute path.
        let request = FlashRequest(
            jobID: jobID,
            sourceAccess: .absolutePath(source.path),
            targetBSDName: target.bsdName,
            sourceBackingBSDName: sourceBackingBSDName,
            advisorySizeBytes: UInt64(max(0, target.sizeBytes)),
            advisorySHA512: advisorySHA512
        )

        // Bridge the callback-based HelperConnection into an async/await
        // continuation. The continuation is resumed exactly once when the
        // helper calls the result block.
        let result: Result<FlashResult, FlashEngineError> = try await withCheckedThrowingContinuation { continuation in
            do {
                try connection.flash(
                    request: request,
                    progress: { [weak self] progressValue in
                        // Forward progress into the actor asynchronously.
                        Task {
                            await self?.handleProgress(progressValue, expectedJobID: jobID)
                        }
                    },
                    result: { resultValue in
                        // Resume the continuation exactly once.
                        continuation.resume(returning: resultValue)
                    }
                )
            } catch let engineError as FlashEngineError {
                continuation.resume(throwing: engineError)
            } catch {
                continuation.resume(throwing: FlashEngineError.connectionFailed(error.localizedDescription))
            }
        }

        // Finish the progress stream regardless of outcome.
        progressContinuation.finish()
        activeJobID = nil

        // Unwrap the result, converting failure cases to thrown errors.
        switch result {
        case .success(let flashResult):
            return flashResult
        case .failure(let error):
            throw error
        }
    }

    /// Request cancellation of the active flash job.
    ///
    /// Best-effort; does nothing if no job is active. The authoritative outcome
    /// still arrives as a `FlashEngineError.cancelled` throw from `flash(...)`.
    public func cancel() {
        guard let jobID = activeJobID else {
            // No active job; nothing to cancel.
            return
        }
        // Encode and send cancel over XPC; ignore encoding errors since the
        // job will terminate via its own result callback if the connection drops.
        try? connection.cancel(jobID: jobID)
    }

    // MARK: - Private helpers

    /// Yield a progress update to the stream after validating the job ID.
    ///
    /// Called from an arbitrary queue via a Task hop into the actor context.
    private func handleProgress(_ progress: FlashProgress, expectedJobID: JobID) {
        // Guard against stale progress from a previous job.
        guard progress.jobID == expectedJobID else {
            return
        }
        progressContinuation.yield(progress)
    }
}
