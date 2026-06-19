/// VerifyCommand.swift - the `usbimager verify` subcommand.
///
/// Hashes an on-disk image file and optionally compares the digest to an
/// expected value. All hashing, hex parsing, and digest comparison is delegated
/// to `ChecksumService` through the injectable seam. The CLI works exclusively
/// with hex strings returned from core; it never holds a `SHA512Digest` value
/// (which would require importing Verifier, excluded from this target by the plan
/// boundary: CLI depends on USBImagerCore + ArgumentParser only).
///
/// Behaviour per the CLI contract:
///   - Always streams the image file and prints the lowercase hex SHA-512.
///   - With --sha512: validates the hex and compares; exits 0 on match, exits 1
///     (verificationMismatch) on mismatch, exits 2 on malformed hex.
///   - With --sums: reads the file body, finds the line matching the image
///     filename, and compares; exits 0 on match, exits 1 on mismatch.
///   - With neither option: prints the digest and exits 0.
///   - Unreadable image, malformed hex, unparsable sums, or missing filename
///     in sums -> exits 2 (badInput) via Usbimager.fail.
///
/// Naming note (from the plan): `verify` means source-image checksum -- it
/// hashes an image file, not a device. Device read-back is `flash --verify`.

import ArgumentParser
import Foundation
import USBImagerCore

// MARK: - VerifyOutcome

/// The typed result of a `verify` run, returned by `performVerify` without
/// terminating the process. Mirrors the `FlashRunResult` pattern used by
/// `FlashCommand` so the delegation tests can drive the full path against fakes.
///
/// Cases:
///   - `digestOnly`: image was hashed and the hex was printed; no comparison
///     was requested; process should exit 0.
///   - `match`: both digests were compared and they match; process exits 0.
///   - `failure`: a `CoreError` was raised; process should call `Usbimager.fail`.
enum VerifyOutcome: Equatable {
    /// Hashed successfully; no expected digest was supplied. Carries the computed hex.
    case digestOnly(computedHex: String)
    /// Both digests were compared and matched. Carries the computed hex.
    case match(computedHex: String)
    /// A core error was raised (badInput, verificationMismatch, ...).
    case failure(error: CoreError)
}

/// `usbimager verify <image> [--sums <file> | --sha512 <hex>]`.
struct VerifyCommand: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Compute an image's SHA-512 and compare it to an expected digest."
    )

    // MARK: - Arguments and options

    /// The image file to hash.
    @Argument(help: "Path to the image file to verify.")
    var image: String

    /// A `SHA512SUMS` file whose line for this image holds the expected digest.
    @Option(name: .long, help: "A SHA512SUMS file holding the expected digest.")
    var sums: String?

    /// An expected SHA-512 digest as 128 hex characters.
    @Option(name: .long, help: "Expected SHA-512 digest (128 hex characters).")
    var sha512: String?

    // MARK: - Run

    /// Hash the image and, when an expected digest was supplied, compare it.
    ///
    /// Delegates to `performVerify` (the testable path without process exit), then
    /// routes the typed outcome to the shared exit path so the process exit code
    /// always matches the frozen CLI contract.
    func run() throws {
        let services = Usbimager.services()
        let outcome = VerifyCommand.performVerify(
            imagePath: image,
            sumsPath: sums,
            sha512Hex: sha512,
            services: services
        )
        switch outcome {
        case .digestOnly(let computedHex):
            // Already printed inside performVerify; exit 0.
            print(computedHex)
            Usbimager.exit(with: .success)
        case .match(let computedHex):
            // Already printed inside performVerify; print match confirmation.
            print(computedHex)
            print("Match: SHA-512 digest verified.")
            Usbimager.exit(with: .success)
        case .failure(let error):
            Usbimager.fail(error)
        }
    }
}

// MARK: - Verify orchestration (testable, no process exit)

extension VerifyCommand {

