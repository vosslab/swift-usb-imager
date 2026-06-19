/// FlashCommandTests.swift - WP-3d delegation and exit-mapping tests for `flash`.
///
/// These tests prove that `usbimager flash`:
///   - resolves the target via the core disk service and calls
///     `FlashOrchestrationService.flash` with that resolved descriptor and a
///     `verifyReadBack` that reflects `--verify`,
///   - maps each `FlashRunResult` case to the right `CoreExitCode` (the frozen
///     CLI-contract mapping), and
///   - routes a bad/unknown target and an unreadable source to exit 2 without
///     touching the flash service.
///
/// The full `run()` terminates the process via `Usbimager.exit`/`fail`, so the
/// tests drive `FlashCommand.performFlash` (the same resolve/validate/orchestrate
/// path minus the final exit) and assert the typed `FlashRunResult` plus the
/// `CoreError.exitCode` mapping. No real device is written; the orchestration
/// service is a recording fake.

import DiskModel
import Foundation
import Testing
@testable import USBImagerCLI
@testable import USBImagerCore

// MARK: - Recording fake orchestration service

/// A `FlashOrchestrationService` that records the arguments of the `flash` call
/// and returns a configurable result, so a test can assert delegation and drive
/// each result case without a real device or helper.
final class RecordingFlashOrchestrationService: FlashOrchestrationService, @unchecked Sendable {

    /// The result `flash` returns. Defaults to a success with an empty digest.
    let resultToReturn: FlashRunResult

    /// Optional progress samples to replay through the callback before returning,
    /// so a test can assert the progress line formatting end to end.
    let progressToEmit: [FlashProgressData]

    // Call-recording state.
    var flashCallCount = 0
    var lastSource: URL? = nil
    var lastTarget: DiskDescriptor? = nil
    var lastAdvisorySHA512: String?? = nil
    var lastVerifyReadBack: Bool? = nil
    var cancelCallCount = 0

    init(
        resultToReturn: FlashRunResult = .success(deviceSHA512: ""),
        progressToEmit: [FlashProgressData] = []
    ) {
        self.resultToReturn = resultToReturn
        self.progressToEmit = progressToEmit
    }

    func flash(
        source: URL,
        target: DiskDescriptor,
        advisorySHA512: String?,
        verifyReadBack: Bool,
        progress: @escaping @Sendable (FlashProgressData) -> Void
    ) async -> FlashRunResult {
        flashCallCount += 1
        lastSource = source
        lastTarget = target
        lastAdvisorySHA512 = advisorySHA512
        lastVerifyReadBack = verifyReadBack
        for sample in progressToEmit {
            progress(sample)
        }
        return resultToReturn
    }

    func cancel() async {
        cancelCallCount += 1
    }
}

// MARK: - Fixture helpers

