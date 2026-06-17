/// DiskSafetyTests.swift - deterministic unit tests for DiskSafety predicates.
///
/// Tests cover:
///   - One fixture per RejectionReason, asserting the specific reason is present.
///   - Allowed-device fixtures (external, removable, writable, non-internal,
///     non-synthesized, no macOS system, no TM, sizes 16/32/64/128/256 GB decimal).
///   - A ground-truth fixture modelling the user's Mac Studio `diskutil list`
///     output; all disks must be rejected so validTargets returns an empty list.
import Foundation
import Testing
@testable import DiskModel

// MARK: - Fixture helpers

/// Build a minimal safe-by-default external USB descriptor, then override
/// specific fields with the provided closure to exercise one failure mode.
///
/// Using a valid baseline means every test only changes the property under test
/// and cannot accidentally trigger a second rejection reason.
private func makeDescriptor(
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
    let descriptor = DiskDescriptor(
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
    return descriptor
}

// MARK: - One fixture per RejectionReason

@Suite("RejectionReason - one fixture per case")
struct RejectionReasonFixtureTests {

    @Test("synthesizedContainer is reported for an APFS-synthesized disk")
    func synthesizedContainer() {
        let disk = makeDescriptor(isSynthesized: true)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 1_000_000, sourceBackingBSDName: nil)
        #expect(reasons.contains(.synthesizedContainer))
    }

    @Test("internalDisk is reported for an internal drive")
    func internalDisk() {
        let disk = makeDescriptor(isInternal: true)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 1_000_000, sourceBackingBSDName: nil)
        #expect(reasons.contains(.internalDisk))
    }

    @Test("carriesMacOSSystem is reported when a macOS system volume is present")
    func carriesMacOSSystem() {
        let disk = makeDescriptor(carriesMacOSSystem: true)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 1_000_000, sourceBackingBSDName: nil)
        #expect(reasons.contains(.carriesMacOSSystem))
    }

    @Test("timeMachineBackup is reported when a Time Machine volume is present")
    func timeMachineBackup() {
        let disk = makeDescriptor(carriesTimeMachine: true)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 1_000_000, sourceBackingBSDName: nil)
        #expect(reasons.contains(.timeMachineBackup))
    }

    @Test("notWritable is reported for a write-protected disk")
    func notWritable() {
        let disk = makeDescriptor(isWritable: false)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 1_000_000, sourceBackingBSDName: nil)
        #expect(reasons.contains(.notWritable))
    }

    @Test("tooSmall is reported when the image exceeds the disk capacity")
    func tooSmall() {
        // Disk is 1 GB, image is 2 GB.
        let disk = makeDescriptor(sizeBytes: 1_000_000_000)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 2_000_000_000, sourceBackingBSDName: nil)
        #expect(reasons.contains(.tooSmall))
    }

    @Test("tooLarge is reported at exactly the 450 GB threshold")
    func tooLargeAtThreshold() {
        // diskSafetyMaxSizeBytes is the first rejected value (inclusive).
        let disk = makeDescriptor(sizeBytes: diskSafetyMaxSizeBytes)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 1_000_000, sourceBackingBSDName: nil)
        #expect(reasons.contains(.tooLarge))
    }

    @Test("tooLarge is reported for a 2 TB drive")
    func tooLargeFor2TB() {
        let disk = makeDescriptor(sizeBytes: 2_000_000_000_000)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 1_000_000, sourceBackingBSDName: nil)
        #expect(reasons.contains(.tooLarge))
    }

    @Test("sourceOverlap is reported when bsdName matches the source disk")
    func sourceOverlap() {
        let disk = makeDescriptor(bsdName: "disk4")
        let reasons = rejectionReasons(
            for: disk,
            imageSizeBytes: 1_000_000,
            sourceBackingBSDName: "disk4"
        )
        #expect(reasons.contains(.sourceOverlap))
    }

    @Test("sourceOverlap is not reported when source is a different disk")
    func sourceOverlapDifferentDisk() {
        let disk = makeDescriptor(bsdName: "disk4")
        let reasons = rejectionReasons(
            for: disk,
            imageSizeBytes: 1_000_000,
            sourceBackingBSDName: "disk2"
        )
        #expect(!reasons.contains(.sourceOverlap))
    }

    @Test("sourceOverlap is not reported when sourceBackingBSDName is nil")
    func sourceOverlapNilSource() {
        let disk = makeDescriptor(bsdName: "disk4")
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 1_000_000, sourceBackingBSDName: nil)
        #expect(!reasons.contains(.sourceOverlap))
    }
}

// MARK: - Allowed device fixtures

@Suite("Allowed device fixtures - isValidTarget returns true")
struct AllowedDeviceTests {

    // A small image size used across all valid-target tests.
    private let smallImage = 4_000_000_000  // 4 GB

