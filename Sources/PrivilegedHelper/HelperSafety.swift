/// HelperSafety.swift -- the helper's INDEPENDENT pre-write safety re-check.
///
/// The app already filtered targets through `DiskSafety` before sending the
/// request, but the helper does not trust that. Running as root, the helper is
/// the last gate before an irreversible raw write, so it re-resolves the target
/// BSD name to a fresh `DiskDescriptor` and re-runs the exact same `DiskSafety`
/// rules itself. A device can change between the app's check and the write
/// (re-plugged, re-mounted, a Time Machine volume appearing), so this re-check
/// uses live state, not the app's stale view.
///
/// Ground-truth image length: the helper derives the image byte count from the
/// OPENED SOURCE FILE, never from `FlashRequest.advisorySizeBytes`. The advisory
/// value is a UI hint and is not trusted for the `.tooSmall` / overlap rules.
///
/// The descriptor resolution glue (DiskArbitration via `DiskEnumerator`) is
/// thin; the decision itself is the pure `DiskSafety.rejectionReasons` call, so
/// the safety logic stays in one shared place for both the picker and the
/// helper.

import Foundation
import DiskModel

// MARK: - HelperSafety

/// Namespace for the helper-side safety re-check. No instances are created.
public enum HelperSafety {

    /// Re-resolve `targetBSDName` to a live descriptor and re-run `DiskSafety`.
    ///
    /// This is the authoritative gate the helper applies immediately before
    /// writing. It throws on any rejection so the caller cannot proceed to a
    /// raw write past a failed check.
    ///
    /// - Parameters:
    ///   - targetBSDName: The whole-disk BSD name to validate (for example
    ///     `"disk4"`). A slice name is reduced to its whole-disk parent first.
    ///   - imageSizeBytes: The GROUND-TRUTH image length, derived by the caller
    ///     from the opened source file -- not from the advisory request value.
    ///   - sourceBackingBSDName: BSD name of the disk the image was read from,
    ///     or `nil` when the source is a plain file. Used for the overlap rule.
    ///   - resolver: Injectable descriptor lookup. Defaults to the live
    ///     DiskArbitration resolver; tests pass a fixture closure.
    /// - Returns: The resolved `DiskDescriptor` that passed every safety rule.
    /// - Throws: `HelperError.targetNotResolvable` when the device cannot be
    ///   described, or `HelperError.targetRejected` with the failing reasons.
    public static func validatedTarget(
        targetBSDName: String,
        imageSizeBytes: Int,
        sourceBackingBSDName: String?,
        resolver: (String) async -> DiskDescriptor? = HelperSafety.liveResolve
    ) async throws -> DiskDescriptor {
        // Reduce any slice name (disk4s1) to the whole-disk parent (disk4); the
        // safety rules and the raw write both operate on the whole disk.
        let wholeName = DiskIdentity.wholeDiskName(for: targetBSDName) ?? targetBSDName

        // Resolve to a fresh, live descriptor. A missing descriptor means the
        // device vanished or is not a real whole disk; refuse rather than guess.
        guard let descriptor = await resolver(wholeName) else {
            throw HelperError.targetNotResolvable(bsdName: wholeName)
        }

        // Re-run the SAME pure rules the picker used, against live state and the
        // ground-truth image length.
        let reasons = rejectionReasons(
            for: descriptor,
            imageSizeBytes: imageSizeBytes,
            sourceBackingBSDName: sourceBackingBSDName
        )
        guard reasons.isEmpty else {
            throw HelperError.targetRejected(reasons: reasons)
        }
        return descriptor
    }

    /// Live descriptor resolver backed by a one-shot `DiskEnumerator` snapshot.
    ///
    /// Creating a fresh enumerator per call keeps this resolver stateless and
    /// safe to call from the helper without holding a long-lived session. When
    /// DiskArbitration is unavailable (returns `nil` from `init?`), resolution
    /// fails and the caller treats the target as not resolvable.
    ///
    /// - Parameter wholeBSDName: A whole-disk BSD name such as `"disk4"`.
    /// - Returns: The matching descriptor, or `nil` when none is found.
    public static func liveResolve(_ wholeBSDName: String) async -> DiskDescriptor? {
        guard let enumerator = DiskEnumerator() else {
            return nil
        }
        // `snapshot()` is actor-isolated; await it directly. No semaphore bridge
        // is needed because the whole safety re-check is async, so no
        // cooperative-pool thread is parked waiting on another task.
        let descriptors = await enumerator.snapshot()
        let match = descriptors.first { $0.bsdName == wholeBSDName }
        return match
    }
}
