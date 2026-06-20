/// VerifyCommandTests.swift - WP-3c delegation and exit-mapping tests for `verify`.
///
/// These tests prove that `usbimager verify`:
///   - delegates hashing to `ChecksumService.sha512Hex(ofFileAt:)`,
///   - delegates pasted-hex validation to `validatePastedHexString` (`--sha512`),
///   - delegates sums-file lookup to `expectedDigestHex(fromSums:matching:)` (`--sums`),
///   - delegates comparison to `hexDigestsMatch`,
///   - returns `.match` on a match, `.failure(.verificationMismatch)` on a mismatch,
///   - returns `.failure(.badInput)` on an unreadable image or malformed hex / sums,
///   - returns `.digestOnly` when neither `--sha512` nor `--sums` is supplied.
///
/// The full `run()` terminates the process via `Usbimager.exit`/`fail`, so all
/// tests drive `VerifyCommand.performVerify` (the same path minus the final exit)
/// and assert the typed `VerifyOutcome`. No real files are hashed; the checksum
/// service is a recording fake.

import Foundation
import KeychainStore
import Testing
import Verifier
@testable import USBImagerCLI
@testable import USBImagerCore

// MARK: - Recording fake checksum service

/// A `ChecksumService` that records protocol-requirement calls and returns
/// configurable results. Lets a test assert delegation and drive each outcome
/// without touching real files.
///
/// The `sha512Hex`, `validatePastedHexString`, `expectedDigestHex`, and
/// `hexDigestsMatch` convenience methods live in the `ChecksumService` protocol
/// extension and are statically dispatched -- they cannot be intercepted by
/// overriding them in a concrete conformer when the caller holds `any ChecksumService`.
/// Instead, this fake overrides the underlying PROTOCOL REQUIREMENTS
/// (`sha512(ofFileAt:)`, `validatePastedHex`, `expectedDigest(fromSums:matching:)`,
/// `matches`) so the extension wrappers call the fake versions and the test can
/// observe delegation by inspecting those call-recording properties.
final class RecordingChecksumService: ChecksumService, @unchecked Sendable {

    // MARK: - Configurable results for sha512(ofFileAt:)

    /// The `SHA512Digest` `sha512(ofFileAt:)` returns. Defaults to 128 `a` hex chars.
    var digestToReturn: SHA512Digest = SHA512Digest(hexString: String(repeating: "a", count: 128))!

    /// When set, `sha512(ofFileAt:)` throws this instead of returning `digestToReturn`.
    var sha512Error: CoreError? = nil

    // MARK: - Configurable results for validatePastedHex

    /// The `SHA512Digest` `validatePastedHex` returns.
    var validatedDigestToReturn: SHA512Digest = SHA512Digest(hexString: String(repeating: "a", count: 128))!

    /// When set, `validatePastedHex` throws this.
    var validatePastedHexError: CoreError? = nil

    // MARK: - Configurable results for expectedDigest(fromSums:matching:)

    /// The `SHA512Digest` `expectedDigest(fromSums:matching:)` returns.
    var expectedDigestToReturn: SHA512Digest = SHA512Digest(hexString: String(repeating: "a", count: 128))!

    /// When set, `expectedDigest(fromSums:matching:)` throws this.
    var expectedDigestError: CoreError? = nil

    // MARK: - Configurable results for matches

    /// The bool `matches(deviceDigest:expected:)` returns.
    var matchesResult: Bool = true

    // MARK: - Call recording

    var sha512OfFileAtCallCount = 0
    var lastSha512URL: URL? = nil

    var validatePastedHexCallCount = 0
    var lastValidatePastedHexInput: String? = nil

    var expectedDigestCallCount = 0
    var lastExpectedDigestFilename: String? = nil

    var matchesCallCount = 0

    // MARK: - ChecksumService protocol requirements

    func sha512(ofFileAt url: URL) throws -> SHA512Digest {
        sha512OfFileAtCallCount += 1
        lastSha512URL = url
        if let error = sha512Error {
            throw error
        }
        return digestToReturn
    }

    func validatePastedHex(_ hexString: String) throws -> SHA512Digest {
        validatePastedHexCallCount += 1
        lastValidatePastedHexInput = hexString
        if let error = validatePastedHexError {
            throw error
        }
        return validatedDigestToReturn
    }

    func expectedDigest(fromSums body: String, matching filename: String) throws -> SHA512Digest {
        expectedDigestCallCount += 1
        lastExpectedDigestFilename = filename
        if let error = expectedDigestError {
            throw error
        }
        return expectedDigestToReturn
    }

