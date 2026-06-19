/// Services.swift - the shared service protocol seam for `USBImagerCore`.
///
/// Declares the service protocols all front ends and the core itself depend on.
/// Concrete implementations live in the named service files:
///
///   - `ChecksumService`            -> Sources/USBImagerCore/ChecksumService.swift
///   - `DiskTargetService` and `ImageSourceService`
///                                  -> Sources/USBImagerCore/DiskTargetService.swift,
///                                     Sources/USBImagerCore/ImageSourceService.swift
///   - `FlashOrchestrationService`  -> Sources/USBImagerCore/FlashOrchestrationService.swift
///
/// Boundary rules these protocols encode (from the plan):
///   - Service boundaries stay small: one service per concern, no mega-service.
///   - Core performs storage operations (Keychain lookup/save) but never decides
///     "offer to save"; that user-intent stays in the GUI/CLI front end.
///   - Core re-uses `DiskModel`/`Verifier`/`FlashEngine`/`KeychainStore`; it does
///     not re-implement safety rules, hashing, or flash logic.
///   - No SwiftUI/AppKit anywhere in this target.
///
/// The protocols are `async` where the underlying work touches an actor
/// (`FlashEngine`, `DiskEnumerator`) so a non-isolated core never forces
/// `@MainActor`. Methods that are pure stay synchronous.

import DiskModel
import FlashEngine
import Foundation
import KeychainStore
import Verifier

// MARK: - ChecksumService

/// Outcome of comparing a flashed/expected digest against the trust sources.
///
/// Mirrors the GUI's `ChecksumMatchOutcome` in numeric/categorical terms so the
/// view model can map straight onto its presentation enum. `ChecksumService`
/// returns this from `matchOutcome`; the front end decides how to render each case.
public enum ChecksumMatchOutcome: Equatable, Sendable {

    /// An official (user-supplied) checksum was provided and the digest matched.
    case officialMatch

    /// An official checksum was provided and the digest did NOT match.
    case officialMismatch

    /// No official checksum, but the digest is present in the Keychain trusted
    /// cache for this image byte length.
    case trustedCacheHit

    /// No official checksum and no trusted-cache hit; nothing to compare against.
    case noOfficialChecksum
}

/// Parse/validate checksums, match by filename, compare digests, and read/write
/// the Keychain trusted-cache. Wraps `Verifier` and `KeychainStore`.
///
/// Ownership: this service performs the storage operations (`lookupTrustedCache`,
/// `saveTrustedCache`); it never auto-saves and never decides whether to offer
/// saving. The caller owns that intent and invokes `saveTrustedCache` explicitly.
///
/// All methods are synchronous and side-effect-free except the two Keychain
/// methods, which touch the injected `KeychainStore` backend (an in-memory
/// backend in tests).
public protocol ChecksumService: Sendable {

    /// Validate a pasted SHA-512 hex string (128 hex chars) into a digest.
    ///
    /// - Parameter hexString: the pasted hex, with or without surrounding
    ///   whitespace and case-insensitive.
    /// - Returns: the parsed `SHA512Digest`.
    /// - Throws: `CoreError.badInput` when the string is not a valid SHA-512 hex.
    func validatePastedHex(_ hexString: String) throws -> SHA512Digest

    /// Parse a `SHA512SUMS` file body and return the digest matching `filename`.
    ///
    /// - Parameters:
    ///   - body: the raw `SHA512SUMS` text (one `digest  filename` line each).
    ///   - filename: the image filename to match (compared by last path component).
    /// - Returns: the `SHA512Digest` whose line matches `filename`.
    /// - Throws: `CoreError.badInput` when the body is unparsable or has no line
    ///   for `filename`.
    func expectedDigest(fromSums body: String, matching filename: String) throws -> SHA512Digest

    /// Compare a device/computed digest against an expected digest.
    ///
    /// - Parameters:
    ///   - deviceDigest: the digest the helper computed by reading back the device
    ///     (or the digest the CLI computed over the source file).
    ///   - expected: the expected digest to compare against.
    /// - Returns: `true` when the two digests are equal.
    func matches(deviceDigest: SHA512Digest, expected: SHA512Digest) -> Bool

    /// Resolve the match outcome against the available trust sources.
    ///
    /// Priority order (fixed): an official digest, then the Keychain trusted
    /// cache, then `noOfficialChecksum`.
    ///
    /// - Parameters:
    ///   - deviceDigest: the digest to evaluate.
    ///   - officialDigest: the user-supplied expected digest, or `nil`.
    ///   - imageByteLength: the source image byte length, used as the cache key
    ///     alongside the digest.
    /// - Returns: the resolved `ChecksumMatchOutcome`.
    func matchOutcome(
        deviceDigest: SHA512Digest,
        officialDigest: SHA512Digest?,
        imageByteLength: Int
    ) -> ChecksumMatchOutcome

