/// DiskDescriptor.swift - value type describing one WHOLE physical disk.
///
/// A `DiskDescriptor` models a top-level BSD disk node (for example `disk4`),
/// never an individual partition slice (`disk4s1`) or an APFS-synthesized
/// volume node. APFS-synthesized volumes are attributed back to their physical
/// parent disk; see `DiskEnumerator` for the attribution logic.
///
/// The field set below is a CONTRACT consumed by the later `DiskSafety`
/// module. `DiskSafety` reads these fields to decide whether a disk is a safe
/// write target. Do not remove or repurpose a field without updating the
/// safety module; add new fields rather than overloading existing ones.
import Foundation

// MARK: - Bus protocol

/// The physical transport a disk is attached through.
///
/// Derived from the DiskArbitration / IOKit device-protocol string. Used by the
/// safety module to favor external removable media (`usb`, `sd`) over fixed
/// internal storage (`sata`, `nvme`).
public enum BusProtocol: String, Sendable, Codable, CaseIterable {
    /// USB mass-storage transport (the common case for flash drives).
    case usb
    /// Secure Digital / built-in card reader transport.
    case sd
    /// Serial ATA, typical of internal spinning or SSD drives.
    case sata
    /// NVM Express, typical of internal PCIe SSDs (including the boot drive).
    case nvme
    /// A synthesized or virtual device with no real physical transport
    /// (for example an APFS synthesized container or a disk image).
    case virtual
    /// Any transport that does not map to a known case above
    /// (Thunderbolt-only, FireWire, SCSI, fibre channel, unknown strings).
    case other

    /// Map a raw DiskArbitration / IOKit protocol string to a `BusProtocol`.
    ///
    /// The comparison is case-insensitive. Unrecognized strings map to
    /// `.other` so an unknown bus never silently looks like a safe target.
    ///
    /// - Parameter raw: The protocol string (for example `"USB"`, `"PCI-Express"`).
    /// - Returns: The matching `BusProtocol` case, or `.other` when unknown.
    public static func fromDeviceProtocol(_ raw: String) -> BusProtocol {
        let value = raw.lowercased()
        // Substring matches keep us robust to vendor decoration like
        // "USB 3.1" or "Apple Fabric / NVMe".
        if value.contains("usb") {
            return .usb
        }
        if value.contains("secure digital") || value == "sd" || value.contains("sdxc") {
            return .sd
        }
        if value.contains("nvme") || value.contains("nvm express") {
            return .nvme
        }
        if value.contains("sata") || value.contains("serial ata") || value.contains("ata") {
            return .sata
        }
        if value.contains("virtual") || value.contains("disk image") {
            return .virtual
        }
        return .other
    }
}

// MARK: - DiskDescriptor

/// Immutable description of one whole physical disk.
///
/// All fields are populated by `DiskEnumerator`; the type itself carries no
/// behavior beyond construction so it stays trivially `Sendable` and `Codable`
/// for transport across actor and XPC boundaries.
public struct DiskDescriptor: Sendable, Codable, Equatable, Hashable, Identifiable {

    /// The BSD device name with no path prefix, for example `"disk4"`.
    ///
    /// Always a whole-disk node; never a partition slice such as `"disk4s1"`.
    public let bsdName: String

    /// The buffered block-device path, for example `"/dev/disk4"`.
    public let devicePath: String

    /// The raw (unbuffered) character-device path, for example `"/dev/rdisk4"`.
    ///
    /// Imaging tools write through the raw node for speed; the safety module
    /// and writer use this path rather than reconstructing it.
    public let rawDevicePath: String

    /// Total media size in bytes as reported by the device.
    ///
    /// `Int` is used (not `UInt64`) to match the rest of the contract and to
    /// stay friendly to Swift integer APIs; macOS media sizes fit comfortably
    /// in a signed 64-bit value.
    public let sizeBytes: Int

    /// `true` when the media can be physically removed (flash drive, SD card).
    public let isRemovable: Bool

