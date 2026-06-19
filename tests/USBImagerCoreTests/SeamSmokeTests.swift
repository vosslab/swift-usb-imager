/// SeamSmokeTests - placeholder coverage for the WP-1a core seam.
///
/// WP-1a only declares the shared types and service signatures; the service
/// bodies land in WP-1b (checksum), WP-1c (disk/source), and WP-1d (flash),
/// each adding its own test files in this same target. These smoke tests assert
/// the frozen value-type contract so a sibling lane that accidentally changes
/// the seam shape fails here first.
import Foundation
import Testing
@testable import USBImagerCore

// MARK: - FlashProgressData

@Suite("FlashProgressData numeric contract")
struct FlashProgressDataTests {

    @Test("Phase has exactly the two progress-bar cases")
    func phaseCases() {
        #expect(FlashProgressData.Phase.allCases.contains(.writing))
        #expect(FlashProgressData.Phase.allCases.contains(.verifying))
    }

    @Test("Derived fraction is nil when total is zero")
    func fractionUnknownDenominator() {
        let sample = FlashProgressData(phase: .writing, bytesDone: 10, totalBytes: 0)
        #expect(sample.fraction == nil)
    }

    @Test("Derived fraction divides bytesDone by totalBytes")
    func fractionDerived() {
        let sample = FlashProgressData(phase: .writing, bytesDone: 1, totalBytes: 4)
        #expect(sample.fraction == 0.25)
    }

    @Test("Derived fraction clamps to the unit interval")
    func fractionClamped() {
        let sample = FlashProgressData(phase: .verifying, bytesDone: 9, totalBytes: 4)
        #expect(sample.fraction == 1.0)
    }
}

// MARK: - CoreError exit codes

@Suite("CoreError exit-code mapping")
struct CoreErrorExitCodeTests {

    @Test("Each error maps to its fixed CLI exit code")
    func exitCodeMapping() {
        #expect(CoreError.badInput(message: "x").exitCode == .badInput)
        #expect(CoreError.verificationMismatch(expected: "a", actual: "b").exitCode == .verificationMismatch)
        #expect(CoreError.helperUnavailable(message: "x").exitCode == .helperUnavailable)
        #expect(CoreError.flashFailed(message: "x").exitCode == .flashFailed)
        #expect(CoreError.cancelled.exitCode == .cancelled)
        #expect(CoreError.appNotFound(message: "x").exitCode == .appNotFound)
    }

    @Test("Exit-code raw values match the CLI contract table")
    func exitCodeRawValues() {
        #expect(CoreExitCode.success.rawValue == 0)
        #expect(CoreExitCode.verificationMismatch.rawValue == 1)
        #expect(CoreExitCode.badInput.rawValue == 2)
        #expect(CoreExitCode.helperUnavailable.rawValue == 3)
        #expect(CoreExitCode.flashFailed.rawValue == 4)
        #expect(CoreExitCode.cancelled.rawValue == 5)
        #expect(CoreExitCode.appNotFound.rawValue == 6)
    }
}
