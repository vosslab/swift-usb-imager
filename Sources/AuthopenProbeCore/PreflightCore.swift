/// PreflightCore.swift -- pure (hardware-free) preflight decision logic.
///
/// PURPOSE
/// -------
/// The authopen_fd_probe executable enforces a raw-device safety preflight
/// before it ever opens a /dev/rdiskN target: the disk must be external,
/// removable, not internal, and not the boot disk, and its identity must
/// re-match immediately before the open. That logic used to live inline in
/// the executable next to the diskutil I/O, which made it impossible to test
/// the refusal decisions without a real USB stick.
///
/// This library holds the side-effect-free core: it takes ALREADY-PARSED
/// inputs (a diskutil plist dictionary, the resolved boot-disk BSD name, the
/// raw path) and returns a decision. It never spawns diskutil and never reads
/// or writes any device. The executable keeps the thin diskutil-calling
/// wrappers and delegates the actual accept/refuse decision here, so the same
/// decisions can be unit-tested against saved plist fixtures with no hardware.

import Foundation

// MARK: - Disk identity snapshot

/// Container for the disk identity snapshot captured at preflight time.
/// Holds values that MUST match on a second query immediately before the open.
public struct DiskIdentity: Equatable {
	// BSD name of the WHOLE disk (e.g. "disk4"), not the raw-device node.
	public let wholeDiskBSD: String
	// Human-readable volume/media name from diskutil.
	public let mediaName: String
	// Total size in bytes as reported by diskutil.
	public let totalSizeBytes: Int
	// Partition or disk UUID as reported by diskutil (used as stable identity).
	public let diskUUID: String

	public init(wholeDiskBSD: String, mediaName: String, totalSizeBytes: Int, diskUUID: String) {
		self.wholeDiskBSD = wholeDiskBSD
		self.mediaName = mediaName
		self.totalSizeBytes = totalSizeBytes
		self.diskUUID = diskUUID
	}

	/// Short one-line summary for logging.
	public var summary: String {
		let mb = totalSizeBytes / (1024 * 1024)
		return "\(wholeDiskBSD) | \(mediaName) | \(mb) MB | uuid=\(diskUUID)"
	}
}

// MARK: - Refusal reasons

/// A typed reason the preflight evaluator refused (or could not evaluate) a
/// target. Each case carries the data the executable needs to print the exact
/// same operator-facing message it printed when the logic was inline.
public enum PreflightRefusal: Equatable, Error {
	// Path did not match the /dev/rdiskN shape.
	case malformedPath(rawPath: String)
	// "External" flag was false or missing. Carries the BusProtocol for logging.
	case notExternal(busProtocol: String)
	// No removable signal was true. Carries the three flags for logging.
	case notRemovable(removable: Bool, removableMedia: Bool, ejectable: Bool)
	// "Internal" flag was true.
	case isInternal
	// The boot-disk BSD name could not be resolved by the caller.
	case bootDiskUnknown
	// The target whole-disk BSD name equals the boot-disk BSD name.
	case isBootDisk(targetBSD: String, bootBSD: String)
	// The plist was present but lacked a required key (e.g. TotalSize).
	case missingIdentityField(field: String)
}

/// The result of evaluating a raw-device target against the preflight invariant.
public enum PreflightDecision: Equatable {
	case accept(DiskIdentity)
	case refuse(PreflightRefusal)
}

// MARK: - Pure path parsing (no I/O)

/// Validate that `path` is a well-formed /dev/rdiskN path.
///
/// Accepted: /dev/rdisk0, /dev/rdisk1, /dev/rdisk4, etc.
/// Rejected: anything else (plain file, /dev/disk, partial prefix, etc.).
/// Returns the matched N suffix on success, or nil on failure.
public func parseRawDevicePath(_ path: String) -> String? {
	// Must start with "/dev/rdisk" and end with one or more digits.
	let prefix = "/dev/rdisk"
	guard path.hasPrefix(prefix) else { return nil }
	let suffix = String(path.dropFirst(prefix.count))
	guard !suffix.isEmpty, suffix.allSatisfy({ $0.isNumber }) else { return nil }
	return suffix
}

/// Derive the whole-disk /dev/diskN path from a /dev/rdiskN path.
///
/// diskutil info operates on /dev/diskN, not the raw node.
public func wholeDiskPath(fromRaw rawPath: String) -> String {
	// "/dev/rdiskN" -> "/dev/diskN" by dropping the 'r'.
	guard rawPath.hasPrefix("/dev/rdisk") else { return rawPath }
	return "/dev/disk" + rawPath.dropFirst("/dev/rdisk".count)
}

/// Extract the whole-disk BSD name (e.g. "disk4") from a /dev/rdiskN path.
///
/// Returns nil if the path is not a well-formed /dev/rdiskN path.
public func wholeDiskBSD(fromRaw rawPath: String) -> String? {
	guard parseRawDevicePath(rawPath) != nil else { return nil }
	let diskPath = wholeDiskPath(fromRaw: rawPath)
	return String(diskPath.dropFirst("/dev/".count))
}

