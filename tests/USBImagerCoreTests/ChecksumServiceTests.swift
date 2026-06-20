/// ChecksumServiceTests.swift - unit tests for DefaultChecksumService.
///
/// Strategy: inject an InMemoryKeychainBackend so tests run without Keychain
/// entitlements or code-signing. Fixture values are 128-char hex strings
/// (valid SHA-512 form) and minimal SHA512SUMS bodies.
///
/// Coverage:
///   - validatePastedHex: valid 128-hex, invalid (too short, bad chars, empty)
///   - expectedDigest(fromSums:matching:): match by bare name + full path, no match, malformed body
///   - matches(deviceDigest:expected:): equal and unequal digests
///   - matchOutcome: officialMatch, officialMismatch, trustedCacheHit, noOfficialChecksum
///   - lookupTrustedCache: cache hit and cache miss via in-memory backend
///   - saveTrustedCache: roundtrip + duplicate treated as success
import Foundation
import Testing
@testable import USBImagerCore
import KeychainStore
import Verifier

// MARK: - Fixture helpers

/// A valid 128-char lowercase hex string representing a "device" digest.
private let deviceHex = String(repeating: "a", count: 128)

/// An alternate 128-char hex string representing a different "expected" digest.
private let expectedHex = String(repeating: "b", count: 128)

/// Parse a hex string into a SHA512Digest. Force-unwrap is safe for known-valid fixtures.
private func digest(_ hex: String) -> SHA512Digest {
    SHA512Digest(hexString: hex)!
}

/// Build a DefaultChecksumService backed by the given in-memory backend.
private func makeService(backend: InMemoryKeychainBackend = InMemoryKeychainBackend()) -> DefaultChecksumService {
    DefaultChecksumService(keychainStore: KeychainStore(backend: backend))
}

/// A `KeychainBackend` whose `loadAll()` always throws a Keychain access error.
/// Injected to prove `matchOutcome` distinguishes a real access failure (which
/// must throw) from a true cache miss (which an empty in-memory backend models).
private struct ThrowingLoadAllKeychainBackend: KeychainBackend {
    func add(key: String, value: Data) throws {}
    func loadAll() throws -> [Data] {
        // errSecAuthFailed (-25293) stands in for a real Keychain access error.
        throw KeychainError.keychainStatus(-25293)
    }
    func delete(key: String) throws {}
}

// MARK: - validatePastedHex

@Suite("validatePastedHex")
struct ValidatePastedHexTests {

    @Test("Valid 128-char lowercase hex returns a SHA512Digest")
    func validLowercaseHex() throws {
        let svc = makeService()
        let result = try svc.validatePastedHex(deviceHex)
        #expect(result == digest(deviceHex))
    }

    @Test("Valid 128-char uppercase hex is accepted after lowercasing")
    func validUppercaseHex() throws {
        let svc = makeService()
        let upper = deviceHex.uppercased()
        let result = try svc.validatePastedHex(upper)
        #expect(result == digest(deviceHex))
    }

    @Test("Surrounding whitespace is trimmed before validation")
    func trimmingWhitespace() throws {
        let svc = makeService()
        let padded = "  \(deviceHex)\n"
        let result = try svc.validatePastedHex(padded)
        #expect(result == digest(deviceHex))
    }

    @Test("Too-short hex throws CoreError.badInput")
    func tooShortHex() throws {
        let svc = makeService()
        let short = String(repeating: "a", count: 64)
        let error = #expect(throws: CoreError.self) {
            _ = try svc.validatePastedHex(short)
        }
        if case .badInput = error { } else {
            Issue.record("expected CoreError.badInput, got \(String(describing: error))")
        }
    }

    @Test("Non-hex characters throw CoreError.badInput")
    func invalidCharacters() throws {
        let svc = makeService()
        // Replace the first two chars with invalid ones.
        let bad = "zz" + String(repeating: "a", count: 126)
        let error = #expect(throws: CoreError.self) {
            _ = try svc.validatePastedHex(bad)
        }
        if case .badInput = error { } else {
            Issue.record("expected CoreError.badInput, got \(String(describing: error))")
        }
    }

    @Test("Empty string throws CoreError.badInput")
    func emptyString() throws {
        let svc = makeService()
        let error = #expect(throws: CoreError.self) {
            _ = try svc.validatePastedHex("")
        }
        if case .badInput = error { } else {
            Issue.record("expected CoreError.badInput, got \(String(describing: error))")
        }
    }
}

// MARK: - expectedDigest(fromSums:matching:)

@Suite("expectedDigest(fromSums:matching:)")
struct ExpectedDigestTests {

