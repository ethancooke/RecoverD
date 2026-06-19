import Foundation
import RecoverDCore

/// A `RawBlockReader` backed by an already-open, read-only file descriptor.
///
/// This is the **no-copy** device path: the fd is typically a privileged descriptor to
/// `/dev/rdiskN` obtained via `authopen` (see `PrivilegedRawDevice`), and every `read` does a
/// single `pread` straight into a `SecureData` that the caller wipes. Nothing is ever copied to
/// the host's storage — unlike the old image-to-`/tmp` approach. Any readable fd works, so tests
/// drive it with a regular file.
///
/// Character devices (`/dev/rdiskN`) require the offset **and** length of every read to be
/// multiples of the block size, so reads are widened to block boundaries and sliced back to the
/// exact requested range. The widened scratch buffer is zeroed before it's freed.
public actor RawFDReader: RawBlockReader {
    private let fd: Int32
    private let totalSizeBytes: Int64
    private let blockSizeBytes: Int
    private let ownsFD: Bool
    private var closed = false

    /// Largest single `pread` issued to the device. Raw devices can reject oversized transfers,
    /// so big reads are looped in aligned segments.
    private let maxTransfer = 8 * 1024 * 1024

    public init(fd: Int32, totalSize: Int64, blockSize: Int, ownsFD: Bool = true) {
        self.fd = fd
        self.totalSizeBytes = totalSize
        self.blockSizeBytes = max(512, blockSize)
        self.ownsFD = ownsFD
    }

    public var totalSize: Int64 { get async { totalSizeBytes } }
    public var blockSize: Int { get async { blockSizeBytes } }

    public func read(at offset: Int64, count: Int) async throws -> SecureData {
        guard !closed else { throw RecoverDError.deviceUnavailable }
        guard count > 0, offset >= 0, offset < totalSizeBytes else { return SecureData(data: Data()) }

        let bs = Int64(blockSizeBytes)
        let want = Int(min(Int64(count), totalSizeBytes - offset))
        let alignedStart = (offset / bs) * bs
        let delta = Int(offset - alignedStart)
        let alignedLen = Int(((Int64(delta + want) + bs - 1) / bs) * bs)

        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: alignedLen, alignment: blockSizeBytes)
        defer {
            if let base = scratch.baseAddress { memset_s(base, alignedLen, 0, alignedLen) }
            scratch.deallocate()
        }

        var got = 0
        while got < alignedLen {
            let chunk = min(alignedLen - got, maxTransfer)
            let n = pread(fd, scratch.baseAddress!.advanced(by: got), chunk, alignedStart + Int64(got))
            if n < 0 {
                let e = errno
                throw RecoverDError.readFailed(offset: offset,
                    cause: "pread errno \(e): \(String(cString: strerror(e)))")
            }
            if n == 0 { break } // EOF / short device
            got += n
        }

        let available = max(0, min(want, got - delta))
        guard available > 0 else { return SecureData(data: Data()) }

        let result = UnsafeMutableRawBufferPointer.allocate(byteCount: available, alignment: 16)
        if let dst = result.baseAddress, let src = scratch.baseAddress {
            dst.copyMemory(from: src.advanced(by: delta), byteCount: available)
        }
        return SecureData(owning: result)
    }

    /// Closes the underlying fd if this reader owns it. Idempotent.
    public func close() {
        guard !closed else { return }
        closed = true
        if ownsFD { Darwin.close(fd) }
    }
}
