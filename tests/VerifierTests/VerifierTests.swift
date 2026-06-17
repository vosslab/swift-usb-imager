/// VerifierTests - real @Test cases for Digest.swift and ChecksumFile.swift.
///
/// Replaces the old compile-time / precondition scaffold with named test
/// functions so failures surface as individual test failures rather than a
/// startup crash.
///
/// NIST FIPS 180-4 Section B.1 reference vector:
///   Input:  "abc" (0x61 0x62 0x63)
///   SHA-512: ddaf35a193617abac9417349ae20413112e6fa4e89a97ea2
///            0a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd
///            454d4423643ce80e2a9ac94fa54ca49f
import Foundation
import Testing
@testable import Verifier

// MARK: - Constants

// Correct NIST FIPS 180-4 Section B.1 value for SHA-512("abc").
// Note: the brief and the old scaffold had a typo at byte 9 (c9 vs cc).
// Verified independently: printf 'abc' | openssl dgst -sha512
private let kAbcSHA512Hex =
    "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea2" +
    "0a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd" +
    "454d4423643ce80e2a9ac94fa54ca49f"

private let kEmptySHA512Hex =
    "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"

// MARK: - SHA-512 one-shot correctness

@Suite("SHA512 One-Shot")
struct SHA512OneShotTests {

    @Test("NIST FIPS 180-4 vector: sha512(of: 'abc') matches known hex")
    func abcVector() {
        let digest = sha512(of: Data("abc".utf8))
        #expect(digest.hexString == kAbcSHA512Hex)
    }

    @Test("Empty-input vector: sha512(of: Data()) matches known hex")
    func emptyVector() {
        let digest = sha512(of: Data())
        #expect(digest.hexString == kEmptySHA512Hex)
    }

    @Test("Tamper: flipping one input byte changes the digest")
    func tamperChangesDigest() {
        let original = sha512(of: Data([0x61, 0x62, 0x63]))
        let tampered = sha512(of: Data([0x61, 0x62, 0x64]))
        #expect(original != tampered)
    }
}

// MARK: - SHA512Hasher streaming

@Suite("SHA512Hasher Streaming")
struct SHA512HasherTests {

    @Test("Chunked streaming equals one-shot for 'abc'")
    func chunkingMatchesOneShot() {
        var hasher = SHA512Hasher()
        hasher.update(Data([0x61]))
        hasher.update(Data([0x62]))
        hasher.update(Data([0x63]))
        let chunked = hasher.finalize()
        let oneShot = sha512(of: Data([0x61, 0x62, 0x63]))
        #expect(chunked == oneShot)
    }

    @Test("Byte-array update matches Data update")
    func byteArrayUpdateMatchesDataUpdate() {
        var hasherData = SHA512Hasher()
        hasherData.update(Data([0x01, 0x02, 0x03]))
        let digestData = hasherData.finalize()

        var hasherBytes = SHA512Hasher()
        hasherBytes.update([UInt8]([0x01, 0x02, 0x03]))
        let digestBytes = hasherBytes.finalize()

        #expect(digestData == digestBytes)
    }
}

// MARK: - SHA512Digest conformances

@Suite("SHA512Digest")
struct SHA512DigestTests {

    @Test("Valid 128-char hex parses successfully")
    func validHexParses() {
        let digest = SHA512Digest(hexString: kAbcSHA512Hex)
        #expect(digest != nil)
    }

    @Test("hexString round-trips through init")
    func hexStringRoundTrip() throws {
        let digest = try #require(SHA512Digest(hexString: kAbcSHA512Hex))
        #expect(digest.hexString == kAbcSHA512Hex)
    }

    @Test("Short hex string returns nil")
    func shortHexReturnsNil() {
        let digest = SHA512Digest(hexString: String(repeating: "a", count: 64))
        #expect(digest == nil)
    }

    @Test("Overlong hex string returns nil")
    func overlongHexReturnsNil() {
        let digest = SHA512Digest(hexString: String(repeating: "a", count: 130))
        #expect(digest == nil)
    }

    @Test("Non-hex characters return nil")
    func nonHexCharReturnsNil() {
        // 'z' is not a hex character
        let digest = SHA512Digest(hexString: String(repeating: "z", count: 128))
        #expect(digest == nil)
    }

