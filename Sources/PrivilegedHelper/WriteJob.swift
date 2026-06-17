/// WriteJob.swift -- the raw, block-aligned write of a source image to a device.
///
/// This is the privileged core: it opens the source (via `SourceAccess`), opens
/// the target raw character device `/dev/rdiskN` with `O_RDWR | O_SYNC | O_EXCL`,
/// and streams the bytes in block-aligned chunks. It reports `FlashProgress`
/// through a callback, checks a `CancellationToken` at every chunk boundary, and
/// computes a streaming SHA-512 of exactly the real image bytes (NOT the tail
/// padding) so the digest matches what `VerifyJob` reads back.
///
/// Flag rationale:
///   - O_RDWR  : the raw node is opened read/write (verify reopens read-only).
///   - O_SYNC  : each write is committed to the device before returning, so a
///               reported byte count reflects bytes actually on the media.
///   - O_EXCL  : on a disk device, demands exclusive access; the open fails if
///               any volume is still mounted. This is why `Unmount` runs first.
///
/// Block alignment: full chunks are already a block-size multiple. The final
/// short chunk is zero-padded up to a block boundary before writing (the device
/// requires aligned writes), but only the real bytes feed the hash and count
/// toward `bytesDone`.
///
/// POSIX is used directly (`open`/`read`/`write`/`fcntl`/`close`) because the
/// `O_EXCL`-on-device and raw-node semantics are not exposed through Foundation
/// `FileHandle`.

import Foundation
import Verifier
import HelperProtocol

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

// MARK: - WriteJob

/// Performs one raw device write and returns the streaming digest of the bytes
/// written. A fresh `WriteJob` is used per flash; it holds no shared state.
public struct WriteJob {

    /// ioctl request to query a block device's logical block size. This is the
    /// macOS `DKIOCGETBLOCKSIZE` constant; computed here to avoid importing the
    /// private `<sys/disk.h>` header into Swift.
    ///
    /// _IOR('d', 24, uint32_t): direction READ, group 'd', number 24, 4-byte
    /// payload. Encoded with the standard BSD `_IOC` layout.
    static let dkiocGetBlockSize: UInt = WriteJob.iocRead(
        group: UInt8(ascii: "d"),
        number: 24,
        size: UInt(MemoryLayout<UInt32>.size)
    )

    /// fcntl command to disable the unified buffer cache for this descriptor.
    /// Equivalent to `F_NOCACHE`; used so writes/reads bypass the page cache and
    /// hit the device directly. Value is stable on macOS.
    static let fNoCache: Int32 = 48

    public init() {}

    /// Stream `source` to the raw `device` and return the SHA-512 of the image.
    ///
    /// - Parameters:
    ///   - sourcePath: Absolute path to the source image (resolved from
    ///     `SourceAccess.absolutePath` by the caller).
    ///   - rawDevicePath: The raw target node, for example `"/dev/rdisk4"`.
    ///   - jobID: Correlates emitted progress with the originating request.
    ///   - cancelToken: Checked at each chunk boundary; a set token stops the
    ///     loop and throws `CancellationError`.
    ///   - progress: Invoked after each chunk with cumulative real-byte counts
    ///     and `phase == .writing`. May be called on the calling thread.
    /// - Returns: The streaming SHA-512 digest of the real image bytes written.
    /// - Throws: `HelperError` on open/IO failure, `CancellationError` on cancel.
    public func run(
        sourcePath: String,
        rawDevicePath: String,
        jobID: JobID,
        cancelToken: CancellationToken,
        progress: (FlashProgress) -> Void
    ) throws -> SHA512Digest {
        // Open the source read-only; derive ground-truth length from its size.
        let sourceFD = open(sourcePath, O_RDONLY)
        guard sourceFD >= 0 else {
            throw HelperError.sourceUnavailable(
                detail: sourcePath + ": " + String(cString: strerror(errno))
            )
        }
        defer { close(sourceFD) }
        let imageLength = try fileSize(fd: sourceFD, path: sourcePath)

        // Open the raw target with exclusive, synchronous read/write access. The
        // O_EXCL on a disk node fails unless every volume is already unmounted.
        let deviceFD = open(rawDevicePath, O_RDWR | O_SYNC | O_EXCL)
        guard deviceFD >= 0 else {
            throw HelperError.deviceOpenFailed(path: rawDevicePath, errnoValue: errno)
        }
        defer { close(deviceFD) }

        // Bypass the buffer cache so written bytes go straight to the media.
        _ = fcntl(deviceFD, WriteJob.fNoCache, 1)

        // Determine the device block size; fall back to 512 if the ioctl fails.
        let blockSize = queryBlockSize(deviceFD: deviceFD)
        // The chunk size must be a block-size multiple; the default already is
        // for 512/4096, but round up defensively for unusual block sizes.
        let chunkBytes = BlockMath.roundUp(
            BlockMath.defaultChunkBytes,
            toMultipleOf: blockSize
        )

        let digest = try streamWrite(
            sourceFD: sourceFD,
            deviceFD: deviceFD,
            imageLength: imageLength,
            blockSize: blockSize,
            chunkBytes: chunkBytes,
            jobID: jobID,
            cancelToken: cancelToken,
            progress: progress
        )
        return digest
    }

    // MARK: - Core streaming loop

