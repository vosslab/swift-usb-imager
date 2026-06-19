/// FileHashAndDiskLookupTests.swift - unit tests for the WP-1e core seam additions.
///
/// Covers two new service methods:
///   - DefaultChecksumService.sha512(ofFileAt:): streaming file hash.
///       * equivalence: the streamed digest matches Verifier.sha512(of:) over the
///         same bytes (proving the chunked path equals the one-shot path), tested
///         for an empty file, a small file, and a file larger than one chunk.
///       * unreadable path: a missing file throws CoreError.badInput.
///   - DefaultDiskTargetService BSD-name lookup: firstDescriptor(withBSDName:in:),
///       the pure matching helper the public diskDescriptor(withBSDName:) delegates
///       to. Driven by a caller-controlled descriptor list so it needs no live
///       DiskArbitration session.
///       * a present name returns the matching descriptor.
///       * a non-existent name returns nil.
///       * an empty list returns nil.
import Foundation
import Testing
@testable import USBImagerCore
@testable import DiskModel
import KeychainStore
import Verifier

// MARK: - Fixture helpers

/// Build a DefaultChecksumService backed by an in-memory Keychain (file hashing
/// does not touch the Keychain, but the init requires a store).
private func makeChecksumService() -> DefaultChecksumService {
    DefaultChecksumService(keychainStore: KeychainStore(backend: InMemoryKeychainBackend()))
}

/// Write `data` to a unique temp file under /tmp and return its URL.
private func writeTempFile(_ data: Data) throws -> URL {
    let url = URL(fileURLWithPath: "/tmp/usbimager_hash_test_\(UUID().uuidString).bin")
    try data.write(to: url)
    return url
}

/// Build a minimal external USB descriptor, overriding only the BSD name.
private func makeDisk(bsdName: String) -> DiskDescriptor {
    let disk = DiskDescriptor(
        bsdName: bsdName,
        devicePath: "/dev/\(bsdName)",
        rawDevicePath: "/dev/r\(bsdName)",
        sizeBytes: 32_000_000_000,
        isRemovable: true,
        isEjectable: true,
        isInternal: false,
        busProtocol: .usb,
        isWritable: true,
        isSynthesized: false,
        carriesMacOSSystem: false,
        carriesTimeMachine: false,
        mountPoints: []
    )
    return disk
}

// MARK: - sha512(ofFileAt:) equivalence

@Suite("DefaultChecksumService - sha512(ofFileAt:)")
struct FileHashTests {

    @Test("Empty file hashes to the same digest as the one-shot path")
    func emptyFileMatchesOneShot() throws {
        let svc = makeChecksumService()
        let bytes = Data()
        let url = try writeTempFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try svc.sha512(ofFileAt: url)
        let oneShot = Verifier.sha512(of: bytes)
        #expect(streamed == oneShot)
    }

    @Test("Small file hashes to the same digest as the one-shot path")
    func smallFileMatchesOneShot() throws {
        let svc = makeChecksumService()
        // A few hundred bytes of known content, well under one 1 MiB chunk.
        let bytes = Data("the quick brown fox jumps over the lazy dog".utf8)
        let url = try writeTempFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try svc.sha512(ofFileAt: url)
        let oneShot = Verifier.sha512(of: bytes)
        #expect(streamed == oneShot)
    }

    @Test("Multi-chunk file hashes to the same digest as the one-shot path")
    func multiChunkFileMatchesOneShot() throws {
        let svc = makeChecksumService()
        // 2.5 MiB so the streaming loop runs more than two full 1 MiB chunks
        // plus a partial final chunk: this is the case the chunked path must
        // get right relative to the one-shot path.
        let byteCount = (5 * (1 << 20)) / 2  // 2.5 MiB
        var bytes = Data(count: byteCount)
        // Fill with a non-uniform pattern so a chunk-boundary bug would change
        // the digest rather than hashing identical bytes everywhere.
        for index in 0..<byteCount {
            bytes[index] = UInt8(index % 251)
        }
        let url = try writeTempFile(bytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try svc.sha512(ofFileAt: url)
        let oneShot = Verifier.sha512(of: bytes)
        #expect(streamed == oneShot)
    }

    // MARK: Unreadable path

    @Test("Missing file throws CoreError.badInput")
    func missingFileThrowsBadInput() {
        let svc = makeChecksumService()
        let missing = URL(fileURLWithPath: "/tmp/usbimager_nonexistent_\(UUID().uuidString).bin")
        do {
            _ = try svc.sha512(ofFileAt: missing)
            #expect(Bool(false), "Expected sha512(ofFileAt:) to throw for a missing file")
        } catch CoreError.badInput {
            // Correct typed error.
        } catch {
            #expect(Bool(false), "Expected CoreError.badInput, got \(error)")
        }
    }
}

// MARK: - BSD-name disk lookup

@Suite("DefaultDiskTargetService - BSD-name lookup")
struct DiskLookupTests {

    @Test("A present BSD name returns the matching descriptor")
    func presentNameReturnsDescriptor() {
        let disks = [makeDisk(bsdName: "disk4"), makeDisk(bsdName: "disk5"), makeDisk(bsdName: "disk6")]
        let match = firstDescriptor(withBSDName: "disk5", in: disks)
        #expect(match?.bsdName == "disk5")
    }

    @Test("A non-existent BSD name returns nil")
    func missingNameReturnsNil() {
        let disks = [makeDisk(bsdName: "disk4"), makeDisk(bsdName: "disk5")]
        let match = firstDescriptor(withBSDName: "disk9", in: disks)
        #expect(match == nil)
    }

    @Test("An empty disk list returns nil")
    func emptyListReturnsNil() {
        let match = firstDescriptor(withBSDName: "disk4", in: [])
        #expect(match == nil)
    }
}
