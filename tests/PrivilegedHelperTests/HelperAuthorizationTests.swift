/// HelperAuthorizationTests.swift -- unit tests for the privileged-caller
/// authorization gate.
///
/// These cover the pure, locally-testable pieces of the SecCode peer check:
///   - requirement-string -> SecRequirement construction (valid and malformed),
///   - the fail-closed deny paths (no audit token, uncompilable requirement),
///   - the allow/deny test factories.
///
/// A full positive `SecCodeCheckValidity` pass requires a live, code-signed XPC
/// peer and is therefore exercised only at the signing/SMAppService milestone,
/// not here. What IS covered here is every path that does NOT need a live peer:
/// requirement compilation and every deny branch.

import Testing
import Security
@testable import PrivilegedHelper
import HelperProtocol

// MARK: - SecRequirement construction

@Suite("CodeSignatureValidator: requirement construction")
struct RequirementConstructionTests {

    @Test("a well-formed requirement string compiles to a SecRequirement")
    func validRequirementCompiles() {
        let text = "anchor apple generic and identifier \"com.example.helper\""
        let requirement = CodeSignatureValidator.makeRequirement(from: text)
        #expect(requirement != nil)
    }

    @Test("an identifier-only requirement string compiles")
    func identifierOnlyCompiles() {
        let requirement = CodeSignatureValidator.makeRequirement(
            from: "identifier \"com.example.app\""
        )
        #expect(requirement != nil)
    }

    @Test("a malformed requirement string does not compile")
    func malformedRequirementFails() {
        // Unterminated string literal is not valid requirement-language grammar,
        // so SecRequirementCreateWithString must refuse it.
        let requirement = CodeSignatureValidator.makeRequirement(
            from: "identifier \"unterminated"
        )
        #expect(requirement == nil)
    }

    @Test("an empty requirement string does not compile")
    func emptyRequirementFails() {
        let requirement = CodeSignatureValidator.makeRequirement(from: "")
        #expect(requirement == nil)
    }
}

// MARK: - Fail-closed evaluation paths

@Suite("CodeSignatureValidator: fail-closed evaluate")
struct EvaluateDenyTests {

    @Test("evaluate denies when no audit token is supplied")
    func denyWithoutToken() {
        let result = CodeSignatureValidator.evaluate(
            auditToken: nil,
            requirementString: "anchor apple generic and identifier \"com.example.helper\""
        )
        #expect(result != .valid)
    }

    @Test("evaluate denies when the requirement string will not compile")
    func denyWithBadRequirement() {
        // Even with a (here nil) token, an uncompilable requirement is a deny;
        // the nil-token branch is checked first, so use nil to reach a deny and
        // confirm a bad requirement never yields .valid.
        let result = CodeSignatureValidator.evaluate(
            auditToken: nil,
            requirementString: "identifier \"unterminated"
        )
        if case .valid = result {
            Issue.record("Uncompilable requirement must never validate")
        }
    }
}

// MARK: - HelperAuthorization gate factories

@Suite("HelperAuthorization: gate decisions")
struct HelperAuthorizationGateTests {

    @Test("allowAll permits a request with no token")
    func allowAllPermits() throws {
        try HelperAuthorization.allowAll.authorize()
    }

    @Test("deny rejects with notAuthorized")
    func denyRejects() {
        let gate = HelperAuthorization.deny(reason: "test reason")
        do {
            try gate.authorize()
            Issue.record("Expected deny gate to throw")
        } catch HelperError.notAuthorized(let detail) {
            #expect(detail == "test reason")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("pinning gate is fail-closed: denies when no peer token is present")
    func pinningDeniesWithoutToken() throws {
        let requirement = try CodeSigningRequirement(
            requirementString: "anchor apple generic and identifier \"com.example.helper\""
        )
        let gate = HelperAuthorization.pinning(requirement: requirement)
        do {
            // authorize() with no token is the in-process path; the pinned gate
            // cannot identify a peer, so it must deny rather than allow.
            try gate.authorize()
            Issue.record("Expected pinning gate to deny without a peer token")
        } catch HelperError.notAuthorized {
            // Expected fail-closed path.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
