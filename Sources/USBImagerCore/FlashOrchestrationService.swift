/// FlashOrchestrationService - concrete flash orchestration service.
///
/// This is the core's single driver for a flash session. It obtains a
/// `FlashEngine` from an injected `FlashEngineFactory`, subscribes to the
/// engine's `progressStream`, maps each helper `FlashProgress` into the
/// GUI-neutral `FlashProgressData`, forwards `cancel()`, and collapses the
/// engine's `async throws` result into a typed `FlashRunResult` the CLI maps to
/// an exit code and the GUI maps to UI state.
///
/// Boundaries (frozen; see Services.swift):
///   - Re-uses `FlashEngine`; it does not re-implement flash or safety logic.
///   - Maps `FlashEngineError` to wording via the core `userMessage(for:)`
///     function so both front ends show the same text.
///   - No SwiftUI/AppKit. The service is an `actor`, so it satisfies `Sendable`
///     and isolates the per-session engine reference that `cancel()` needs,
///     without forcing `@MainActor`.
///
/// The helper-absent path is owned by the injected factory: `makeEngine()`
/// throws `CoreError.helperUnavailable`, which this service returns directly as
/// `.failure(.helperUnavailable)` (CLI exit code 3) before any device work.

import DiskModel
import FlashEngine
import Foundation
import HelperProtocol

// MARK: - DefaultFlashOrchestrationService

