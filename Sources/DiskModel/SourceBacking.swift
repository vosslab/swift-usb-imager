/// SourceBacking.swift -- resolve the backing whole-disk BSD name for a file.
///
/// The `sourceOverlap` safety rule needs to know which physical disk a source
/// image was read from, so the helper can refuse to flash a target that is the
/// same disk the image lives on. This file turns a filesystem path into the BSD
/// name of the WHOLE disk that backs the volume containing that path, using
/// DiskArbitration. It is deliberately a thin, pure-ish lookup: it creates a
/// short-lived DA session, asks DiskArbitration for the volume's media BSD name,
/// and reduces any slice name to its whole-disk parent via `DiskIdentity`.
///
/// Resolution is best-effort. When the path lives on a synthetic, network, or
/// otherwise non-describable volume, this returns `nil` and the overlap rule
/// simply does not fire for that source -- the other safety rules still apply.

import Foundation
import DiskArbitration

// MARK: - SourceBacking

/// Namespace for resolving a file path to its backing whole-disk BSD name.
public enum SourceBacking {

    /// Resolve the WHOLE-disk BSD name of the volume that contains `path`.
    ///
    /// - Parameter path: An absolute filesystem path (typically the source image).
    /// - Returns: The whole-disk BSD name (for example `"disk4"`), or `nil` when
    ///   DiskArbitration cannot describe the backing volume.
    public static func wholeDiskBSDName(forPath path: String) -> String? {
        // A fresh, short-lived session keeps this a stateless lookup.
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return nil
        }
        // DiskArbitration resolves the volume that owns this path via its URL.
        let url = URL(fileURLWithPath: path) as CFURL
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url) else {
            return nil
        }
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else {
            return nil
        }
        // The media BSD name is the slice or whole-disk node backing the volume.
        guard let mediaBSDName = description[kDADiskDescriptionMediaBSDNameKey as String]
            as? String else {
            return nil
        }
        // Reduce a slice name (disk4s2) to its whole-disk parent (disk4); the
        // overlap rule and the raw write both operate on the whole disk.
        let wholeName = DiskIdentity.wholeDiskName(for: mediaBSDName) ?? mediaBSDName
        return wholeName
    }
}