    /// Look up a trusted checksum in the Keychain cache.
    ///
    /// - Parameters:
    ///   - digest: the digest key.
    ///   - imageByteLength: the image byte-length key.
    /// - Returns: the cached `TrustedChecksum`, or `nil` on a cache miss.
    /// - Throws: a `CoreError` if the Keychain backend errors unexpectedly.
    func lookupTrustedCache(digest: SHA512Digest, imageByteLength: Int) throws -> TrustedChecksum?

    /// Save a trusted checksum to the Keychain cache.
    ///
    /// The caller decides whether and when to call this; the service never
    /// auto-saves. A duplicate-item condition is treated as success (already
    /// cached is fine).
    ///
    /// - Parameter checksum: the entry to persist.
    /// - Throws: a `CoreError` if the Keychain backend errors (other than a
    ///   duplicate, which is swallowed).
    func saveTrustedCache(_ checksum: TrustedChecksum) throws

    /// Compute the SHA-512 digest of a source image FILE by streaming it.
    ///
    /// The file is read in fixed-size chunks and fed through the incremental
    /// `SHA512Hasher` so a multi-gigabyte image is never loaded into memory at
    /// once. This is the CLI `verify` path: hash the source file and compare it
    /// against an expected digest. The result is byte-for-byte identical to
    /// `Verifier.sha512(of:)` over the same bytes.
    ///
    /// - Parameter url: a `file:`-backed URL to a local image file.
    /// - Returns: the file's `SHA512Digest`.
    /// - Throws: `CoreError.badInput` when the file is missing or unreadable.
    func sha512(ofFileAt url: URL) throws -> SHA512Digest
}

// MARK: - ImageSourceService

/// Stat an image file for the workflow.
///
/// Implemented by wrapping `FileManager`. It performs no hashing and no disk
/// safety logic.
public protocol ImageSourceService: Sendable {

    /// Return the byte length of the file at `url`.
    ///
    /// - Parameter url: a `file:`-backed URL to a local image file.
    /// - Returns: the file's byte length.
    /// - Throws: `CoreError.badInput` when the file is missing or unreadable.
    func byteLength(of url: URL) throws -> Int
}

// MARK: - DiskTargetService

/// Enumerate disks and filter them to safe write targets, reusing `DiskModel`.
///
/// Re-uses `DiskEnumerator.snapshot()` and `validTargets(...)`; does NOT
/// re-implement any safety rule. The display name is the one stable, GUI-neutral
/// formatting helper core owns (the GUI's row formatting and the CLI's `list`
/// row formatting both build on it).
public protocol DiskTargetService: Sendable {

    /// Snapshot all currently attached whole disks.
    ///
    /// - Returns: the full disk list (unfiltered).
    func snapshotDisks() async -> [DiskDescriptor]

    /// Resolve a single disk by its BSD name (e.g. "disk4").
    ///
    /// Takes a fresh snapshot and returns the first disk whose `bsdName` equals
    /// `bsdName`. This is the CLI `flash` path: the user names a target by its
    /// BSD name and core turns that string into the matching `DiskDescriptor`.
    ///
    /// - Parameter bsdName: the BSD name to match exactly.
    /// - Returns: the matching `DiskDescriptor`, or `nil` when no attached disk
    ///   has that BSD name.
    func diskDescriptor(withBSDName bsdName: String) async -> DiskDescriptor?

    /// Filter `disks` to the safe write targets for an image of the given size.
    ///
    /// Delegates to `DiskModel.validTargets(from:imageSizeBytes:sourceBackingBSDName:)`.
    ///
    /// - Parameters:
    ///   - disks: the candidate disks (typically from `snapshotDisks`).
    ///   - imageSizeBytes: the image byte length the target must hold.
    ///   - sourceBackingBSDName: the BSD name of the disk the source lives on, or
    ///     `nil` when the source is a plain file.
    /// - Returns: the subset of `disks` that are safe targets.
    func validTargets(
        from disks: [DiskDescriptor],
        imageSizeBytes: Int,
        sourceBackingBSDName: String?
    ) -> [DiskDescriptor]

    /// A stable, GUI-neutral display name for a disk (e.g. for a list row).
    ///
    /// - Parameter disk: the disk to describe.
    /// - Returns: a human-readable single-line name.
    func displayName(for disk: DiskDescriptor) -> String
}

// MARK: - FlashOrchestrationService

