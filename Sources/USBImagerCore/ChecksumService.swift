/// ChecksumService.swift - concrete implementation of the `ChecksumService` protocol.
///
/// Wraps `Verifier` (validatePastedHex, ChecksumFile, SHA512Digest) and
/// `KeychainStore` (TrustedChecksum, lookup/save via an injected backend).
///
/// Ownership split: this service performs the storage operations (lookupTrustedCache,
/// saveTrustedCache) but never auto-saves and never decides "offer to save". The
/// caller owns that intent and invokes saveTrustedCache explicitly.
///
/// No SwiftUI/AppKit. All methods are synchronous and side-effect-free except the
/// two Keychain methods, which touch the injected KeychainStore backend.
import Foundation
import KeychainStore
import Verifier

// MARK: - DefaultChecksumService

/// The concrete `ChecksumService` implementation shipped by USBImagerCore.
///
/// Inject `KeychainStore(backend: InMemoryKeychainBackend())` in tests to avoid
/// Keychain entitlement requirements. The production path passes
/// `KeychainStore()` (the real Keychain via SecurityKeychainBackend).
public struct DefaultChecksumService: ChecksumService {

    // Injected Keychain storage backend.
    private let keychainStore: KeychainStore

    // MARK: - Init

    /// Create a service with the real Keychain backend.
    public init() {
        self.keychainStore = KeychainStore()
    }

    /// Create a service with an injected Keychain backend (for testing).
    ///
    /// - Parameter keychainStore: a `KeychainStore` wrapping an in-memory or
    ///   real backend. In tests, pass `KeychainStore(backend: InMemoryKeychainBackend())`.
    public init(keychainStore: KeychainStore) {
        self.keychainStore = keychainStore
    }

    // MARK: - ChecksumService conformance

