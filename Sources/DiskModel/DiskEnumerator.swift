/// DiskEnumerator.swift - live whole-disk enumeration via DiskArbitration.
///
/// `DiskEnumerator` snapshots the currently attached whole physical disks and
/// streams appeared/disappeared events as media are plugged in or removed. It
/// uses the DiskArbitration framework to describe each node and reuses the pure
/// helpers in `DiskIdentity` and `VolumeAttribution` for all naming and roll-up
/// logic, so the framework glue stays thin and the rules stay testable.
///
/// Key mapping (DiskArbitration description dictionary):
///   - kDADiskDescriptionMediaBSDNameKey   -> bsdName / devicePath / rawDevicePath
///   - kDADiskDescriptionMediaSizeKey       -> sizeBytes
///   - kDADiskDescriptionMediaRemovableKey  -> isRemovable
///   - kDADiskDescriptionMediaEjectableKey  -> isEjectable
///   - kDADiskDescriptionDeviceInternalKey  -> isInternal
///   - kDADiskDescriptionDeviceProtocolKey  -> busProtocol
///   - kDADiskDescriptionMediaWritableKey   -> isWritable
///   - kDADiskDescriptionMediaWholeKey      -> whole-disk filter (with name shape)
///   - kDADiskDescriptionVolumeKindKey + "synthesized" media path -> isSynthesized
///   - kDADiskDescriptionVolumePathKey      -> mountPoints (per volume node)
///   - kDADiskDescriptionVolumeNameKey / volume path -> macOS-system + Time Machine
///
/// macOS-system detection: a volume mounted at "/" (the live system root) marks
/// its physical parent disk as `carriesMacOSSystem`. Time Machine detection: a
/// volume named with the Time Machine "Backups of" convention, or mounted under
/// the Time Machine backup path, marks `carriesTimeMachine`. Both signals are
/// folded to the physical parent by `VolumeAttribution`, which is how an
/// APFS-synthesized system or backup volume taints the disk it lives on.
import Foundation
import DiskArbitration

// MARK: - Event

/// A live change in the set of attached whole disks.
public enum DiskEvent: Sendable, Equatable {
    /// A whole disk became available; carries its full descriptor.
    case appeared(DiskDescriptor)
    /// A whole disk went away; carries the BSD name that disappeared.
    case disappeared(bsdName: String)
}

// MARK: - DiskEnumerator

