import Foundation
import RecoverDCore

/// A `RawBlockReader` that caches recently-read, block-aligned regions so the deep-carve scan and
/// the size resolvers (footer/IFD/box/EBML walks) don't read the same bytes off the device twice.
///
/// The resolvers read *forward* from a hit to find the file's end; those are the same bytes the
/// sequential scan reaches a moment later. Caching the overlap turns that double read into one.
///
/// FIFO eviction keeps it bounded; since both the scan and the resolvers move forward, the oldest
/// blocks are the ones already behind the scan. Cached blocks are zeroed when evicted, and the
/// whole cache is wiped when the reader is released (its `SecureData` blocks `deinit`-wipe), so no
/// recovered content lingers beyond the scan.
public actor CachingBlockReader: RawBlockReader {
    private let base: any RawBlockReader
    private let cacheBlock: Int64
    private let maxBytes: Int64
    private let totalSizeBytes: Int64
    private let deviceBlock: Int

    private var blocks: [Int64: SecureData] = [:]
    private var fifo: [Int64] = []
    private var cachedBytes: Int64 = 0
    private var inflight: [Int64: Task<SecureData, Error>] = [:]

    public init(_ base: any RawBlockReader,
                cacheBlock: Int = 4 * 1024 * 1024,
                maxBytes: Int = 256 * 1024 * 1024) async {
        self.base = base
        self.cacheBlock = Int64(cacheBlock)
        self.maxBytes = Int64(maxBytes)
        self.totalSizeBytes = await base.totalSize
        self.deviceBlock = await base.blockSize
    }

    public var totalSize: Int64 { get async { totalSizeBytes } }
    public var blockSize: Int { get async { deviceBlock } }

    public func read(at offset: Int64, count: Int) async throws -> SecureData {
        guard count > 0, offset >= 0, offset < totalSizeBytes else { return SecureData(data: Data()) }
        let want = Int(min(Int64(count), totalSizeBytes - offset))
        // The caller owns and wipes the result, so we always hand back a fresh copy assembled from
        // cached blocks (never the cached buffer itself).
        let out = UnsafeMutableRawBufferPointer.allocate(byteCount: want, alignment: 16)
        if let b = out.baseAddress { memset(b, 0, want) }

        var produced = 0
        var pos = offset
        while produced < want {
            let blockStart = (pos / cacheBlock) * cacheBlock
            let block = try await blockData(blockStart)
            let within = Int(pos - blockStart)
            guard within < block.count else { break } // short device read at EOF
            let take = min(block.count - within, want - produced)
            block.withUnsafeBytes { src in
                if let s = src.baseAddress, let d = out.baseAddress {
                    d.advanced(by: produced).copyMemory(from: s.advanced(by: within), byteCount: take)
                }
            }
            produced += take
            pos += Int64(take)
        }
        return SecureData(owning: out)
    }

    /// Returns the cached block starting at `start`, fetching it once. Concurrent requests for the
    /// same block (e.g. the prefetch and a resolver) share a single in-flight fetch.
    private func blockData(_ start: Int64) async throws -> SecureData {
        if let cached = blocks[start] { return cached }
        if let pending = inflight[start] { return try await pending.value }

        let n = Int(min(cacheBlock, totalSizeBytes - start))
        let base = self.base
        let task = Task { try await base.read(at: start, count: n) }
        inflight[start] = task
        do {
            let block = try await task.value
            inflight[start] = nil
            blocks[start] = block
            fifo.append(start)
            cachedBytes += Int64(block.count)
            while cachedBytes > maxBytes, fifo.count > 1 {
                let oldest = fifo.removeFirst()
                if let evicted = blocks.removeValue(forKey: oldest) {
                    cachedBytes -= Int64(evicted.count)
                    evicted.wipe()
                }
            }
            return block
        } catch {
            inflight[start] = nil
            throw error
        }
    }

    /// Zero and drop all cached blocks. Called when the scan finishes.
    public func purge() {
        for block in blocks.values { block.wipe() }
        blocks.removeAll()
        fifo.removeAll()
        cachedBytes = 0
    }
}
