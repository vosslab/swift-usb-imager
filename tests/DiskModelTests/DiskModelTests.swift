/// DiskModelTests - deterministic unit tests for the pure DiskModel logic.
///
/// These tests exercise only the side-effect-free helpers and the value-type
/// contract. They never touch a live DiskArbitration session or real hardware,
/// so they are fast and reproducible. The live `DiskEnumerator` paths are
/// covered separately by manual / integration testing on real machines.
import Foundation
import Testing
@testable import DiskModel

// MARK: - Raw-path derivation

@Suite("DiskIdentity path derivation")
struct DiskIdentityPathTests {

    @Test("Buffered device path prepends /dev/")
    func devicePath() {
        #expect(DiskIdentity.devicePath(for: "disk4") == "/dev/disk4")
        #expect(DiskIdentity.devicePath(for: "disk0") == "/dev/disk0")
    }

    @Test("Raw device path inserts the r prefix on the node name")
    func rawDevicePath() {
        #expect(DiskIdentity.rawDevicePath(for: "disk4") == "/dev/rdisk4")
        #expect(DiskIdentity.rawDevicePath(for: "disk10") == "/dev/rdisk10")
    }
}

// MARK: - Whole-disk vs partition filter

@Suite("DiskIdentity whole-disk filter")
struct WholeDiskFilterTests {

    @Test("Plain diskN names are whole disks")
    func wholeDisksAccepted() {
        #expect(DiskIdentity.isWholeDisk("disk0"))
        #expect(DiskIdentity.isWholeDisk("disk4"))
        #expect(DiskIdentity.isWholeDisk("disk12"))
    }

    @Test("Partition and APFS slice names are rejected")
    func slicesRejected() {
        #expect(!DiskIdentity.isWholeDisk("disk4s1"))
        #expect(!DiskIdentity.isWholeDisk("disk4s1s2"))
        #expect(!DiskIdentity.isWholeDisk("disk0s2"))
    }

    @Test("Malformed names are rejected")
    func junkRejected() {
        #expect(!DiskIdentity.isWholeDisk("disk"))
        #expect(!DiskIdentity.isWholeDisk("rdisk4"))
        #expect(!DiskIdentity.isWholeDisk("sda"))
        #expect(!DiskIdentity.isWholeDisk(""))
        #expect(!DiskIdentity.isWholeDisk("disk4x"))
    }
}

// MARK: - Parent attribution (name reduction)

@Suite("DiskIdentity parent reduction")
struct WholeDiskNameTests {

    @Test("Slices reduce to their physical parent")
    func slicesReduce() {
        #expect(DiskIdentity.wholeDiskName(for: "disk4s1") == "disk4")
        #expect(DiskIdentity.wholeDiskName(for: "disk4s1s2") == "disk4")
        #expect(DiskIdentity.wholeDiskName(for: "disk12s3") == "disk12")
    }

    @Test("A whole disk reduces to itself")
    func wholeReducesToSelf() {
        #expect(DiskIdentity.wholeDiskName(for: "disk4") == "disk4")
        #expect(DiskIdentity.wholeDiskName(for: "disk0") == "disk0")
    }

    @Test("Junk input yields nil rather than a fabricated parent")
    func junkYieldsNil() {
        #expect(DiskIdentity.wholeDiskName(for: "disk") == nil)
        #expect(DiskIdentity.wholeDiskName(for: "rdisk4") == nil)
        #expect(DiskIdentity.wholeDiskName(for: "sda1") == nil)
        #expect(DiskIdentity.wholeDiskName(for: "") == nil)
    }
}

// MARK: - Volume attribution fold

@Suite("VolumeAttribution fold")
struct VolumeAttributionTests {

    @Test("Mount points from many slices fold onto one parent, sorted + unique")
    func mountPointsFold() {
        let facts = [
            VolumeFact(bsdName: "disk4s2", mountPoint: "/Volumes/Data", isMacOSSystem: false, isTimeMachine: false),
            VolumeFact(bsdName: "disk4s1", mountPoint: "/", isMacOSSystem: true, isTimeMachine: false),
            VolumeFact(bsdName: "disk4s3", mountPoint: "/Volumes/Data", isMacOSSystem: false, isTimeMachine: false),
        ]
        let result = VolumeAttribution.attribute(facts: facts, toWholeDisk: "disk4")
        #expect(result.mountPoints == ["/", "/Volumes/Data"])
    }

    @Test("A single system volume taints the whole physical disk")
    func systemRoleAttributed() {
        let facts = [
            VolumeFact(bsdName: "disk4s1", mountPoint: "/", isMacOSSystem: true, isTimeMachine: false),
            VolumeFact(bsdName: "disk4s2", mountPoint: nil, isMacOSSystem: false, isTimeMachine: false),
        ]
        let result = VolumeAttribution.attribute(facts: facts, toWholeDisk: "disk4")
        #expect(result.carriesMacOSSystem)
        #expect(!result.carriesTimeMachine)
    }

