/// BlockMath.swift -- pure block-alignment arithmetic for the raw write loop.
///
/// Writing to a raw character device (`/dev/rdiskN`) is fastest and, on some
/// media, only legal when writes are aligned to the device block size. The raw
/// loop reads the source in `blockSize`-multiple chunks and aligns the final
/// (short) chunk up to a block boundary, padding the tail with zero bytes when
/// the image length is not an exact multiple of the block size.
///
/// These helpers are split out as side-effect-free functions so the alignment
/// math is unit-testable without opening a device or touching the filesystem.

import Foundation

// MARK: - BlockMath

/// Namespace for pure block-alignment helpers. No instances are created.
public enum BlockMath {

    /// The default I/O chunk size used when a device does not report one.
    ///
    /// 8 MiB balances syscall overhead against memory use and is a multiple of
    /// every common device block size (512 and 4096), so a buffer of this size
    /// is always block-aligned.
    public static let defaultChunkBytes: Int = 8 * 1024 * 1024

    /// A conservative fallback logical block size when the device cannot be
    /// queried. 512 bytes is the historical sector size and divides every
    /// larger power-of-two block size.
    public static let fallbackBlockSize: Int = 512

    /// Round `value` UP to the next multiple of `blockSize`.
    ///
    /// Used to size the final write so it lands on a block boundary. When
    /// `value` is already a multiple, it is returned unchanged. A `blockSize`
    /// of zero or less is treated as 1 (no alignment) so the function never
    /// divides by zero.
    ///
    /// - Parameters:
    ///   - value: The unaligned byte count (for example a short final chunk).
    ///   - blockSize: The device block size to align to.
    /// - Returns: `value` rounded up to the nearest `blockSize` multiple.
    public static func roundUp(_ value: Int, toMultipleOf blockSize: Int) -> Int {
        // Guard against a non-positive block size; treat it as no alignment.
        guard blockSize > 1 else {
            return max(value, 0)
        }
        guard value > 0 else {
            return 0
        }
        // Ceiling division then multiply gives the next block boundary.
        let blocks = (value + blockSize - 1) / blockSize
        let aligned = blocks * blockSize
        return aligned
    }

    /// Decide how many bytes to read from the source for the next chunk.
    ///
    /// Returns the smaller of the configured chunk size and the bytes that
    /// remain, so the loop never reads past the image length. The returned
    /// value is the count of REAL source bytes for this chunk; tail padding to
    /// a block boundary is computed separately by `paddedLength`.
    ///
    /// - Parameters:
    ///   - bytesRemaining: Real source bytes still to be written.
    ///   - chunkBytes: The preferred chunk size (a block-size multiple).
    /// - Returns: The number of real source bytes to read this iteration.
    public static func nextReadLength(bytesRemaining: Int, chunkBytes: Int) -> Int {
        guard bytesRemaining > 0 else {
            return 0
        }
        let length = min(bytesRemaining, max(chunkBytes, 1))
        return length
    }

    /// Compute the on-device write length for a chunk of `realBytes` real bytes.
    ///
    /// Full-size chunks are already block-aligned, so they pass through. The
    /// final short chunk is rounded up to a block boundary; the caller zero-pads
    /// the difference. Writing the padded length keeps the raw device write
    /// aligned even when the image length is not a block multiple.
    ///
    /// - Parameters:
    ///   - realBytes: Real source bytes in this chunk.
    ///   - blockSize: The device block size.
    /// - Returns: The aligned byte count to actually write to the device.
    public static func paddedLength(realBytes: Int, blockSize: Int) -> Int {
        let padded = roundUp(realBytes, toMultipleOf: blockSize)
        return padded
    }
}
