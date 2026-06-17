/// BlockMathTests.swift - deterministic unit tests for BlockMath pure helpers.
///
/// Coverage:
///   - roundUp: aligned value, unaligned value, edge cases (0, 1, negative).
///   - nextReadLength: normal, remaining < chunk, zero remaining.
///   - paddedLength: full chunks pass through, short chunks are padded.

import Testing
@testable import PrivilegedHelper

// MARK: - roundUp tests

@Suite("BlockMath.roundUp")
struct RoundUpTests {

    @Test("Value already aligned returns unchanged")
    func alreadyAligned() {
        // 4096 is an exact multiple of 4096.
        let result = BlockMath.roundUp(4096, toMultipleOf: 4096)
        #expect(result == 4096)
    }

    @Test("512-byte aligned value at block size returns block size")
    func oneBlock() {
        let result = BlockMath.roundUp(512, toMultipleOf: 512)
        #expect(result == 512)
    }

    @Test("One byte rounds up to a full block")
    func oneByteRoundsToBlock() {
        let result = BlockMath.roundUp(1, toMultipleOf: 512)
        #expect(result == 512)
    }

    @Test("513 bytes rounds up to 1024 (two 512-byte blocks)")
    func unalignedValue() {
        let result = BlockMath.roundUp(513, toMultipleOf: 512)
        #expect(result == 1024)
    }

    @Test("Zero value returns zero regardless of block size")
    func zeroValue() {
        let result = BlockMath.roundUp(0, toMultipleOf: 512)
        #expect(result == 0)
    }

    @Test("Block size of zero is treated as 1 (no alignment)")
    func blockSizeZeroTreatedAsOne() {
        let result = BlockMath.roundUp(7, toMultipleOf: 0)
        #expect(result == 7)
    }

    @Test("Block size of 1 means no alignment; value passes through")
    func blockSizeOne() {
        let result = BlockMath.roundUp(7, toMultipleOf: 1)
        #expect(result == 7)
    }

    @Test("Large value aligned to 4096-byte block")
    func largeValue4096Block() {
        // 8 MiB chunk is already a multiple of 4096.
        let eightMiB = 8 * 1024 * 1024
        let result = BlockMath.roundUp(eightMiB, toMultipleOf: 4096)
        #expect(result == eightMiB)
    }

    @Test("4097 bytes rounds up to 8192 with 4096-byte block")
    func unaligned4096() {
        let result = BlockMath.roundUp(4097, toMultipleOf: 4096)
        #expect(result == 8192)
    }

    @Test("Exactly two blocks stays at two blocks")
    func twoBlocks() {
        let result = BlockMath.roundUp(1024, toMultipleOf: 512)
        #expect(result == 1024)
    }

    @Test("Negative value treated as not positive, returns 0")
    func negativeValueReturnsZero() {
        let result = BlockMath.roundUp(-1, toMultipleOf: 512)
        #expect(result == 0)
    }
}

// MARK: - nextReadLength tests

@Suite("BlockMath.nextReadLength")
struct NextReadLengthTests {

    @Test("Returns chunkBytes when remaining exceeds chunk size")
    func remainingExceedsChunk() {
        let result = BlockMath.nextReadLength(
            bytesRemaining: 100_000_000,
            chunkBytes: BlockMath.defaultChunkBytes
        )
        #expect(result == BlockMath.defaultChunkBytes)
    }

    @Test("Returns bytesRemaining when smaller than chunkBytes")
    func remainingLessThanChunk() {
        let result = BlockMath.nextReadLength(
            bytesRemaining: 1_000,
            chunkBytes: BlockMath.defaultChunkBytes
        )
        #expect(result == 1_000)
    }

    @Test("Returns 0 when bytesRemaining is 0")
    func zeroRemaining() {
        let result = BlockMath.nextReadLength(
            bytesRemaining: 0,
            chunkBytes: BlockMath.defaultChunkBytes
        )
        #expect(result == 0)
    }

    @Test("Returns 1 when both bytesRemaining and chunkBytes are 1")
    func bothOne() {
        let result = BlockMath.nextReadLength(
            bytesRemaining: 1,
            chunkBytes: 1
        )
        #expect(result == 1)
    }

    @Test("Returns chunkBytes when bytesRemaining exactly equals chunkBytes")
    func exactlyEqualToChunk() {
        let chunk = BlockMath.defaultChunkBytes
        let result = BlockMath.nextReadLength(
            bytesRemaining: chunk,
            chunkBytes: chunk
        )
        #expect(result == chunk)
    }

    @Test("chunkBytes of 0 is treated as 1; small remaining is returned")
    func chunkSizeZero() {
        // chunkBytes 0 -> max(0, 1) = 1; min(5, 1) = 1
        let result = BlockMath.nextReadLength(
            bytesRemaining: 5,
            chunkBytes: 0
        )
        #expect(result == 1)
    }
}

// MARK: - paddedLength tests

@Suite("BlockMath.paddedLength")
struct PaddedLengthTests {

    @Test("Full 512-byte block needs no padding")
    func fullBlock512() {
        let result = BlockMath.paddedLength(realBytes: 512, blockSize: 512)
        #expect(result == 512)
    }

    @Test("1-byte real chunk is padded to one full block (512)")
    func oneBytePaddedTo512() {
        let result = BlockMath.paddedLength(realBytes: 1, blockSize: 512)
        #expect(result == 512)
    }

    @Test("511-byte real chunk is padded to one full block (512)")
    func shortChunkPaddedTo512() {
        let result = BlockMath.paddedLength(realBytes: 511, blockSize: 512)
        #expect(result == 512)
    }

    @Test("8 MiB real chunk aligned to 4096 passes through unchanged")
    func fullChunk8MiBWith4096Block() {
        let eightMiB = 8 * 1024 * 1024
        let result = BlockMath.paddedLength(realBytes: eightMiB, blockSize: 4096)
        #expect(result == eightMiB)
    }

    @Test("4097 bytes padded to 8192 with 4096-byte block size")
    func slightlyOver4096() {
        let result = BlockMath.paddedLength(realBytes: 4097, blockSize: 4096)
        #expect(result == 8192)
    }

    @Test("Zero real bytes returns zero (nothing to pad)")
    func zeroBytes() {
        let result = BlockMath.paddedLength(realBytes: 0, blockSize: 512)
        #expect(result == 0)
    }

    @Test("Fallback block size (512) used for alignment")
    func fallbackBlockSize() {
        // defaultChunkBytes is a multiple of fallbackBlockSize; no padding.
        let result = BlockMath.paddedLength(
            realBytes: BlockMath.defaultChunkBytes,
            blockSize: BlockMath.fallbackBlockSize
        )
        #expect(result == BlockMath.defaultChunkBytes)
    }
}

// MARK: - Constants

@Suite("BlockMath constants")
struct BlockMathConstantsTests {

    @Test("defaultChunkBytes is 8 MiB")
    func defaultChunkIs8MiB() {
        #expect(BlockMath.defaultChunkBytes == 8 * 1024 * 1024)
    }

    @Test("fallbackBlockSize is 512")
    func fallbackIs512() {
        #expect(BlockMath.fallbackBlockSize == 512)
    }

    @Test("defaultChunkBytes is a multiple of fallbackBlockSize")
    func chunkIsMultipleOfFallback() {
        #expect(BlockMath.defaultChunkBytes % BlockMath.fallbackBlockSize == 0)
    }

    @Test("defaultChunkBytes is a multiple of 4096 (common device block size)")
    func chunkIsMultipleOf4096() {
        #expect(BlockMath.defaultChunkBytes % 4096 == 0)
    }
}
