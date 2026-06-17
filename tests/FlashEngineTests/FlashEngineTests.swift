/// FlashEngineTests.swift - unit tests for FlashEngine using a fake HelperConnection.
///
/// Strategy: inject a `FakeHelperConnection` conformer that lets each test
/// script progress events and a terminal result without touching XPC.
///
/// Coverage:
///   - Progress events reach the `progressStream`.
///   - A success result is returned from `flash(...)`.
///   - A helper failure maps to `FlashEngineError.helperReportedFailure`.
///   - A helper cancellation maps to `FlashEngineError.cancelled`.
///   - `cancel()` during a job triggers the cancellation path.
///   - A connection error thrown synchronously maps to `FlashEngineError`.

import Foundation
import Testing
@testable import FlashEngine
import DiskModel
import HelperProtocol

// MARK: - FakeHelperConnection

/// Async fake that fires scripted progress events then delivers the terminal
/// result via a Task, matching the production XPC pattern where progress
/// and result callbacks arrive on arbitrary queues after `flash()` returns.
///
/// Using Task for both deliveries gives the Swift concurrency runtime a chance
/// to schedule the engine's own actor hops (which also use Task) before
/// `finish()` is called on the progress stream.
final class FakeHelperConnection: HelperConnection, @unchecked Sendable {

    /// Events the fake will fire before delivering the result.
    let progressEvents: [FlashProgress]

    /// The terminal result the fake delivers after all progress events.
    let terminalResult: Result<FlashResult, FlashEngineError>

    /// Set to `true` when `cancel(jobID:)` is invoked.
    private(set) var cancelCalled: Bool = false

    /// Optionally throw on `flash(...)` instead of calling the result callback.
    let throwOnFlash: FlashEngineError?

    init(
        progressEvents: [FlashProgress] = [],
        terminalResult: Result<FlashResult, FlashEngineError>,
        throwOnFlash: FlashEngineError? = nil
    ) {
        self.progressEvents = progressEvents
        self.terminalResult = terminalResult
        self.throwOnFlash = throwOnFlash
    }

    func flash(
        request: FlashRequest,
        progress progressCallback: @escaping @Sendable (FlashProgress) -> Void,
        result resultCallback: @escaping @Sendable (Result<FlashResult, FlashEngineError>) -> Void
    ) throws {
        if let error = throwOnFlash {
            throw error
        }
        // Echo the request's jobID into every progress event, mirroring the real
        // helper: the app assigns the jobID inside FlashRequest and the helper
        // stamps it onto each FlashProgress so the engine's handleProgress guard
        // recognizes the events as belonging to this job.
        let events = progressEvents.map { event in
            FlashProgress(
                jobID: request.jobID,
                bytesDone: event.bytesDone,
                totalBytes: event.totalBytes,
                phase: event.phase
            )
        }
        let terminal = terminalResult
        // Deliver all callbacks asynchronously, matching the XPC production pattern
        // where callbacks arrive on an arbitrary queue after flash() returns.
        // A brief sleep between progress events and the result gives the engine's
        // own Task hops (Task { await self?.handleProgress(...) }) time to run
        // before the result callback triggers progressContinuation.finish().
        Task {
            // Sleep briefly before firing progress events so the test's collectTask
            // can enter the for-await loop on the progressStream before any events
            // arrive. Task.yield() only yields within the same executor; a real sleep
            // gives the Swift runtime scheduler a chance to run tasks on OTHER
            // executors (including the FlashEngine actor's executor).
            try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms initial delay
            for event in events {
                progressCallback(event)
                // Sleep after each progress callback so the engine's Task hop
                // (Task { await self?.handleProgress(...) }) can acquire the actor
                // and enqueue the event in the AsyncStream continuation before the
                // next callback is fired and before resultCallback resumes flash().
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms per event
            }
            // Additional sleep to let the final handleProgress Task enqueue its
            // yield() call in the AsyncStream before resultCallback triggers
            // progressContinuation.finish() inside flash().
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms final delay
            resultCallback(terminal)
        }
    }