    func matches(deviceDigest: SHA512Digest, expected: SHA512Digest) -> Bool {
        matchesCallCount += 1
        return matchesResult
    }

    func matchOutcome(
        deviceDigest: SHA512Digest,
        officialDigest: SHA512Digest?,
        imageByteLength: Int
    ) throws -> ChecksumMatchOutcome { .noOfficialChecksum }

    func lookupTrustedCache(digest: SHA512Digest, imageByteLength: Int) throws -> TrustedChecksum? { nil }

    func saveTrustedCache(_ checksum: TrustedChecksum) throws {}
}

// MARK: - Fixture helpers

/// Build a `CoreServices` bundle wired with the recording checksum service.
private func makeVerifyServices(checksum: RecordingChecksumService) -> CoreServices {
    return CoreServices(
        checksum: checksum,
        imageSource: FakeImageSourceService(fixedLength: 4096),
        diskTarget: nil,
        flashOrchestration: FakeFlashOrchestrationService()
    )
}

// MARK: - Delegation tests (digest-only, --sha512, --sums)

@Suite("usbimager verify delegates to ChecksumService", .serialized)
struct VerifyCommandDelegationTests {

    @Test("sha512(ofFileAt:) is called with the image URL")
    func callsSha512WithImageURL() {
        let fake = RecordingChecksumService()
        let services = makeVerifyServices(checksum: fake)

        _ = VerifyCommand.performVerify(
            imagePath: "/tmp/fixture.iso",
            sumsPath: nil,
            sha512Hex: nil,
            services: services
        )

        // The extension sha512Hex(ofFileAt:) calls the protocol requirement sha512(ofFileAt:).
        #expect(fake.sha512OfFileAtCallCount == 1)
        #expect(fake.lastSha512URL?.path == "/tmp/fixture.iso")
    }

    @Test("--sha512 path calls validatePastedHex and matches via the service")
    func sha512OptionDelegatesValidationAndComparison() {
        let fake = RecordingChecksumService()
        // Both computed and validated digests match so matches returns true.
        let matchDigest = SHA512Digest(hexString: String(repeating: "c", count: 128))!
        fake.digestToReturn = matchDigest
        fake.validatedDigestToReturn = matchDigest
        fake.matchesResult = true
        let services = makeVerifyServices(checksum: fake)

        let pastedHex = String(repeating: "c", count: 128)
        _ = VerifyCommand.performVerify(
            imagePath: "/tmp/fixture.iso",
            sumsPath: nil,
            sha512Hex: pastedHex,
            services: services
        )

        // The extension validatePastedHexString calls validatePastedHex (protocol requirement).
        #expect(fake.validatePastedHexCallCount == 1)
        #expect(fake.lastValidatePastedHexInput == pastedHex)
        // The extension hexDigestsMatch calls matches (protocol requirement).
        #expect(fake.matchesCallCount == 1)
    }

    @Test("--sums path calls expectedDigest(fromSums:matching:) and matches via the service")
    func sumsOptionDelegatesLookupAndComparison() {
        let fake = RecordingChecksumService()
        let matchDigest = SHA512Digest(hexString: String(repeating: "d", count: 128))!
        fake.digestToReturn = matchDigest
        fake.expectedDigestToReturn = matchDigest
        fake.matchesResult = true
        let services = makeVerifyServices(checksum: fake)

        // Write a real temp sums file so the String(contentsOfFile:) read succeeds.
        let sumsBody = String(repeating: "d", count: 128) + "  fixture.iso\n"
        let tmpURL = URL(fileURLWithPath: "/tmp/verify_test.sha512sums")
        try? sumsBody.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        _ = VerifyCommand.performVerify(
            imagePath: "/tmp/fixture.iso",
            sumsPath: tmpURL.path,
            sha512Hex: nil,
            services: services
        )

        // The extension expectedDigestHex calls expectedDigest(fromSums:matching:).
        #expect(fake.expectedDigestCallCount == 1)
        #expect(fake.lastExpectedDigestFilename == "/tmp/fixture.iso")
        // The extension hexDigestsMatch calls matches.
        #expect(fake.matchesCallCount == 1)
    }

