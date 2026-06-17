/// ChecksumFile.swift - Parse SHA512SUMS-format files and validate pasted hex strings.
///
/// Supports two input modes:
///   1. A raw 128-hex-char string (pasted directly from a download page).
///   2. A SHA512SUMS body in the format produced by `sha512sum`:
///          <128 hex chars>  <filename>
///      Lines with a single space or two spaces after the digest are accepted.
import Foundation

// MARK: - Errors

/// Errors produced by checksum file parsing and matching.
public enum ChecksumFileError: Error, Equatable {
    /// The pasted hex string is not exactly 128 valid hex characters.
    case invalidHexString(String)
    /// No entry for the requested filename was found in the checksum file.
    case filenameNotFound(String)
    /// A line in the SHA512SUMS body could not be parsed.
    case malformedLine(String)
}

// MARK: - Parsed entry

/// A single (filename, digest) pair from a SHA512SUMS file.
public struct ChecksumEntry: Equatable {
    public let filename: String
    public let digest: SHA512Digest

    public init(filename: String, digest: SHA512Digest) {
        self.filename = filename
        self.digest = digest
    }
}

// MARK: - Match result

/// Result of comparing a computed digest against the expected one.
public enum MatchResult: Equatable {
    /// The digests are equal - hash match confirmed.
    case hashMatch
    /// The digests differ - the image is corrupt or tampered.
    case hashMismatch(expected: SHA512Digest, actual: SHA512Digest)
}

// MARK: - ChecksumFile

/// Parses SHA512SUMS-format content and matches filenames to expected digests.
public struct ChecksumFile {

    /// All entries parsed from the checksum body.
    public let entries: [ChecksumEntry]

    // MARK: Parsing

    /// Parse a complete SHA512SUMS body.
    ///
    /// Lines that are blank or start with `#` are silently skipped.
    /// Any other line that does not match `<128 hex>  <filename>` throws
    /// `ChecksumFileError.malformedLine`.
    public init(sha512SumsBody body: String) throws {
        var parsed = [ChecksumEntry]()
        let lines = body.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip blank lines and comment lines.
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let entry = try ChecksumFile.parseLine(trimmed)
            parsed.append(entry)
        }
        entries = parsed
    }

    /// Parse a single SHA512SUMS line: `<128 hex chars><separator><filename>`.
    ///
    /// `sha512sum` uses two spaces for text mode and ` *` for binary mode.
    /// We accept both (one or two separating spaces, or space+asterisk).
    private static func parseLine(_ line: String) throws -> ChecksumEntry {
        // The digest is always the first 128 characters.
        guard line.count > 130 else {
            throw ChecksumFileError.malformedLine(line)
        }
        let hexEnd = line.index(line.startIndex, offsetBy: 128)
        let hexPart = String(line[line.startIndex..<hexEnd])
        guard let digest = SHA512Digest(hexString: hexPart) else {
            throw ChecksumFileError.malformedLine(line)
        }
        // The separator is one or two chars: "  " (text) or " *" (binary).
        let afterHex = line[hexEnd...]
        guard afterHex.hasPrefix("  ") || afterHex.hasPrefix(" *") || afterHex.hasPrefix(" ") else {
            throw ChecksumFileError.malformedLine(line)
        }
        // Drop the separator (1 or 2 chars) to get the filename.
        let separatorLength: Int
        if afterHex.hasPrefix("  ") || afterHex.hasPrefix(" *") {
            separatorLength = 2
        } else {
            separatorLength = 1
        }
        let filenameStart = line.index(hexEnd, offsetBy: separatorLength)
        let filename = String(line[filenameStart...]).trimmingCharacters(in: .whitespaces)
        guard !filename.isEmpty else {
            throw ChecksumFileError.malformedLine(line)
        }
        return ChecksumEntry(filename: filename, digest: digest)
    }

    // MARK: Matching

    /// Find the expected digest for `filename` in the parsed entries.
    ///
    /// - Returns: The `SHA512Digest` for the first matching filename.
    /// - Throws: `ChecksumFileError.filenameNotFound` if no entry matches.
    public func expectedDigest(for filename: String) throws -> SHA512Digest {
        // Strip any leading path component so "/tmp/ubuntu.iso" matches "ubuntu.iso".
        let base = URL(fileURLWithPath: filename).lastPathComponent
        for entry in entries where entry.filename == base || entry.filename == filename {
            return entry.digest
        }
        throw ChecksumFileError.filenameNotFound(filename)
    }

    /// Compare a computed digest against the expected one for `filename`.
    ///
    /// - Returns: `.hashMatch` or `.hashMismatch(expected:actual:)`.
    /// - Throws: `ChecksumFileError.filenameNotFound` if the filename is absent.
    public func verify(filename: String, computedDigest: SHA512Digest) throws -> MatchResult {
        let expected = try expectedDigest(for: filename)
        if expected == computedDigest {
            return .hashMatch
        }
        return .hashMismatch(expected: expected, actual: computedDigest)
    }
}

// MARK: - Pasted hex validation

/// Validate a pasted SHA-512 hex string (as copied from a download page).
///
/// - Parameter hexString: The raw string to validate.
/// - Returns: A `SHA512Digest` if the string is exactly 128 valid hex chars.
/// - Throws: `ChecksumFileError.invalidHexString` otherwise.
public func validatePastedHex(_ hexString: String) throws -> SHA512Digest {
    guard let digest = SHA512Digest(hexString: hexString) else {
        throw ChecksumFileError.invalidHexString(hexString)
    }
    return digest
}
