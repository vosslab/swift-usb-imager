/// DiskModel: drive descriptor and enumerator.
///
/// Public surface:
///   - `DiskDescriptor` (DiskDescriptor.swift): whole-disk value type and
///     CONTRACT for the later `DiskSafety` module.
///   - `DiskIdentity` (DiskIdentity.swift): pure BSD-name helpers.
///   - `VolumeAttribution` (VolumeAttribution.swift): pure volume roll-up.
///   - `DiskEnumerator` (DiskEnumerator.swift): live DiskArbitration + IOKit
///     enumeration and appeared/disappeared streaming.
///
/// The `DiskSafety` predicates land in a later task; this module exposes the
/// fields that module consumes but does not itself decide write-safety.
public enum DiskModel {
    /// Module version token, updated as the real implementation lands.
    public static let version = "0.1.0"
}
