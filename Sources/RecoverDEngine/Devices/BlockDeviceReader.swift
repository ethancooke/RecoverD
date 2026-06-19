import Foundation
import RecoverDCore

/// Abstracts raw, block-level reads from a source (a real device via the privileged helper, or
/// a `.dmg`/raw image file for tests). Reading returns `SecureData` so transient *content* is
/// zeroed when the caller is done. The engine never holds raw bytes outside `SecureData`.
public protocol RawBlockReader: Sendable {
    var totalSize: Int64 { get async }
    var blockSize: Int { get async }
    func read(at offset: Int64, count: Int) async throws -> SecureData
}

/// A `RawBlockReader` backed by a local file URL (a `.dmg`, raw image, or — when privileges
/// allow — a `/dev/rdisk*` node). This is the test/no-helper path: it needs no privilege for
/// regular files, making the engine fully exercisable against fixture images.
public actor URLBlockReader: RawBlockReader {
    private let url: URL
    private let totalSizeBytes: Int64
    private let blockSizeBytes: Int
    private let handle: FileHandle?

    public init(url: URL, blockSize: Int = 512) async throws {
        self.url = url
        self.handle = try FileHandle(forReadingFrom: url)
        let endOffset = try self.handle?.seekToEnd() ?? 0
        try? self.handle?.seek(toOffset: 0)
        self.totalSizeBytes = Int64(endOffset)
        self.blockSizeBytes = blockSize
    }

    public var totalSize: Int64 { get async { totalSizeBytes } }
    public var blockSize: Int { get async { blockSizeBytes } }

    public func read(at offset: Int64, count: Int) async throws -> SecureData {
        guard let handle else { throw RecoverDError.deviceUnavailable }
        guard count > 0 else { return SecureData(data: Data()) }
        let clamped = max(0, offset)
        try handle.seek(toOffset: UInt64(clamped))
        let data = (try handle.read(upToCount: count)) ?? Data()
        return SecureData(data: data)
    }
}

extension URLBlockReader {
    public var sourceURL: URL { url }
}
