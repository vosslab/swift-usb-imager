/// FlashState.swift - four-panel state machine for the USB imager UI.
///
/// Panels in order: source -> target -> flash -> verify.
///
/// The enum models every stable resting point and every transient phase.
/// `AppViewModel` is the sole writer; SwiftUI views are read-only observers.

import DiskModel
import Foundation
import HelperProtocol
import USBImagerCore

// MARK: - OfficialChecksumSource

/// How the user supplied the expected checksum for the source image.
public enum OfficialChecksumSource: Sendable, Equatable {
    /// User pasted a raw 128-hex-char SHA-512 string.
    case pastedHex(hexString: String)
    /// User loaded a SHA512SUMS file; we matched by source filename.
    case sha512SumsFile(body: String)
}

// MARK: - ChecksumMatchOutcome

/// Result of comparing the device SHA-512 to an official (expected) digest.
public enum ChecksumMatchOutcome: Sendable, Equatable {
    /// Device hash matches the official expected digest.
    case officialMatch
    /// Device hash does not match the official digest.
    case officialMismatch
    /// The device hash was found in the Keychain trusted-checksum cache.
    case trustedCacheHit
    /// No official checksum was supplied; cannot compare.
    case noOfficialChecksum
}

// MARK: - FlashProgressSnapshot

/// Human-readable snapshot of in-progress flash/verify state.
///
/// Derived by `AppViewModel` on every `FlashProgress` update; views bind
/// directly to these pre-formatted strings so the view layer has zero math.
public struct FlashProgressSnapshot: Sendable, Equatable {

    /// Fraction complete in [0, 1]; derived from `bytesDone / totalBytes`.
    /// Clamps to 0 when `totalBytes` is 0 to avoid division by zero.
    public let fraction: Double

    /// Bytes done in this phase.
    public let bytesDone: UInt64

    /// Total bytes for this phase.
    public let totalBytes: UInt64

    /// Current phase label for display (e.g. "Writing", "Verifying").
    public let phaseLabel: String

    /// Human-readable throughput string, e.g. "42.3 MB/s". Empty when not
    /// yet calculable (first update or zero elapsed time).
    public let speedLabel: String

    /// Human-readable bytes-done string, e.g. "1.2 GB / 7.9 GB".
    public let transferLabel: String

    // MARK: - Construction

    /// Build a snapshot from a raw `FlashProgress` value plus timing context.
    ///
    /// - Parameters:
    ///   - progress: the raw progress event from the helper.
    ///   - startDate: wall-clock time when the current phase began.
    ///   - now: current wall-clock time (injectable for tests).
    public static func make(
        from progress: FlashProgress,
        phaseStart: Date,
        now: Date = Date()
    ) -> FlashProgressSnapshot {
        let total = progress.totalBytes
        let done = progress.bytesDone
        let fraction: Double
        if total > 0 {
            fraction = min(1.0, Double(done) / Double(total))
        } else {
            fraction = 0
        }
        let elapsed = now.timeIntervalSince(phaseStart)
        let speedLabel: String
        if elapsed > 0 && done > 0 {
            let bytesPerSecond = Double(done) / elapsed
            speedLabel = formatBytes(UInt64(bytesPerSecond)) + "/s"
        } else {
            speedLabel = ""
        }
        let phaseLabel = Self.label(for: progress.phase)
        let transferLabel = formatBytes(done) + " / " + formatBytes(total)
        return FlashProgressSnapshot(
            fraction: fraction,
            bytesDone: done,
            totalBytes: total,
            phaseLabel: phaseLabel,
            speedLabel: speedLabel,
            transferLabel: transferLabel
        )
    }

    /// Build a snapshot from a numeric core `FlashProgressData` value plus timing.
    ///
    /// This is the path used by `AppViewModel` once the workflow moved to
    /// `USBImagerCore`: the core flash service emits numeric `FlashProgressData`
    /// samples, and this view-layer factory formats them into display strings.
    /// The core `Phase` is intentionally narrower than the helper `FlashPhase`
    /// (only `.writing`/`.verifying`); its label mapping lives here.
    ///
    /// - Parameters:
    ///   - data: the numeric progress sample from the core flash service.
    ///   - phaseStart: wall-clock time when the current phase began.
    ///   - now: current wall-clock time (injectable for tests).
    public static func make(
        from data: FlashProgressData,
        phaseStart: Date,
        now: Date = Date()
    ) -> FlashProgressSnapshot {
        let total = data.totalBytes
        let done = data.bytesDone
        let fraction: Double
        if total > 0 {
            fraction = min(1.0, Double(done) / Double(total))
        } else {
            fraction = 0
        }
        let elapsed = now.timeIntervalSince(phaseStart)
        let speedLabel: String
        if elapsed > 0 && done > 0 {
            let bytesPerSecond = Double(done) / elapsed
            speedLabel = formatBytes(UInt64(bytesPerSecond)) + "/s"
        } else {
            speedLabel = ""
        }
        let phaseLabel = Self.label(for: data.phase)
        let transferLabel = formatBytes(done) + " / " + formatBytes(total)
        return FlashProgressSnapshot(
            fraction: fraction,
            bytesDone: done,
            totalBytes: total,
            phaseLabel: phaseLabel,
            speedLabel: speedLabel,
            transferLabel: transferLabel
        )
    }