    @Test("A Time Machine volume taints the whole physical disk")
    func timeMachineRoleAttributed() {
        let facts = [
            VolumeFact(bsdName: "disk6s1", mountPoint: "/Volumes/Backup", isMacOSSystem: false, isTimeMachine: true),
        ]
        let result = VolumeAttribution.attribute(facts: facts, toWholeDisk: "disk6")
        #expect(result.carriesTimeMachine)
        #expect(!result.carriesMacOSSystem)
    }

    @Test("Facts for other disks are ignored")
    func otherDisksIgnored() {
        let facts = [
            VolumeFact(bsdName: "disk4s1", mountPoint: "/", isMacOSSystem: true, isTimeMachine: false),
            VolumeFact(bsdName: "disk9s1", mountPoint: "/Volumes/USB", isMacOSSystem: false, isTimeMachine: false),
        ]
        let result = VolumeAttribution.attribute(facts: facts, toWholeDisk: "disk9")
        #expect(result.mountPoints == ["/Volumes/USB"])
        #expect(!result.carriesMacOSSystem)
        #expect(!result.carriesTimeMachine)
    }

    @Test("Empty / unmounted facts produce an empty roll-up")
    func emptyFold() {
        let facts = [
            VolumeFact(bsdName: "disk4s1", mountPoint: nil, isMacOSSystem: false, isTimeMachine: false),
            VolumeFact(bsdName: "disk4s2", mountPoint: "", isMacOSSystem: false, isTimeMachine: false),
        ]
        let result = VolumeAttribution.attribute(facts: facts, toWholeDisk: "disk4")
        #expect(result.mountPoints.isEmpty)
        #expect(!result.carriesMacOSSystem)
        #expect(!result.carriesTimeMachine)
    }
}

// MARK: - BusProtocol mapping

@Suite("BusProtocol mapping")
struct BusProtocolTests {

    @Test("Known transports map to their case")
    func knownTransports() {
        #expect(BusProtocol.fromDeviceProtocol("USB") == .usb)
        #expect(BusProtocol.fromDeviceProtocol("USB 3.1") == .usb)
        #expect(BusProtocol.fromDeviceProtocol("Secure Digital") == .sd)
        #expect(BusProtocol.fromDeviceProtocol("SATA") == .sata)
        #expect(BusProtocol.fromDeviceProtocol("Serial ATA") == .sata)
        #expect(BusProtocol.fromDeviceProtocol("NVMe") == .nvme)
        #expect(BusProtocol.fromDeviceProtocol("Virtual Interface") == .virtual)
    }

    @Test("Unknown transports map to other, never a safe-looking case")
    func unknownTransports() {
        #expect(BusProtocol.fromDeviceProtocol("FireWire") == .other)
        #expect(BusProtocol.fromDeviceProtocol("") == .other)
        #expect(BusProtocol.fromDeviceProtocol("Fibre Channel") == .other)
    }
}

// MARK: - DiskDescriptor construction + Codable contract

@Suite("DiskDescriptor construction and Codable")
struct DiskDescriptorTests {

    /// A representative whole-disk descriptor used across the tests below.
    private func sampleDescriptor() -> DiskDescriptor {
        let descriptor = DiskDescriptor(
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
            mountPoints: ["/Volumes/UNTITLED"]
        )
        return descriptor
    }

    @Test("All fields are stored verbatim by the initializer")
    func fieldsStored() {
        let descriptor = sampleDescriptor()
        #expect(descriptor.bsdName == "disk4")
        #expect(descriptor.devicePath == "/dev/disk4")
        #expect(descriptor.rawDevicePath == "/dev/rdisk4")
        #expect(descriptor.sizeBytes == 32_000_000_000)
        #expect(descriptor.isRemovable)
        #expect(descriptor.isEjectable)
        #expect(!descriptor.isInternal)
        #expect(descriptor.busProtocol == .usb)
        #expect(descriptor.isWritable)
        #expect(!descriptor.isSynthesized)
        #expect(!descriptor.carriesMacOSSystem)
        #expect(!descriptor.carriesTimeMachine)
        #expect(descriptor.mountPoints == ["/Volumes/UNTITLED"])
    }

    @Test("Identifiable id is the BSD name")
    func identityIsBsdName() {
        let descriptor = sampleDescriptor()
        #expect(descriptor.id == "disk4")
    }

    @Test("Descriptor round-trips through Codable unchanged")
    func codableRoundTrip() throws {
        let descriptor = sampleDescriptor()
        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(DiskDescriptor.self, from: data)
        #expect(decoded == descriptor)
    }
}