/// Terminal result of a flash orchestration run.
///
/// The typed, front-end-neutral outcome returned by `FlashOrchestrationService.flash`:
/// a success carries the helper-derived device digest; a failure/cancel carries
/// the typed `CoreError` the CLI maps to an exit code and the GUI maps to UI
/// state.
public enum FlashRunResult: Equatable, Sendable {

    /// The write (and read-back, when requested) completed. `deviceSHA512` is the
    /// helper-derived ground-truth digest, lowercase hex.
    case success(deviceSHA512: String)

    /// The run did not succeed. `error` is the typed reason (helper-unavailable,
    /// flash-failed, cancelled, mismatch, or bad input).
    case failure(error: CoreError)
}

/// A factory the orchestration service uses to obtain a `FlashEngine`.
///
/// Injecting the engine (rather than constructing an `XPCHelperConnection`
/// inline) lets tests drive a fake `HelperConnection` -- including the
/// helper-absent path -- with no real device or install. Production passes a
/// factory that builds an engine over an `XPCHelperConnection`.
public protocol FlashEngineFactory: Sendable {

    /// Create a fresh `FlashEngine` for one flash session.
    ///
    /// - Returns: a new engine.
    /// - Throws: `CoreError.helperUnavailable` when the helper connection cannot
    ///   be established (the no-helper path the CLI maps to exit code 3).
    func makeEngine() throws -> FlashEngine
}

/// Drive `FlashEngine`, surface progress as `FlashProgressData`, support cancel,
/// and return a typed `FlashRunResult`. Maps `FlashEngineError` to a message via
/// the core `userMessage(for:)` function.
///
/// The service is an `async` boundary because it hops to the `FlashEngine`
/// actor; it does not adopt `@MainActor`.
public protocol FlashOrchestrationService: Sendable {

    /// Flash `source` onto `target`, emitting numeric progress and returning a
    /// typed result.
    ///
    /// - Parameters:
    ///   - source: the `file:`-backed image URL. Bytes never enter core; the
    ///     helper opens the file itself.
    ///   - target: the whole-disk descriptor to write.
    ///   - advisorySHA512: optional expected source digest, lowercase hex, for UI
    ///     feedback only (not a safety gate).
    ///   - verifyReadBack: when `true`, the run performs device read-back
    ///     verification (the `flash --verify` path) and a mismatch yields
    ///     `.failure(.verificationMismatch)`.
    ///   - progress: invoked for each numeric progress sample. May be called on
    ///     any task; the caller marshals to its own isolation.
    /// - Returns: the terminal `FlashRunResult`.
    func flash(
        source: URL,
        target: DiskDescriptor,
        advisorySHA512: String?,
        verifyReadBack: Bool,
        progress: @escaping @Sendable (FlashProgressData) -> Void
    ) async -> FlashRunResult

    /// Request cancellation of the in-flight flash, if any.
    ///
    /// Best-effort; the authoritative outcome still arrives as a
    /// `.failure(.cancelled)` from the originating `flash` call.
    func cancel() async
}

// MARK: - Default implementations

/// Default file-hashing implementation shared by all `ChecksumService` conformers.
///
/// Lives in a protocol extension so adding `sha512(ofFileAt:)` does not force
/// every conformer (production, GUI stub, CLI fake) to write its own body. The
/// logic is pure -- it depends only on `Verifier.SHA512Hasher` -- so it does not
/// need any conformer state.
extension ChecksumService {

