/// HelperProtocolTests: real round-trip and validation tests for the XPC
/// control-plane contract.
///
/// Covers:
///   - Codable round-trip for FlashRequest (including each SourceAccess case),
///     FlashProgress, and FlashResult, through the shared HelperProtocolCoding
///     encode/decode helpers used on the wire.
///   - CodeSigningRequirement shape validation: valid strings parse, malformed
///     strings throw the expected error.

import Foundation
import Testing
@testable import HelperProtocol

// MARK: - FlashRequest round-trip

@Suite("FlashRequest Codable round-trip")
struct FlashRequestRoundTripTests {

    @Test("absolutePath request round-trips through the wire coding")
    func absolutePathRoundTrip() throws {
        let original = FlashRequest(
            jobID: JobID.generate(),
            sourceAccess: .absolutePath("/Volumes/Images/ubuntu-24.04.iso"),
            targetBSDName: "disk4",
            sourceBackingBSDName: "disk2",
            advisorySizeBytes: 5_368_709_120,
            advisorySHA512: String(repeating: "a", count: 128)
        )
        let data = try HelperProtocolCoding.encode(original)
        let decoded = try HelperProtocolCoding.decode(FlashRequest.self, from: data)
        #expect(decoded == original)
        // The new correlation and overlap fields survive the wire round trip.
        #expect(decoded.jobID == original.jobID)
        #expect(decoded.sourceBackingBSDName == "disk2")
    }

    @Test("fileDescriptor source case round-trips (reserved marker)")
    func fileDescriptorRoundTrip() throws {
        let original = FlashRequest(
            jobID: JobID.generate(),
            sourceAccess: .fileDescriptor,
            targetBSDName: "disk9",
            sourceBackingBSDName: nil,
            advisorySizeBytes: 0,
            advisorySHA512: nil
        )
        let data = try HelperProtocolCoding.encode(original)
        let decoded = try HelperProtocolCoding.decode(FlashRequest.self, from: data)
        #expect(decoded == original)
        #expect(decoded.sourceAccess == .fileDescriptor)
        #expect(decoded.advisorySHA512 == nil)
        #expect(decoded.sourceBackingBSDName == nil)
    }

    @Test("stageCopy source case round-trips with its staging path")
    func stageCopyRoundTrip() throws {
        let original = FlashRequest(
            jobID: JobID.generate(),
            sourceAccess: .stageCopy("/tmp/stage/image.img"),
            targetBSDName: "disk2",
            sourceBackingBSDName: nil,
            advisorySizeBytes: 1024,
            advisorySHA512: nil
        )
        let data = try HelperProtocolCoding.encode(original)
        let decoded = try HelperProtocolCoding.decode(FlashRequest.self, from: data)
        #expect(decoded == original)
        #expect(decoded.sourceAccess == .stageCopy("/tmp/stage/image.img"))
    }
}

// MARK: - FlashProgress round-trip

@Suite("FlashProgress Codable round-trip")
struct FlashProgressRoundTripTests {

    @Test("progress round-trips across all phases")
    func progressRoundTrips() throws {
        let jobID = JobID(rawValue: "11111111-2222-3333-4444-555555555555")
        let phases: [FlashPhase] = [.unmounting, .writing, .verifying, .done]
        for phase in phases {
            let original = FlashProgress(
                jobID: jobID,
                bytesDone: 4096,
                totalBytes: 8192,
                phase: phase
            )
            let data = try HelperProtocolCoding.encode(original)
            let decoded = try HelperProtocolCoding.decode(FlashProgress.self, from: data)
            #expect(decoded == original)
            #expect(decoded.phase == phase)
        }
    }
}

// MARK: - FlashResult round-trip

@Suite("FlashResult Codable round-trip")
struct FlashResultRoundTripTests {

    @Test("success result with device digest round-trips")
    func successRoundTrip() throws {
        let original = FlashResult(
            jobID: JobID.generate(),
            outcome: .success,
            deviceSHA512: String(repeating: "f", count: 128),
            errorMessage: nil
        )
        let data = try HelperProtocolCoding.encode(original)
        let decoded = try HelperProtocolCoding.decode(FlashResult.self, from: data)
        #expect(decoded == original)
        #expect(decoded.outcome == .success)
        #expect(decoded.errorMessage == nil)
    }

    @Test("failed result with error message round-trips")
    func failedRoundTrip() throws {
        let original = FlashResult(
            jobID: JobID.generate(),
            outcome: .failed,
            deviceSHA512: nil,
            errorMessage: "device disappeared mid-write"
        )
        let data = try HelperProtocolCoding.encode(original)
        let decoded = try HelperProtocolCoding.decode(FlashResult.self, from: data)
        #expect(decoded == original)
        #expect(decoded.outcome == .failed)
        #expect(decoded.deviceSHA512 == nil)
    }

    @Test("cancelled result round-trips")
    func cancelledRoundTrip() throws {
        let original = FlashResult(
            jobID: JobID.generate(),
            outcome: .cancelled,
            deviceSHA512: nil,
            errorMessage: nil
        )
        let data = try HelperProtocolCoding.encode(original)
        let decoded = try HelperProtocolCoding.decode(FlashResult.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - CodeSigningRequirement validation

@Suite("CodeSigningRequirement shape validation")
struct CodeSigningRequirementTests {

    @Test("well-formed designated requirement string parses")
    func validRequirementParses() throws {
        let text = "anchor apple generic and identifier \"com.example.helper\""
        let requirement = try CodeSigningRequirement(requirementString: text)
        #expect(requirement.requirementString == text)
    }

    @Test("identifier-only clause is accepted")
    func identifierOnlyParses() throws {
        let requirement = try CodeSigningRequirement(
            requirementString: "identifier \"com.example.app\""
        )
        #expect(requirement.requirementString.contains("identifier"))
    }

    @Test("grouped certificate clause with parentheses parses")
    func groupedClauseParses() throws {
        let text = "(certificate leaf[subject.CN] = \"Apple Mac OS Application Signing\")"
        let requirement = try CodeSigningRequirement(requirementString: text)
        #expect(requirement.requirementString == text)
    }

    @Test("empty string throws .empty")
    func emptyThrows() {
        #expect(throws: CodeSigningRequirementError.empty) {
            try CodeSigningRequirement(requirementString: "   ")
        }
    }

    @Test("string with no recognized clause throws .missingClause")
    func missingClauseThrows() {
        #expect(throws: CodeSigningRequirementError.missingClause) {
            try CodeSigningRequirement(requirementString: "and or not foobar")
        }
    }

    @Test("unbalanced quotes throw .unbalancedQuotes")
    func unbalancedQuotesThrows() {
        #expect(throws: CodeSigningRequirementError.unbalancedQuotes) {
            try CodeSigningRequirement(requirementString: "identifier \"com.example.helper")
        }
    }

    @Test("unbalanced parentheses throw .unbalancedParentheses")
    func unbalancedParenthesesThrows() {
        #expect(throws: CodeSigningRequirementError.unbalancedParentheses) {
            try CodeSigningRequirement(requirementString: "(identifier \"com.example.helper\"")
        }
    }

    @Test("a close-before-open paren throws .unbalancedParentheses")
    func closeBeforeOpenThrows() {
        #expect(throws: CodeSigningRequirementError.unbalancedParentheses) {
            try CodeSigningRequirement(requirementString: "identifier \"x\") and anchor apple")
        }
    }
}
