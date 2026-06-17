/// HelperSafetyTests.swift - unit tests for HelperSafety.validatedTarget
/// using an injected resolver instead of live DiskArbitration.
///
/// Coverage:
///   - Every Mac Studio disk (disk0/3/4/5/6/7) is rejected by validatedTarget.
///   - A non-resolvable BSD name throws targetNotResolvable.
///   - A valid external USB disk is accepted.
///   - A slice name is reduced to its whole-disk parent before lookup.

import Testing
@testable import PrivilegedHelper
import DiskModel

// MARK: - Fixture builders

/// Build a full DiskDescriptor for the given name, optionally overriding fields.
private func makeDisk(
    bsdName: String,
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
    DiskDescriptor(
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
}

// MARK: - Mac Studio ground-truth fixture descriptors

/// Mirrors the ground-truth Mac Studio disk layout from DiskSafetyTests.
private enum MacStudioFixture {
    static let disk0 = makeDisk(
        bsdName: "disk0",
        sizeBytes: 500_300_000_000,
        isRemovable: false,
        isEjectable: false,
        isInternal: true,
        busProtocol: .nvme,
        carriesMacOSSystem: true,
        mountPoints: ["/"]
    )
    static let disk3 = makeDisk(
        bsdName: "disk3",
        sizeBytes: 500_300_000_000,
        isRemovable: false,
        isEjectable: false,
        isInternal: true,
        busProtocol: .virtual,
        isSynthesized: true
    )
    static let disk4 = makeDisk(
        bsdName: "disk4",
        sizeBytes: 2_000_000_000_000,
        busProtocol: .usb,
        mountPoints: ["/Volumes/External"]
    )
    static let disk5 = makeDisk(
        bsdName: "disk5",
        sizeBytes: 2_000_000_000_000,
        busProtocol: .virtual,
        isSynthesized: true
    )
    static let disk6 = makeDisk(
        bsdName: "disk6",
        sizeBytes: 1_000_000_000_000,
        busProtocol: .usb,
        carriesTimeMachine: true,
        mountPoints: ["/Volumes/Backups"]
    )
    static let disk7 = makeDisk(
        bsdName: "disk7",
        sizeBytes: 1_000_000_000_000,
        busProtocol: .virtual,
        isSynthesized: true
    )

    /// All Mac Studio disks as an array for iteration.
    static let all: [DiskDescriptor] = [disk0, disk3, disk4, disk5, disk6, disk7]
}

/// Build a resolver closure that returns the given disk when the BSD name matches,
/// and `nil` otherwise.
private func singleDiskResolver(_ disk: DiskDescriptor) -> (String) -> DiskDescriptor? {
    { bsdName in
        disk.bsdName == bsdName ? disk : nil
    }
}

/// Build a resolver from a dictionary of bsdName -> DiskDescriptor.
private func dictionaryResolver(_ disks: [DiskDescriptor]) -> (String) -> DiskDescriptor? {
    let map = Dictionary(uniqueKeysWithValues: disks.map { ($0.bsdName, $0) })
    return { bsdName in map[bsdName] }
}

// MARK: - Mac Studio rejection tests

@Suite("HelperSafety: Mac Studio disks are all rejected")
struct HelperSafetyMacStudioTests {

    private let imageSizeBytes = 4_000_000_000  // 4 GB

    @Test("disk0 (internal NVMe boot disk) is rejected")
    func disk0Rejected() async {
        let resolver = singleDiskResolver(MacStudioFixture.disk0)
        await #expect(throws: (any Error).self) {
            try await HelperSafety.validatedTarget(
                targetBSDName: "disk0",
                imageSizeBytes: imageSizeBytes,
                sourceBackingBSDName: nil,
                resolver: resolver
            )
        }
    }

    @Test("disk3 (synthesized APFS container) is rejected")
    func disk3Rejected() async {
        let resolver = singleDiskResolver(MacStudioFixture.disk3)
        await #expect(throws: (any Error).self) {
            try await HelperSafety.validatedTarget(
                targetBSDName: "disk3",
                imageSizeBytes: imageSizeBytes,
                sourceBackingBSDName: nil,
                resolver: resolver
            )
        }
    }

    @Test("disk4 (2 TB external USB, too large) is rejected")
    func disk4Rejected() async {
        let resolver = singleDiskResolver(MacStudioFixture.disk4)
        await #expect(throws: (any Error).self) {
            try await HelperSafety.validatedTarget(
                targetBSDName: "disk4",
                imageSizeBytes: imageSizeBytes,
                sourceBackingBSDName: nil,
                resolver: resolver
            )
        }
    }

    @Test("disk5 (synthesized APFS container) is rejected")
    func disk5Rejected() async {
        let resolver = singleDiskResolver(MacStudioFixture.disk5)
        await #expect(throws: (any Error).self) {
            try await HelperSafety.validatedTarget(
                targetBSDName: "disk5",
                imageSizeBytes: imageSizeBytes,
                sourceBackingBSDName: nil,
                resolver: resolver
            )
        }
    }

    @Test("disk6 (1 TB Time Machine backup, too large) is rejected")
    func disk6Rejected() async {
        let resolver = singleDiskResolver(MacStudioFixture.disk6)
        await #expect(throws: (any Error).self) {
            try await HelperSafety.validatedTarget(
                targetBSDName: "disk6",
                imageSizeBytes: imageSizeBytes,
                sourceBackingBSDName: nil,
                resolver: resolver
            )
        }
    }

    @Test("disk7 (synthesized APFS container) is rejected")
    func disk7Rejected() async {
        let resolver = singleDiskResolver(MacStudioFixture.disk7)
        await #expect(throws: (any Error).self) {
            try await HelperSafety.validatedTarget(
                targetBSDName: "disk7",
                imageSizeBytes: imageSizeBytes,
                sourceBackingBSDName: nil,
                resolver: resolver
            )
        }
    }

    @Test("All Mac Studio disks throw targetRejected (not targetNotResolvable)")
    func allDisksThrowTargetRejected() async {
        let resolver = dictionaryResolver(MacStudioFixture.all)
        for disk in MacStudioFixture.all {
            do {
                _ = try await HelperSafety.validatedTarget(
                    targetBSDName: disk.bsdName,
                    imageSizeBytes: imageSizeBytes,
                    sourceBackingBSDName: nil,
                    resolver: resolver
                )
                Issue.record("Expected \(disk.bsdName) to throw but it did not")
            } catch HelperError.targetRejected {
                // Expected path for all Mac Studio disks.
            } catch HelperError.targetNotResolvable {
                Issue.record("\(disk.bsdName) was not resolvable; resolver may be broken")
            } catch {
                Issue.record("Unexpected error for \(disk.bsdName): \(error)")
            }
        }
    }
}

