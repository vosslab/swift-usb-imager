/// HelperAuthorization.swift -- the privileged-caller authorization gate.
///
/// The helper runs as root and drives irreversible raw disk writes, so it must
/// authenticate the connecting peer before doing any destructive work. macOS
/// expresses "only the genuine app may call me" as a code-signing designated
/// requirement evaluated against the peer's `SecCode`.
///
/// This file implements that gate. Given the connecting peer's audit token (from
/// `NSXPCConnection.auditToken`), it builds a `SecCode` for that process via
/// `SecCodeCopyGuestWithAttributes(kSecGuestAttributeAudit)`, builds a
/// `SecRequirement` from the pinned requirement string, and runs
/// `SecCodeCheckValidity`. The connection is allowed only when validity passes;
/// any non-success `OSStatus` rejects it.
///
/// The production gate is `pinning(requirement:)`. It is FAIL-CLOSED: if no audit
/// token is supplied (so the peer cannot be identified), it denies. `allowAll`
/// and `deny(reason:)` remain as test factories for exercising the in-process
/// pipeline and the rejection path without a live signed peer.
///
/// SCOPE NOTE: wiring the audit token from a live `NSXPCConnection` into
/// `authorize(auditToken:)` happens where the helper sets up its XPC listener
/// (a later milestone). The evaluation logic itself -- requirement-string to
/// `SecRequirement`, and the `SecCode`/`SecRequirement` validity check -- is
/// fully implemented and unit-tested here against the pure pieces.

import Foundation
import Security
import HelperProtocol

// MARK: - Code-signature validation primitives

/// Outcome of a code-signature validity check, with the underlying `OSStatus`.
public enum CodeSignatureCheck: Equatable, Sendable {
    /// The peer satisfied the requirement.
    case valid
    /// The peer failed the requirement (or could not be evaluated). `status`
    /// carries the `OSStatus` from the Security framework for diagnosis.
    case invalid(status: OSStatus)
}

/// Pure, Security-framework-backed validation helpers for the authorization
/// gate. These are static and side-effect-free apart from calling into Security,
/// so the requirement-construction path is unit-testable without a live peer.
public enum CodeSignatureValidator {

    /// Build a `SecRequirement` from a designated-requirement string.
    ///
    /// This is the requirement-string -> `SecRequirement` construction the gate
    /// depends on; a malformed string yields `nil`, which the caller treats as a
    /// hard deny (an unusable requirement can never be satisfied).
    ///
    /// - Parameter requirementString: The pinned designated requirement.
    /// - Returns: A `SecRequirement`, or `nil` when the string will not compile.
    public static func makeRequirement(
        from requirementString: String
    ) -> SecRequirement? {
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            requirementString as CFString,
            SecCSFlags(),
            &requirement
        )
        guard status == errSecSuccess else {
            return nil
        }
        return requirement
    }

    /// Build a `SecCode` for the process identified by `auditToken`.
    ///
    /// Uses `SecCodeCopyGuestWithAttributes` against the system root of trust
    /// with the `kSecGuestAttributeAudit` selector, the canonical way to obtain
    /// a dynamic code reference for a connected XPC peer.
    ///
    /// - Parameter auditToken: The peer's audit token (`NSXPCConnection.auditToken`).
    /// - Returns: A `SecCode` for that process, or `nil` when none can be found.
    public static func makeGuestCode(auditToken: audit_token_t) -> SecCode? {
        // The audit token must be passed as CFData carrying the raw token bytes.
        var token = auditToken
        let tokenData = withUnsafeBytes(of: &token) { rawBuffer in
            Data(rawBuffer)
        }
        let attributes: [CFString: Any] = [
            kSecGuestAttributeAudit: tokenData as CFData,
        ]
        var guest: SecCode?
        let status = SecCodeCopyGuestWithAttributes(
            nil,
            attributes as CFDictionary,
            SecCSFlags(),
            &guest
        )
        guard status == errSecSuccess else {
            return nil
        }
        return guest
    }

    /// Check that `code` satisfies `requirement` via `SecCodeCheckValidity`.
    ///
    /// - Parameters:
    ///   - code: The peer's dynamic code reference.
    ///   - requirement: The pinned designated requirement.
    /// - Returns: `.valid` only when the Security framework reports success.
    public static func checkValidity(
        code: SecCode,
        requirement: SecRequirement
    ) -> CodeSignatureCheck {
        let status = SecCodeCheckValidity(code, SecCSFlags(), requirement)
        guard status == errSecSuccess else {
            return .invalid(status: status)
        }
        return .valid
    }

    /// Full peer evaluation: build the guest code, build the requirement, and
    /// check validity. Any missing piece or non-success status is a deny.
    ///
    /// - Parameters:
    ///   - auditToken: The peer's audit token, or `nil` when unavailable.
    ///   - requirementString: The pinned designated requirement.
    /// - Returns: `.valid` only when the peer satisfies the requirement.
    public static func evaluate(
        auditToken: audit_token_t?,
        requirementString: String
    ) -> CodeSignatureCheck {
        // No token means the peer cannot be identified; fail closed.
        guard let auditToken else {
            return .invalid(status: errSecCSNoSuchCode)
        }
        // A requirement string that will not compile can never be satisfied.
        guard let requirement = makeRequirement(from: requirementString) else {
            return .invalid(status: errSecCSReqInvalid)
        }
        // No code reference for the peer means there is nothing to trust.
        guard let code = makeGuestCode(auditToken: auditToken) else {
            return .invalid(status: errSecCSNoSuchCode)
        }
        let result = checkValidity(code: code, requirement: requirement)
        return result
    }
}