/// Build a minimal `DiskDescriptor` fixture for tests.
private func makeFlashFixtureDisk(bsdName: String = "disk4") -> DiskDescriptor {
    return DiskDescriptor(
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

/// A `DiskTargetService` that resolves a single named disk and returns it from
/// `diskDescriptor(withBSDName:)` via the protocol-extension default (which calls
/// `snapshotDisks`). An unknown name resolves to nil.
final class ResolvingDiskTargetService: DiskTargetService, @unchecked Sendable {
    let disks: [DiskDescriptor]
    init(disks: [DiskDescriptor]) { self.disks = disks }
    func snapshotDisks() async -> [DiskDescriptor] { disks }
    func validTargets(
        from disks: [DiskDescriptor],
        imageSizeBytes: Int,
        sourceBackingBSDName: String?
    ) -> [DiskDescriptor] { disks }
    func displayName(for disk: DiskDescriptor) -> String { disk.bsdName }
}

/// Build a `CoreServices` bundle wiring the recording flash service, a resolving
/// disk service, and an image-source service with a fixed (readable) byte length.
private func makeFlashServices(
    flash: RecordingFlashOrchestrationService,
    disks: [DiskDescriptor],
    sourceByteLength: Int = 4096
) -> CoreServices {
    return CoreServices(
        checksum: FakeChecksumService(),
        imageSource: FakeImageSourceService(fixedLength: sourceByteLength),
        diskTarget: ResolvingDiskTargetService(disks: disks),
        flashOrchestration: flash
    )
}

/// An `ImageSourceService` that always throws `badInput` (unreadable source).
private struct ThrowingImageSourceService: ImageSourceService {
    func byteLength(of url: URL) throws -> Int {
        throw CoreError.badInput(message: "unreadable")
    }
}

// MARK: - Delegation tests

@Suite("usbimager flash delegates to FlashOrchestrationService", .serialized)
struct FlashCommandDelegationTests {

    @Test("flash() is called with the resolved descriptor and verifyReadBack=false")
    func callsFlashWithResolvedDescriptorNoVerify() {
        let disk = makeFlashFixtureDisk(bsdName: "disk4")
        let fake = RecordingFlashOrchestrationService(resultToReturn: .success(deviceSHA512: "abc"))
        let services = makeFlashServices(flash: fake, disks: [disk])

        let result = FlashCommand.performFlash(
            sourcePath: "/tmp/fixture.iso",
            targetBSDName: "disk4",
            verifyReadBack: false,
            services: services,
            progress: { _ in }
        )

        #expect(fake.flashCallCount == 1)
        #expect(fake.lastTarget?.bsdName == "disk4")
        #expect(fake.lastVerifyReadBack == false)
        // advisorySHA512 is always nil from the CLI flash path.
        #expect(fake.lastAdvisorySHA512 == .some(nil))
        // The source URL is the file URL for the given path.
        #expect(fake.lastSource?.path == "/tmp/fixture.iso")
        #expect(result == .success(deviceSHA512: "abc"))
    }

    @Test("--verify maps to verifyReadBack=true on the flash call")
    func verifyFlagMapsToVerifyReadBack() {
        let disk = makeFlashFixtureDisk(bsdName: "disk7")
        let fake = RecordingFlashOrchestrationService()
        let services = makeFlashServices(flash: fake, disks: [disk])

        _ = FlashCommand.performFlash(
            sourcePath: "/tmp/fixture.iso",
            targetBSDName: "disk7",
            verifyReadBack: true,
            services: services,
            progress: { _ in }
        )

        #expect(fake.lastVerifyReadBack == true)
    }

    @Test("Progress samples are forwarded to the progress callback")
    func progressSamplesForwarded() {
        let disk = makeFlashFixtureDisk()
        let samples = [
            FlashProgressData(phase: .writing, bytesDone: 50, totalBytes: 100),
            FlashProgressData(phase: .verifying, bytesDone: 100, totalBytes: 100),
        ]
        let fake = RecordingFlashOrchestrationService(progressToEmit: samples)
        let services = makeFlashServices(flash: fake, disks: [disk])

        nonisolated(unsafe) var received: [FlashProgressData] = []
        _ = FlashCommand.performFlash(
            sourcePath: "/tmp/fixture.iso",
            targetBSDName: disk.bsdName,
            verifyReadBack: false,
            services: services,
            progress: { received.append($0) }
        )

        #expect(received == samples)
    }
}

// MARK: - Result-to-exit-code mapping

@Suite("usbimager flash maps each result case to the contract exit code", .serialized)
struct FlashCommandExitCodeTests {

    /// Helper: run performFlash with a fake returning `result` and map to an exit code.
    private func exitCode(for result: FlashRunResult) -> CoreExitCode {
        let disk = makeFlashFixtureDisk()
        let fake = RecordingFlashOrchestrationService(resultToReturn: result)
        let services = makeFlashServices(flash: fake, disks: [disk])
        let outcome = FlashCommand.performFlash(
            sourcePath: "/tmp/fixture.iso",
            targetBSDName: disk.bsdName,
            verifyReadBack: false,
            services: services,
            progress: { _ in }
        )
        switch outcome {
        case .success:
            return .success
        case .failure(let error):
            return error.exitCode
        }
    }

    @Test("success maps to exit 0")
    func successExitsZero() {
        #expect(exitCode(for: .success(deviceSHA512: "deadbeef")) == .success)
    }

    @Test("helperUnavailable maps to exit 3")
    func helperUnavailableExitsThree() {
        let code = exitCode(for: .failure(error: .helperUnavailable(message: "no helper")))
        #expect(code == .helperUnavailable)
        #expect(code.rawValue == 3)
    }

    @Test("verificationMismatch maps to exit 1")
    func verificationMismatchExitsOne() {
        let code = exitCode(for: .failure(error: .verificationMismatch(expected: "a", actual: "b")))
        #expect(code == .verificationMismatch)
        #expect(code.rawValue == 1)
    }

    @Test("flashFailed maps to exit 4")
    func flashFailedExitsFour() {
        let code = exitCode(for: .failure(error: .flashFailed(message: "io error")))
        #expect(code == .flashFailed)
        #expect(code.rawValue == 4)
    }

    @Test("cancelled maps to exit 5")
    func cancelledExitsFive() {
        let code = exitCode(for: .failure(error: .cancelled))
        #expect(code == .cancelled)
        #expect(code.rawValue == 5)
    }
}

// MARK: - Bad-input paths (no flash call)

@Suite("usbimager flash rejects bad input before touching the flash service", .serialized)
struct FlashCommandBadInputTests {

    @Test("Unknown target BSD name yields badInput (exit 2) and never calls flash")
    func unknownTargetExitsTwo() {
        // Disk service resolves only "disk4"; ask for a name that does not exist.
        let fake = RecordingFlashOrchestrationService()
        let services = makeFlashServices(flash: fake, disks: [makeFlashFixtureDisk(bsdName: "disk4")])

        let result = FlashCommand.performFlash(
            sourcePath: "/tmp/fixture.iso",
            targetBSDName: "bogusdisk999",
            verifyReadBack: false,
            services: services,
            progress: { _ in }
        )

        #expect(fake.flashCallCount == 0)
        if case .failure(let error) = result {
            #expect(error.exitCode == .badInput)
            #expect(error.exitCode.rawValue == 2)
        } else {
            Issue.record("Expected a badInput failure for an unknown target.")
        }
    }

    @Test("Unreadable source yields badInput (exit 2) and never calls flash")
    func unreadableSourceExitsTwo() {
        let disk = makeFlashFixtureDisk()
        let fake = RecordingFlashOrchestrationService()
        let services = CoreServices(
            checksum: FakeChecksumService(),
            imageSource: ThrowingImageSourceService(),
            diskTarget: ResolvingDiskTargetService(disks: [disk]),
            flashOrchestration: fake
        )

        let result = FlashCommand.performFlash(
            sourcePath: "/tmp/missing.iso",
            targetBSDName: disk.bsdName,
            verifyReadBack: false,
            services: services,
            progress: { _ in }
        )

        #expect(fake.flashCallCount == 0)
        if case .failure(let error) = result {
            #expect(error.exitCode == .badInput)
        } else {
            Issue.record("Expected a badInput failure for an unreadable source.")
        }
    }

    @Test("Missing disk session (nil diskTarget) yields badInput (exit 2)")
    func nilDiskTargetExitsTwo() {
        let fake = RecordingFlashOrchestrationService()
        let services = CoreServices(
            checksum: FakeChecksumService(),
            imageSource: FakeImageSourceService(fixedLength: 4096),
            diskTarget: nil,
            flashOrchestration: fake
        )

        let result = FlashCommand.performFlash(
            sourcePath: "/tmp/fixture.iso",
            targetBSDName: "disk4",
            verifyReadBack: false,
            services: services,
            progress: { _ in }
        )

        #expect(fake.flashCallCount == 0)
        if case .failure(let error) = result {
            #expect(error.exitCode == .badInput)
        } else {
            Issue.record("Expected a badInput failure when no disk session is available.")
        }
    }
}

// MARK: - Progress line formatting

@Suite("FlashCommand.progressLine formats numeric progress")
struct FlashCommandProgressLineTests {

    @Test("Writing phase with a known fraction shows a percentage")
    func writingWithPercentage() {
        let sample = FlashProgressData(phase: .writing, bytesDone: 25, totalBytes: 100)
        let line = FlashCommand.progressLine(for: sample)
        #expect(line.contains("[writing]"))
        #expect(line.contains("25%"))
        #expect(line.contains("25/100 bytes"))
    }

    @Test("Verifying phase label is used")
    func verifyingLabel() {
        let sample = FlashProgressData(phase: .verifying, bytesDone: 100, totalBytes: 100)
        let line = FlashCommand.progressLine(for: sample)
        #expect(line.contains("[verifying]"))
        #expect(line.contains("100%"))
    }

    @Test("Unknown denominator (totalBytes 0) omits the percentage")
    func unknownDenominatorNoPercent() {
        let sample = FlashProgressData(phase: .writing, bytesDone: 10, totalBytes: 0)
        let line = FlashCommand.progressLine(for: sample)
        #expect(line.contains("[writing]"))
        #expect(!line.contains("%"))
        #expect(line.contains("10/0 bytes"))
    }
}
