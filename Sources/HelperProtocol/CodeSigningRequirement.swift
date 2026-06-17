/// CodeSigningRequirement: holder + pure validator for a SecCode designated
/// requirement string used to authenticate the XPC peer.
///
/// Both ends of the `NSXPCConnection` will pin the other end's code-signing
/// identity so a malicious process cannot impersonate the app or the helper.
/// macOS expresses that pin as a "designated requirement" string evaluated by
/// the Security framework (`SecRequirementCreateWithString` /
/// `SecCodeCheckValidity`).
///
/// SCOPE OF THIS FILE: this milestone defines the CONTRACT only. It carries the
/// requirement string and performs a PURE structural validation (shape check)
/// of that string. It does NOT call into the Security framework and does NOT
/// perform the real peer check; that wiring (auditing the connecting peer's
/// `SecCode` against this requirement) lands with the XPC connection setup in a
/// later milestone. Keeping the validator pure makes it unit-testable without a
/// signed binary or a live connection.

import Foundation

// MARK: - Validation errors

/// Why a requirement string failed the structural shape check.
public enum CodeSigningRequirementError: Error, Equatable {
    /// The string was empty or only whitespace.
    case empty
    /// The string contained no recognized requirement clause
    /// (`identifier`, `anchor`, or `certificate`).
    case missingClause
    /// Unbalanced quoting (an odd number of double-quote characters).
    case unbalancedQuotes
    /// Unbalanced grouping parentheses.
    case unbalancedParentheses
}

// MARK: - CodeSigningRequirement

/// A validated-shape holder for a designated-requirement string.
///
/// Construction runs the pure shape check; a successfully constructed value has
/// passed structural validation but has NOT been evaluated against any running
/// code. The real `SecCode` peer check happens at connection time.
public struct CodeSigningRequirement: Equatable, Sendable {

    /// The raw designated-requirement string, e.g.
    /// `anchor apple generic and identifier "com.example.helper"`.
    public let requirementString: String

    /// Construct from a raw string after passing the pure shape check.
    ///
    /// - Throws: `CodeSigningRequirementError` if the string is structurally
    ///   malformed. A thrown error means "do not even attempt a SecCode check
    ///   with this string"; it does not mean the peer is untrusted.
    public init(requirementString: String) throws {
        try CodeSigningRequirement.validateShape(requirementString)
        self.requirementString = requirementString
    }

    /// Pure structural validation of a designated-requirement string.
    ///
    /// This is deliberately conservative and Security-framework-free. It checks
    /// that the string is non-empty, mentions at least one recognized clause
    /// keyword, and has balanced quotes and parentheses. It does NOT validate
    /// full requirement-language grammar and it does NOT evaluate the
    /// requirement against any code.
    ///
    /// - Parameter string: the candidate requirement string.
    /// - Throws: `CodeSigningRequirementError` describing the first problem found.
    public static func validateShape(_ string: String) throws {
        // Reject empty or whitespace-only input.
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw CodeSigningRequirementError.empty
        }

        // Quotes must be balanced (even count of double-quote characters).
        let quoteCount = trimmed.filter { $0 == "\"" }.count
        if quoteCount % 2 != 0 {
            throw CodeSigningRequirementError.unbalancedQuotes
        }

        // Parentheses must be balanced and never close before they open.
        var depth = 0
        for character in trimmed {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth < 0 {
                    throw CodeSigningRequirementError.unbalancedParentheses
                }
            }
        }
        if depth != 0 {
            throw CodeSigningRequirementError.unbalancedParentheses
        }

        // Must contain at least one recognized requirement clause keyword.
        // We match case-insensitively against the lowercased string.
        let lowered = trimmed.lowercased()
        let recognizedClauses = ["identifier", "anchor", "certificate"]
        let hasClause = recognizedClauses.contains { lowered.contains($0) }
        if !hasClause {
            throw CodeSigningRequirementError.missingClause
        }
    }
}
