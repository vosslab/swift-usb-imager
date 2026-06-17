/// KeychainStoreTests.swift - Unit tests for the trusted-checksum cache.
///
/// All tests use `InMemoryKeychainBackend` so no Keychain entitlements or
/// code-signing are needed. The real `SecurityKeychainBackend` is an integration
/// concern exercised only on signed targets.
import Testing
import Verifier
import KeychainStore

// MARK: - Test helpers

/// A hex string that is exactly 128 characters (all zeros), used as a minimal
/// valid SHA-512 digest throughout the tests.
private let zeroHex = String(repeating: "0", count: 128)
/// A second distinct digest (all ones).
private let onesHex = String(repeating: "f", count: 128)

/// Convenience: build a digest from a hex string, crashing if invalid.
private func digest(_ hex: String) -> SHA512Digest {
    SHA512Digest(hexString: hex)!
}

/// Convenience: build a fresh `KeychainStore` backed by an in-memory fake.
private func makeStore() -> KeychainStore {
    KeychainStore(backend: InMemoryKeychainBackend())
}

// MARK: - KeychainStoreTests

@Suite("KeychainStoreTests")
struct KeychainStoreTests {

    // MARK: Round-trip

    @Test("save then lookup returns the stored record")
    func roundTripSaveAndLookup() throws {
        let store = makeStore()
        let checksum = TrustedChecksum(
            sha512: digest(zeroHex),
            imageByteLength: 1_024,
            originalFilename: "ubuntu.iso",
            sourceLabel: "ubuntu.com"
        )
        try store.save(checksum)

        let result = try store.lookup(sha512: digest(zeroHex), imageByteLength: 1_024)
        #expect(result != nil)
        #expect(result == checksum)
    }

    @Test("lookup returns nil when cache is empty")
    func lookupMissOnEmpty() throws {
        let store = makeStore()
        let result = try store.lookup(sha512: digest(zeroHex), imageByteLength: 1_024)
        #expect(result == nil)
    }

    // MARK: Match key semantics

    @Test("same filename but different sha512 does NOT match")
    func differentSha512NoMatch() throws {
        let store = makeStore()
        // Save a record with zeroHex digest.
        let saved = TrustedChecksum(
            sha512: digest(zeroHex),
            imageByteLength: 512,
            originalFilename: "same.iso",
            sourceLabel: nil
        )
        try store.save(saved)

        // Lookup with a different digest but the same filename - must miss.
        let result = try store.lookup(sha512: digest(onesHex), imageByteLength: 512)
        #expect(result == nil)
    }

    @Test("same sha512 but different imageByteLength does NOT match")
    func differentByteLengthNoMatch() throws {
        let store = makeStore()
        let saved = TrustedChecksum(
            sha512: digest(zeroHex),
            imageByteLength: 1_000,
            originalFilename: "img.iso",
            sourceLabel: nil
        )
        try store.save(saved)

        // Same digest, different length - must miss.
        let result = try store.lookup(sha512: digest(zeroHex), imageByteLength: 2_000)
        #expect(result == nil)
    }

    @Test("same sha512+length with different filename DOES match")
    func differentFilenameStillMatches() throws {
        let store = makeStore()
        // Store a record with "original.iso".
        let saved = TrustedChecksum(
            sha512: digest(zeroHex),
            imageByteLength: 8_192,
            originalFilename: "original.iso",
            sourceLabel: "example.com"
        )
        try store.save(saved)

        // Lookup by the same sha512+length - filename is irrelevant.
        let result = try store.lookup(sha512: digest(zeroHex), imageByteLength: 8_192)
        #expect(result != nil)
        // The returned record still carries the original filename stored at save time.
        #expect(result?.originalFilename == "original.iso")
    }

    // MARK: Duplicate detection