    /// Validate a pasted SHA-512 hex string (128 hex chars) into a digest.
    ///
    /// Strips surrounding whitespace and accepts upper- or lowercase hex. Throws
    /// `CoreError.badInput` when the string is not a valid 128-character hex digest.
    ///
    /// - Parameter hexString: the raw pasted string, trimmed before validation.
    /// - Returns: a `SHA512Digest` on success.
    /// - Throws: `CoreError.badInput(message:)` on malformed input.
    public func validatePastedHex(_ hexString: String) throws -> SHA512Digest {
        // Trim surrounding whitespace so copy-paste from browser pages works.
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // Verifier.validatePastedHex throws ChecksumFileError.invalidHexString on failure.
            return try Verifier.validatePastedHex(trimmed)
        } catch {
            // Map the Verifier-level error to the core-level typed error.
            throw CoreError.badInput(message: "Invalid SHA-512 hex digest: expected 128 hex characters, got \"\(trimmed)\".")
        }
    }

    /// Parse a SHA512SUMS file body and return the digest for the given filename.
    ///
    /// The `filename` is matched by last path component so a full path such as
    /// `/tmp/ubuntu.iso` matches a `SHA512SUMS` entry for `ubuntu.iso`. Throws
    /// `CoreError.badInput` when the body is unparsable or no entry matches.
    ///
    /// - Parameters:
    ///   - body: raw text from a `sha512sum`-produced file.
    ///   - filename: the image filename or full path to match.
    /// - Returns: the `SHA512Digest` for the matching entry.
    /// - Throws: `CoreError.badInput(message:)` on parse failure or no match.
    public func expectedDigest(fromSums body: String, matching filename: String) throws -> SHA512Digest {
        // Match by last path component so "/tmp/ubuntu.iso" finds "ubuntu.iso".
        let base = URL(fileURLWithPath: filename).lastPathComponent
        let checksumFile: ChecksumFile
        do {
            // ChecksumFile.init throws ChecksumFileError.malformedLine on bad lines.
            checksumFile = try ChecksumFile(sha512SumsBody: body)
        } catch {
            throw CoreError.badInput(message: "Could not parse the SHA512SUMS file body: \(error).")
        }
        do {
            // expectedDigest(for:) throws ChecksumFileError.filenameNotFound when missing.
            return try checksumFile.expectedDigest(for: base)
        } catch {
            throw CoreError.badInput(message: "No checksum entry found for \"\(base)\" in the SHA512SUMS file.")
        }
    }

    /// Compare a device/computed digest against an expected digest.
    ///
    /// - Parameters:
    ///   - deviceDigest: the digest computed from the device or source file.
    ///   - expected: the expected digest to compare against.
    /// - Returns: `true` when the digests are equal.
    public func matches(deviceDigest: SHA512Digest, expected: SHA512Digest) -> Bool {
        deviceDigest == expected
    }

    /// Resolve the match outcome against available trust sources.
    ///
    /// Priority order (fixed by the plan):
    ///   1. If an official digest is provided, compare and return `.officialMatch` or
    ///      `.officialMismatch` regardless of the Keychain cache.
    ///   2. If no official digest, look up the device digest in the Keychain trusted
    ///      cache. A hit returns `.trustedCacheHit`.
    ///   3. Nothing to compare against: return `.noOfficialChecksum`.
    ///
    /// A genuine Keychain access failure during the cache probe is distinguished
    /// from a true miss. `keychainStore.lookup` returns `nil` for a real miss (the
    /// digest is simply not cached) and throws only on an access error. A real
    /// access error is propagated as `CoreError.badInput` so the caller can surface
    /// it; it is NOT collapsed into `.noOfficialChecksum`, which would silently
    /// downgrade a verification verdict.
    ///
    /// - Parameters:
    ///   - deviceDigest: the digest to evaluate.
    ///   - officialDigest: the user-supplied expected digest, or `nil`.
    ///   - imageByteLength: the image byte length used as the Keychain cache key.
    /// - Returns: the resolved `ChecksumMatchOutcome`.
    /// - Throws: `CoreError.badInput` when the Keychain cache probe fails for a
    ///   reason other than a true miss.
    public func matchOutcome(
        deviceDigest: SHA512Digest,
        officialDigest: SHA512Digest?,
        imageByteLength: Int
    ) throws -> ChecksumMatchOutcome {
        // Priority 1: official digest provided -- compare and return immediately.
        if let official = officialDigest {
            return deviceDigest == official ? .officialMatch : .officialMismatch
        }
        // Priority 2: no official digest -- probe the Keychain trusted cache.
        // A true miss returns nil (-> noOfficialChecksum below). A genuine access
        // error throws CoreError.badInput so the caller can surface it instead of
        // silently downgrading the verdict.
        let cached: TrustedChecksum?
        do {
            cached = try keychainStore.lookup(sha512: deviceDigest, imageByteLength: imageByteLength)
        } catch {
            throw CoreError.badInput(message: "Keychain trusted-cache lookup failed: \(error).")
        }
        if cached != nil {
            return .trustedCacheHit
        }
        // Priority 3: nothing to compare against (a true cache miss).
        return .noOfficialChecksum
    }

    /// Look up a trusted checksum in the Keychain cache.
    ///
    /// - Parameters:
    ///   - digest: the SHA-512 digest key.
    ///   - imageByteLength: the image byte-length key.
    /// - Returns: a cached `TrustedChecksum`, or `nil` on a miss.
    /// - Throws: `CoreError.badInput` if the backend errors unexpectedly.
    public func lookupTrustedCache(digest: SHA512Digest, imageByteLength: Int) throws -> TrustedChecksum? {
        do {
            return try keychainStore.lookup(sha512: digest, imageByteLength: imageByteLength)
        } catch {
            throw CoreError.badInput(message: "Keychain lookup failed: \(error).")
        }
    }

    /// Save a trusted checksum to the Keychain cache.
    ///
    /// The caller decides whether and when to invoke this; the service never auto-saves.
    /// A duplicate-item error is swallowed (the item is already cached -- success).
    ///
    /// - Parameter checksum: the entry to persist.
    /// - Throws: `CoreError.badInput` for non-duplicate Keychain errors.
    public func saveTrustedCache(_ checksum: TrustedChecksum) throws {
        do {
            try keychainStore.save(checksum)
        } catch KeychainError.duplicateItem {
            // Duplicate is success: the item is already in the cache.
            return
        } catch {
            throw CoreError.badInput(message: "Keychain save failed: \(error).")
        }
    }

    // sha512(ofFileAt:) is supplied by the ChecksumService protocol extension in
    // Services.swift so every conformer shares one streaming implementation.
}