    // MARK: - Private helpers

    /// Human-readable phase label for a core progress-bar phase.
    private static func label(for phase: FlashProgressData.Phase) -> String {
        switch phase {
        case .writing:
            return "Writing"
        case .verifying:
            return "Verifying"
        }
    }

    /// Human-readable phase label suitable for a progress heading.
    private static func label(for phase: FlashPhase) -> String {
        switch phase {
        case .unmounting:
            return "Unmounting"
        case .writing:
            return "Writing"
        case .verifying:
            return "Verifying"
        case .done:
            return "Done"
        }
    }
}

// MARK: - FlashState

/// The complete state of one flash session.
///
/// The enum advances forward through the four panels; only `AppViewModel`
/// transitions between cases. The `.idle` case is the initial state and the
/// state after a successful verify or explicit reset.
public enum FlashState: Sendable {

    // MARK: - Panel 1: source selection (idle / source chosen)

    /// No image selected yet. The UI shows the source-picker panel.
    case idle

    /// An image file has been selected but no target has been chosen.
    ///
    /// - Parameter url: The URL of the selected disk image.
    case sourceSelected(url: URL)

    // MARK: - Panel 2: target selection

    /// A target disk has been chosen; waiting for the user to confirm and start.
    ///
    /// - Parameters:
    ///   - sourceURL: The selected disk image URL.
    ///   - target: The chosen write target.
    case targetSelected(sourceURL: URL, target: TargetInfo)

    /// The user has tapped "Flash" and a final confirmation is being shown.
    ///
    /// - Parameters:
    ///   - sourceURL: The selected disk image URL.
    ///   - target: The chosen write target.
    case confirming(sourceURL: URL, target: TargetInfo)

    // MARK: - Panel 3: flash in progress

    /// A flash job is running. Progress is updated on every `FlashProgress` event.
    ///
    /// - Parameter snapshot: Current progress snapshot with pre-formatted strings.
    case flashing(snapshot: FlashProgressSnapshot)

    // MARK: - Panel 4: verify / result

    /// The flash completed and the device hash is being compared.
    ///
    /// - Parameter snapshot: Final progress snapshot shown while comparing hashes.
    case verifying(snapshot: FlashProgressSnapshot)

    /// Flash + verify succeeded.
    ///
    /// - Parameters:
    ///   - deviceSHA512: The SHA-512 the helper computed from the written bytes.
    ///   - matchOutcome: How the device hash compared to official / cached values.
    case succeeded(deviceSHA512: String, matchOutcome: ChecksumMatchOutcome)

    /// Flash failed with a human-readable message.
    case failed(message: String)

    /// The user cancelled the flash.
    case cancelled
}

// MARK: - TargetInfo

/// Lightweight bundle of information about the chosen write target, carried
/// through the `.targetSelected` and `.confirming` states.
public struct TargetInfo: Sendable, Equatable {
    /// The chosen disk descriptor.
    public let disk: DiskDescriptor
    /// Human-readable display name, e.g. "SanDisk Ultra 32 GB (disk4)".
    public let displayName: String

    public init(disk: DiskDescriptor, displayName: String) {
        self.disk = disk
        self.displayName = displayName
    }
}

// MARK: - FlashState convenience predicates

extension FlashState {

    /// `true` when the state allows the user to select a new source image.
    public var canSelectSource: Bool {
        switch self {
        case .idle, .sourceSelected, .targetSelected, .confirming,
             .succeeded, .failed, .cancelled:
            return true
        case .flashing, .verifying:
            return false
        }
    }

    /// `true` when a flash job is actively running.
    public var isActive: Bool {
        switch self {
        case .flashing, .verifying:
            return true
        default:
            return false
        }
    }

    /// `true` when the state is a terminal outcome (succeeded/failed/cancelled).
    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        default:
            return false
        }
    }

    /// The 1-based panel that is the current step (the single loud/focused panel).
    /// idle -> 1 (Source), sourceSelected -> 2 (Target),
    /// targetSelected/confirming/flashing -> 3 (Flash),
    /// verifying/succeeded/failed/cancelled -> 4 (Verify).
    public var currentStep: Int {
        switch self {
        case .idle:
            return 1
        case .sourceSelected:
            return 2
        case .targetSelected, .confirming, .flashing:
            return 3
        case .verifying, .succeeded, .failed, .cancelled:
            return 4
        }
    }
}