    @Test("saving the same sha512+length twice throws duplicateItem")
    func duplicateThrows() throws {
        let store = makeStore()
        let checksum = TrustedChecksum(
            sha512: digest(zeroHex),
            imageByteLength: 256,
            originalFilename: "a.iso",
            sourceLabel: nil
        )
        try store.save(checksum)

        // Second save with same key must throw.
        #expect(throws: KeychainError.duplicateItem) {
            try store.save(checksum)
        }
    }

    @Test("two records with different sha512 can both be saved")
    func twoDistinctRecordsCoexist() throws {
        let store = makeStore()
        let first = TrustedChecksum(
            sha512: digest(zeroHex),
            imageByteLength: 1_024,
            originalFilename: "a.iso",
            sourceLabel: nil
        )
        let second = TrustedChecksum(
            sha512: digest(onesHex),
            imageByteLength: 1_024,
            originalFilename: "b.iso",
            sourceLabel: nil
        )
        try store.save(first)
        try store.save(second)

        let all = try store.list()
        #expect(all.count == 2)
    }

    // MARK: Remove

    @Test("remove deletes the matching record and lookup returns nil afterwards")
    func removeWorks() throws {
        let store = makeStore()
        let checksum = TrustedChecksum(
            sha512: digest(zeroHex),
            imageByteLength: 2_048,
            originalFilename: "test.iso",
            sourceLabel: nil
        )
        try store.save(checksum)

        // Confirm it is there before removal.
        let before = try store.lookup(sha512: digest(zeroHex), imageByteLength: 2_048)
        #expect(before != nil)

        try store.remove(sha512: digest(zeroHex), imageByteLength: 2_048)

        // Must be gone after removal.
        let after = try store.lookup(sha512: digest(zeroHex), imageByteLength: 2_048)
        #expect(after == nil)
    }

    @Test("remove on non-existent key succeeds silently")
    func removeMissingSucceedsSilently() throws {
        let store = makeStore()
        // Should not throw even though nothing is stored.
        try store.remove(sha512: digest(zeroHex), imageByteLength: 99)
    }

    @Test("remove only deletes the targeted record, not others")
    func removeIsSelective() throws {
        let store = makeStore()
        let first = TrustedChecksum(
            sha512: digest(zeroHex),
            imageByteLength: 100,
            originalFilename: "one.iso",
            sourceLabel: nil
        )
        let second = TrustedChecksum(
            sha512: digest(onesHex),
            imageByteLength: 200,
            originalFilename: "two.iso",
            sourceLabel: nil
        )
        try store.save(first)
        try store.save(second)

        try store.remove(sha512: digest(zeroHex), imageByteLength: 100)

        // first is gone.
        let hitFirst = try store.lookup(sha512: digest(zeroHex), imageByteLength: 100)
        #expect(hitFirst == nil)

        // second is still present.
        let hitSecond = try store.lookup(sha512: digest(onesHex), imageByteLength: 200)
        #expect(hitSecond != nil)
    }

    // MARK: List

    @Test("list returns all saved records")
    func listAll() throws {
        let store = makeStore()
        #expect(try store.list().isEmpty)

        let checksum = TrustedChecksum(
            sha512: digest(zeroHex),
            imageByteLength: 4_096,
            originalFilename: "disk.iso",
            sourceLabel: nil
        )
        try store.save(checksum)

        let all = try store.list()
        #expect(all.count == 1)
        #expect(all.first == checksum)
    }

    // MARK: Optional sourceLabel

    @Test("sourceLabel nil round-trips correctly")
    func nilSourceLabel() throws {
        let store = makeStore()
        let checksum = TrustedChecksum(
            sha512: digest(zeroHex),
            imageByteLength: 333,
            originalFilename: "no-label.iso",
            sourceLabel: nil
        )
        try store.save(checksum)
        let result = try store.lookup(sha512: digest(zeroHex), imageByteLength: 333)
        #expect(result?.sourceLabel == nil)
    }

    @Test("sourceLabel non-nil round-trips correctly")
    func nonNilSourceLabel() throws {
        let store = makeStore()
        let checksum = TrustedChecksum(
            sha512: digest(onesHex),
            imageByteLength: 777,
            originalFilename: "labeled.iso",
            sourceLabel: "releases.example.org"
        )
        try store.save(checksum)
        let result = try store.lookup(sha512: digest(onesHex), imageByteLength: 777)
        #expect(result?.sourceLabel == "releases.example.org")
    }
}