// MARK: - Pure identity capture (no I/O)

/// Build a DiskIdentity from an already-parsed whole-disk plist dictionary.
///
/// `wholeDiskBSD` is the BSD name the caller resolved (e.g. "disk4"). The plist
/// is the parsed `diskutil info -plist /dev/diskN` output. Returns nil (with the
/// missing field name) if a required key is absent, mirroring the executable's
/// "missing TotalSize" refusal path.
public func diskIdentity(fromPlist plist: [String: Any], wholeDiskBSD: String)
	-> Result<DiskIdentity, PreflightRefusal> {
	// MediaName is optional in the original; default to "(unknown)".
	let mediaName = plist["MediaName"] as? String ?? "(unknown)"

	// TotalSize is required.
	guard let totalSizeBytes = plist["TotalSize"] as? Int else {
		return .failure(.missingIdentityField(field: "TotalSize"))
	}

	// Identity anchor: prefer "DiskUUID"; fall back to a name+size tuple.
	let diskUUID: String
	if let uuid = plist["DiskUUID"] as? String, !uuid.isEmpty {
		diskUUID = uuid
	} else {
		diskUUID = "name=\(mediaName),size=\(totalSizeBytes)"
	}

	let identity = DiskIdentity(
		wholeDiskBSD: wholeDiskBSD,
		mediaName: mediaName,
		totalSizeBytes: totalSizeBytes,
		diskUUID: diskUUID
	)
	return .success(identity)
}

// MARK: - Pure preflight evaluator (no I/O)

/// Evaluate the full raw-device preflight invariant against parsed inputs.
///
/// Inputs:
///   - rawPath:    the operator-supplied target (e.g. "/dev/rdisk4").
///   - plist:      parsed `diskutil info -plist /dev/diskN` for the whole disk.
///   - bootWholeBSD: the resolved boot-disk whole BSD name (e.g. "disk0"), or
///                 nil if the caller could not determine it.
///
/// Returns `.accept(identity)` when every gate passes, or `.refuse(reason)`
/// describing the FIRST gate that failed, in the same order the executable
/// evaluated them inline (path, external, removable, internal, boot disk,
/// identity capture). This function performs NO I/O.
public func evaluateRawDevicePreflight(
	rawPath: String,
	plist: [String: Any],
	bootWholeBSD: String?
) -> PreflightDecision {
	// Gate 1: path format.
	guard let bsd = wholeDiskBSD(fromRaw: rawPath) else {
		return .refuse(.malformedPath(rawPath: rawPath))
	}

	// Gate 2: External flag (must be true). Absent key reads as false so we
	// fail closed: a disk we cannot prove is external is refused.
	let externalFlag = plist["External"] as? Bool ?? false
	guard externalFlag else {
		let busProtocol = plist["BusProtocol"] as? String ?? "(unknown)"
		return .refuse(.notExternal(busProtocol: busProtocol))
	}

	// Gate 3: removability. USB sticks often report Removable=false but
	// RemovableMedia=true and/or Ejectable=true, so ANY true signal accepts.
	let removable = plist["Removable"] as? Bool ?? false
	let removableMedia = plist["RemovableMedia"] as? Bool ?? false
	let ejectable = plist["Ejectable"] as? Bool ?? false
	guard removable || removableMedia || ejectable else {
		return .refuse(.notRemovable(
			removable: removable,
			removableMedia: removableMedia,
			ejectable: ejectable
		))
	}

	// Gate 4: Internal flag (must be false).
	let internalFlag = plist["Internal"] as? Bool ?? false
	guard !internalFlag else {
		return .refuse(.isInternal)
	}

	// Gate 5: not the boot/system disk.
	guard let bootBSD = bootWholeBSD else {
		return .refuse(.bootDiskUnknown)
	}
	guard bsd != bootBSD else {
		return .refuse(.isBootDisk(targetBSD: bsd, bootBSD: bootBSD))
	}

	// Gate 6: record disk identity (also enforces required-key presence).
	switch diskIdentity(fromPlist: plist, wholeDiskBSD: bsd) {
	case .failure(let reason):
		return .refuse(reason)
	case .success(let identity):
		return .accept(identity)
	}
}

// MARK: - Pure identity comparison (no I/O)

/// Compare a recorded identity against a freshly captured one and return the
/// names of the fields that changed.
///
/// The probe re-queries diskutil immediately before opening; any changed field
/// means the medium is not the same physical disk (BSD numbers change on
/// reinsert). The returned list is empty when the identities match.
///
/// Field names match the executable's mismatch labels so the wrapper can print
/// the same operator-facing lines:
///   - "UUID/anchor"
///   - "size"
///   - "media name"
public func identityMismatchFields(recorded: DiskIdentity, current: DiskIdentity)
	-> [String] {
	var fields: [String] = []
	if current.diskUUID != recorded.diskUUID {
		fields.append("UUID/anchor")
	}
	if current.totalSizeBytes != recorded.totalSizeBytes {
		fields.append("size")
	}
	if current.mediaName != recorded.mediaName {
		fields.append("media name")
	}
	return fields
}