    /// A minimal SHA512SUMS body with two entries.
    private let sumsBody = """
        \(String(repeating: "a", count: 128))  ubuntu.iso
        \(String(repeating: "b", count: 128))  debian.iso
        """

    @Test("Match by bare filename returns the correct digest")
    func matchByBareName() throws {
        let svc = makeService()
        let result = try svc.expectedDigest(fromSums: sumsBody, matching: "ubuntu.iso")
        #expect(result == digest(deviceHex))
    }

    @Test("Match by full path uses last path component")
    func matchByFullPath() throws {
        let svc = makeService()
        let result = try svc.expectedDigest(fromSums: sumsBody, matching: "/tmp/ubuntu.iso")
        #expect(result == digest(deviceHex))
    }

    @Test("Non-matching filename throws CoreError.badInput")
    func noMatchThrows() throws {
        let svc = makeService()
        let error = #expect(throws: CoreError.self) {
            _ = try svc.expectedDigest(fromSums: sumsBody, matching: "fedora.iso")
        }
        if case .badInput = error { } else {
            Issue.record("expected CoreError.badInput, got \(String(describing: error))")
        }
    }

    @Test("Malformed SHA512SUMS body throws CoreError.badInput")
    func malformedBody() throws {
        let svc = makeService()
        // A line that is not a valid SHA512SUMS entry.
        let bad = "not-a-valid-line"
        let error = #expect(throws: CoreError.self) {
            _ = try svc.expectedDigest(fromSums: bad, matching: "ubuntu.iso")
        }
        if case .badInput = error { } else {
            Issue.record("expected CoreError.badInput, got \(String(describing: error))")
        }
    }
}

// MARK: - matches(deviceDigest:expected:)

@Suite("matches(deviceDigest:expected:)")
struct MatchesTests {

    @Test("Equal digests return true")
    func equalDigests() {
        let svc = makeService()
        let d = digest(deviceHex)
        #expect(svc.matches(deviceDigest: d, expected: d))
    }

    @Test("Unequal digests return false")
    func unequalDigests() {
        let svc = makeService()
        #expect(!svc.matches(deviceDigest: digest(deviceHex), expected: digest(expectedHex)))
    }
}

// MARK: - matchOutcome priority

@Suite("matchOutcome priority")
struct MatchOutcomeTests {

    @Test("officialDigest present and matching returns officialMatch")
    func officialMatch() throws {
        let svc = makeService()
        let d = digest(deviceHex)
        let outcome = try svc.matchOutcome(deviceDigest: d, officialDigest: d, imageByteLength: 1_000)
        #expect(outcome == .officialMatch)
    }

    @Test("officialDigest present but mismatched returns officialMismatch")
    func officialMismatch() throws {
        let svc = makeService()
        let outcome = try svc.matchOutcome(
            deviceDigest: digest(deviceHex),
            officialDigest: digest(expectedHex),
            imageByteLength: 1_000
        )
        #expect(outcome == .officialMismatch)
    }

    @Test("No officialDigest and cache hit returns trustedCacheHit")
    func trustedCacheHit() throws {
        let backend = InMemoryKeychainBackend()
        let svc = makeService(backend: backend)
        let d = digest(deviceHex)
        let byteLength = 2_000
        // Pre-populate the cache so a lookup succeeds.
        let trusted = TrustedChecksum(sha512: d, imageByteLength: byteLength, originalFilename: "test.iso")
        try svc.saveTrustedCache(trusted)
        let outcome = try svc.matchOutcome(deviceDigest: d, officialDigest: nil, imageByteLength: byteLength)
        #expect(outcome == .trustedCacheHit)
    }

    @Test("No officialDigest and empty cache returns noOfficialChecksum")
    func noOfficialChecksum() throws {
        let svc = makeService()
        let outcome = try svc.matchOutcome(
            deviceDigest: digest(deviceHex),
            officialDigest: nil,
            imageByteLength: 3_000
        )
        #expect(outcome == .noOfficialChecksum)
    }

    @Test("officialDigest takes priority over a Keychain cache hit")
    func officialDigestPriority() throws {
        let backend = InMemoryKeychainBackend()
        let svc = makeService(backend: backend)
        let d = digest(deviceHex)
        let byteLength = 4_000
        // Pre-populate cache so it would return trustedCacheHit if checked.
        let trusted = TrustedChecksum(sha512: d, imageByteLength: byteLength, originalFilename: "test.iso")
        try svc.saveTrustedCache(trusted)
        // Pass a mismatched official digest -- should return officialMismatch, not trustedCacheHit.
        let outcome = try svc.matchOutcome(
            deviceDigest: d,
            officialDigest: digest(expectedHex),
            imageByteLength: byteLength
        )
        #expect(outcome == .officialMismatch)
    }