    /// `true` when the OS reports the device as ejectable.
    ///
    /// Ejectable and removable usually agree but can differ; both are exposed
    /// so the safety module can require either signal.
    public let isEjectable: Bool

    /// `true` when the device is internal to the machine (built-in storage).
    ///
    /// The internal boot drive reports `true`; external USB media reports
    /// `false`. The safety module treats internal disks as unsafe targets.
    public let isInternal: Bool

    /// The physical transport the disk is attached through.
    public let busProtocol: BusProtocol

    /// `true` when the device is writable (not hardware write-protected and
    /// not a read-only synthesized node).
    public let isWritable: Bool

    /// `true` when the node is an APFS-synthesized container rather than a real
    /// physical disk.
    ///
    /// Synthesized containers (the `diskN` that APFS creates on top of a
    /// physical store) are never write targets; they are surfaced so the
    /// enumerator can attribute their volumes to the physical parent.
    public let isSynthesized: Bool

    /// `true` when any volume on this disk carries a bootable macOS system.
    ///
    /// Set when an APFS volume with role "System" (or a recognized macOS
    /// system volume) lives on this physical disk. The safety module refuses
    /// to write to any disk where this is `true`.
    public let carriesMacOSSystem: Bool

    /// `true` when any volume on this disk is a Time Machine backup store.
    ///
    /// Set when an APFS volume with the Time Machine / Backup role, or a
    /// "Backups of <host>" volume, lives on this physical disk.
    public let carriesTimeMachine: Bool

    /// Filesystem mount points for every mounted volume on this disk.
    ///
    /// Each entry is an absolute path such as `"/"` or
    /// `"/Volumes/Untitled"`. Empty when nothing on the disk is mounted.
    public let mountPoints: [String]

    /// The device vendor string as reported by DiskArbitration
    /// (`kDADiskDescriptionDeviceVendorKey`), for example `"SanDisk"`.
    ///
    /// Empty string when the field is absent (virtual disks, some SD readers).
    public let vendor: String

    /// The device model string as reported by DiskArbitration
    /// (`kDADiskDescriptionDeviceModelKey`), for example `"Ultra"`.
    ///
    /// Empty string when the field is absent.
    public let model: String

    /// The name of the first mounted volume on this disk, if any.
    ///
    /// Folded from the per-node `VolumeFact.volumeName` values by
    /// `VolumeAttribution.attribute(facts:toWholeDisk:)`. Empty string when no
    /// mounted volume on this disk carries a name.
    public let volumeLabel: String

    /// Stable identity for SwiftUI / `Identifiable`; the BSD name is unique
    /// per whole disk for the lifetime of that device's attachment.
    public var id: String { bsdName }

    /// Designated initializer.
    ///
    /// Safety-relevant fields (`carriesMacOSSystem`, `carriesTimeMachine`, etc.)
    /// have no default values so they can never be accidentally omitted.
    /// Identity fields (`vendor`, `model`, `volumeLabel`) default to empty
    /// string so existing call sites outside the enumerator compile unchanged.
    public init(
        bsdName: String,
        devicePath: String,
        rawDevicePath: String,
        sizeBytes: Int,
        isRemovable: Bool,
        isEjectable: Bool,
        isInternal: Bool,
        busProtocol: BusProtocol,
        isWritable: Bool,
        isSynthesized: Bool,
        carriesMacOSSystem: Bool,
        carriesTimeMachine: Bool,
        mountPoints: [String],
        vendor: String = "",
        model: String = "",
        volumeLabel: String = ""
    ) {
        self.bsdName = bsdName
        self.devicePath = devicePath
        self.rawDevicePath = rawDevicePath
        self.sizeBytes = sizeBytes
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.busProtocol = busProtocol
        self.isWritable = isWritable
        self.isSynthesized = isSynthesized
        self.carriesMacOSSystem = carriesMacOSSystem
        self.carriesTimeMachine = carriesTimeMachine
        self.mountPoints = mountPoints
        self.vendor = vendor
        self.model = model
        self.volumeLabel = volumeLabel
    }
}