    @Test("digest-only path calls sha512(ofFileAt:) but not validatePastedHex or expectedDigest")
    func digestOnlyPathSkipsComparison() {
        let fake = RecordingChecksumService()
        let services = makeVerifyServices(checksum: fake)

        _ = VerifyCommand.performVerify(
            imagePath: "/tmp/fixture.iso",
            sumsPath: nil,
            sha512Hex: nil,
            services: services
        )

        #expect(fake.sha512OfFileAtCallCount == 1)
        #expect(fake.validatePastedHexCallCount == 0)
        #expect(fake.expectedDigestCallCount == 0)
        #expect(fake.matchesCallCount == 0)
    }
}

// MARK: - Exit-code mapping (outcome cases)

@Suite("usbimager verify maps outcomes to the correct VerifyOutcome case", .serialized)
struct VerifyCommandOutcomeTests {

    @Test("digest-only (no comparison) returns .digestOnly with the computed hex")
    func digestOnlyReturnsDigestOnly() {
        let fake = RecordingChecksumService()
        let eDigest = SHA512Digest(hexString: String(repeating: "e", count: 128))!
        fake.digestToReturn = eDigest
        let services = makeVerifyServices(checksum: fake)

        let result = VerifyCommand.performVerify(
            imagePath: "/tmp/fixture.iso",
            sumsPath: nil,
            sha512Hex: nil,
            services: services
        )

        #expect(result == .digestOnly(computedHex: String(repeating: "e", count: 128)))
    }

    @Test("match (--sha512) returns .match with the computed hex")
    func sha512MatchReturnsMatch() {
        let fake = RecordingChecksumService()
        let matchDigest = SHA512Digest(hexString: String(repeating: "f", count: 128))!
        fake.digestToReturn = matchDigest
        fake.validatedDigestToReturn = matchDigest
        fake.matchesResult = true
        let services = makeVerifyServices(checksum: fake)

        let matchHex = String(repeating: "f", count: 128)
        let result = VerifyCommand.performVerify(
            imagePath: "/tmp/fixture.iso",
            sumsPath: nil,
            sha512Hex: matchHex,
            services: services
        )

        #expect(result == .match(computedHex: matchHex))
    }

    @Test("mismatch (--sha512) returns .failure(.verificationMismatch) -- exit 1")
    func sha512MismatchReturnsFailure() {
        let fake = RecordingChecksumService()
        let computedDigest = SHA512Digest(hexString: String(repeating: "1", count: 128))!
        let expectedDigest = SHA512Digest(hexString: String(repeating: "2", count: 128))!
        fake.digestToReturn = computedDigest
        fake.validatedDigestToReturn = expectedDigest
        // matches returns false to simulate a mismatch.
        fake.matchesResult = false
        let services = makeVerifyServices(checksum: fake)

        let expectedHex = String(repeating: "2", count: 128)
        let result = VerifyCommand.performVerify(
            imagePath: "/tmp/fixture.iso",
            sumsPath: nil,
            sha512Hex: expectedHex,
            services: services
        )

        if case .failure(let error) = result {
            // SeamSmokeTests owns the numeric exit-code table; the typed enum
            // check above is the contract this test asserts.
            #expect(error.exitCode == .verificationMismatch)
        } else {
            Issue.record("Expected .failure(.verificationMismatch) for a digest mismatch.")
        }
    }

    @Test("match (--sums) returns .match with the computed hex")
    func sumsMatchReturnsMatch() {
        let fake = RecordingChecksumService()
        let matchDigest = SHA512Digest(hexString: String(repeating: "a", count: 128))!
        fake.digestToReturn = matchDigest
        fake.expectedDigestToReturn = matchDigest
        fake.matchesResult = true
        let services = makeVerifyServices(checksum: fake)

        let matchHex = String(repeating: "a", count: 128)
        let sumsBody = matchHex + "  fixture.iso\n"
        let tmpURL = URL(fileURLWithPath: "/tmp/verify_sumstest.sha512sums")
        try? sumsBody.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let result = VerifyCommand.performVerify(
            imagePath: "/tmp/fixture.iso",
            sumsPath: tmpURL.path,
            sha512Hex: nil,
            services: services
        )

        #expect(result == .match(computedHex: matchHex))
    }