// MARK: - Non-resolvable target

@Suite("HelperSafety: non-resolvable target")
struct HelperSafetyNotResolvableTests {

    @Test("Unknown BSD name throws targetNotResolvable")
    func unknownNameThrows() async {
        let resolver: (String) -> DiskDescriptor? = { _ in nil }
        do {
            _ = try await HelperSafety.validatedTarget(
                targetBSDName: "disk99",
                imageSizeBytes: 1_000_000,
                sourceBackingBSDName: nil,
                resolver: resolver
            )
            Issue.record("Expected targetNotResolvable to be thrown")
        } catch HelperError.targetNotResolvable(let bsdName) {
            #expect(bsdName == "disk99")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

// MARK: - Valid target acceptance

@Suite("HelperSafety: valid external USB disk is accepted")
struct HelperSafetyAcceptanceTests {

    @Test("A 32 GB external USB disk passes the safety re-check")
    func externalUSBAccepted() async throws {
        let validDisk = makeDisk(bsdName: "disk4")
        let resolver = singleDiskResolver(validDisk)
        let result = try await HelperSafety.validatedTarget(
            targetBSDName: "disk4",
            imageSizeBytes: 4_000_000_000,
            sourceBackingBSDName: nil,
            resolver: resolver
        )
        #expect(result.bsdName == "disk4")
    }

    @Test("Returns the resolved descriptor on acceptance")
    func returnsDescriptor() async throws {
        let validDisk = makeDisk(
            bsdName: "disk8",
            sizeBytes: 64_000_000_000
        )
        let resolver = singleDiskResolver(validDisk)
        let returned = try await HelperSafety.validatedTarget(
            targetBSDName: "disk8",
            imageSizeBytes: 1_000_000_000,
            sourceBackingBSDName: nil,
            resolver: resolver
        )
        #expect(returned == validDisk)
    }

    @Test("sourceOverlap fires when the target is the source's backing disk")
    func sourceOverlapRejectsBackingDisk() async {
        // A valid external disk that would otherwise pass, but it is also the
        // disk the image was read from -- the overlap rule must reject it.
        let validDisk = makeDisk(bsdName: "disk4")
        let resolver = singleDiskResolver(validDisk)
        do {
            _ = try await HelperSafety.validatedTarget(
                targetBSDName: "disk4",
                imageSizeBytes: 4_000_000_000,
                sourceBackingBSDName: "disk4",
                resolver: resolver
            )
            Issue.record("Expected sourceOverlap rejection but call succeeded")
        } catch HelperError.targetRejected(let reasons) {
            #expect(reasons.contains(.sourceOverlap))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

// MARK: - Slice name reduction

@Suite("HelperSafety: slice name is reduced to whole-disk parent")
struct HelperSafetySliceReductionTests {

    @Test("disk4s1 is reduced to disk4 before resolution")
    func sliceNameReducedToWholeDisk() async throws {
        let validDisk = makeDisk(bsdName: "disk4")
        // The resolver is keyed on "disk4"; asking for "disk4s1" should reduce first.
        let resolver = singleDiskResolver(validDisk)
        let result = try await HelperSafety.validatedTarget(
            targetBSDName: "disk4s1",
            imageSizeBytes: 4_000_000_000,
            sourceBackingBSDName: nil,
            resolver: resolver
        )
        #expect(result.bsdName == "disk4")
    }

    @Test("disk0s1s1 reduces to disk0 before resolution")
    func deepSliceNameReducedToWholeDisk() async {
        // disk0 is the internal boot drive and must be rejected.
        let resolver = singleDiskResolver(MacStudioFixture.disk0)
        await #expect(throws: (any Error).self) {
            try await HelperSafety.validatedTarget(
                targetBSDName: "disk0s1s1",
                imageSizeBytes: 4_000_000_000,
                sourceBackingBSDName: nil,
                resolver: resolver
            )
        }
    }
}
