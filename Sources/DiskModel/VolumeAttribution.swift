/// VolumeAttribution.swift - pure logic to attribute volume facts to a parent.
///
/// DiskArbitration reports facts per node: a whole disk (`disk4`), a partition
/// slice (`disk4s2`), and any APFS-synthesized volume node. The system and
/// Time Machine roles, and the mount point, live on the volume nodes, but the
/// safety-relevant descriptor describes the WHOLE physical disk. This file
/// folds many per-node facts into one whole-disk roll-up.
///
/// The merge is a pure function of its inputs, so it is unit tested without a
/// live DiskArbitration session.
import Foundation

// MARK: - VolumeFact

/// One fact gathered from a single DiskArbitration node.
///
/// `DiskEnumerator` builds these from the DiskArbitration description
/// dictionary; the merge below never reads DiskArbitration directly.
public struct VolumeFact: Sendable, Equatable {

    /// The BSD name of the node this fact came from (`"disk4"`, `"disk4s2"`).
    public let bsdName: String

    /// Absolute mount point if the node is mounted, otherwise `nil`.
    public let mountPoint: String?

    /// The DiskArbitration volume name (for example `"UNTITLED"`, `"Macintosh HD"`).
    ///
    /// Empty string when the node carries no volume name.
    public let volumeName: String

    /// `true` when this node is (or hosts) a bootable macOS system volume.
    public let isMacOSSystem: Bool

    /// `true` when this node is a Time Machine backup store.
    public let isTimeMachine: Bool

    public init(
        bsdName: String,
        mountPoint: String?,
        volumeName: String = "",
        isMacOSSystem: Bool,
        isTimeMachine: Bool
    ) {
        self.bsdName = bsdName
        self.mountPoint = mountPoint
        self.volumeName = volumeName
        self.isMacOSSystem = isMacOSSystem
        self.isTimeMachine = isTimeMachine
    }
}

// MARK: - Aggregated roll-up

/// The merged result of folding every `VolumeFact` for one whole disk.
public struct AttributedVolumes: Sendable, Equatable {

    /// Sorted, de-duplicated mount points across every node on the disk.
    public let mountPoints: [String]

    /// `true` when any node on the disk carries a macOS system volume.
    public let carriesMacOSSystem: Bool

    /// `true` when any node on the disk carries a Time Machine backup.
    public let carriesTimeMachine: Bool

    /// The first non-empty volume name found across mounted nodes, or empty string.
    ///
    /// Used as the human-readable volume label in the target-row secondary line.
    /// The value is the first non-empty `VolumeFact.volumeName` after sorting by
    /// mount point so the result is deterministic across runs.
    public let volumeLabel: String

    public init(
        mountPoints: [String],
        carriesMacOSSystem: Bool,
        carriesTimeMachine: Bool,
        volumeLabel: String = ""
    ) {
        self.mountPoints = mountPoints
        self.carriesMacOSSystem = carriesMacOSSystem
        self.carriesTimeMachine = carriesTimeMachine
        self.volumeLabel = volumeLabel
    }
}

// MARK: - Attribution

/// Namespace for the pure volume-attribution fold. No instances are created.
public enum VolumeAttribution {

    /// Fold every volume fact belonging to `wholeDiskName` into one roll-up.
    ///
    /// Each fact whose parent whole-disk name equals `wholeDiskName`
    /// contributes its mount point and roles. Facts for other disks are
    /// ignored, so the caller may pass a flat list spanning many disks.
    ///
    /// - Parameters:
    ///   - facts: Per-node facts, possibly spanning multiple physical disks.
    ///   - wholeDiskName: The whole-disk name to attribute facts to
    ///     (for example `"disk4"`).
    /// - Returns: The merged `AttributedVolumes` for that whole disk.
    public static func attribute(
        facts: [VolumeFact],
        toWholeDisk wholeDiskName: String
    ) -> AttributedVolumes {
        var mountSet = Set<String>()
        var carriesSystem = false
        var carriesTimeMachine = false
        // Collect name-bearing facts for a deterministic label pick below.
        var namedFacts: [(mountPoint: String, volumeName: String)] = []
        for fact in facts {
            // Only fold facts whose physical parent is the target whole disk.
            guard DiskIdentity.wholeDiskName(for: fact.bsdName) == wholeDiskName else {
                continue
            }
            if let mount = fact.mountPoint, !mount.isEmpty {
                mountSet.insert(mount)
                // Retain (mount, name) pairs so the label pick is sorted below.
                if !fact.volumeName.isEmpty {
                    namedFacts.append((mountPoint: mount, volumeName: fact.volumeName))
                }
            }
            // OR the roles: a single system or backup volume taints the disk.
            carriesSystem = carriesSystem || fact.isMacOSSystem
            carriesTimeMachine = carriesTimeMachine || fact.isTimeMachine
        }
        // Sort for a stable, deterministic descriptor.
        let mountPoints = mountSet.sorted()
        // Pick the first volume name by sorted mount point so the result is stable.
        let firstNamed = namedFacts.sorted { $0.mountPoint < $1.mountPoint }.first
        let volumeLabel = firstNamed?.volumeName ?? ""
        let result = AttributedVolumes(
            mountPoints: mountPoints,
            carriesMacOSSystem: carriesSystem,
            carriesTimeMachine: carriesTimeMachine,
            volumeLabel: volumeLabel
        )
        return result
    }
}
