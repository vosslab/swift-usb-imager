/// DiskTargetService.swift - concrete implementation of the `DiskTargetService` protocol.
///
/// Wraps `DiskEnumerator.snapshot()` (async, actor-isolated) and the pure
/// `DiskModel.validTargets(from:imageSizeBytes:sourceBackingBSDName:)` function
/// to filter disks. Does NOT re-implement any safety rule: all filtering logic
/// stays in DiskModel.
///
/// Also provides a stable, GUI-neutral `displayName(for:)` string for a disk so
/// both the CLI list output and the GUI target row build on the same core label.
///
/// No SwiftUI/AppKit.
import DiskModel
import Foundation

// MARK: - BSD-name lookup helper

/// Return the first disk in `disks` whose `bsdName` equals `bsdName`, or `nil`.
///
/// Pure and synchronous over a caller-supplied list so the matching rule can be
/// unit-tested against fixtures without a live DiskArbitration snapshot. The
/// public `diskDescriptor(withBSDName:)` method feeds this helper a fresh
/// snapshot.
internal func firstDescriptor(withBSDName bsdName: String, in disks: [DiskDescriptor]) -> DiskDescriptor? {
    // Exact match on the BSD name; first match wins (BSD names are unique).
    return disks.first { $0.bsdName == bsdName }
}

// MARK: - DefaultDiskTargetService

/// The concrete `DiskTargetService` implementation shipped by USBImagerCore.
///
/// `snapshotDisks()` is `async` because `DiskEnumerator` is an actor; all other
/// methods are synchronous pure functions over the values they receive.
///
/// In unit tests, build `DiskDescriptor` fixtures directly and pass them to
/// `validTargets(from:imageSizeBytes:sourceBackingBSDName:)` -- no live
/// enumerator is needed. Inject a `DiskEnumerator` to test `snapshotDisks`
/// with a real (or sandboxed) DiskArbitration session.
public struct DefaultDiskTargetService: DiskTargetService {

    // Injected enumerator; nil only in tests that skip snapshot.
    private let enumerator: DiskEnumerator?

    // MARK: - Init

    /// Create a service with a fresh `DiskEnumerator` (production path).
    ///
    /// Returns `nil` when the DiskArbitration session cannot be created (sandbox
    /// denial or a system without DiskArbitration access). Callers that need a
    /// non-optional service can use `init(enumerator:)` and supply a pre-built
    /// enumerator, or handle `nil` at the call site.
    public init?() {
        guard let enumerator = DiskEnumerator() else {
            return nil
        }
        self.enumerator = enumerator
    }

    /// Create a service with an explicit `DiskEnumerator` (for testing or when
    /// an enumerator already exists).
    ///
    /// - Parameter enumerator: the enumerator to use for `snapshotDisks()`.
    public init(enumerator: DiskEnumerator) {
        self.enumerator = enumerator
    }

    // MARK: - DiskTargetService conformance

    /// Snapshot all currently attached whole disks.
    ///
    /// Hops to the `DiskEnumerator` actor for the snapshot; the actor provides
    /// the concurrency isolation. Returns an empty list when no enumerator is
    /// available (the service was constructed without one and the session failed).
    ///
    /// - Returns: one `DiskDescriptor` per attached whole physical disk.
    public func snapshotDisks() async -> [DiskDescriptor] {
        guard let enumerator else {
            return []
        }
        return await enumerator.snapshot()
    }

    // diskDescriptor(withBSDName:) is supplied by the DiskTargetService protocol
    // extension in Services.swift: it composes snapshotDisks() with the file-scope
    // firstDescriptor(withBSDName:in:) helper, so every conformer shares one
    // lookup implementation.

    /// Filter `disks` to the safe write targets for an image of the given size.
    ///
    /// Delegates entirely to `DiskModel.validTargets(from:imageSizeBytes:
    /// sourceBackingBSDName:)`. No safety logic lives here.
    ///
    /// - Parameters:
    ///   - disks: the candidate disks (typically from `snapshotDisks`).
    ///   - imageSizeBytes: the image byte length the target must hold.
    ///   - sourceBackingBSDName: the BSD name of the disk the source lives on,
    ///     or `nil` when the source is a plain file.
    /// - Returns: the subset of `disks` that pass all DiskModel safety checks.
    public func validTargets(
        from disks: [DiskDescriptor],
        imageSizeBytes: Int,
        sourceBackingBSDName: String?
    ) -> [DiskDescriptor] {
        // Delegate via the DiskModel module-level alias that names the free
        // function. A direct bare `validTargets(...)` would self-resolve to this
        // protocol method (infinite recursion).
        let targets = diskModelValidTargets(
            from: disks,
            imageSizeBytes: imageSizeBytes,
            sourceBackingBSDName: sourceBackingBSDName
        )
        return targets
    }

    /// A stable, GUI-neutral single-line display name for a disk.
    ///
    /// Forwards to the canonical `DiskModel.diskDisplayName(for:)` so the CLI
    /// `list` output, the GUI target row, and the screenshot harness all share one
    /// formatter and produce identical strings.
    ///
    /// - Parameter disk: the disk to describe.
    /// - Returns: a human-readable single-line name.
    public func displayName(for disk: DiskDescriptor) -> String {
        diskDisplayName(for: disk)
    }
}
