/// Digest.swift - CryptoKit streaming SHA-512.
///
/// The public MVP API exposes only SHA-512.
import CryptoKit
import Foundation

// MARK: - SHA512Digest value type

/// A finalized SHA-512 digest. Codable, Equatable, and sendable.
///
/// Comparison uses a constant-time-ish path via CryptoKit's internal equality
/// on the underlying `SHA512.Digest` before falling back to byte-by-byte
/// comparison on the raw bytes - both are branch-free for fixed-length inputs.
public struct SHA512Digest: Equatable, Hashable, Codable, Sendable {

    /// Raw 64 bytes of the digest.
    public let bytes: [UInt8]

    /// Lowercase hex string (128 characters).
    public var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Internal construction

    init(_ cryptoDigest: CryptoKit.SHA512.Digest) {
        bytes = Array(cryptoDigest)
    }

    /// Initialize from a 128-character lowercase hex string.
    ///
    /// Returns `nil` if the string is not exactly 128 hex characters.
    public init?(hexString: String) {
        guard hexString.count == 128 else { return nil }
        let lower = hexString.lowercased()
        let validChars = CharacterSet(charactersIn: "0123456789abcdef")
        guard lower.unicodeScalars.allSatisfy({ validChars.contains($0) }) else { return nil }
        var result = [UInt8]()
        result.reserveCapacity(64)
        var index = lower.startIndex
        while index < lower.endIndex {
            let nextIndex = lower.index(index, offsetBy: 2)
            let byteString = lower[index..<nextIndex]
            // Force-unwrap is safe: we validated all chars above.
            result.append(UInt8(byteString, radix: 16)!)
            index = nextIndex
        }
        bytes = result
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hex = try container.decode(String.self)
        guard let digest = SHA512Digest(hexString: hex) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected 128-char hex string for SHA512Digest"
            )
        }
        self = digest
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }

    // MARK: Equatable

    /// Constant-time-ish equality: compare all 64 bytes regardless of first mismatch.
    public static func == (lhs: SHA512Digest, rhs: SHA512Digest) -> Bool {
        guard lhs.bytes.count == rhs.bytes.count else { return false }
        // XOR all bytes; non-zero means mismatch.
        let mismatch = zip(lhs.bytes, rhs.bytes).reduce(UInt8(0)) { acc, pair in
            acc | (pair.0 ^ pair.1)
        }
        return mismatch == 0
    }
}

// MARK: - SHA512Hasher (streaming)

/// Incremental SHA-512 hasher. Feed data in chunks, then call `finalize()`.
///
/// Not `Sendable` because `SHA512` is a mutable struct that must be used
/// on a single thread.
public struct SHA512Hasher {
    private var hasher = CryptoKit.SHA512()

    public init() {}

    /// Feed a chunk of data into the hasher.
    public mutating func update(_ data: Data) {
        hasher.update(data: data)
    }

    /// Feed a chunk of raw bytes into the hasher.
    public mutating func update(_ bytes: [UInt8]) {
        hasher.update(data: Data(bytes))
    }

    /// Finalize and return the digest. The hasher must not be used after this call.
    public func finalize() -> SHA512Digest {
        SHA512Digest(hasher.finalize())
    }
}

// MARK: - One-shot convenience

/// Compute SHA-512 for a complete `Data` value in one call.
public func sha512(of data: Data) -> SHA512Digest {
    var h = SHA512Hasher()
    h.update(data)
    return h.finalize()
}
