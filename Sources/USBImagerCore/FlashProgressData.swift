/// FlashProgressData - GUI-neutral, numeric-only progress value for a flash job.
///
/// This is the single shared progress meaning for the whole workflow. Both the
/// SwiftUI GUI and the `usbimager` CLI consume `FlashProgressData` and format
/// their own display from these numbers: the GUI builds its
/// `FlashProgressSnapshot` display strings, the CLI prints its own status lines.
/// Keeping a numbers-only type here stops the two front ends from inventing
/// parallel progress meanings.
///
/// Design rules (frozen; consumers must not change these):
///   - No display strings. No localized text, no percent-formatted strings, no
///     human-readable phase names. Only enum + numeric fields live here.
///   - `Phase` is intentionally narrower than the helper's `FlashPhase`. The
///     workflow surfaces only the two phases a front end renders a progress bar
///     for -- writing and verifying. The helper's `.unmounting` and `.done`
///     phases are lifecycle states the orchestration service maps away; they are
///     not progress-bar phases and so are not part of this type.
///   - `fraction` is optional because a phase may report progress before its
///     `totalBytes` denominator is known (a zero/unknown total yields `nil`
///     rather than a divide-by-zero or a misleading 0.0).

import Foundation

// MARK: - FlashProgressData

/// One numeric progress sample for an in-flight flash job.
///
/// The flash orchestration service maps each helper `FlashProgress` into a
/// `FlashProgressData`. Consumers compute their own display from the numeric
/// fields.
public struct FlashProgressData: Equatable, Sendable {

    // MARK: - Phase

    /// The progress-bar phase of a flash job, GUI-neutral.
    ///
    /// Only the two phases a front end renders progress for appear here. This is
    /// deliberately a subset of the helper's `FlashPhase`; the orchestration
    /// service owns the mapping from helper phases to these cases.
    public enum Phase: String, Equatable, Sendable, CaseIterable {

        /// Streaming source bytes to the raw device.
        case writing

        /// Re-reading the written device and hashing to verify it.
        case verifying
    }

    /// The current progress-bar phase.
    public let phase: Phase

    /// Bytes processed so far within the current phase's denominator.
    public let bytesDone: UInt64

    /// Total bytes for the current phase. May be `0` when the helper has not yet
    /// reported a denominator for this phase.
    public let totalBytes: UInt64

    /// Completed fraction in `0.0...1.0` for the current phase, or `nil` when
    /// `totalBytes` is unknown (zero) so a meaningful fraction cannot be formed.
    ///
    /// Provided as a stored, optional field rather than a computed property so
    /// the orchestration service decides exactly when a fraction is meaningful;
    /// consumers never have to guard a divide-by-zero themselves.
    public let fraction: Double?

    // MARK: - Init

    /// Designated initializer with an explicit fraction.
    ///
    /// - Parameters:
    ///   - phase: the progress-bar phase this sample belongs to.
    ///   - bytesDone: bytes processed so far in the current phase.
    ///   - totalBytes: total bytes for the current phase (`0` when unknown).
    ///   - fraction: completed fraction, or `nil` when no denominator exists.
    public init(phase: Phase, bytesDone: UInt64, totalBytes: UInt64, fraction: Double?) {
        self.phase = phase
        self.bytesDone = bytesDone
        self.totalBytes = totalBytes
        self.fraction = fraction
    }

    /// Convenience initializer that derives `fraction` from the byte counts.
    ///
    /// `fraction` is `nil` when `totalBytes` is `0` (no denominator), and
    /// otherwise `bytesDone / totalBytes` clamped to `0.0...1.0`. This is the
    /// expected construction path for the orchestration service when mapping a
    /// helper `FlashProgress`; the explicit initializer above stays available for
    /// callers that compute a fraction by other means.
    ///
    /// - Parameters:
    ///   - phase: the progress-bar phase this sample belongs to.
    ///   - bytesDone: bytes processed so far in the current phase.
    ///   - totalBytes: total bytes for the current phase (`0` when unknown).
    public init(phase: Phase, bytesDone: UInt64, totalBytes: UInt64) {
        let derivedFraction: Double?
        if totalBytes == 0 {
            // No denominator yet: report no fraction rather than a fake 0.0.
            derivedFraction = nil
        } else {
            let ratio = Double(bytesDone) / Double(totalBytes)
            // Clamp to the unit interval; a helper may briefly report bytesDone
            // slightly past totalBytes at a phase boundary.
            derivedFraction = min(1.0, max(0.0, ratio))
        }
        self.init(
            phase: phase,
            bytesDone: bytesDone,
            totalBytes: totalBytes,
            fraction: derivedFraction
        )
    }
}