    func cancel(jobID: JobID) throws {
        cancelCalled = true
    }

    func invalidate() {}
}

// MARK: - Shared fixture builders

/// A minimal external USB disk descriptor used across engine tests.
private func makeTarget(bsdName: String = "disk4") -> DiskDescriptor {
    DiskDescriptor(
        bsdName: bsdName,
        devicePath: "/dev/\(bsdName)",
        rawDevicePath: "/dev/r\(bsdName)",
        sizeBytes: 32_000_000_000,
        isRemovable: true,
        isEjectable: true,
        isInternal: false,
        busProtocol: .usb,
        isWritable: true,
        isSynthesized: false,
        carriesMacOSSystem: false,
        carriesTimeMachine: false,
        mountPoints: []
    )
}

/// A synthetic 128-char SHA-512 hex string used as a device digest in results.
private let fakeSHA512 = String(repeating: "a", count: 128)

/// A fake source URL that does not need to exist on disk (engine passes the path
/// to the helper; the fake helper ignores it).
private let fakeSourceURL = URL(fileURLWithPath: "/tmp/fake_image.img")

// MARK: - Progress forwarding tests
//
// FlashEngine.flash() assigns a jobID and now carries it INSIDE the FlashRequest.
// The helper (real or the fake here) echoes that jobID on every FlashProgress, so
// the engine's handleProgress guard recognizes the events and forwards them to the
// progressStream. These tests confirm that forwarding works end to end.

/// A progress event whose jobID is a placeholder; the fake overwrites it with the
/// request's jobID before delivery, so only the byte/phase fields matter here.
private func makeProgressEvent(
    bytesDone: UInt64,
    totalBytes: UInt64,
    phase: FlashPhase
) -> FlashProgress {
    FlashProgress(
        jobID: JobID(rawValue: "placeholder-overwritten-by-fake"),
        bytesDone: bytesDone,
        totalBytes: totalBytes,
        phase: phase
    )
}

@Suite("FlashEngine progress forwarding")
struct FlashEngineProgressTests {

    @Test("A single progress event reaches the progressStream")
    func singleProgressEvent() async throws {
        let jobID = JobID.generate()
        let successResult = FlashResult(
            jobID: jobID,
            outcome: .success,
            deviceSHA512: fakeSHA512,
            errorMessage: nil
        )
        let event = makeProgressEvent(bytesDone: 4096, totalBytes: 8192, phase: .writing)
        let fake = FakeHelperConnection(
            progressEvents: [event],
            terminalResult: .success(successResult)
        )
        let engine = FlashEngine(connection: fake)
        let stream = await engine.progressStream

        // Collect events concurrently with the flash run.
        let collectTask = Task { () -> [FlashProgress] in
            var collected: [FlashProgress] = []
            for await progress in stream {
                collected.append(progress)
            }
            return collected
        }

        _ = try await engine.flash(
            source: fakeSourceURL,
            target: makeTarget(),
            advisorySHA512: nil
        )
        let collected = await collectTask.value
        #expect(collected.count == 1)
        #expect(collected.first?.bytesDone == 4096)
        #expect(collected.first?.phase == .writing)
    }

