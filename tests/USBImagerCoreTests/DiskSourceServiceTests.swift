/// DiskSourceServiceTests.swift - unit tests for DefaultImageSourceService and
/// DefaultDiskTargetService (WP-1c).
///
/// ImageSourceService tests:
///   - byteLength(of:) returns the correct size for a real temp file written under /tmp.
///   - byteLength(of:) throws CoreError.badInput for a missing file.
///   - byteLength(of:) throws CoreError.badInput for a directory path.
///
/// DiskTargetService tests:
///   - validTargets delegates to DiskModel.validTargets with no re-implementation
///     (proven by exercising it against the same DiskDescriptor fixtures used in
///     DiskModelTests/DiskSafetyTests).
///   - displayName produces the expected format for several fixture disks.
///
/// Fixture strategy: build DiskDescriptor values directly (no live DiskArbitration
/// session needed) using the same makeDescriptor helper pattern from DiskSafetyTests.
/// The snapshotDisks() path is not tested here because it requires a live
/// DiskArbitration session; that path is covered by the existing DiskEnumerator live
/// behavior and is exercised by the real app at run time.
import Foundation
import Testing
@testable import USBImagerCore
@testable import DiskModel

// MARK: - Fixture helper

/// Build a minimal safe-by-default external USB descriptor, overriding specific
/// fields to exercise the case under test. Mirrors the pattern in DiskSafetyTests.
private func makeDisk(
    bsdName: String = "disk4",
    sizeBytes: Int = 32_000_000_000,
    isRemovable: Bool = true,
    isEjectable: Bool = true,
    isInternal: Bool = false,
    busProtocol: BusProtocol = .usb,
    isWritable: Bool = true,
    isSynthesized: Bool = false,
    carriesMacOSSystem: Bool = false,
    carriesTimeMachine: Bool = false,
    mountPoints: [String] = []
) -> DiskDescriptor {
    let disk = DiskDescriptor(
        bsdName: bsdName,
        devicePath: "/dev/\(bsdName)",
        rawDevicePath: "/dev/r\(bsdName)",
        sizeBytes: sizeBytes,
        isRemovable: isRemovable,
        isEjectable: isEjectable,
        isInternal: isInternal,
        busProtocol: busProtocol,
        isWritable: isWritable,
        isSynthesized: isSynthesized,
        carriesMacOSSystem: carriesMacOSSystem,
        carriesTimeMachine: carriesTimeMachine,
        mountPoints: mountPoints
    )
    return disk
}

// MARK: - ImageSourceService tests

@Suite("DefaultImageSourceService - byteLength")
struct ImageSourceServiceTests {

    let service = DefaultImageSourceService()

    // MARK: Happy path: real temp file

    @Test("byteLength returns the correct size for a small temp file")
    func byteLengthRealFile() throws {
        // Write 1024 bytes to a temp file under /tmp.
        let tmpURL = URL(fileURLWithPath: "/tmp/usbimager_test_\(UUID().uuidString).bin")
        let data = Data(repeating: 0xAB, count: 1024)
        try data.write(to: tmpURL)
        defer {
            // Best-effort cleanup; failure here should not mask test failure.
            try? FileManager.default.removeItem(at: tmpURL)
        }
        let length = try service.byteLength(of: tmpURL)
        #expect(length == 1024)
    }

