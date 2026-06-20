/// CLIScaffoldTests.swift - WP-3a scaffold tests for the `usbimager` root.
///
/// These prove the scaffold contract the subcommand lanes (WP-3b/3c/3d/3e)
/// build on:
///   - the root command registers all four subcommands,
///   - the injectable service seam (`Usbimager.servicesOverride`) is honored, so
///     a subcommand can be run against fakes, and
///   - the shared exit-code mapping is the frozen CLI-contract table.
///
/// They do NOT test subcommand behavior (that arrives with each lane). They lock
/// the seam and the registration so a later lane's delegation test can simply set
/// `Usbimager.servicesOverride` to a recording fake.

import ArgumentParser
import DiskModel
import Foundation
import Testing
import Verifier
import KeychainStore
@testable import USBImagerCLI
@testable import USBImagerCore

// MARK: - Fakes for the service seam

/// A do-nothing `ChecksumService` for seam tests. Methods are not exercised here;
/// they exist so the fake can stand in for the real service in a `CoreServices`.
struct FakeChecksumService: ChecksumService {
    func validatePastedHex(_ hexString: String) throws -> SHA512Digest {
        throw CoreError.badInput(message: "fake")
    }
    func expectedDigest(fromSums body: String, matching filename: String) throws -> SHA512Digest {
        throw CoreError.badInput(message: "fake")
    }
    func matches(deviceDigest: SHA512Digest, expected: SHA512Digest) -> Bool { false }
    func matchOutcome(
        deviceDigest: SHA512Digest,
        officialDigest: SHA512Digest?,
        imageByteLength: Int
    ) throws -> ChecksumMatchOutcome { .noOfficialChecksum }
    func lookupTrustedCache(digest: SHA512Digest, imageByteLength: Int) throws -> TrustedChecksum? { nil }
    func saveTrustedCache(_ checksum: TrustedChecksum) throws {}
}

/// A `ImageSourceService` that returns a fixed byte length so a test can prove the
/// seam delivered this exact fake to a subcommand.
struct FakeImageSourceService: ImageSourceService {
    let fixedLength: Int
    func byteLength(of url: URL) throws -> Int { fixedLength }
}

/// A `DiskTargetService` returning a fixed, empty disk set.
struct FakeDiskTargetService: DiskTargetService {
    func snapshotDisks() async -> [DiskDescriptor] { [] }
    func validTargets(
        from disks: [DiskDescriptor],
        imageSizeBytes: Int,
        sourceBackingBSDName: String?
    ) -> [DiskDescriptor] { [] }
    func displayName(for disk: DiskDescriptor) -> String { "fake" }
}

/// A `FlashOrchestrationService` that always reports the helper unavailable.
struct FakeFlashOrchestrationService: FlashOrchestrationService {
    func flash(
        source: URL,
        target: DiskDescriptor,
        advisorySHA512: String?,
        verifyReadBack: Bool,
        progress: @escaping @Sendable (FlashProgressData) -> Void
    ) async -> FlashRunResult {
        .failure(error: .helperUnavailable(message: "fake"))
    }
    func cancel() async {}
}

/// Build a fake services bundle with a recognizable image-source byte length.
func makeFakeServices(byteLength: Int) -> CoreServices {
    let services = CoreServices(
        checksum: FakeChecksumService(),
        imageSource: FakeImageSourceService(fixedLength: byteLength),
        diskTarget: FakeDiskTargetService(),
        flashOrchestration: FakeFlashOrchestrationService()
    )
    return services
}

// MARK: - Subcommand registration

@Suite("usbimager root registers all four subcommands")
struct SubcommandRegistrationTests {

    @Test("All four subcommands are registered on the root")
    func registersFour() {
        let registered = Usbimager.configuration.subcommands.map { String(describing: $0) }
        #expect(registered.contains("ListCommand"))
        #expect(registered.contains("VerifyCommand"))
        #expect(registered.contains("FlashCommand"))
        #expect(registered.contains("OpenCommand"))
    }

    @Test("Each subcommand declares its CLI name")
    func subcommandNames() {
        #expect(ListCommand.configuration.commandName == "list")
        #expect(VerifyCommand.configuration.commandName == "verify")
        #expect(FlashCommand.configuration.commandName == "flash")
        #expect(OpenCommand.configuration.commandName == "open")
    }

    @Test("Root command name is usbimager")
    func rootName() {
        #expect(Usbimager.configuration.commandName == "usbimager")
    }
}

// MARK: - Injectable service seam

@Suite("usbimager service seam is injectable", .serialized)
struct ServiceSeamTests {

    /// Clear any override after each case so suites stay independent.
    private func clearOverride() { Usbimager.servicesOverride = nil }

    @Test("services() returns the test override when set")
    func overrideHonored() throws {
        defer { clearOverride() }
        Usbimager.servicesOverride = makeFakeServices(byteLength: 4242)
        let resolved = Usbimager.services()
        // Proven by the recognizable fake byte length flowing through the seam.
        let length = try resolved.imageSource.byteLength(of: URL(fileURLWithPath: "/tmp/x"))
        #expect(length == 4242)
    }

    @Test("services() falls back to live services when no override is set")
    func liveFallback() {
        clearOverride()
        let resolved = Usbimager.services()
        // Falsifiable contract: with no override, the seam must resolve the LIVE
        // services, never a test fake. If the fallback path leaked an override
        // (or the seam failed to clear), the resolved image source would be the
        // FakeImageSourceService injected elsewhere; assert it is not.
        #expect(!(resolved.imageSource is FakeImageSourceService))
    }
}

// MARK: - Shared exit-code mapping

@Suite("usbimager shared exit-code path matches the CLI contract")
struct ExitCodeMappingTests {

    @Test("Error messages exist for every CoreError case")
    func messagesForEachCase() {
        let cases: [CoreError] = [
            .badInput(message: "m"),
            .verificationMismatch(expected: "a", actual: "b"),
            .helperUnavailable(message: "m"),
            .flashFailed(message: "m"),
            .cancelled,
            .appNotFound(message: "m"),
        ]
        for error in cases {
            #expect(!Usbimager.errorMessage(for: error).isEmpty)
        }
    }

    @Test("Each CoreError maps to its frozen exit code")
    func exitCodes() {
        #expect(CoreError.badInput(message: "m").exitCode == .badInput)
        #expect(CoreError.verificationMismatch(expected: "a", actual: "b").exitCode == .verificationMismatch)
        #expect(CoreError.helperUnavailable(message: "m").exitCode == .helperUnavailable)
        #expect(CoreError.flashFailed(message: "m").exitCode == .flashFailed)
        #expect(CoreError.cancelled.exitCode == .cancelled)
        #expect(CoreError.appNotFound(message: "m").exitCode == .appNotFound)
    }
}