    /// Compute the SHA-512 digest of a source image file by streaming it.
    ///
    /// Reads the file in fixed-size 1 MiB chunks through the incremental
    /// `SHA512Hasher` and finalizes, so a multi-gigabyte image is hashed without
    /// loading it into memory at once. The result matches `Verifier.sha512(of:)`
    /// over the same bytes (the streaming path and one-shot path are equivalent).
    ///
    /// - Parameter url: a `file:`-backed URL to a local image file.
    /// - Returns: the file's `SHA512Digest`.
    /// - Throws: `CoreError.badInput` when the file is missing or unreadable.
    public func sha512(ofFileAt url: URL) throws -> SHA512Digest {
        // Open the file for reading; a missing/unreadable path surfaces as badInput.
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw CoreError.badInput(message: "Could not open file for hashing at \"\(url.path)\": \(error).")
        }
        // Always close the handle, on success or on a read error.
        defer {
            try? handle.close()
        }
        // Stream the file 1 MiB at a time through the incremental hasher.
        let chunkSize = 1 << 20  // 1 MiB
        var hasher = SHA512Hasher()
        do {
            // read(upToCount:) returns nil at end-of-file, an empty Data for a
            // zero-length file, and otherwise the next chunk (<= chunkSize bytes).
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                hasher.update(chunk)
            }
        } catch {
            throw CoreError.badInput(message: "Failed to read file for hashing at \"\(url.path)\": \(error).")
        }
        // Finalize after the last chunk; equivalent to one-shot sha512(of:).
        let digest = hasher.finalize()
        return digest
    }

    /// Hash a source image file and return the digest as a lowercase hex string.
    ///
    /// Convenience wrapper over `sha512(ofFileAt:)` that formats the digest so
    /// callers in the CLI target can work with plain strings without naming the
    /// `SHA512Digest` Verifier type directly (the CLI target depends on
    /// `USBImagerCore + ArgumentParser` only -- no direct `Verifier` dependency).
    ///
    /// - Parameter url: a `file:`-backed URL to a local image file.
    /// - Returns: the 128-character lowercase hex SHA-512 string.
    /// - Throws: `CoreError.badInput` when the file is missing or unreadable.
    public func sha512Hex(ofFileAt url: URL) throws -> String {
        let digest = try sha512(ofFileAt: url)
        return digest.hexString
    }

    /// Parse a `SHA512SUMS` file body and return the digest for the given filename
    /// as a lowercase hex string.
    ///
    /// Convenience for CLI callers that work with plain strings. Delegates to
    /// `expectedDigest(fromSums:matching:)` and formats the result.
    ///
    /// - Parameters:
    ///   - body: raw text from a `sha512sum`-produced file.
    ///   - filename: the image filename or full path to match.
    /// - Returns: the 128-character lowercase hex SHA-512 for the matching entry.
    /// - Throws: `CoreError.badInput` on parse failure or no match.
    public func expectedDigestHex(fromSums body: String, matching filename: String) throws -> String {
        let digest = try expectedDigest(fromSums: body, matching: filename)
        return digest.hexString
    }

    /// Validate a pasted SHA-512 hex string and return it normalized (lowercase,
    /// trimmed) when valid, or throw `CoreError.badInput` when malformed.
    ///
    /// Convenience for CLI callers that want to validate user input and get back
    /// a canonical hex string without holding a `SHA512Digest` value.
    ///
    /// - Parameter hexString: the raw pasted string.
    /// - Returns: the validated 128-character lowercase hex string.
    /// - Throws: `CoreError.badInput` when the input is not a valid SHA-512 hex.
    public func validatePastedHexString(_ hexString: String) throws -> String {
        let digest = try validatePastedHex(hexString)
        return digest.hexString
    }

    /// Compare two digests supplied as lowercase hex strings and return whether
    /// they match.
    ///
    /// Convenience for CLI callers that hold hex strings rather than `SHA512Digest`
    /// values. Returns `false` when either string is malformed (rather than
    /// throwing, since a malformed input is caught earlier in the verify flow by
    /// `validatePastedHexString`).
    ///
    /// - Parameters:
    ///   - computedHex: the 128-character lowercase hex computed from the image.
    ///   - expectedHex: the 128-character lowercase hex supplied by the user.
    /// - Returns: `true` when both parse successfully and the digests are equal.
    public func hexDigestsMatch(computedHex: String, expectedHex: String) -> Bool {
        // Both hex strings must parse to valid SHA512Digest values to compare.
        guard
            let computed = SHA512Digest(hexString: computedHex),
            let expected = SHA512Digest(hexString: expectedHex)
        else {
            return false
        }
        return matches(deviceDigest: computed, expected: expected)
    }
}

/// Default BSD-name lookup shared by all `DiskTargetService` conformers.
///
/// Lives in a protocol extension so adding `diskDescriptor(withBSDName:)` does not
/// force every conformer to write its own body. It composes the existing
/// `snapshotDisks()` requirement with the pure `firstDescriptor(withBSDName:in:)`
/// matching helper, so a conformer that controls `snapshotDisks()` (a test fake)
/// controls the lookup result without a live DiskArbitration session.
extension DiskTargetService {

    /// Resolve a single disk by its BSD name (e.g. "disk4").
    ///
    /// Takes a fresh snapshot via `snapshotDisks()` and returns the first disk
    /// whose `bsdName` equals `bsdName`, else `nil`.
    ///
    /// - Parameter bsdName: the BSD name to match exactly.
    /// - Returns: the matching `DiskDescriptor`, or `nil` on no match.
    public func diskDescriptor(withBSDName bsdName: String) async -> DiskDescriptor? {
        // Snapshot, then apply the pure file-scope matching helper.
        let disks = await snapshotDisks()
        return firstDescriptor(withBSDName: bsdName, in: disks)
    }
}