    private func externalUSBDisk(bsdName: String, sizeBytes: Int) -> DiskDescriptor {
        let disk = makeDescriptor(
            bsdName: bsdName,
            sizeBytes: sizeBytes,
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
        return disk
    }

    @Test("16 GB external USB flash drive is a valid target")
    func allowed16GB() {
        let disk = externalUSBDisk(bsdName: "disk4", sizeBytes: 16_000_000_000)
        #expect(isValidTarget(disk, imageSizeBytes: smallImage, sourceBackingBSDName: nil))
    }

    @Test("32 GB external USB flash drive is a valid target")
    func allowed32GB() {
        let disk = externalUSBDisk(bsdName: "disk4", sizeBytes: 32_000_000_000)
        #expect(isValidTarget(disk, imageSizeBytes: smallImage, sourceBackingBSDName: nil))
    }

    @Test("64 GB external USB flash drive is a valid target")
    func allowed64GB() {
        let disk = externalUSBDisk(bsdName: "disk4", sizeBytes: 64_000_000_000)
        #expect(isValidTarget(disk, imageSizeBytes: smallImage, sourceBackingBSDName: nil))
    }

    @Test("128 GB external USB flash drive is a valid target")
    func allowed128GB() {
        let disk = externalUSBDisk(bsdName: "disk4", sizeBytes: 128_000_000_000)
        #expect(isValidTarget(disk, imageSizeBytes: smallImage, sourceBackingBSDName: nil))
    }

    @Test("256 GB external USB flash drive is a valid target")
    func allowed256GB() {
        let disk = externalUSBDisk(bsdName: "disk4", sizeBytes: 256_000_000_000)
        #expect(isValidTarget(disk, imageSizeBytes: smallImage, sourceBackingBSDName: nil))
    }

    @Test("449 GB disk is just below the tooLarge threshold and is valid")
    func allowed449GB() {
        // 449_999_999_999 is one byte below diskSafetyMaxSizeBytes (450 GB).
        let disk = externalUSBDisk(bsdName: "disk4", sizeBytes: diskSafetyMaxSizeBytes - 1)
        #expect(isValidTarget(disk, imageSizeBytes: smallImage, sourceBackingBSDName: nil))
    }

    @Test("External SD-card disk is a valid target")
    func allowedSDCard() {
        let disk = makeDescriptor(
            bsdName: "disk5",
            sizeBytes: 64_000_000_000,
            busProtocol: .sd
        )
        #expect(isValidTarget(disk, imageSizeBytes: smallImage, sourceBackingBSDName: nil))
    }

    @Test("Valid target disk has no rejection reasons")
    func noRejectionReasons() {
        let disk = externalUSBDisk(bsdName: "disk4", sizeBytes: 32_000_000_000)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: smallImage, sourceBackingBSDName: nil)
        #expect(reasons.isEmpty)
    }

    @Test("validTargets returns only the valid disks from a mixed list")
    func mixedListFiltered() {
        let good = externalUSBDisk(bsdName: "disk4", sizeBytes: 32_000_000_000)
        let bad = makeDescriptor(bsdName: "disk0", isInternal: true, carriesMacOSSystem: true)
        let result = validTargets(from: [good, bad], imageSizeBytes: smallImage, sourceBackingBSDName: nil)
        #expect(result.count == 1)
        #expect(result[0].bsdName == "disk4")
    }
}

// MARK: - tooLarge boundary checks

@Suite("tooLarge boundary")
struct TooLargeBoundaryTests {

    @Test("One byte below 450 GB is NOT tooLarge")
    func justBelowThreshold() {
        let disk = makeDescriptor(sizeBytes: diskSafetyMaxSizeBytes - 1)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 1_000_000, sourceBackingBSDName: nil)
        #expect(!reasons.contains(.tooLarge))
    }

    @Test("Exactly 450 GB IS tooLarge (inclusive threshold)")
    func exactlyAtThreshold() {
        let disk = makeDescriptor(sizeBytes: diskSafetyMaxSizeBytes)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 1_000_000, sourceBackingBSDName: nil)
        #expect(reasons.contains(.tooLarge))
    }

    @Test("One byte above 450 GB IS tooLarge")
    func justAboveThreshold() {
        let disk = makeDescriptor(sizeBytes: diskSafetyMaxSizeBytes + 1)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 1_000_000, sourceBackingBSDName: nil)
        #expect(reasons.contains(.tooLarge))
    }
}

// MARK: - tooSmall boundary checks

@Suite("tooSmall boundary")
struct TooSmallBoundaryTests {

