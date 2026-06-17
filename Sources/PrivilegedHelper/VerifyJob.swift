/// VerifyJob.swift -- read the device back and re-hash to confirm the write.
///
/// After `WriteJob` finishes, the helper does NOT trust that the write loop and
/// the media agree. It re-opens the raw device read-only, disables the buffer
/// cache (`F_NOCACHE`) so stale cached pages cannot mask a bad write, reads back
/// exactly the image length, and streams a fresh SHA-512. The read-back digest
/// is compared against the write-time digest; any divergence is a hard failure.
///
/// The read-back hashes exactly `imageLength` real bytes -- the same span the
/// write loop fed to its hasher -- so a byte-for-byte-correct device yields the
/// identical digest even though the final block on disk may carry zero padding
/// beyond the image length.

import Foundation
import Verifier
import HelperProtocol

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - VerifyJob

/// Re-reads a freshly written device and returns the read-back SHA-512 digest.
public struct VerifyJob {

    public init() {}

    /// Read `imageLength` bytes from the raw `device` and hash them.
    ///
    /// - Parameters:
    ///   - rawDevicePath: The raw target node, for example `"/dev/rdisk4"`.
    ///   - imageLength: The exact number of real image bytes to read back. This
    ///     is the ground-truth length the write phase used, never the advisory.
    ///   - jobID: Correlates emitted progress with the originating request.
    ///   - cancelToken: Checked at each chunk boundary; a set token throws.
    ///   - progress: Invoked after each chunk with cumulative byte counts and
    ///     `phase == .verifying`.
    /// - Returns: The read-back SHA-512 digest of the device's first
    ///   `imageLength` bytes.
    /// - Throws: `HelperError` on open/IO failure, `CancellationError` on cancel.
    public func run(
        rawDevicePath: String,
        imageLength: UInt64,
        jobID: JobID,
        cancelToken: CancellationToken,
        progress: (FlashProgress) -> Void
    ) throws -> SHA512Digest {
        // Re-open read-only; a write handle is not needed to verify.
        let deviceFD = open(rawDevicePath, O_RDONLY)
        guard deviceFD >= 0 else {
            throw HelperError.deviceOpenFailed(path: rawDevicePath, errnoValue: errno)
        }
        defer { close(deviceFD) }

        // Bypass the buffer cache so we read what the media holds, not a cached
        // copy of what we just wrote.
        _ = fcntl(deviceFD, WriteJob.fNoCache, 1)

        let blockSize = queryBlockSize(deviceFD: deviceFD)
        let chunkBytes = BlockMath.roundUp(
            BlockMath.defaultChunkBytes,
            toMultipleOf: blockSize
        )

        let digest = try streamRead(
            deviceFD: deviceFD,
            imageLength: imageLength,
            chunkBytes: chunkBytes,
            jobID: jobID,
            cancelToken: cancelToken,
            progress: progress
        )
        return digest
    }

    // MARK: - Core read loop

    /// Read exactly `imageLength` bytes in chunks, hashing as we go.
    private func streamRead(
        deviceFD: Int32,
        imageLength: UInt64,
        chunkBytes: Int,
        jobID: JobID,
        cancelToken: CancellationToken,
        progress: (FlashProgress) -> Void
    ) throws -> SHA512Digest {
        var hasher = SHA512Hasher()
        var bytesDone: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: chunkBytes)

        while bytesDone < imageLength {
            if cancelToken.isCancelled {
                throw CancellationError()
            }

            let remaining = Int(imageLength - bytesDone)
            let readLength = BlockMath.nextReadLength(
                bytesRemaining: remaining,
                chunkBytes: chunkBytes
            )

            let n = try readChunk(
                fd: deviceFD,
                into: &buffer,
                count: readLength,
                bytesSoFar: bytesDone
            )
            // The device must yield every byte we wrote; a short read here means
            // the media returned less than the image length -- a hard failure.
            guard n == readLength else {
                throw HelperError.ioFailed(
                    detail: "device short read on verify",
                    errnoValue: 0,
                    bytesSoFar: bytesDone
                )
            }

            hasher.update(Array(buffer[0..<n]))
            bytesDone += UInt64(n)

            let update = FlashProgress(
                jobID: jobID,
                bytesDone: bytesDone,
                totalBytes: imageLength,
                phase: .verifying
            )
            progress(update)
        }

        let digest = hasher.finalize()
        return digest
    }

    // MARK: - POSIX helpers

    /// Read up to `count` bytes into `buffer`, retrying short reads and `EINTR`.
    private func readChunk(
        fd: Int32,
        into buffer: inout [UInt8],
        count: Int,
        bytesSoFar: UInt64
    ) throws -> Int {
        var total = 0
        while total < count {
            let want = count - total
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                let base = raw.baseAddress!.advanced(by: total)
                let result = read(fd, base, want)
                return result
            }
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                throw HelperError.ioFailed(
                    detail: "device read",
                    errnoValue: errno,
                    bytesSoFar: bytesSoFar + UInt64(total)
                )
            }
            if n == 0 {
                break
            }
            total += n
        }
        return total
    }

    /// Query the device logical block size, mirroring `WriteJob`'s ioctl.
    private func queryBlockSize(deviceFD: Int32) -> Int {
        var blockSize: UInt32 = 0
        let result = ioctl(deviceFD, WriteJob.dkiocGetBlockSize, &blockSize)
        if result != 0 || blockSize == 0 {
            return BlockMath.fallbackBlockSize
        }
        return Int(blockSize)
    }
}