/// Enumerates whole physical disks and streams attach/detach events.
///
/// The type is an `actor` so its DiskArbitration session and continuation
/// state are isolated; all framework callbacks hop back onto the actor.
public actor DiskEnumerator {

    /// The DiskArbitration session used for both snapshot and live callbacks.
    private let session: DASession

    /// Active continuations for `events()` streams, keyed by a token so each
    /// consumer can be finished independently.
    private var continuations: [UUID: AsyncStream<DiskEvent>.Continuation] = [:]

    /// Create an enumerator with a fresh DiskArbitration session.
    ///
    /// Returns `nil` when a session cannot be created (sandbox denial or a
    /// system without DiskArbitration access).
    public init?() {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            return nil
        }
        self.session = session
    }

    // MARK: Snapshot

    /// Capture the set of whole disks currently attached.
    ///
    /// This walks `/dev` for whole-disk nodes, describes each through
    /// DiskArbitration, and folds volume facts onto each whole disk. It does
    /// not start live callbacks; use `events()` for streaming.
    ///
    /// - Returns: One `DiskDescriptor` per attached whole physical disk.
    public func snapshot() -> [DiskDescriptor] {
        let bsdNames = Self.currentWholeDiskBSDNames()
        // Gather every volume fact once so attribution can fold synthesized
        // and partition volumes onto their physical parent.
        let facts = Self.gatherVolumeFacts(session: session)
        var descriptors = [DiskDescriptor]()
        for bsdName in bsdNames {
            if let descriptor = Self.describeWholeDisk(
                bsdName: bsdName,
                session: session,
                facts: facts
            ) {
                descriptors.append(descriptor)
            }
        }
        // Stable ordering by BSD name keeps the UI list deterministic.
        descriptors.sort { $0.bsdName < $1.bsdName }
        return descriptors
    }

    // MARK: Live events

    /// Stream appeared/disappeared events for whole disks.
    ///
    /// The returned stream first replays an `.appeared` event for every disk
    /// already attached, then delivers live changes until the consumer stops
    /// iterating. Multiple concurrent streams are supported.
    ///
    /// - Returns: An `AsyncStream` of `DiskEvent` values.
    public func events() -> AsyncStream<DiskEvent> {
        let token = UUID()
        let stream = AsyncStream<DiskEvent> { continuation in
            self.register(token: token, continuation: continuation)
        }
        return stream
    }

    /// Register a new continuation, replay the current snapshot, and arm
    /// DiskArbitration callbacks on first use.
    private func register(
        token: UUID,
        continuation: AsyncStream<DiskEvent>.Continuation
    ) {
        let isFirst = continuations.isEmpty
        continuations[token] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.unregister(token: token) }
        }
        // Replay current state so a new subscriber sees existing disks.
        for descriptor in snapshot() {
            continuation.yield(.appeared(descriptor))
        }
        if isFirst {
            armCallbacks()
        }
    }

    /// Drop a finished continuation and disarm callbacks when none remain.
    private func unregister(token: UUID) {
        continuations[token] = nil
        if continuations.isEmpty {
            disarmCallbacks()
        }
    }

    /// Broadcast an event to every active continuation.
    private func broadcast(_ event: DiskEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    // MARK: DiskArbitration callbacks

    /// Schedule the session on a run loop and install appear/disappear handlers.
    private func armCallbacks() {
        // Pass an unretained pointer to self so the C callbacks can hop back.
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(
            session,
            nil,
            diskAppearedCallback,
            context
        )
        DARegisterDiskDisappearedCallback(
            session,
            nil,
            diskDisappearedCallback,
            context
        )
        DASessionScheduleWithRunLoop(
            session,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
    }

    /// Unschedule the session from the run loop.
    private func disarmCallbacks() {
        DASessionUnscheduleFromRunLoop(
            session,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
    }

    /// Handle a DiskArbitration "appeared" callback for one node.
    ///
    /// Only whole-disk nodes produce an `.appeared` event; partition and
    /// synthesized volume nodes are ignored here because their facts are
    /// already folded into their parent's descriptor on the next snapshot.
    fileprivate func handleAppeared(bsdName: String) {
        guard DiskIdentity.isWholeDisk(bsdName) else {
            return
        }
        let facts = Self.gatherVolumeFacts(session: session)
        guard let descriptor = Self.describeWholeDisk(
            bsdName: bsdName,
            session: session,
            facts: facts
        ) else {
            return
        }
        broadcast(.appeared(descriptor))
    }

    /// Handle a DiskArbitration "disappeared" callback for one node.
    fileprivate func handleDisappeared(bsdName: String) {
        guard DiskIdentity.isWholeDisk(bsdName) else {
            return
        }
        broadcast(.disappeared(bsdName: bsdName))
    }

    // MARK: Description helpers (pure given DiskArbitration input)

    /// Build a `DiskDescriptor` for one whole disk from its DiskArbitration
    /// description and the gathered volume facts.
    ///
    /// - Returns: A descriptor, or `nil` when the node cannot be described or
    ///   is not actually a whole disk.
    private static func describeWholeDisk(
        bsdName: String,
        session: DASession,
        facts: [VolumeFact]
    ) -> DiskDescriptor? {
        guard DiskIdentity.isWholeDisk(bsdName) else {
            return nil
        }
        guard let disk = DADiskCreateFromBSDName(
            kCFAllocatorDefault,
            session,
            DiskIdentity.devicePath(for: bsdName)
        ) else {
            return nil
        }
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else {
            return nil
        }
        // Confirm this node really is a whole disk per DiskArbitration too.
        let isWhole = boolValue(description, kDADiskDescriptionMediaWholeKey)
        guard isWhole else {
            return nil
        }
        let sizeBytes = intValue(description, kDADiskDescriptionMediaSizeKey)
        let isRemovable = boolValue(description, kDADiskDescriptionMediaRemovableKey)
        let isEjectable = boolValue(description, kDADiskDescriptionMediaEjectableKey)
        let isInternal = boolValue(description, kDADiskDescriptionDeviceInternalKey)
        let isWritable = boolValue(description, kDADiskDescriptionMediaWritableKey)
        let protocolString = stringValue(description, kDADiskDescriptionDeviceProtocolKey)
        let busProtocol = BusProtocol.fromDeviceProtocol(protocolString)
        // A whole disk is "synthesized" when DiskArbitration reports a virtual
        // protocol (APFS synthesized containers carry the "Virtual Interface").
        let isSynthesized = (busProtocol == .virtual)
            || protocolString.lowercased().contains("virtual")
        // Fold every volume fact for this disk onto the physical parent.
        let attributed = VolumeAttribution.attribute(facts: facts, toWholeDisk: bsdName)
        let descriptor = DiskDescriptor(
            bsdName: bsdName,
            devicePath: DiskIdentity.devicePath(for: bsdName),
            rawDevicePath: DiskIdentity.rawDevicePath(for: bsdName),
            sizeBytes: sizeBytes,
            isRemovable: isRemovable,
            isEjectable: isEjectable,
            isInternal: isInternal,
            busProtocol: busProtocol,
            isWritable: isWritable,
            isSynthesized: isSynthesized,
            carriesMacOSSystem: attributed.carriesMacOSSystem,
            carriesTimeMachine: attributed.carriesTimeMachine,
            mountPoints: attributed.mountPoints
        )
        return descriptor
    }

    /// Collect per-node volume facts (mount point, system/TM roles) for every
    /// BSD node DiskArbitration can describe under `/dev`.
    private static func gatherVolumeFacts(session: DASession) -> [VolumeFact] {
        var facts = [VolumeFact]()
        for bsdName in currentAllDiskBSDNames() {
            guard let disk = DADiskCreateFromBSDName(
                kCFAllocatorDefault,
                session,
                DiskIdentity.devicePath(for: bsdName)
            ) else {
                continue
            }
            guard let description = DADiskCopyDescription(disk) as? [String: Any] else {
                continue
            }
            let mountPoint = volumePath(description)
            let volumeName = stringValue(description, kDADiskDescriptionVolumeNameKey)
            // The live system root mounts at "/"; that marks a macOS system disk.
            let isSystem = (mountPoint == "/")
            // A LOCAL mounted volume that hides from Finder (non-browsable) is
            // almost always a Time Machine store, a local snapshot, or another
            // system-internal mount. Treating it as protected is the
            // conservative, over-reject-is-safe choice. Only consult this signal
            // for non-network volumes that are actually mounted.
            let isLocalMount = (mountPoint != nil)
                && (boolValue(description, kDADiskDescriptionVolumeNetworkKey) == false)
            let isMountedAndHidden = isLocalMount
                && (Self.volumeIsBrowsable(atMountPoint: mountPoint) == false)
            // Time Machine local stores mount under the backup path; the volume
            // name follows the "Backups of <host>" convention. Apple has used
            // several mount-path prefixes across OS versions, so match all known
            // ones, plus the mounted-but-hidden signal above.
            let isTimeMachine = volumeName.hasPrefix("Backups of")
                || Self.mountHasTimeMachinePrefix(mountPoint)
                || isMountedAndHidden
            let fact = VolumeFact(
                bsdName: bsdName,
                mountPoint: mountPoint,
                isMacOSSystem: isSystem,
                isTimeMachine: isTimeMachine
            )
            facts.append(fact)
        }
        return facts
    }

    // MARK: Time Machine and browsable signals

    /// Known mount-path prefixes used by Time Machine and local backup stores.
    ///
    /// Apple has mounted these under several roots across OS versions; matching
    /// the whole set keeps a backup volume protected regardless of where the OS
    /// chose to mount it. Over-matching here is safe: it can only reject more.
    private static let timeMachineMountPrefixes: [String] = [
        "/Volumes/.timemachine",
        "/Volumes/com.apple.TimeMachine",
        "/Volumes/MobileBackups",
        "/Volumes/Backups.backupdb",
        "/System/Volumes/Data/.Snapshots",
        "/.MobileBackups",
    ]

    /// Whether a mount point begins with any known Time Machine path prefix.
    ///
    /// - Parameter mountPoint: The volume mount path, or `nil` when unmounted.
    /// - Returns: `true` when the path matches a Time Machine prefix.
    private static func mountHasTimeMachinePrefix(_ mountPoint: String?) -> Bool {
        guard let mountPoint else {
            return false
        }
        let matches = timeMachineMountPrefixes.contains { mountPoint.hasPrefix($0) }
        return matches
    }

    /// Whether the volume at `mountPoint` is browsable (visible in Finder).
    ///
    /// Non-browsable local volumes are typically backup stores or system-internal
    /// mounts. The browsable flag is a URL resource value, not a DiskArbitration
    /// description key, so it is read here from the mount path. A path that
    /// cannot be queried is treated as browsable (the default safe assumption so
    /// this signal alone never rejects a normal external disk).
    ///
    /// - Parameter mountPoint: The volume mount path, or `nil` when unmounted.
    /// - Returns: `true` when browsable or unknown; `false` only when the system
    ///   explicitly reports the volume as non-browsable.
    private static func volumeIsBrowsable(atMountPoint mountPoint: String?) -> Bool {
        guard let mountPoint else {
            return true
        }
        let url = URL(fileURLWithPath: mountPoint)
        guard let values = try? url.resourceValues(forKeys: [.volumeIsBrowsableKey]),
              let browsable = values.volumeIsBrowsable else {
            // Unknown: assume browsable so this signal does not over-reject.
            return true
        }
        return browsable
    }

    // MARK: DiskArbitration dictionary accessors

    /// Read a `Bool` value from a DiskArbitration description dictionary.
    ///
    /// Missing or non-boolean values read as `false`, the safe default for
    /// every flag the safety module treats as "permissive when true".
    private static func boolValue(_ dict: [String: Any], _ key: CFString) -> Bool {
        guard let number = dict[key as String] as? NSNumber else {
            return false
        }
        return number.boolValue
    }

    /// Read an `Int` value (used for media size) from the description.
    private static func intValue(_ dict: [String: Any], _ key: CFString) -> Int {
        guard let number = dict[key as String] as? NSNumber else {
            return 0
        }
        return number.intValue
    }

    /// Read a `String` value from the description, empty when absent.
    private static func stringValue(_ dict: [String: Any], _ key: CFString) -> String {
        guard let value = dict[key as String] as? String else {
            return ""
        }
        return value
    }

    /// Read the volume mount path (a file URL) from the description, if mounted.
    private static func volumePath(_ dict: [String: Any]) -> String? {
        guard let url = dict[kDADiskDescriptionVolumePathKey as String] as? URL else {
            return nil
        }
        return url.path
    }

    // MARK: /dev enumeration

    /// List every BSD disk node name under `/dev` (whole disks and slices).
    private static func currentAllDiskBSDNames() -> [String] {
        let devURL = URL(fileURLWithPath: "/dev")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: devURL,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return []
        }
        var names = [String]()
        for entry in entries {
            let name = entry.lastPathComponent
            // Buffered block nodes are "diskNsM"; skip the raw "rdisk" nodes so
            // each unit is enumerated once.
            if name.hasPrefix("disk") {
                names.append(name)
            }
        }
        return names
    }

    /// List only the whole-disk BSD node names under `/dev`.
    private static func currentWholeDiskBSDNames() -> [String] {
        let all = currentAllDiskBSDNames()
        let whole = all.filter { DiskIdentity.isWholeDisk($0) }
        return whole
    }
}

// MARK: - C callback trampolines

/// DiskArbitration C callback for an appeared disk; hops onto the actor.
private func diskAppearedCallback(
    disk: DADisk,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    guard let bsdNamePointer = DADiskGetBSDName(disk) else { return }
    let bsdName = String(cString: bsdNamePointer)
    let enumerator = Unmanaged<DiskEnumerator>.fromOpaque(context).takeUnretainedValue()
    Task { await enumerator.handleAppeared(bsdName: bsdName) }
}

/// DiskArbitration C callback for a disappeared disk; hops onto the actor.
private func diskDisappearedCallback(
    disk: DADisk,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    guard let bsdNamePointer = DADiskGetBSDName(disk) else { return }
    let bsdName = String(cString: bsdNamePointer)
    let enumerator = Unmanaged<DiskEnumerator>.fromOpaque(context).takeUnretainedValue()
    Task { await enumerator.handleDisappeared(bsdName: bsdName) }
}