    @Test("Disk equal to image size is NOT tooSmall")
    func exactFit() {
        let disk = makeDescriptor(sizeBytes: 8_000_000_000)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 8_000_000_000, sourceBackingBSDName: nil)
        #expect(!reasons.contains(.tooSmall))
    }

    @Test("Disk one byte smaller than the image IS tooSmall")
    func oneByteUnder() {
        let disk = makeDescriptor(sizeBytes: 7_999_999_999)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 8_000_000_000, sourceBackingBSDName: nil)
        #expect(reasons.contains(.tooSmall))
    }
}

// MARK: - Multiple reasons accumulate

@Suite("Multiple rejection reasons accumulate independently")
struct MultipleReasonsTests {

    @Test("A synthesized internal disk accumulates both reasons")
    func synthesizedAndInternal() {
        let disk = makeDescriptor(isInternal: true, isSynthesized: true)
        let reasons = rejectionReasons(for: disk, imageSizeBytes: 1_000_000, sourceBackingBSDName: nil)
        #expect(reasons.contains(.synthesizedContainer))
        #expect(reasons.contains(.internalDisk))
    }

    @Test("A disk with all bad flags accumulates all reasons")
    func allReasonsPresent() {
        let disk = makeDescriptor(
            sizeBytes: 1_000_000,
            isInternal: true,
            isWritable: false,
            isSynthesized: true,
            carriesMacOSSystem: true,
            carriesTimeMachine: true
        )
        // imageSizeBytes > disk.sizeBytes to trigger tooSmall.
        let reasons = rejectionReasons(
            for: disk,
            imageSizeBytes: 2_000_000,
            sourceBackingBSDName: disk.bsdName
        )
        #expect(reasons.contains(.synthesizedContainer))
        #expect(reasons.contains(.internalDisk))
        #expect(reasons.contains(.carriesMacOSSystem))
        #expect(reasons.contains(.timeMachineBackup))
        #expect(reasons.contains(.notWritable))
        #expect(reasons.contains(.tooSmall))
        #expect(reasons.contains(.sourceOverlap))
        // Note: sizeBytes (1 MB) < diskSafetyMaxSizeBytes, so .tooLarge is absent.
        #expect(!reasons.contains(.tooLarge))
    }
}

// MARK: - Ground-truth fixture: Mac Studio diskutil list

/// This suite models the exact disk layout reported by `diskutil list` on the
/// user's Mac Studio.  `validTargets` must return an empty list because no disk
/// in this set is a safe write target.
///
/// Disk layout:
///   disk0  - internal boot drive, carries macOS, 500.3 GB
///   disk3  - APFS synthesized container (boot pool)
///   disk4  - external USB/Thunderbolt, 2 TB (too large)
///   disk5  - APFS synthesized container
///   disk6  - external Time Machine backup, 1 TB
///   disk7  - APFS synthesized container
@Suite("Ground-truth fixture: Mac Studio diskutil list")
struct MacStudioGroundTruthTests {

    // The image size used across all ground-truth assertions.
    private let imageSizeBytes = 4_000_000_000  // 4 GB

    // MARK: Individual disk descriptors

    private var disk0: DiskDescriptor {
        // Internal boot NVMe SSD; carries the macOS system volume.
        let disk = DiskDescriptor(
            bsdName: "disk0",
            devicePath: "/dev/disk0",
            rawDevicePath: "/dev/rdisk0",
            sizeBytes: 500_300_000_000,
            isRemovable: false,
            isEjectable: false,
            isInternal: true,
            busProtocol: .nvme,
            isWritable: true,
            isSynthesized: false,
            carriesMacOSSystem: true,
            carriesTimeMachine: false,
            mountPoints: ["/"]
        )
        return disk
    }

    private var disk3: DiskDescriptor {
        // APFS synthesized container layered over disk0.
        let disk = DiskDescriptor(
            bsdName: "disk3",
            devicePath: "/dev/disk3",
            rawDevicePath: "/dev/rdisk3",
            sizeBytes: 500_300_000_000,
            isRemovable: false,
            isEjectable: false,
            isInternal: true,
            busProtocol: .virtual,
            isWritable: true,
            isSynthesized: true,
            carriesMacOSSystem: false,
            carriesTimeMachine: false,
            mountPoints: []
        )
        return disk
    }

    private var disk4: DiskDescriptor {
        // External 2 TB drive - too large to be plausible flash media.
        let disk = DiskDescriptor(
            bsdName: "disk4",
            devicePath: "/dev/disk4",
            rawDevicePath: "/dev/rdisk4",
            sizeBytes: 2_000_000_000_000,
            isRemovable: true,
            isEjectable: true,
            isInternal: false,
            busProtocol: .usb,
            isWritable: true,
            isSynthesized: false,
            carriesMacOSSystem: false,
            carriesTimeMachine: false,
            mountPoints: ["/Volumes/External"]
        )
        return disk
    }

