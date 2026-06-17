/// FlashTypes: the Codable control-plane value types shared across the XPC
/// boundary between the unprivileged app and the privileged helper.
///
/// These are CONTROL data only. No image bytes appear in any of these types.
/// The helper opens the source file itself and streams bytes directly to the
/// target device.
///
/// SAFETY NOTE on advisory fields: `FlashRequest.advisorySizeBytes` and
/// `FlashRequest.advisorySHA512` are HINTS supplied by the app for UI feedback
/// (progress denominator, early sanity checks). They are NOT trusted. The
/// helper re-stats the real file for the true size and re-hashes the bytes it
/// actually wrote; `FlashResult.deviceSHA512` is the helper-derived truth.

import Foundation

// MARK: - JobID

/// Opaque identifier correlating a request with its progress and result.
///
/// Backed by a `UUID` string so it survives JSON encoding unambiguously and is
/// stable across the XPC boundary.
public struct JobID: Codable, Hashable, Sendable {

    /// The underlying identifier value.
    public let rawValue: String

    /// Wrap an existing identifier string (e.g. one received over XPC).
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Generate a fresh, unique job identifier.
    public static func generate() -> JobID {
        let generated = JobID(rawValue: UUID().uuidString)
        return generated
    }
}

// MARK: - SourceAccess

/// How the helper should obtain the bytes to write.
///
/// Only `.absolutePath` is wired now. `.fileDescriptor` and `.stageCopy` are
/// reserved for later milestones and are intentionally part of the enum today
/// so the wire format and call sites are shaped for them in advance:
///
///   - `.absolutePath(String)`: the helper opens the file at this path directly.
///     Simplest path; relies on the helper running as root to read the source.
///   - `.fileDescriptor`: the app will open the file and transfer an already-open
///     descriptor to the helper, so the helper inherits the app's access rights
///     without needing its own read permission. The associated payload is left
///     unspecified here because file-descriptor transfer is carried out-of-band
///     by `NSXPCConnection` machinery, not inside this Codable value; this case
///     is a marker that such a descriptor accompanies the message.
///   - `.stageCopy(String)`: the app first copies the source into a staging
///     location the helper can read, then passes that staging path. Used when
///     the original lives somewhere the helper must not touch directly.
///
/// The Codable representation is a tagged union: a `kind` discriminator plus an
/// optional `path`. This keeps JSON stable and lets new cases be added without
/// breaking older decoders that ignore unknown optional fields.
public enum SourceAccess: Codable, Hashable, Sendable {

    /// The helper opens the file at this absolute path.
    case absolutePath(String)

    /// Reserved: the app transfers an open file descriptor out-of-band.
    case fileDescriptor

    /// Reserved: the app stages a copy at this path for the helper to read.
    case stageCopy(String)

    // Tagged-union coding keys.
    private enum CodingKeys: String, CodingKey {
        case kind
        case path
    }

    // Stable discriminator strings for the `kind` field.
    private enum Kind: String, Codable {
        case absolutePath
        case fileDescriptor
        case stageCopy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .absolutePath:
            let path = try container.decode(String.self, forKey: .path)
            self = .absolutePath(path)
        case .fileDescriptor:
            self = .fileDescriptor
        case .stageCopy:
            let path = try container.decode(String.self, forKey: .path)
            self = .stageCopy(path)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absolutePath(let path):
            try container.encode(Kind.absolutePath, forKey: .kind)
            try container.encode(path, forKey: .path)
        case .fileDescriptor:
            try container.encode(Kind.fileDescriptor, forKey: .kind)
        case .stageCopy(let path):
            try container.encode(Kind.stageCopy, forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }
}

// MARK: - FlashRequest

/// A request to flash a source onto a target USB/disk device.
public struct FlashRequest: Codable, Hashable, Sendable {

    /// The job identity the app assigned to this session. The helper MUST echo
    /// this exact value in every `FlashProgress` and `FlashResult` it emits so
    /// the app can correlate events back to the originating request. The app
    /// generates it; the helper does not invent its own.
    public let jobID: JobID

