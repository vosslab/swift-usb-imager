/// DiskSafety.swift - pure predicate functions over `DiskDescriptor`.
///
/// These functions decide whether a disk may be used as a write target for
/// a disk-image flash operation.  They are intentionally side-effect-free so
/// both the UI picker and the privileged helper can call them without sharing
/// state or worrying about concurrency.
///
/// All rules are independent: a disk that violates three rules will have all
/// three `RejectionReason` values in the returned array, and every reason is
/// displayed to the user.

// MARK: - Size constants

/// The upper bound (exclusive) for a valid flash target, in decimal bytes.
///
/// Any disk reporting a capacity at or above this value is rejected with
/// `.tooLarge`.  450 GB (decimal, 450 * 10^9) is chosen to catch terabyte
/// and multi-terabyte fixed drives while allowing the largest common
/// consumer flash media (256 GB and 400 GB cards / drives).
public let diskSafetyMaxSizeBytes: Int = 450_000_000_000

// MARK: - RejectionReason

/// Each case represents a single, independently evaluated reason that a disk
/// is not a safe write target.
///
/// The UI displays every case that is present so the user understands exactly
/// why a disk is excluded.
public enum RejectionReason: String, Sendable, Codable, CaseIterable, Equatable {

    /// The disk is an APFS-synthesized container, not a real physical device.
    case synthesizedContainer

    /// The disk is reported as internal to the machine (built-in storage).
    case internalDisk

    /// At least one volume on the disk carries a bootable macOS system.
    case carriesMacOSSystem

    /// At least one volume on the disk is a Time Machine backup store.
    case timeMachineBackup

    /// The device is not writable (hardware write-protect or read-only node).
    case notWritable

    /// The disk is smaller than the image that would be written to it.
    case tooSmall

    /// The disk is too large to be plausible flash media (>= 450 GB).
    case tooLarge

    /// The disk is the source backing store for the image being flashed.
    ///
    /// Writing an image derived from a disk back onto that same disk would
    /// destroy the data it was read from.
    case sourceOverlap
}

// MARK: - Safety predicates

/// Returns every reason `disk` is not a safe write target, or an empty array
/// when the disk is safe to flash.
///
/// Each rule is evaluated independently; multiple reasons may be returned for
/// a single disk.
///
/// - Parameters:
///   - disk: The candidate write target.
///   - imageSizeBytes: The byte length of the image that will be written.
///   - sourceBackingBSDName: The BSD name of the disk the image was read from,
///     or `nil` when the source is not a disk (for example a file).
/// - Returns: An array of `RejectionReason` values; empty means "safe to use".
public func rejectionReasons(
    for disk: DiskDescriptor,
    imageSizeBytes: Int,
    sourceBackingBSDName: String?
) -> [RejectionReason] {
    var reasons: [RejectionReason] = []

    // Reject APFS-synthesized containers (not real physical disks).
    if disk.isSynthesized {
        reasons.append(.synthesizedContainer)
    }

    // Reject built-in internal storage.
    if disk.isInternal {
        reasons.append(.internalDisk)
    }

    // Reject disks that carry a live macOS system volume.
    if disk.carriesMacOSSystem {
        reasons.append(.carriesMacOSSystem)
    }

    // Reject disks used as Time Machine backup stores.
    if disk.carriesTimeMachine {
        reasons.append(.timeMachineBackup)
    }

    // Reject hardware-write-protected or read-only nodes.
    if !disk.isWritable {
        reasons.append(.notWritable)
    }

    // Reject disks that are smaller than the image.
    if disk.sizeBytes < imageSizeBytes {
        reasons.append(.tooSmall)
    }

    // Reject disks that are implausibly large for flash media.
    if disk.sizeBytes >= diskSafetyMaxSizeBytes {
        reasons.append(.tooLarge)
    }

    // Reject the disk that the source image was read from.
    if let sourceBSD = sourceBackingBSDName, disk.bsdName == sourceBSD {
        reasons.append(.sourceOverlap)
    }

    return reasons
}

/// Returns `true` when `disk` has no rejection reasons and is safe to flash.
///
/// - Parameters:
///   - disk: The candidate write target.
///   - imageSizeBytes: The byte length of the image that will be written.
///   - sourceBackingBSDName: The BSD name of the disk the image was read from,
///     or `nil` when the source is not a disk.
/// - Returns: `true` if no rejection reasons apply.
public func isValidTarget(
    _ disk: DiskDescriptor,
    imageSizeBytes: Int,
    sourceBackingBSDName: String?
) -> Bool {
    let reasons = rejectionReasons(
        for: disk,
        imageSizeBytes: imageSizeBytes,
        sourceBackingBSDName: sourceBackingBSDName
    )
    return reasons.isEmpty
}

/// Filters `disks` down to only those that are valid write targets.
///
/// - Parameters:
///   - disks: The full list of detected disks.
///   - imageSizeBytes: The byte length of the image that will be written.
///   - sourceBackingBSDName: The BSD name of the disk the image was read from,
///     or `nil` when the source is not a disk.
/// - Returns: The subset of `disks` that pass all safety checks.
public func validTargets(
    from disks: [DiskDescriptor],
    imageSizeBytes: Int,
    sourceBackingBSDName: String?
) -> [DiskDescriptor] {
    let valid = disks.filter { disk in
        isValidTarget(disk, imageSizeBytes: imageSizeBytes, sourceBackingBSDName: sourceBackingBSDName)
    }
    return valid
}
