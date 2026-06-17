/// DiskIdentity.swift - pure, side-effect-free helpers for BSD disk names.
///
/// These functions encode the deterministic naming rules macOS uses for BSD
/// disk nodes. They are factored out of `DiskEnumerator` so the rules can be
/// unit tested without a live DiskArbitration session or real hardware.
///
/// Naming reference:
///   - A whole disk is `diskN` (for example `disk4`).
///   - A partition slice is `diskNsM` (for example `disk4s1`).
///   - APFS adds further nesting `diskNsMsK` (for example `disk4s1s1`).
///   - The buffered block node lives at `/dev/diskN`.
///   - The raw character node lives at `/dev/rdiskN` (an `r` prefix on the
///     same name).
import Foundation

// MARK: - DiskIdentity

/// Namespace for pure BSD-name helpers. No instances are created.
public enum DiskIdentity {

    /// Decide whether a BSD name refers to a WHOLE disk rather than a slice.
    ///
    /// Whole disks match `disk` followed by one or more digits and nothing
    /// else. Any `s<digits>` suffix marks a partition or APFS volume slice.
    ///
    /// - Parameter bsdName: A BSD name such as `"disk4"` or `"disk4s1"`.
    /// - Returns: `true` for `"disk4"`, `false` for `"disk4s1"` or junk input.
    public static func isWholeDisk(_ bsdName: String) -> Bool {
        // Must start with the literal "disk".
        guard bsdName.hasPrefix("disk") else {
            return false
        }
        let suffix = bsdName.dropFirst("disk".count)
        // The remainder must be a non-empty run of digits with no slice marker.
        guard !suffix.isEmpty else {
            return false
        }
        for character in suffix where !character.isNumber {
            return false
        }
        return true
    }

    /// Reduce any BSD slice name to its whole-disk parent name.
    ///
    /// `"disk4s1"` and `"disk4s1s2"` both reduce to `"disk4"`. A name that is
    /// already a whole disk is returned unchanged. Junk input that does not
    /// begin with `disk<digits>` returns `nil` so callers fail loudly rather
    /// than fabricating a parent.
    ///
    /// - Parameter bsdName: Any BSD node name.
    /// - Returns: The whole-disk parent name, or `nil` when the name is not a
    ///   recognizable BSD disk node.
    public static func wholeDiskName(for bsdName: String) -> String? {
        guard bsdName.hasPrefix("disk") else {
            return nil
        }
        let digits = bsdName.dropFirst("disk".count)
        // Collect the leading digit run; that run plus "disk" is the parent.
        var unitDigits = ""
        for character in digits {
            if character.isNumber {
                unitDigits.append(character)
            } else {
                // First non-digit (the start of "s1", etc.) ends the unit number.
                break
            }
        }
        guard !unitDigits.isEmpty else {
            return nil
        }
        let parent = "disk" + unitDigits
        return parent
    }

    /// Derive the buffered block-device path for a BSD name.
    ///
    /// - Parameter bsdName: A BSD name such as `"disk4"`.
    /// - Returns: The `/dev/diskN` path, for example `"/dev/disk4"`.
    public static func devicePath(for bsdName: String) -> String {
        let path = "/dev/" + bsdName
        return path
    }

    /// Derive the raw (unbuffered) character-device path for a BSD name.
    ///
    /// The raw node prepends `r` to the BSD name: `disk4` -> `/dev/rdisk4`.
    ///
    /// - Parameter bsdName: A BSD name such as `"disk4"`.
    /// - Returns: The `/dev/rdiskN` path, for example `"/dev/rdisk4"`.
    public static func rawDevicePath(for bsdName: String) -> String {
        let path = "/dev/r" + bsdName
        return path
    }
}
