/// KeychainStore.swift - Trusted-checksum cache backed by Keychain Services.
///
/// MVP scope: cache user-approved SHA-512 digests so re-flashing the same image
/// auto-matches without re-prompting. Match key is (sha512 + imageByteLength).
/// Filename and sourceLabel are metadata only; they do NOT participate in lookup.
///
/// Elevation/authorization state is NEVER stored here.
///
/// The `KeychainBackend` protocol lets unit tests inject an in-memory fake so
/// tests run without Keychain entitlements or code-signing. The real backend
/// (`SecurityKeychainBackend`) calls Keychain Services and is used in production.
import Foundation
import Security
import Verifier

// MARK: - TrustedChecksum record

/// A user-approved image checksum stored in the trusted-checksum cache.
///
/// Match key is (sha512, imageByteLength). `originalFilename` and `sourceLabel`
/// are informational metadata and do NOT participate in lookups.
public struct TrustedChecksum: Codable, Sendable, Equatable {
    /// SHA-512 digest of the image bytes as verified by the user.
    public let sha512: SHA512Digest
    /// Exact byte length of the image file when hashed.
    public let imageByteLength: Int
    /// Original filename at the time the user approved the checksum.
    public let originalFilename: String
    /// Optional human-readable label identifying the image source (e.g. "ubuntu.com").
    public let sourceLabel: String?

    public init(
        sha512: SHA512Digest,
        imageByteLength: Int,
        originalFilename: String,
        sourceLabel: String? = nil
    ) {
        self.sha512 = sha512
        self.imageByteLength = imageByteLength
        self.originalFilename = originalFilename
        self.sourceLabel = sourceLabel
    }
}

// MARK: - KeychainError

/// Errors surfaced by `KeychainStore`.
public enum KeychainError: Error, Sendable, Equatable {
    /// A Keychain Services call returned a non-zero OSStatus.
    case keychainStatus(OSStatus)
    /// The stored data could not be encoded or decoded as JSON.
    case encodingFailure(String)
    /// A record with the same (sha512 + imageByteLength) already exists.
    case duplicateItem
}

// MARK: - KeychainBackend protocol

/// Abstraction over raw Keychain Services so unit tests can inject an in-memory fake.
///
/// Keys are opaque strings chosen by `KeychainStore`. Values are raw `Data` blobs
/// (JSON-encoded `TrustedChecksum` in practice).
public protocol KeychainBackend: Sendable {
    /// Store `value` under `key`. Throws `KeychainError.duplicateItem` if already present.
    func add(key: String, value: Data) throws
    /// Return all values stored under any key with the given service tag.
    func loadAll() throws -> [Data]
    /// Delete the entry for `key`. Succeeds silently if not found.
    func delete(key: String) throws
}

// MARK: - InMemoryKeychainBackend (fake for unit tests)

/// Thread-safe in-memory Keychain fake. Inject this in unit tests to avoid
/// Keychain entitlement requirements.
public final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {
    // NSLock used so the backend is safe across Swift concurrency contexts.
    private let lock = NSLock()
    // Dictionary keyed on the opaque string key used by KeychainStore.
    private var store: [String: Data] = [:]

    public init() {}

    public func add(key: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard store[key] == nil else {
            throw KeychainError.duplicateItem
        }
        store[key] = value
    }

    public func loadAll() throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        // Return a stable snapshot; order is intentionally unspecified.
        return Array(store.values)
    }

    public func delete(key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: key)
    }
}

// MARK: - SecurityKeychainBackend (real Keychain Services)

/// Production backend that calls macOS Keychain Services.
///
/// Requires the `keychain-access-groups` or `com.apple.security.keychain-access-groups`
/// entitlement (or a signed app with default keychain access). Not suitable for
/// unit tests running under `swift test` without a signing identity.
public struct SecurityKeychainBackend: KeychainBackend {
    /// Service string used to namespace all trusted-checksum items.
    private let service: String

    public init(service: String = "dev.swift-usb-imager.trusted-checksums") {
        self.service = service
    }