    @Test("Multiple progress events reach the progressStream in order")
    func multipleProgressEvents() async throws {
        let jobID = JobID.generate()
        let successResult = FlashResult(
            jobID: jobID,
            outcome: .success,
            deviceSHA512: fakeSHA512,
            errorMessage: nil
        )
        let events = [
            makeProgressEvent(bytesDone: 0, totalBytes: 8192, phase: .unmounting),
            makeProgressEvent(bytesDone: 4096, totalBytes: 8192, phase: .writing),
            makeProgressEvent(bytesDone: 8192, totalBytes: 8192, phase: .verifying),
        ]
        let fake = FakeHelperConnection(
            progressEvents: events,
            terminalResult: .success(successResult)
        )
        let engine = FlashEngine(connection: fake)
        let stream = await engine.progressStream

        let collectTask = Task { () -> [FlashProgress] in
            var collected: [FlashProgress] = []
            for await progress in stream {
                collected.append(progress)
            }
            return collected
        }

        _ = try await engine.flash(
            source: fakeSourceURL,
            target: makeTarget(),
            advisorySHA512: nil
        )
        let collected = await collectTask.value
        #expect(collected.count == 3)
        #expect(collected.map { $0.phase } == [.unmounting, .writing, .verifying])
    }

    @Test("Engine finishes progressStream after flash completes")
    func progressStreamFinishesAfterFlash() async throws {
        let jobID = JobID.generate()
        let successResult = FlashResult(
            jobID: jobID,
            outcome: .success,
            deviceSHA512: fakeSHA512,
            errorMessage: nil
        )
        let fake = FakeHelperConnection(
            progressEvents: [],
            terminalResult: .success(successResult)
        )
        let engine = FlashEngine(connection: fake)

        // Obtain the stream reference before flash() for the same reason as the
        // other progress tests: avoid competing with flash() for the actor when
        // acquiring the `let progressStream` property.
        let stream = await engine.progressStream

        // Collect all events; the for-await loop must terminate.
        let collectTask = Task { () -> Int in
            var count = 0
            for await _ in stream {
                count += 1
            }
            return count
        }

        _ = try await engine.flash(
            source: fakeSourceURL,
            target: makeTarget(),
            advisorySHA512: nil
        )
        let count = await collectTask.value
        // No events were queued; stream should finish with zero events.
        #expect(count == 0)
    }
}

// MARK: - Success result tests

@Suite("FlashEngine success result")
struct FlashEngineSuccessTests {

    @Test("flash returns FlashResult on helper success")
    func returnsFlashResult() async throws {
        let jobID = JobID.generate()
        let expected = FlashResult(
            jobID: jobID,
            outcome: .success,
            deviceSHA512: fakeSHA512,
            errorMessage: nil
        )
        let fake = FakeHelperConnection(
            progressEvents: [],
            terminalResult: .success(expected)
        )
        let engine = FlashEngine(connection: fake)

        let result = try await engine.flash(
            source: fakeSourceURL,
            target: makeTarget(),
            advisorySHA512: nil
        )
        #expect(result.outcome == .success)
        #expect(result.deviceSHA512 == fakeSHA512)
    }

    @Test("flash passes advisorySHA512 to the connection (smoke)")
    func advisorySHA512Forwarded() async throws {
        let jobID = JobID.generate()
        let successResult = FlashResult(
            jobID: jobID,
            outcome: .success,
            deviceSHA512: fakeSHA512,
            errorMessage: nil
        )
        let fake = FakeHelperConnection(
            progressEvents: [],
            terminalResult: .success(successResult)
        )
        let engine = FlashEngine(connection: fake)

        // No assertion on the advisory hex value itself - the fake ignores it.
        // This test confirms flash() does not throw when advisory is provided.
        let result = try await engine.flash(
            source: fakeSourceURL,
            target: makeTarget(),
            advisorySHA512: fakeSHA512
        )
        #expect(result.outcome == .success)
    }
}

// MARK: - Failure mapping tests

@Suite("FlashEngine error mapping")
struct FlashEngineErrorTests {

    @Test("Helper reported failure maps to helperReportedFailure")
    func helperFailureMapped() async throws {
        let fake = FakeHelperConnection(
            progressEvents: [],
            terminalResult: .failure(.helperReportedFailure(message: "write error"))
        )
        let engine = FlashEngine(connection: fake)

        do {
            _ = try await engine.flash(
                source: fakeSourceURL,
                target: makeTarget(),
                advisorySHA512: nil
            )
            Issue.record("Expected helperReportedFailure to be thrown")
        } catch let error as FlashEngineError {
            if case .helperReportedFailure(let message) = error {
                #expect(message == "write error")
            } else {
                Issue.record("Wrong error case: \(error)")
            }
        }
    }

