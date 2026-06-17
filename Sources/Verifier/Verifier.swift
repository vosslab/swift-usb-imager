/// Verifier module - SHA-512 streaming digest and SHA512SUMS checksum parsing.
///
/// Public API surface:
///   - `SHA512Digest`    - Codable, Equatable digest value type (Digest.swift)
///   - `SHA512Hasher`    - incremental streaming hasher    (Digest.swift)
///   - `sha512(of:)`     - one-shot convenience function   (Digest.swift)
///   - `ChecksumFile`    - SHA512SUMS parser and matcher   (ChecksumFile.swift)
///   - `validatePastedHex(_:)` - raw hex string validator  (ChecksumFile.swift)
///   - `ChecksumEntry`   - parsed (filename, digest) pair  (ChecksumFile.swift)
///   - `MatchResult`     - `.hashMatch` / `.hashMismatch`  (ChecksumFile.swift)
///   - `ChecksumFileError` - typed errors                  (ChecksumFile.swift)