    public func add(key: String, value: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: value,
            // Accessible after first unlock; does not migrate to iCloud.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            throw KeychainError.duplicateItem
        }
        guard status == errSecSuccess else {
            throw KeychainError.keychainStatus(status)
        }
    }

    public func loadAll() throws -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // errSecItemNotFound is a valid empty-list result, not an error.
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw KeychainError.keychainStatus(status)
        }
        guard let array = result as? [Data] else {
            return []
        }
        return array
    }

    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // Silently succeed if not found.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.keychainStatus(status)
        }
    }
}

// MARK: - KeychainStore

/// Trusted-checksum cache over a `KeychainBackend`.
///
/// Usage:
/// ```swift
/// let store = KeychainStore()                         // production, real Keychain
/// let store = KeychainStore(backend: InMemoryKeychainBackend()) // unit tests
/// try store.save(TrustedChecksum(...))
/// let hit = try store.lookup(sha512: digest, imageByteLength: 42_000_000)
/// ```
///
/// Match key is **(sha512 + imageByteLength)**. Filename and source label are
/// metadata only and do not affect lookup results.
///
/// Elevation state is NEVER stored here.
public struct KeychainStore: Sendable {
    private let backend: any KeychainBackend
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: Initializers

    /// Production initializer: uses `SecurityKeychainBackend`.
    public init(service: String = "dev.swift-usb-imager.trusted-checksums") {
        self.backend = SecurityKeychainBackend(service: service)
    }

    /// Dependency-injection initializer: pass an `InMemoryKeychainBackend` in tests.
    public init(backend: some KeychainBackend) {
        self.backend = backend
    }

    // MARK: - Private helpers

    /// Stable, opaque storage key derived from the match key (sha512 + byteLength).
    ///
    /// Using the hex digest plus the byte length makes each key unique per image
    /// version. The colon separator prevents accidental collisions between a short
    /// hex prefix + long length and a longer hex prefix + short length.
    private func storageKey(for checksum: TrustedChecksum) -> String {
        "\(checksum.sha512.hexString):\(checksum.imageByteLength)"
    }

    private func encode(_ checksum: TrustedChecksum) throws -> Data {
        do {
            return try encoder.encode(checksum)
        } catch {
            throw KeychainError.encodingFailure("Encode failed: \(error)")
        }
    }

    private func decode(_ data: Data) throws -> TrustedChecksum {
        do {
            return try decoder.decode(TrustedChecksum.self, from: data)
        } catch {
            throw KeychainError.encodingFailure("Decode failed: \(error)")
        }
    }

    // MARK: - Public API

    /// Persist a user-approved trusted checksum.
    ///
    /// Throws `KeychainError.duplicateItem` if a record with the same
    /// (sha512 + imageByteLength) already exists.
    public func save(_ checksum: TrustedChecksum) throws {
        let key = storageKey(for: checksum)
        let data = try encode(checksum)
        try backend.add(key: key, value: data)
    }

    /// Find a cached trusted checksum whose (sha512 + imageByteLength) matches.
    ///
    /// Returns `nil` when no matching record exists. Filename and sourceLabel
    /// are NOT used for matching; only sha512 and imageByteLength matter.
    public func lookup(sha512: SHA512Digest, imageByteLength: Int) throws -> TrustedChecksum? {
        // Build the key the same way save() would.
        let targetKey = "\(sha512.hexString):\(imageByteLength)"
        // Load all blobs and decode each; return the first match.
        // In practice the list is small (tens of entries at most).
        let blobs = try backend.loadAll()
        for blob in blobs {
            let record = try decode(blob)
            let recordKey = storageKey(for: record)
            if recordKey == targetKey {
                return record
            }
        }
        return nil
    }

    /// Return every trusted checksum in the cache, in unspecified order.
    public func list() throws -> [TrustedChecksum] {
        let blobs = try backend.loadAll()
        return try blobs.map { try decode($0) }
    }

    /// Remove the trusted checksum whose (sha512 + imageByteLength) matches.
    ///
    /// Succeeds silently when no matching record exists.
    public func remove(sha512: SHA512Digest, imageByteLength: Int) throws {
        let key = "\(sha512.hexString):\(imageByteLength)"
        try backend.delete(key: key)
    }
}