    @Test("Equatable: two digests from same hex are equal")
    func equatable() throws {
        let a = try #require(SHA512Digest(hexString: kAbcSHA512Hex))
        let b = try #require(SHA512Digest(hexString: kAbcSHA512Hex))
        #expect(a == b)
    }

    @Test("Hashable: digests from same hex hash equally")
    func hashable() throws {
        let a = try #require(SHA512Digest(hexString: kAbcSHA512Hex))
        let b = try #require(SHA512Digest(hexString: kAbcSHA512Hex))
        var set: Set<SHA512Digest> = []
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
    }
}

// MARK: - ChecksumFile parsing

@Suite("ChecksumFile")
struct ChecksumFileTests {

    private let twoEntryBody: String = {
        let hex1 = String(repeating: "a", count: 128)
        let hex2 = String(repeating: "b", count: 128)
        return hex1 + "  ubuntu-24.04.iso\n" + hex2 + "  ubuntu-24.04-desktop.iso\n"
    }()

    @Test("Parses well-formed two-entry SHA512SUMS body")
    func parseTwoEntries() throws {
        let file = try ChecksumFile(sha512SumsBody: twoEntryBody)
        #expect(file.entries.count == 2)
    }

    @Test("expectedDigest(for:) returns the correct digest")
    func expectedDigestForKnownFile() throws {
        let file = try ChecksumFile(sha512SumsBody: twoEntryBody)
        let digest = try file.expectedDigest(for: "ubuntu-24.04.iso")
        let expected = try #require(SHA512Digest(hexString: String(repeating: "a", count: 128)))
        #expect(digest == expected)
    }

    @Test("expectedDigest(for:) throws for unknown filename")
    func expectedDigestThrowsForUnknownFile() throws {
        let file = try ChecksumFile(sha512SumsBody: twoEntryBody)
        #expect(throws: (any Error).self) {
            try file.expectedDigest(for: "nonexistent.iso")
        }
    }

    @Test("Malformed line throws during init")
    func malformedLineThrows() {
        let badBody = "not-a-valid-line\n"
        #expect(throws: (any Error).self) {
            try ChecksumFile(sha512SumsBody: badBody)
        }
    }

    @Test("NIST vector: verify returns .hashMatch for correct digest")
    func verifyHashMatch() throws {
        let body = kAbcSHA512Hex + "  ubuntu-24.04.iso\n"
        let file = try ChecksumFile(sha512SumsBody: body)
        let computed = sha512(of: Data([0x61, 0x62, 0x63]))
        let result = try file.verify(filename: "ubuntu-24.04.iso", computedDigest: computed)
        #expect(result == .hashMatch)
    }

    @Test("verify returns .hashMismatch for wrong digest")
    func verifyHashMismatch() throws {
        let body = kAbcSHA512Hex + "  ubuntu-24.04.iso\n"
        let file = try ChecksumFile(sha512SumsBody: body)
        // A different input produces a different digest
        let wrongComputed = sha512(of: Data([0x64, 0x65, 0x66]))
        let result = try file.verify(filename: "ubuntu-24.04.iso", computedDigest: wrongComputed)
        switch result {
        case .hashMismatch:
            break   // expected
        case .hashMatch:
            Issue.record("Expected .hashMismatch but got .hashMatch")
        }
    }
}

// MARK: - validatePastedHex

@Suite("validatePastedHex")
struct ValidatePastedHexTests {

    @Test("Accepts a valid 128-char hex string")
    func acceptsValidHex() throws {
        let digest = try validatePastedHex(kAbcSHA512Hex)
        #expect(digest.hexString == kAbcSHA512Hex)
    }

    @Test("Throws on hex string shorter than 128 chars")
    func throwsOnShortHex() {
        #expect(throws: (any Error).self) {
            try validatePastedHex(String(repeating: "a", count: 64))
        }
    }

    @Test("Throws on hex string longer than 128 chars")
    func throwsOnLongHex() {
        #expect(throws: (any Error).self) {
            try validatePastedHex(String(repeating: "a", count: 200))
        }
    }

    @Test("Throws on string with invalid hex characters")
    func throwsOnBadCharset() {
        // 'z' is outside [0-9a-fA-F]
        #expect(throws: (any Error).self) {
            try validatePastedHex(String(repeating: "z", count: 128))
        }
    }
}