    @Test("byteLength returns the correct size for an empty temp file")
    func byteLengthEmptyFile() throws {
        let tmpURL = URL(fileURLWithPath: "/tmp/usbimager_test_\(UUID().uuidString).bin")
        let data = Data()
        try data.write(to: tmpURL)
        defer {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        let length = try service.byteLength(of: tmpURL)
        #expect(length == 0)
    }

    @Test("byteLength returns the correct size for a larger temp file")
    func byteLengthLargerFile() throws {
        // 4 MB -- exercises the Int path for a non-trivial size.
        let byteCount = 4 * 1024 * 1024
        let tmpURL = URL(fileURLWithPath: "/tmp/usbimager_test_\(UUID().uuidString).bin")
        let data = Data(repeating: 0x00, count: byteCount)
        try data.write(to: tmpURL)
        defer {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        let length = try service.byteLength(of: tmpURL)
        #expect(length == byteCount)
    }

    // MARK: Missing file throws badInput

    @Test("byteLength throws CoreError.badInput for a missing file")
    func byteLengthMissingFile() {
        let missingURL = URL(fileURLWithPath: "/tmp/usbimager_nonexistent_\(UUID().uuidString).bin")
        do {
            _ = try service.byteLength(of: missingURL)
            #expect(Bool(false), "Expected byteLength to throw for a missing file")
        } catch CoreError.badInput {
            // Correct error thrown.
        } catch {
            #expect(Bool(false), "Expected CoreError.badInput, got \(error)")
        }
    }

    // MARK: Directory path throws badInput

    @Test("byteLength throws CoreError.badInput for a directory path")
    func byteLengthDirectory() {
        let dirURL = URL(fileURLWithPath: "/tmp")
        do {
            _ = try service.byteLength(of: dirURL)
            #expect(Bool(false), "Expected byteLength to throw for a directory")
        } catch CoreError.badInput {
            // Correct error thrown.
        } catch {
            #expect(Bool(false), "Expected CoreError.badInput, got \(error)")
        }
    }
}

// MARK: - DiskTargetService tests

@Suite("DefaultDiskTargetService - validTargets delegation")
struct DiskTargetServiceValidTargetsTests {

    // Use the failable init's fallback: test without a live DiskArbitration session
    // by constructing the service via the enumerator-less path. Since DefaultDiskTargetService
    // only needs an enumerator for snapshotDisks(), and our tests drive validTargets
    // and displayName with fixture data, we create a service via the enumerator path.
    // However, init?() may fail in sandbox; we guard gracefully.
    //
    // Strategy: build a DiskEnumerator for real tests (runs on macOS with DiskArbitration)
    // or skip the snapshotDisks path. For validTargets and displayName, we use the
    // service's methods directly with fixtures; no actor call is needed.

    // A small image size used across filter tests.
    private let smallImage = 4_000_000_000  // 4 GB

    // MARK: validTargets delegates to DiskModel

    @Test("validTargets returns only the valid disk from a mixed list")
    func validTargetsMixedList() {
        // This exercises the delegation path: if DiskTargetService re-implemented
        // safety rules, the results might differ from DiskModel. Using the same
        // fixtures as DiskSafetyTests proves the service does not diverge.
        let goodDisk = makeDisk(bsdName: "disk4", sizeBytes: 32_000_000_000)
        let badInternal = makeDisk(bsdName: "disk0", isInternal: true, carriesMacOSSystem: true)
        let badSynthesized = makeDisk(bsdName: "disk3", isSynthesized: true)

        // Build the service via the enumerator initializer path. init?() can fail
        // in restricted environments; a nil enumerator surfaces as a visible
        // known issue rather than a silent pass.
        guard let enumerator = DiskEnumerator() else {
            withKnownIssue("DiskArbitration unavailable; cannot build DefaultDiskTargetService") {
                Issue.record("DiskEnumerator() returned nil")
            }
            return
        }
        let service = DefaultDiskTargetService(enumerator: enumerator)

        let result = service.validTargets(
            from: [goodDisk, badInternal, badSynthesized],
            imageSizeBytes: smallImage,
            sourceBackingBSDName: nil
        )
        // Guard-first so an unexpected count cannot trap on the [0] index; the
        // intent is "only the good disk survives", expressed structurally.
        #expect(result.map(\.bsdName) == ["disk4"])
    }

    @Test("validTargets returns an empty list when all disks are invalid")
    func validTargetsAllInvalid() {
        let internal0 = makeDisk(bsdName: "disk0", isInternal: true, carriesMacOSSystem: true)
        let synthesized3 = makeDisk(bsdName: "disk3", isSynthesized: true)
        let tooLarge4 = makeDisk(bsdName: "disk4", sizeBytes: 2_000_000_000_000)
        let timeMachine6 = makeDisk(bsdName: "disk6", carriesTimeMachine: true)

        guard let enumerator = DiskEnumerator() else {
            withKnownIssue("DiskArbitration unavailable; cannot build DefaultDiskTargetService") {
                Issue.record("DiskEnumerator() returned nil")
            }
            return
        }
        let service = DefaultDiskTargetService(enumerator: enumerator)

        let result = service.validTargets(
            from: [internal0, synthesized3, tooLarge4, timeMachine6],
            imageSizeBytes: smallImage,
            sourceBackingBSDName: nil
        )
        #expect(result.isEmpty)
    }

    @Test("validTargets respects the sourceBackingBSDName overlap rule")
    func validTargetsSourceOverlap() {
        // disk4 is otherwise valid but is the source backing disk.
        let disk4 = makeDisk(bsdName: "disk4", sizeBytes: 32_000_000_000)

        guard let enumerator = DiskEnumerator() else {
            withKnownIssue("DiskArbitration unavailable; cannot build DefaultDiskTargetService") {
                Issue.record("DiskEnumerator() returned nil")
            }
            return
        }
        let service = DefaultDiskTargetService(enumerator: enumerator)

        let result = service.validTargets(
            from: [disk4],
            imageSizeBytes: smallImage,
            sourceBackingBSDName: "disk4"
        )
        #expect(result.isEmpty)
    }

    @Test("validTargets returns an empty list for an empty input")
    func validTargetsEmpty() {
        guard let enumerator = DiskEnumerator() else {
            withKnownIssue("DiskArbitration unavailable; cannot build DefaultDiskTargetService") {
                Issue.record("DiskEnumerator() returned nil")
            }
            return
        }
        let service = DefaultDiskTargetService(enumerator: enumerator)

        let result = service.validTargets(
            from: [],
            imageSizeBytes: smallImage,
            sourceBackingBSDName: nil
        )
        #expect(result.isEmpty)
    }
}

// MARK: - DiskTargetService displayName tests

@Suite("DefaultDiskTargetService - displayName formatting")
struct DiskTargetServiceDisplayNameTests {

    // displayName forwards to the pure DiskModel.diskDisplayName(for:) formatter.
    // These tests call that formatter directly on a DiskDescriptor, so no live
    // DiskArbitration enumerator is needed and the cases cannot silently skip.
    // The structural checks below (vendor prefix, size suffix, protocol token)
    // survive label-wording tweaks; the one exact-equality case is a deliberate,
    // documented lock on the full display-string contract.

    // MARK: Vendor + model present (full human identity)

    @Test("displayName for a vendor+model USB disk locks the full human identity")
    func displayNameUSBWithVendorModel() {
        // Simulate a real USB drive where DiskArbitration provides vendor and model.
        let disk = DiskDescriptor(
            bsdName: "disk4",
            devicePath: "/dev/disk4",
            rawDevicePath: "/dev/rdisk4",
            sizeBytes: 32_000_000_000,
            isRemovable: true,
            isEjectable: true,
            isInternal: false,
            busProtocol: .usb,
            isWritable: true,
            isSynthesized: false,
            carriesMacOSSystem: false,
            carriesTimeMachine: false,
            mountPoints: [],
            vendor: "SanDisk",
            model: "Ultra"
        )
        let name = diskDisplayName(for: disk)
        // Intentional display-contract lock: this one case pins the full string
        // (vendor + model + decimal-GB size) so an accidental format change is
        // caught. Other cases below use structural checks.
        #expect(name == "SanDisk Ultra 32.0 GB")
    }

    // MARK: Vendor/model absent (bus-protocol fallback)

    @Test("displayName without vendor/model carries the USB protocol token and size")
    func displayNameUSB32GB() {
        // No vendor or model: falls back to bus-protocol label.
        let disk = makeDisk(bsdName: "disk4", sizeBytes: 32_000_000_000, busProtocol: .usb)
        let name = diskDisplayName(for: disk)
        // Structural: a USB token plus the decimal-GB size, order-independent.
        #expect(name.localizedCaseInsensitiveContains("USB"))
        #expect(name.hasSuffix("32.0 GB"))
    }

    @Test("displayName for an SD disk carries the SD protocol token and size")
    func displayNameSD64GB() {
        let disk = makeDisk(bsdName: "disk5", sizeBytes: 64_000_000_000, busProtocol: .sd)
        let name = diskDisplayName(for: disk)
        #expect(name.localizedCaseInsensitiveContains("SD"))
        #expect(name.hasSuffix("64.0 GB"))
    }

    @Test("displayName for an NVMe internal disk carries the nvme token and size")
    func displayNameNVMe() {
        let disk = makeDisk(
            bsdName: "disk0",
            sizeBytes: 500_300_000_000,
            isInternal: true,
            busProtocol: .nvme
        )
        let name = diskDisplayName(for: disk)
        // 500_300_000_000 / 1e9 = 500.3
        #expect(name.localizedCaseInsensitiveContains("NVME"))
        #expect(name.hasSuffix("500.3 GB"))
    }

    @Test("displayName for a virtual (synthesized) disk carries the virtual token")
    func displayNameVirtual() {
        let disk = makeDisk(
            bsdName: "disk3",
            sizeBytes: 500_300_000_000,
            busProtocol: .virtual,
            isSynthesized: true
        )
        let name = diskDisplayName(for: disk)
        #expect(name.localizedCaseInsensitiveContains("VIRTUAL"))
        #expect(name.hasSuffix("500.3 GB"))
    }

    @Test("displayName size always appears in the string")
    func displayNameContainsSize() {
        let disk = makeDisk(bsdName: "disk9", sizeBytes: 16_000_000_000)
        let name = diskDisplayName(for: disk)
        // Size suffix is always present; vendor/model may vary.
        #expect(name.hasSuffix("16.0 GB"))
    }

    @Test("displayName with vendor only carries the vendor prefix and size")
    func displayNameVendorOnly() {
        let disk = DiskDescriptor(
            bsdName: "disk4",
            devicePath: "/dev/disk4",
            rawDevicePath: "/dev/rdisk4",
            sizeBytes: 32_000_000_000,
            isRemovable: true,
            isEjectable: true,
            isInternal: false,
            busProtocol: .usb,
            isWritable: true,
            isSynthesized: false,
            carriesMacOSSystem: false,
            carriesTimeMachine: false,
            mountPoints: [],
            vendor: "SanDisk",
            model: ""
        )
        let name = diskDisplayName(for: disk)
        // Structural: vendor leads, size trails; empty model leaves no gap to pin.
        #expect(name.hasPrefix("SanDisk"))
        #expect(name.hasSuffix("32.0 GB"))
    }
}