    @Test("A genuine Keychain access error throws CoreError instead of a silent miss")
    func keychainAccessErrorThrows() {
        // The probe backend always throws on loadAll, modeling a real access
        // failure (not a miss). matchOutcome must propagate a typed CoreError
        // rather than collapsing into .noOfficialChecksum.
        let svc = DefaultChecksumService(
            keychainStore: KeychainStore(backend: ThrowingLoadAllKeychainBackend())
        )
        #expect(throws: CoreError.self) {
            try svc.matchOutcome(
                deviceDigest: digest(deviceHex),
                officialDigest: nil,
                imageByteLength: 5_000
            )
        }
    }

    @Test("A true cache miss does not throw and stays noOfficialChecksum")
    func trueMissDoesNotThrow() throws {
        // An empty in-memory backend returns nil on lookup (a true miss), which
        // must resolve to .noOfficialChecksum without throwing.
        let svc = makeService()
        let outcome = try svc.matchOutcome(
            deviceDigest: digest(deviceHex),
            officialDigest: nil,
            imageByteLength: 6_000
        )
        #expect(outcome == .noOfficialChecksum)
    }
}

// MARK: - lookupTrustedCache

@Suite("lookupTrustedCache")
struct LookupTrustedCacheTests {

    @Test("Cache miss returns nil")
    func cacheMiss() throws {
        let svc = makeService()
        let result = try svc.lookupTrustedCache(digest: digest(deviceHex), imageByteLength: 1_000)
        #expect(result == nil)
    }

    @Test("Cache hit after save returns the stored TrustedChecksum")
    func cacheHit() throws {
        let backend = InMemoryKeychainBackend()
        let svc = makeService(backend: backend)
        let d = digest(deviceHex)
        let byteLength = 5_000
        let entry = TrustedChecksum(
            sha512: d,
            imageByteLength: byteLength,
            originalFilename: "big.iso",
            sourceLabel: "example.com"
        )
        try svc.saveTrustedCache(entry)
        let result = try svc.lookupTrustedCache(digest: d, imageByteLength: byteLength)
        #expect(result == entry)
    }

    @Test("Lookup with wrong byteLength returns nil")
    func wrongByteLength() throws {
        let backend = InMemoryKeychainBackend()
        let svc = makeService(backend: backend)
        let d = digest(deviceHex)
        let entry = TrustedChecksum(sha512: d, imageByteLength: 6_000, originalFilename: "a.iso")
        try svc.saveTrustedCache(entry)
        // Use a different byteLength as the key.
        let result = try svc.lookupTrustedCache(digest: d, imageByteLength: 7_000)
        #expect(result == nil)
    }
}

// MARK: - saveTrustedCache

@Suite("saveTrustedCache")
struct SaveTrustedCacheTests {

    @Test("Save and lookup roundtrip succeeds")
    func saveAndLookup() throws {
        let backend = InMemoryKeychainBackend()
        let svc = makeService(backend: backend)
        let d = digest(expectedHex)
        let byteLength = 8_000
        let entry = TrustedChecksum(sha512: d, imageByteLength: byteLength, originalFilename: "x.iso")
        try svc.saveTrustedCache(entry)
        let fetched = try svc.lookupTrustedCache(digest: d, imageByteLength: byteLength)
        #expect(fetched == entry)
    }

    @Test("Duplicate save does not throw")
    func duplicateSave() throws {
        let backend = InMemoryKeychainBackend()
        let svc = makeService(backend: backend)
        let d = digest(deviceHex)
        let entry = TrustedChecksum(sha512: d, imageByteLength: 9_000, originalFilename: "y.iso")
        try svc.saveTrustedCache(entry)
        // Second save of the same item must succeed (duplicate is treated as success).
        try svc.saveTrustedCache(entry)
    }

    @Test("Two distinct entries with the same digest but different byteLengths are both stored")
    func distinctByteLengths() throws {
        let backend = InMemoryKeychainBackend()
        let svc = makeService(backend: backend)
        let d = digest(deviceHex)
        let e1 = TrustedChecksum(sha512: d, imageByteLength: 10_000, originalFilename: "v1.iso")
        let e2 = TrustedChecksum(sha512: d, imageByteLength: 20_000, originalFilename: "v2.iso")
        try svc.saveTrustedCache(e1)
        try svc.saveTrustedCache(e2)
        let r1 = try svc.lookupTrustedCache(digest: d, imageByteLength: 10_000)
        let r2 = try svc.lookupTrustedCache(digest: d, imageByteLength: 20_000)
        #expect(r1 == e1)
        #expect(r2 == e2)
    }
}