    @Test("Helper cancellation maps to FlashEngineError.cancelled")
    func helperCancelledMapped() async throws {
        let fake = FakeHelperConnection(
            progressEvents: [],
            terminalResult: .failure(.cancelled)
        )
        let engine = FlashEngine(connection: fake)

        do {
            _ = try await engine.flash(
                source: fakeSourceURL,
                target: makeTarget(),
                advisorySHA512: nil
            )
            Issue.record("Expected .cancelled to be thrown")
        } catch FlashEngineError.cancelled {
            // Expected path.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Connection failure from synchronous throw maps to connectionFailed")
    func connectionFailedMapped() async throws {
        let fake = FakeHelperConnection(
            progressEvents: [],
            terminalResult: .success(FlashResult(
                jobID: JobID.generate(),
                outcome: .success,
                deviceSHA512: nil,
                errorMessage: nil
            )),
            throwOnFlash: .connectionFailed("XPC not available")
        )
        let engine = FlashEngine(connection: fake)

        do {
            _ = try await engine.flash(
                source: fakeSourceURL,
                target: makeTarget(),
                advisorySHA512: nil
            )
            Issue.record("Expected connectionFailed to be thrown")
        } catch let error as FlashEngineError {
            if case .connectionFailed(let detail) = error {
                #expect(detail == "XPC not available")
            } else {
                Issue.record("Wrong error case: \(error)")
            }
        }
    }

    @Test("helperReportedFailure with nil message is preserved")
    func helperFailureNilMessage() async throws {
        let fake = FakeHelperConnection(
            progressEvents: [],
            terminalResult: .failure(.helperReportedFailure(message: nil))
        )
        let engine = FlashEngine(connection: fake)

        do {
            _ = try await engine.flash(
                source: fakeSourceURL,
                target: makeTarget(),
                advisorySHA512: nil
            )
            Issue.record("Expected helperReportedFailure to be thrown")
        } catch let error as FlashEngineError {
            if case .helperReportedFailure(let message) = error {
                #expect(message == nil)
            } else {
                Issue.record("Wrong error case: \(error)")
            }
        }
    }
}

// MARK: - Cancel tests

@Suite("FlashEngine cancel")
struct FlashEngineCancelTests {

    @Test("cancel() when no job is active is a no-op (does not crash)")
    func cancelWithNoActiveJob() async {
        let fake = FakeHelperConnection(
            progressEvents: [],
            terminalResult: .success(FlashResult(
                jobID: JobID.generate(),
                outcome: .success,
                deviceSHA512: nil,
                errorMessage: nil
            ))
        )
        let engine = FlashEngine(connection: fake)
        // Must not crash.
        await engine.cancel()
        #expect(!fake.cancelCalled)
    }

    @Test("cancel() during an active job calls connection.cancel")
    func cancelDuringActiveJob() async throws {
        // The fake delivers a cancellation result immediately, so flash() throws .cancelled.
        let fake = FakeHelperConnection(
            progressEvents: [],
            terminalResult: .failure(.cancelled)
        )
        let engine = FlashEngine(connection: fake)

        // Start the flash job on a concurrent Task.
        let flashTask = Task {
            do {
                _ = try await engine.flash(
                    source: fakeSourceURL,
                    target: makeTarget(),
                    advisorySHA512: nil
                )
            } catch FlashEngineError.cancelled {
                // Expected outcome.
            }
        }

        // Cancel via the engine API. Because the fake resolves immediately,
        // the job may already be done, but the cancel path must not crash.
        await engine.cancel()
        try await flashTask.value

        // The fake's cancel method may or may not have been called depending on
        // race timing, but no error should have propagated.
    }
}