    /// Hash the image file and optionally compare to an expected digest, returning
    /// a typed `VerifyOutcome` without terminating the process.
    ///
    /// This is the full `verify` behavior minus the final `Foundation.exit`: it
    /// computes the digest via `ChecksumService.sha512Hex(ofFileAt:)`, then either
    /// validates a pasted hex (`--sha512`) or parses a sums file (`--sums`),
    /// compares, and returns the typed outcome. The caller maps that to an exit code.
    ///
    /// Keeping the exit out of `performVerify` lets delegation tests drive the full
    /// path against a recording fake and assert the outcome without killing the
    /// test process.
    ///
    /// - Parameters:
    ///   - imagePath: the positional image file path to hash.
    ///   - sumsPath: the `--sums` file path when provided.
    ///   - sha512Hex: the `--sha512` pasted hex string when provided.
    ///   - services: the resolved core services (real or injected fakes).
    /// - Returns: the typed `VerifyOutcome`; error cases arrive as `.failure`.
    static func performVerify(
        imagePath: String,
        sumsPath: String?,
        sha512Hex: String?,
        services: CoreServices
    ) -> VerifyOutcome {
        let checksumService = services.checksum
        let imageURL = URL(fileURLWithPath: imagePath)

        // Stream-hash the image file and get the result as a lowercase hex string.
        // Unreadable / missing path -> CoreError.badInput -> .failure(.badInput).
        let computedHex: String
        do {
            computedHex = try checksumService.sha512Hex(ofFileAt: imageURL)
        } catch let coreError as CoreError {
            return .failure(error: coreError)
        } catch {
            return .failure(error: .badInput(message: "Could not hash image at \"\(imagePath)\": \(error)."))
        }

        // Resolve which expected digest (if any) to compare against.
        if let sumsFilePath = sumsPath {
            // --sums: read the SHA512SUMS file body and find the entry by filename.
            let sumsBody: String
            do {
                sumsBody = try String(contentsOfFile: sumsFilePath, encoding: .utf8)
            } catch {
                return .failure(error: .badInput(
                    message: "Could not read SHA512SUMS file at \"\(sumsFilePath)\": \(error)."
                ))
            }
            let expectedHex: String
            do {
                // Match by image last path component so a full path like "/tmp/ubuntu.iso"
                // finds the "ubuntu.iso" entry in the sums file.
                expectedHex = try checksumService.expectedDigestHex(fromSums: sumsBody, matching: imagePath)
            } catch let coreError as CoreError {
                return .failure(error: coreError)
            } catch {
                return .failure(error: .badInput(message: "Could not parse sums file: \(error)."))
            }
            // Compare and return the appropriate outcome.
            return hexMatchOutcome(
                checksumService: checksumService,
                computedHex: computedHex,
                expectedHex: expectedHex
            )
        } else if let hexInput = sha512Hex {
            // --sha512: validate the provided hex string (normalise and confirm it is
            // 128 hex chars) then compare. A malformed hex -> .failure(.badInput).
            let expectedHex: String
            do {
                expectedHex = try checksumService.validatePastedHexString(hexInput)
            } catch let coreError as CoreError {
                return .failure(error: coreError)
            } catch {
                return .failure(error: .badInput(message: "Malformed hex: \(error)."))
            }
            // Compare and return the appropriate outcome.
            return hexMatchOutcome(
                checksumService: checksumService,
                computedHex: computedHex,
                expectedHex: expectedHex
            )
        }
        // Neither option: digest was computed; return it for the caller to print.
        return .digestOnly(computedHex: computedHex)
    }
}

// MARK: - Private helpers

/// Compare two hex digests via the core service and return the typed outcome.
///
/// Extracts the comparison logic shared by the `--sums` and `--sha512` branches.
///
/// - Parameters:
///   - checksumService: the core service that performs the equality check.
///   - computedHex: the lowercase hex computed from the image file.
///   - expectedHex: the lowercase hex from the user-supplied expected digest.
/// - Returns: `.match` when digests match, `.failure(.verificationMismatch)` otherwise.
private func hexMatchOutcome(
    checksumService: any ChecksumService,
    computedHex: String,
    expectedHex: String
) -> VerifyOutcome {
    if checksumService.hexDigestsMatch(computedHex: computedHex, expectedHex: expectedHex) {
        return .match(computedHex: computedHex)
    } else {
        return .failure(error: .verificationMismatch(expected: expectedHex, actual: computedHex))
    }
}

