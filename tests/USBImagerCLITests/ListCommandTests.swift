/// ListCommandTests.swift - WP-3b delegation tests for `usbimager list`.
///
/// These tests prove that `ListCommand.run()` delegates to the core
/// `DiskTargetService` seam rather than containing its own disk-safety or
/// enumeration logic. Each test sets `Usbimager.servicesOverride` to a recording
/// fake, runs the command, and asserts that the expected service methods were
/// called with the expected arguments.

import DiskModel
import Foundation
import Testing
@testable import USBImagerCLI
@testable import USBImagerCore

// MARK: - Recording fake

/// A `DiskTargetService` that records which methods were called and with what
/// arguments, so a test can assert delegation without inspecting stdout.
final class RecordingDiskTargetService: DiskTargetService, @unchecked Sendable {

    // Disks to return from snapshotDisks.
    let snapshotResult: [DiskDescriptor]

    // Disks to return from validTargets.
    let validTargetsResult: [DiskDescriptor]

    // Call-recording state -- mutated from the async task that calls snapshotDisks.
    var snapshotCallCount = 0
    var validTargetsCallCount = 0
    var lastValidTargetsImageSizeBytes: Int? = nil
    var lastValidTargetsSourceBSD: String? = nil
    var displayNameCallCount = 0

    init(snapshotResult: [DiskDescriptor] = [], validTargetsResult: [DiskDescriptor] = []) {
        self.snapshotResult = snapshotResult
        self.validTargetsResult = validTargetsResult
    }

    func snapshotDisks() async -> [DiskDescriptor] {
        snapshotCallCount += 1
        return snapshotResult
    }

    func validTargets(
        from disks: [DiskDescriptor],
        imageSizeBytes: Int,
        sourceBackingBSDName: String?
    ) -> [DiskDescriptor] {
        validTargetsCallCount += 1
        lastValidTargetsImageSizeBytes = imageSizeBytes
        lastValidTargetsSourceBSD = sourceBackingBSDName
        return validTargetsResult
    }

    func displayName(for disk: DiskDescriptor) -> String {
        displayNameCallCount += 1
        return "\(disk.bsdName)  (\(disk.busProtocol.rawValue), fake)"
    }
}

// MARK: - Fixture helper

/// Build a minimal `DiskDescriptor` fixture for tests.
///
/// Only `bsdName` and `busProtocol` vary between cases; the safety-irrelevant
/// fields are filled with stable values so the fixture stays short.
private func makeFixtureDisk(
    bsdName: String = "disk9",
    busProtocol: BusProtocol = .usb
) -> DiskDescriptor {
    return DiskDescriptor(
        bsdName: bsdName,
        devicePath: "/dev/\(bsdName)",
        rawDevicePath: "/dev/r\(bsdName)",
        sizeBytes: 32_000_000_000,
        isRemovable: true,
        isEjectable: true,
        isInternal: false,
        busProtocol: busProtocol,
        isWritable: true,
        isSynthesized: false,
        carriesMacOSSystem: false,
        carriesTimeMachine: false,
        mountPoints: []
    )
}

/// Build a `CoreServices` bundle wrapping the recording disk service.
private func makeServicesWithDisk(
    _ diskService: RecordingDiskTargetService
) -> CoreServices {
    // ChecksumService, ImageSourceService, FlashOrchestrationService are not
    // exercised by `list`; use the scaffold fakes from CLIScaffoldTests.
    return CoreServices(
        checksum: FakeChecksumService(),
        imageSource: FakeImageSourceService(fixedLength: 0),
        diskTarget: diskService,
        flashOrchestration: FakeFlashOrchestrationService()
    )
}

// MARK: - Delegation tests

@Suite("usbimager list delegates to DiskTargetService", .serialized)
struct ListCommandDelegationTests {

    /// Clear the override after every test so suites stay independent.
    private func clearOverride() { Usbimager.servicesOverride = nil }

    @Test("snapshotDisks() and validTargets() are both called")
    func callsSnapshotAndValidTargets() throws {
        defer { clearOverride() }
        let disk = makeFixtureDisk()
        let fake = RecordingDiskTargetService(
            snapshotResult: [disk],
            validTargetsResult: [disk]
        )
        Usbimager.servicesOverride = makeServicesWithDisk(fake)

        // Run the subcommand. ArgumentParser.parseAsRoot throws on usage errors;
        // a clean run from a parsed command calls run() directly.
        var cmd = ListCommand()
        try cmd.run()

        #expect(fake.snapshotCallCount == 1, "snapshotDisks() was not called")
        #expect(fake.validTargetsCallCount == 1, "validTargets() was not called")
    }

    @Test("validTargets is called with imageSizeBytes: 0 and nil sourceBackingBSDName")
    func validTargetsArguments() throws {
        defer { clearOverride() }
        let fake = RecordingDiskTargetService(snapshotResult: [], validTargetsResult: [])
        Usbimager.servicesOverride = makeServicesWithDisk(fake)

        var cmd = ListCommand()
        try cmd.run()

        // The list command has no image; imageSizeBytes must be 0 and source BSD nil.
        #expect(fake.lastValidTargetsImageSizeBytes == 0)
        #expect(fake.lastValidTargetsSourceBSD == nil)
    }

    @Test("displayName(for:) is called once per safe target disk")
    func displayNameCalledPerTarget() throws {
        defer { clearOverride() }
        let diskA = makeFixtureDisk(bsdName: "disk4", busProtocol: .usb)
        let diskB = makeFixtureDisk(bsdName: "disk5", busProtocol: .sd)
        let fake = RecordingDiskTargetService(
            snapshotResult: [diskA, diskB],
            validTargetsResult: [diskA, diskB]
        )
        Usbimager.servicesOverride = makeServicesWithDisk(fake)

        var cmd = ListCommand()
        try cmd.run()

        // One displayName call per disk in the validTargets result.
        #expect(fake.displayNameCallCount == 2)
    }

    @Test("Empty safe-target list exits cleanly (no throw)")
    func emptyTargetListExitsClean() throws {
        defer { clearOverride() }
        let fake = RecordingDiskTargetService(snapshotResult: [], validTargetsResult: [])
        Usbimager.servicesOverride = makeServicesWithDisk(fake)

        // An empty safe-target list is not an error; run() must not throw.
        var cmd = ListCommand()
        try cmd.run()

        // snapshotDisks and validTargets were still called; displayName was not.
        #expect(fake.snapshotCallCount == 1)
        #expect(fake.validTargetsCallCount == 1)
        #expect(fake.displayNameCallCount == 0)
    }
}