/// Concrete `FlashOrchestrationService` backed by an injected `FlashEngineFactory`.
///
/// One instance can drive sequential sessions, but a single instance is not
/// meant to run two `flash` calls concurrently: the active-engine reference that
/// `cancel()` targets is per-session. Production builds one engine per flash
/// from an `XPCHelperConnection`; tests inject a fake factory/connection.
public actor DefaultFlashOrchestrationService: FlashOrchestrationService {

    // MARK: - Private state

    /// Builds a fresh `FlashEngine` for each flash session. Throws
    /// `CoreError.helperUnavailable` when the helper connection cannot be made.
    private let engineFactory: FlashEngineFactory

    /// The engine driving the in-flight session, retained only so `cancel()` can
    /// reach it. `nil` between sessions.
    private var activeEngine: FlashEngine?

    // MARK: - Init

    /// Create a service that obtains engines from `engineFactory`.
    ///
    /// - Parameter engineFactory: the injected factory. Production passes a
    ///   factory that builds an engine over an `XPCHelperConnection`; tests pass
    ///   a fake that can also simulate the helper-absent path.
    public init(engineFactory: FlashEngineFactory) {
        self.engineFactory = engineFactory
    }

    // MARK: - FlashOrchestrationService

    public func flash(
        source: URL,
        target: DiskDescriptor,
        advisorySHA512: String?,
        verifyReadBack: Bool,
        progress: @escaping @Sendable (FlashProgressData) -> Void
    ) async -> FlashRunResult {
        // Obtain the engine first. A throwing factory is the no-helper path: the
        // helper connection could not be established, so the run fails before any
        // device is touched. The factory throws `CoreError.helperUnavailable`; we
        // surface anything else it might throw as the same typed reason so the
        // CLI still exits 3 rather than crashing.
        let engine: FlashEngine
        do {
            engine = try engineFactory.makeEngine()
        } catch let coreError as CoreError {
            return .failure(error: coreError)
        } catch {
            return .failure(error: .helperUnavailable(message: error.localizedDescription))
        }

        // Retain the engine so a concurrent `cancel()` can reach it, then clear
        // the reference when this session ends regardless of outcome.
        activeEngine = engine
        defer { activeEngine = nil }

        // Drain the progress stream on a child task while the flash runs. The
        // engine finishes the stream when the job terminates, so this task ends
        // on its own; we still await it below to guarantee every emitted sample
        // is delivered before we return. `progressStream` carries the helper's
        // four-phase `FlashProgress`; `mapProgress` drops the lifecycle phases
        // (`.unmounting`/`.done`) and forwards only the two progress-bar phases.
        let progressStream = await engine.progressStream
        let progressTask = Task {
            for await sample in progressStream {
                guard let mapped = Self.mapProgress(sample) else {
                    // A lifecycle phase with no progress-bar meaning; skip it.
                    continue
                }
                progress(mapped)
            }
        }

        // Drive the flash and collapse the engine's throwing result into a typed
        // outcome. The engine returns only `.success`; failed and cancelled
        // outcomes arrive as thrown `FlashEngineError`s.
        let runResult: FlashRunResult
        do {
            let flashResult = try await engine.flash(
                source: source,
                target: target,
                advisorySHA512: advisorySHA512
            )
            runResult = Self.resultForSuccess(
                flashResult,
                advisorySHA512: advisorySHA512,
                verifyReadBack: verifyReadBack
            )
        } catch let engineError as FlashEngineError {
            runResult = Self.resultForEngineError(engineError)
        } catch {
            // The engine's documented surface is `FlashEngineError`; any other
            // thrown error is an unexpected mid-write failure.
            runResult = .failure(error: .flashFailed(message: error.localizedDescription))
        }

        // The stream is finished by `engine.flash`; await the drain so no
        // in-flight progress sample is dropped after we return.
        await progressTask.value
        return runResult
    }

    public func cancel() async {
        // Best-effort: forward to the active engine if a session is running. The
        // authoritative `.failure(.cancelled)` still arrives from the originating
        // `flash` call.
        await activeEngine?.cancel()
    }

    // MARK: - Result mapping (pure, static)

    /// Build the terminal result for an engine `.success`.
    ///
    /// When `verifyReadBack` is requested and an advisory source digest is on
    /// hand, the helper-derived device digest is compared against it: a mismatch
    /// is a verification failure (CLI exit code 1), not a success. Without
    /// `verifyReadBack`, or without an advisory digest to compare against, a
    /// completed write is reported as success carrying the device digest.
    ///
    /// - Parameters:
    ///   - flashResult: the engine's `.success` result.
    ///   - advisorySHA512: the expected source digest (lowercase hex), or `nil`.
    ///   - verifyReadBack: whether read-back verification was requested.
    /// - Returns: `.success(deviceSHA512:)` or `.failure(.verificationMismatch)`.
    static func resultForSuccess(
        _ flashResult: FlashResult,
        advisorySHA512: String?,
        verifyReadBack: Bool
    ) -> FlashRunResult {
        // The helper-derived device digest is the ground truth. It is optional on
        // the wire; an empty string stands in when the helper sent none so the
        // result type always carries a value. Normalize to canonical lowercase
        // hex once here: the helper documents lowercase output, and pinning it
        // means the success payload and the mismatch comparison agree regardless
        // of casing the wire happened to carry.
        let deviceDigest = (flashResult.deviceSHA512 ?? "").lowercased()

        // Read-back mismatch only applies when verification was requested and we
        // actually have an expected digest to compare against. Compare case-
        // insensitively since hex casing is not significant.
        if verifyReadBack, let expected = advisorySHA512 {
            let normalizedExpected = expected.lowercased()
            if normalizedExpected != deviceDigest {
                let mismatch = CoreError.verificationMismatch(
                    expected: normalizedExpected,
                    actual: deviceDigest
                )
                return .failure(error: mismatch)
            }
        }
        return .success(deviceSHA512: deviceDigest)
    }

    /// Map a thrown `FlashEngineError` to the typed `FlashRunResult` failure.
    ///
    /// `.cancelled` maps to the dedicated `CoreError.cancelled` (exit code 5);
    /// every other engine error is a mid-write flash failure (exit code 4) whose
    /// message comes from the shared `userMessage(for:)` mapping.
    ///
    /// - Parameter engineError: the error thrown by `FlashEngine.flash`.
    /// - Returns: the typed failure result.
    static func resultForEngineError(_ engineError: FlashEngineError) -> FlashRunResult {
        switch engineError {
        case .cancelled:
            return .failure(error: .cancelled)
        default:
            let message = userMessage(for: engineError)
            return .failure(error: .flashFailed(message: message))
        }
    }

    // MARK: - Progress mapping (pure, static)

    /// Map a helper `FlashProgress` into a `FlashProgressData`, or `nil` for a
    /// lifecycle phase that has no progress-bar meaning.
    ///
    /// The workflow's `FlashProgressData.Phase` is intentionally narrower than
    /// the helper's `FlashPhase`: only `.writing` and `.verifying` are progress-
    /// bar phases. `.unmounting` and `.done` are lifecycle states the front ends
    /// do not render a bar for, so they are dropped here.
    ///
    /// - Parameter sample: the helper progress sample.
    /// - Returns: the mapped `FlashProgressData`, or `nil` to skip the sample.
    static func mapProgress(_ sample: FlashProgress) -> FlashProgressData? {
        let mappedPhase: FlashProgressData.Phase
        switch sample.phase {
        case .writing:
            mappedPhase = .writing
        case .verifying:
            mappedPhase = .verifying
        case .unmounting, .done:
            // Lifecycle phases, not progress-bar phases; map them away.
            return nil
        }
        // Use the byte-count convenience initializer so the fraction is derived
        // (and left nil) consistently with the rest of the workflow.
        let mapped = FlashProgressData(
            phase: mappedPhase,
            bytesDone: sample.bytesDone,
            totalBytes: sample.totalBytes
        )
        return mapped
    }
}