    private var disk5: DiskDescriptor {
        // APFS synthesized container layered over disk4.
        let disk = DiskDescriptor(
            bsdName: "disk5",
            devicePath: "/dev/disk5",
            rawDevicePath: "/dev/rdisk5",
            sizeBytes: 2_000_000_000_000,
            isRemovable: true,
            isEjectable: true,
            isInternal: false,
            busProtocol: .virtual,
            isWritable: true,
            isSynthesized: true,
            carriesMacOSSystem: false,
            carriesTimeMachine: false,
            mountPoints: []
        )
        return disk
    }

    private var disk6: DiskDescriptor {
        // External 1 TB Time Machine backup drive.
        let disk = DiskDescriptor(
            bsdName: "disk6",
            devicePath: "/dev/disk6",
            rawDevicePath: "/dev/rdisk6",
            sizeBytes: 1_000_000_000_000,
            isRemovable: true,
            isEjectable: true,
            isInternal: false,
            busProtocol: .usb,
            isWritable: true,
            isSynthesized: false,
            carriesMacOSSystem: false,
            carriesTimeMachine: true,
            mountPoints: ["/Volumes/Backups"]
        )
        return disk
    }

    private var disk7: DiskDescriptor {
        // APFS synthesized container layered over disk6.
        let disk = DiskDescriptor(
            bsdName: "disk7",
            devicePath: "/dev/disk7",
            rawDevicePath: "/dev/rdisk7",
            sizeBytes: 1_000_000_000_000,
            isRemovable: true,
            isEjectable: true,
            isInternal: false,
            busProtocol: .virtual,
            isWritable: true,
            isSynthesized: true,
            carriesMacOSSystem: false,
            carriesTimeMachine: false,
            mountPoints: []
        )
        return disk
    }

    private var allMacStudioDisks: [DiskDescriptor] {
        let disks = [disk0, disk3, disk4, disk5, disk6, disk7]
        return disks
    }

    // MARK: Per-disk rejection assertions

    @Test("disk0 is rejected: internalDisk + carriesMacOSSystem")
    func disk0Rejected() {
        let reasons = rejectionReasons(
            for: disk0,
            imageSizeBytes: imageSizeBytes,
            sourceBackingBSDName: nil
        )
        #expect(reasons.contains(.internalDisk))
        #expect(reasons.contains(.carriesMacOSSystem))
    }

    @Test("disk3 is rejected: synthesizedContainer")
    func disk3Rejected() {
        let reasons = rejectionReasons(
            for: disk3,
            imageSizeBytes: imageSizeBytes,
            sourceBackingBSDName: nil
        )
        #expect(reasons.contains(.synthesizedContainer))
    }

    @Test("disk4 is rejected: tooLarge (2 TB)")
    func disk4Rejected() {
        let reasons = rejectionReasons(
            for: disk4,
            imageSizeBytes: imageSizeBytes,
            sourceBackingBSDName: nil
        )
        #expect(reasons.contains(.tooLarge))
    }

    @Test("disk5 is rejected: synthesizedContainer")
    func disk5Rejected() {
        let reasons = rejectionReasons(
            for: disk5,
            imageSizeBytes: imageSizeBytes,
            sourceBackingBSDName: nil
        )
        #expect(reasons.contains(.synthesizedContainer))
    }

    @Test("disk6 is rejected: timeMachineBackup + tooLarge (1 TB)")
    func disk6Rejected() {
        let reasons = rejectionReasons(
            for: disk6,
            imageSizeBytes: imageSizeBytes,
            sourceBackingBSDName: nil
        )
        #expect(reasons.contains(.timeMachineBackup))
        #expect(reasons.contains(.tooLarge))
    }

    @Test("disk7 is rejected: synthesizedContainer")
    func disk7Rejected() {
        let reasons = rejectionReasons(
            for: disk7,
            imageSizeBytes: imageSizeBytes,
            sourceBackingBSDName: nil
        )
        #expect(reasons.contains(.synthesizedContainer))
    }

    // MARK: validTargets ground-truth assertion

    @Test("validTargets returns an empty list for the full Mac Studio disk set")
    func validTargetsIsEmpty() {
        let result = validTargets(
            from: allMacStudioDisks,
            imageSizeBytes: imageSizeBytes,
            sourceBackingBSDName: nil
        )
        #expect(result.isEmpty)
    }

    @Test("Every disk in the Mac Studio set has at least one rejection reason")
    func everyDiskHasAReason() {
        for disk in allMacStudioDisks {
            let reasons = rejectionReasons(
                for: disk,
                imageSizeBytes: imageSizeBytes,
                sourceBackingBSDName: nil
            )
            #expect(!reasons.isEmpty, "Expected \(disk.bsdName) to have at least one rejection reason")
        }
    }
}