    /// How the helper obtains the source bytes (path now; fd/stage later).
    public let sourceAccess: SourceAccess

    /// BSD device node name of the target, e.g. "disk4". The helper resolves
    /// this to the real device and applies its own safety checks before writing.
    public let targetBSDName: String

    /// BSD name of the disk the source image was read from, when the app could
    /// resolve it (`nil` when the source is a plain file with no distinct
    /// backing disk). Carried so the helper's `sourceOverlap` safety rule can
    /// fire when the source lives on a disk that is also a flash target. The
    /// helper treats this as an advisory hint and computes its own value too;
    /// neither side trusts the other for the final decision.
    public let sourceBackingBSDName: String?

    /// ADVISORY source size in bytes, for the progress denominator only.
    /// The helper re-stats the real file for the authoritative total.
    public let advisorySizeBytes: UInt64

    /// ADVISORY expected SHA-512 of the source, lowercase hex, for early UI
    /// sanity checks only. The helper re-hashes what it actually writes; this
    /// value is never trusted as a safety gate. Optional because the app may
    /// not have a checksum on hand.
    public let advisorySHA512: String?

    public init(jobID: JobID,
                sourceAccess: SourceAccess,
                targetBSDName: String,
                sourceBackingBSDName: String?,
                advisorySizeBytes: UInt64,
                advisorySHA512: String?) {
        self.jobID = jobID
        self.sourceAccess = sourceAccess
        self.targetBSDName = targetBSDName
        self.sourceBackingBSDName = sourceBackingBSDName
        self.advisorySizeBytes = advisorySizeBytes
        self.advisorySHA512 = advisorySHA512
    }
}

// MARK: - FlashProgress

/// Phase of a flash job, reported as it advances.
public enum FlashPhase: String, Codable, Hashable, Sendable {
    /// Unmounting any volumes on the target before writing.
    case unmounting
    /// Streaming bytes to the raw device.
    case writing
    /// Re-reading the device and hashing to verify the write.
    case verifying
    /// Job finished (terminal phase for progress reporting).
    case done
}

/// Incremental progress for an in-flight flash job.
public struct FlashProgress: Codable, Hashable, Sendable {

    /// Correlates this progress update with its originating request.
    public let jobID: JobID

    /// Bytes processed so far in the current phase's denominator.
    public let bytesDone: UInt64

    /// Total bytes for the current phase. Derived by the helper from the real
    /// source size, not from `FlashRequest.advisorySizeBytes`.
    public let totalBytes: UInt64

    /// Current phase of the job.
    public let phase: FlashPhase

    public init(jobID: JobID,
                bytesDone: UInt64,
                totalBytes: UInt64,
                phase: FlashPhase) {
        self.jobID = jobID
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
        self.phase = phase
    }
}

// MARK: - FlashResult

/// Terminal outcome category for a flash job.
public enum FlashOutcome: String, Codable, Hashable, Sendable {
    /// The write completed and verification succeeded.
    case success
    /// The job failed; see `FlashResult.errorMessage`.
    case failed
    /// The job was cancelled before completion.
    case cancelled
}

/// Final result of a flash (or verify) job.
public struct FlashResult: Codable, Hashable, Sendable {

    /// Correlates this result with its originating request.
    public let jobID: JobID

    /// Terminal outcome category.
    public let outcome: FlashOutcome

    /// SHA-512 the helper computed by reading the device/source back, lowercase
    /// hex. This is the helper-derived ground truth, not the advisory hash.
    /// Optional because a failed or cancelled job may not produce a digest.
    public let deviceSHA512: String?

    /// Human-readable failure detail when `outcome == .failed`. Optional.
    public let errorMessage: String?

    public init(jobID: JobID,
                outcome: FlashOutcome,
                deviceSHA512: String?,
                errorMessage: String?) {
        self.jobID = jobID
        self.outcome = outcome
        self.deviceSHA512 = deviceSHA512
        self.errorMessage = errorMessage
    }
}