// MARK: - HelperAuthorization

/// A pluggable authorization decision point for incoming helper requests.
///
/// `HelperService` calls `authorize()` (or `authorize(auditToken:)` once the XPC
/// listener supplies the peer token) before any destructive work. The
/// production value is `pinning(requirement:)`, which evaluates the peer's
/// `SecCode` against the pinned requirement. `allowAll` and `deny(reason:)`
/// remain for in-process pipeline runs and rejection-path tests.
public struct HelperAuthorization: Sendable {

    /// The decision closure. Receives the connecting peer's audit token (or
    /// `nil` when unavailable) and returns `nil` to allow or a `HelperError` to
    /// deny. Marked `@Sendable` so the service can hold it across concurrency
    /// domains.
    public let decide: @Sendable (audit_token_t?) -> HelperError?

    public init(decide: @escaping @Sendable (audit_token_t?) -> HelperError?) {
        self.decide = decide
    }

    /// Run the gate without a peer token. Convenience for the in-process
    /// pipeline; the production gate denies when no token is present.
    ///
    /// - Throws: the `HelperError` produced by `decide` when access is refused.
    public func authorize() throws {
        try authorize(auditToken: nil)
    }

    /// Run the gate against the connecting peer's audit token.
    ///
    /// - Parameter auditToken: The peer's audit token, or `nil` when unavailable.
    /// - Throws: the `HelperError` produced by `decide` when access is refused.
    public func authorize(auditToken: audit_token_t?) throws {
        if let error = decide(auditToken) {
            throw error
        }
    }

    // MARK: - Factories

    /// Development / in-process default: allow every request.
    ///
    /// For running the pipeline and its tests end to end without a signed peer.
    /// Never use this as the production gate; production uses `pinning`.
    public static let allowAll = HelperAuthorization(decide: { _ in nil })

    /// A gate that always denies, for exercising the rejection path in tests.
    ///
    /// - Parameter reason: Human-readable detail attached to the error.
    public static func deny(reason: String) -> HelperAuthorization {
        let auth = HelperAuthorization(decide: { _ in
            HelperError.notAuthorized(detail: reason)
        })
        return auth
    }

    /// The production gate: allow only peers whose `SecCode` satisfies the
    /// pinned designated requirement.
    ///
    /// Evaluation: build a `SecCode` for the peer from its audit token, build a
    /// `SecRequirement` from `requirement.requirementString`, and run
    /// `SecCodeCheckValidity`. FAIL-CLOSED: a missing token, an uncompilable
    /// requirement, a missing code reference, or any non-success `OSStatus` all
    /// deny the connection.
    ///
    /// - Parameter requirement: The pinned designated requirement for the peer.
    public static func pinning(
        requirement: CodeSigningRequirement
    ) -> HelperAuthorization {
        let requirementString = requirement.requirementString
        let auth = HelperAuthorization(decide: { auditToken in
            let result = CodeSignatureValidator.evaluate(
                auditToken: auditToken,
                requirementString: requirementString
            )
            switch result {
            case .valid:
                return nil
            case .invalid(let status):
                let detail = "peer failed code-signing requirement (OSStatus "
                    + String(status) + ")"
                return HelperError.notAuthorized(detail: detail)
            }
        })
        return auth
    }
}
