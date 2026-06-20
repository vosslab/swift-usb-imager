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

import Foundation

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

/// Distinctly named alias for `validTargets(from:imageSizeBytes:sourceBackingBSDName:)`.
///
/// Every `DiskTargetService` conformer must filter through the DiskModel free
/// function, but a bare `validTargets(...)` inside a conformance body resolves to
/// the protocol method on `self` (infinite recursion). This module-level alias
/// names the free function unambiguously so all conformers share one forwarding
/// point instead of each defining a private file-scope wrapper.
///
/// - Parameters:
///   - disks: The full list of detected disks.
///   - imageSizeBytes: The byte length of the image that will be written.
///   - sourceBackingBSDName: The BSD name of the disk the image was read from,
///     or `nil` when the source is not a disk.
/// - Returns: The subset of `disks` that pass all safety checks.
///
/// NOTE: This alias exists only as a recursion guard. Conformers call it instead
/// of the bare `validTargets(...)`, whose unqualified name would self-resolve to
/// the protocol method on `self` and recurse infinitely.
public func diskModelValidTargets(
    from disks: [DiskDescriptor],
    imageSizeBytes: Int,
    sourceBackingBSDName: String?
) -> [DiskDescriptor] {
    return validTargets(
        from: disks,
        imageSizeBytes: imageSizeBytes,
        sourceBackingBSDName: sourceBackingBSDName
    )
}

// MARK: - Display name

/// A stable, GUI-neutral single-line display name for a disk.
///
/// Composes a human-readable identity from vendor, model, and size so the
/// operator can identify the physical device without reading the BSD name. This
/// is the one canonical formatter: `DiskTargetService.displayName(for:)`
/// conformers forward here so the CLI `list` output, the GUI target row, and the
/// screenshot harness all produce identical strings.
///
/// Format (when vendor and model are available):
///   "<vendor> <model> <size>"    e.g. "SanDisk Ultra 32.0 GB"
///
/// Graceful degradation (missing fields):
///   - Vendor empty, model present:  "<model> <size>"
///   - Vendor present, model empty:  "<vendor> <size>"
///   - Both empty:                   "<busProtocol> <size>"  e.g. "USB 32.0 GB"
///
/// Size uses decimal gigabytes (1 GB = 1,000,000,000 bytes) with one decimal
/// place, matching macOS Disk Utility conventions.
///
/// - Parameter disk: the disk to describe.
/// - Returns: a human-readable single-line name.
public func diskDisplayName(for disk: DiskDescriptor) -> String {
    let gb = Double(disk.sizeBytes) / 1_000_000_000.0
    let sizeString = String(format: "%.1f GB", gb)
    // Build the identity prefix from whatever human-readable strings are available.
    let vendor = disk.vendor.trimmingCharacters(in: .whitespaces)
    let model = disk.model.trimmingCharacters(in: .whitespaces)
    let prefix: String
    if !vendor.isEmpty && !model.isEmpty {
        // Full identity: "SanDisk Ultra"
        prefix = "\(vendor) \(model)"
    } else if !model.isEmpty {
        // Model only: "Ultra"
        prefix = model
    } else if !vendor.isEmpty {
        // Vendor only: "SanDisk"
        prefix = vendor
    } else {
        // No device strings; fall back to bus protocol token.
        prefix = disk.busProtocol.rawValue.uppercased()
    }
    let name = "\(prefix) \(sizeString)"
    return name
}