    @Test("mismatch (--sums) returns .failure(.verificationMismatch) -- exit 1")
    func sumsMismatchReturnsFailure() {
        let fake = RecordingChecksumService()
        let computedDigest = SHA512Digest(hexString: String(repeating: "3", count: 128))!
        let expectedDigestValue = SHA512Digest(hexString: String(repeating: "4", count: 128))!
        fake.digestToReturn = computedDigest
        fake.expectedDigestToReturn = expectedDigestValue
        fake.matchesResult = false
        let services = makeVerifyServices(checksum: fake)

        let expectedHex = String(repeating: "4", count: 128)
        let sumsBody = expectedHex + "  fixture.iso\n"
        let tmpURL = URL(fileURLWithPath: "/tmp/verify_sumstest2.sha512sums")
        try? sumsBody.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let result = VerifyCommand.performVerify(
            imagePath: "/tmp/fixture.iso",
            sumsPath: tmpURL.path,
            sha512Hex: nil,
            services: services
        )

        if case .failure(let error) = result {
            // SeamSmokeTests owns the numeric exit-code table; the typed enum
            // check above is the contract this test asserts.
            #expect(error.exitCode == .verificationMismatch)
        } else {
            Issue.record("Expected .failure(.verificationMismatch) for a sums mismatch.")
        }
    }
}

// MARK: - Bad-input paths (exit 2)

@Suite("usbimager verify returns .failure(.badInput) on bad input -- exit 2", .serialized)
struct VerifyCommandBadInputTests {

    @Test("Unreadable image yields .failure(.badInput) -- exit 2")
    func unreadableImageExitsTwo() {
        let fake = RecordingChecksumService()
        // sha512(ofFileAt:) throws badInput for an unreadable image.
        fake.sha512Error = .badInput(message: "file not found")
        let services = makeVerifyServices(checksum: fake)

        let result = VerifyCommand.performVerify(
            imagePath: "/tmp/missing_fixture.iso",
            sumsPath: nil,
            sha512Hex: nil,
            services: services
        )

        if case .failure(let error) = result {
            // SeamSmokeTests owns the numeric exit-code table; the typed enum
            // check is the contract this test asserts.
            #expect(error.exitCode == .badInput)
        } else {
            Issue.record("Expected .failure(.badInput) for an unreadable image.")
        }
    }

    @Test("Malformed --sha512 hex string yields .failure(.badInput) -- exit 2")
    func malformedSha512HexExitsTwo() {
        let fake = RecordingChecksumService()
        // validatePastedHex throws badInput for a malformed hex string.
        fake.validatePastedHexError = .badInput(message: "not a valid hex string")
        let services = makeVerifyServices(checksum: fake)

        let result = VerifyCommand.performVerify(
            imagePath: "/tmp/fixture.iso",
            sumsPath: nil,
            sha512Hex: "notahex",
            services: services
        )

        if case .failure(let error) = result {
            // SeamSmokeTests owns the numeric exit-code table; the typed enum
            // check is the contract this test asserts.
            #expect(error.exitCode == .badInput)
        } else {
            Issue.record("Expected .failure(.badInput) for a malformed --sha512 value.")
        }
    }

    @Test("Unreadable --sums file yields .failure(.badInput) -- exit 2")
    func unreadableSumsFileExitsTwo() {
        let fake = RecordingChecksumService()
        let services = makeVerifyServices(checksum: fake)

        let result = VerifyCommand.performVerify(
            imagePath: "/tmp/fixture.iso",
            sumsPath: "/tmp/definitely_does_not_exist_12345.sha512sums",
            sha512Hex: nil,
            services: services
        )

        if case .failure(let error) = result {
            // SeamSmokeTests owns the numeric exit-code table; the typed enum
            // check is the contract this test asserts.
            #expect(error.exitCode == .badInput)
        } else {
            Issue.record("Expected .failure(.badInput) for an unreadable sums file.")
        }
    }

    @Test("Unparsable sums body yields .failure(.badInput) -- exit 2")
    func unparsableSumsBodyExitsTwo() {
        let fake = RecordingChecksumService()
        // expectedDigest(fromSums:matching:) throws badInput when the body has no match.
        fake.expectedDigestError = .badInput(message: "no matching entry")
        let services = makeVerifyServices(checksum: fake)

        let sumsBody = "not a valid sums line\n"
        let tmpURL = URL(fileURLWithPath: "/tmp/verify_bad_sums.sha512sums")
        try? sumsBody.write(to: tmpURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let result = VerifyCommand.performVerify(
            imagePath: "/tmp/fixture.iso",
            sumsPath: tmpURL.path,
            sha512Hex: nil,
            services: services
        )

        if case .failure(let error) = result {
            // SeamSmokeTests owns the numeric exit-code table; the typed enum
            // check is the contract this test asserts.
            #expect(error.exitCode == .badInput)
        } else {
            Issue.record("Expected .failure(.badInput) for an unparsable sums file.")
        }
    }
}