    /// The block-aligned read/write/hash loop. Factored out so the open/close
    /// resource handling in `run` stays small and this stays focused on the math.
    private func streamWrite(
        sourceFD: Int32,
        deviceFD: Int32,
        imageLength: UInt64,
        blockSize: Int,
        chunkBytes: Int,
        jobID: JobID,
        cancelToken: CancellationToken,
        progress: (FlashProgress) -> Void
    ) throws -> SHA512Digest {
        var hasher = SHA512Hasher()
        var bytesDone: UInt64 = 0

        // Reusable buffer sized for the largest aligned chunk plus tail padding.
        var buffer = [UInt8](repeating: 0, count: chunkBytes)

        while bytesDone < imageLength {
            // Cooperative cancel checkpoint at every chunk boundary.
            if cancelToken.isCancelled {
                throw CancellationError()
            }

            let remaining = Int(imageLength - bytesDone)
            let readLength = BlockMath.nextReadLength(
                bytesRemaining: remaining,
                chunkBytes: chunkBytes
            )

            // Read exactly `readLength` real bytes from the source.
            let realRead = try readExactly(
                fd: sourceFD,
                into: &buffer,
                count: readLength,
                context: "source"
            )
            // A short read before the expected length means the file changed
            // under us; refuse rather than write a truncated image.
            guard realRead == readLength else {
                throw HelperError.ioFailed(
                    detail: "source short read",
                    errnoValue: 0,
                    bytesSoFar: bytesDone
                )
            }

            // Align the on-device write up to a block boundary; zero the pad
            // region so no stale buffer bytes leak onto the device tail.
            let writeLength = BlockMath.paddedLength(
                realBytes: realRead,
                blockSize: blockSize
            )
            if writeLength > realRead {
                for index in realRead..<writeLength {
                    buffer[index] = 0
                }
            }

            try writeExactly(
                fd: deviceFD,
                from: buffer,
                count: writeLength,
                bytesSoFar: bytesDone
            )

            // Hash only the REAL bytes so the digest matches the source image,
            // not the padded tail; the read-back verifier hashes the same span.
            hasher.update(Array(buffer[0..<realRead]))

            bytesDone += UInt64(realRead)

            // Report cumulative real-byte progress for this writing phase.
            let update = FlashProgress(
                jobID: jobID,
                bytesDone: bytesDone,
                totalBytes: imageLength,
                phase: .writing
            )
            progress(update)
        }

        let digest = hasher.finalize()
        return digest
    }

    // MARK: - POSIX helpers

    /// Stat the open source descriptor for its byte length (ground truth).
    private func fileSize(fd: Int32, path: String) throws -> UInt64 {
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw HelperError.sourceUnavailable(
                detail: path + ": fstat " + String(cString: strerror(errno))
            )
        }
        let size = UInt64(info.st_size)
        return size
    }

    /// Read up to `count` bytes into `buffer[0..<count]`, retrying short reads
    /// and `EINTR`. Returns the total bytes read (may be < count only at EOF).
    private func readExactly(
        fd: Int32,
        into buffer: inout [UInt8],
        count: Int,
        context: String
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
                    detail: context + " read",
                    errnoValue: errno,
                    bytesSoFar: UInt64(total)
                )
            }
            if n == 0 {
                // EOF; return what we have so the caller can detect a short read.
                break
            }
            total += n
        }
        return total
    }

    /// Write exactly `count` bytes from `buffer[0..<count]`, retrying short
    /// writes and `EINTR`. Throws on any unrecoverable error.
    private func writeExactly(
        fd: Int32,
        from buffer: [UInt8],
        count: Int,
        bytesSoFar: UInt64
    ) throws {
        var total = 0
        while total < count {
            let want = count - total
            let n = buffer.withUnsafeBytes { raw -> Int in
                let base = raw.baseAddress!.advanced(by: total)
                let result = write(fd, base, want)
                return result
            }
            if n < 0 {
                if errno == EINTR {
                    continue
                }
                throw HelperError.ioFailed(
                    detail: "device write",
                    errnoValue: errno,
                    bytesSoFar: bytesSoFar + UInt64(total)
                )
            }
            total += n
        }
    }

    /// Query the device logical block size via `DKIOCGETBLOCKSIZE`.
    ///
    /// Returns `BlockMath.fallbackBlockSize` when the ioctl fails, so the write
    /// loop always has a safe, power-of-two block size to align to.
    private func queryBlockSize(deviceFD: Int32) -> Int {
        var blockSize: UInt32 = 0
        let result = ioctl(deviceFD, WriteJob.dkiocGetBlockSize, &blockSize)
        if result != 0 || blockSize == 0 {
            return BlockMath.fallbackBlockSize
        }
        return Int(blockSize)
    }

    // MARK: - ioctl encoding

    /// Encode a BSD `_IOR(group, number, size)` ioctl request number.
    ///
    /// Mirrors the C `_IOC` macro: direction bits, payload size, group, number.
    /// Used to build `DKIOCGETBLOCKSIZE` without a bridging header.
    static func iocRead(group: UInt8, number: UInt8, size: UInt) -> UInt {
        // BSD ioctl encoding constants (from <sys/ioccom.h>).
        let iocReadBit: UInt = 0x4000_0000          // IOC_OUT (read into caller)
        let parameterMask: UInt = 0x1FFF             // IOCPARM_MASK (13 bits)
        let groupShift: UInt = 8
        let directionShift: UInt = 16

        let sizeField = (size & parameterMask) << directionShift
        let groupField = UInt(group) << groupShift
        let numberField = UInt(number)
        let request = iocReadBit | sizeField | groupField | numberField
        return request
    }
}
